import ArgumentParser
import Capture
import Core
import Foundation
import Store

/// Spec privacy §5.7. Destructive by explicit consent only: without `--dry-run` or `--yes` it
/// reports what it would delete and exits 2. Deleting on demand must never be gated behind
/// stopping the daemon first, so a live daemon only earns a warning, never a refusal.
struct PurgeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "purge",
        abstract: "Delete stored events by time, app, URL, or the current privacy rules.")

    @Option(name: .long, help: "Start time: 2h, 30m, unix seconds, or ISO-8601 (default: all).")
    var since: String?
    @Option(name: .long, help: "End time (same grammar).") var until: String?
    @Option(name: .long, help: "Bundle identifier filter.") var app: String?
    @Option(name: .long, help: "Delete rows whose URL or document contains this substring.")
    var urlContains: String?
    @Flag(name: .long, help: "Delete rows the current privacy rules would protect.")
    var applyRules = false
    @Flag(name: .long, help: "Delete every stored event.") var all = false
    @Flag(name: .long, help: "Report what would be deleted and change nothing.") var dryRun = false
    @Flag(name: .long, help: "Confirm deletion (required for a real purge).") var yes = false
    @Flag(name: .long, help: "Emit a JSON envelope.") var json = false

    struct Result: Encodable {
        let matched: Int
        let deleted: Int
        let vacuumed: Bool
        let dryRun: Bool
    }

    /// Pure selection so the matching rules are testable without a store. `--apply-rules`
    /// evaluates the real `PrivacyPolicy`, so there is never a second matcher to drift. Stored
    /// protected-context marker rows carry no url/document/title (privacy §5.5): `compactMap`
    /// simply drops those from the URL/document haystack rather than treating a missing field
    /// as a match, and `evaluateContext` sees the same nils it would for a live context.
    static func select(
        events: [RawEvent], app: String?, urlContains: String?, applyRules: Bool,
        policy: PrivacyPolicy
    ) -> [RawEvent] {
        events.filter { event in
            if let app, event.bundleID != app { return false }
            if let needle = urlContains?.lowercased() {
                let haystack = [event.url, event.document].compactMap { $0?.lowercased() }
                guard haystack.contains(where: { $0.contains(needle) }) else { return false }
            }
            if applyRules {
                guard
                    case .protected = policy.evaluateContext(
                        bundleID: event.bundleID, windowTitle: event.windowTitle,
                        document: event.document, url: event.url)
                else { return false }
            }
            return true
        }
    }

    /// Pages through the store with `afterID` — never plain `ts` ordering — so a selection
    /// larger than `EventQuery.maxLimit` is never silently truncated, and a non-monotonic
    /// timestamp can never let a row slip past the cursor. `afterID` starts at `0` (ids are
    /// 1-based) so even the first page is id-ordered; see `ExportCommand`, which pages the same
    /// way for the same reason. `pageLimit` defaults to the real max and is only overridden in
    /// tests, to exercise the loop without seeding tens of thousands of rows.
    static func fetchAllCandidates(
        store: EventStore, since: Double, until: Double?, pageLimit: Int = EventQuery.maxLimit
    ) async throws -> [RawEvent] {
        var all: [RawEvent] = []
        var afterID: Int64? = 0
        while true {
            let page = try await store.query(
                EventQuery(since: since, until: until, limit: pageLimit, afterID: afterID))
            all += page
            guard page.count == pageLimit, let last = page.last?.id else { break }
            afterID = last
        }
        return all
    }

    // MARK: - Locked-database handling (spec privacy §5.7)
    //
    // "`purge` on a locked database retries briefly then exits non-zero with a clear message
    // rather than partially deleting." SQLite's own `busy_timeout` (2s, set on every read-write
    // connection) already retries a single blocked statement internally, but a long-held write
    // lock — a concurrent VACUUM, measured at ~2.09s — can outlast that. These helpers add one
    // more, short, application-level retry on top before giving up.

    /// sqlite3.h: `SQLITE_BUSY` = 5 ("the database file is locked"), `SQLITE_LOCKED` = 6 ("a
    /// table in the database is locked"). Hardcoded rather than importing SQLite3 into this
    /// target: `DatabaseError` already carries the raw code as an `Int32`, and masking to the
    /// low byte also matches an extended result code, should those ever be turned on.
    private static let sqliteBusy: Int32 = 5
    private static let sqliteLocked: Int32 = 6

    static func isLockedError(_ error: Error) -> Bool {
        guard let dbError = error as? DatabaseError else { return false }
        let primary = dbError.code & 0xff
        return primary == sqliteBusy || primary == sqliteLocked
    }

    /// Retries a transient lock briefly with exponential backoff; any other error, or the last
    /// attempt's error, propagates immediately. `sleep` is injectable so tests can exhaust every
    /// attempt without actually waiting.
    static func retryOnBusy<T>(
        attempts: Int = 3, initialDelay: Duration = .milliseconds(300),
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        _ operation: () async throws -> T
    ) async throws -> T {
        var delay = initialDelay
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                guard isLockedError(error), attempt < attempts else { break }
                try? await sleep(delay)
                delay *= 2
            }
        }
        throw lastError!
    }

    /// Thrown when a chunk of a multi-chunk delete fails after exhausting its retries: carries
    /// how many rows were confirmed deleted by earlier chunks so the caller never has to guess
    /// between "deleted everything" and "deleted nothing" — it always knows exactly how far the
    /// purge got.
    struct PartialDeleteFailure: Error {
        let deleted: Int
        let underlying: Error
    }

    /// Deletes `ids` in the same ≤500-row chunks `EventStore.deleteEvents` uses internally, but
    /// retries each chunk independently so one chunk's failure can never lose the count of
    /// chunks already committed. A retry re-submits the same id list, which is always safe:
    /// deleting an id a second time (already gone from an earlier, successful attempt) matches
    /// zero rows and changes nothing.
    static func deleteWithRetry(
        ids: [Int64], attempts: Int = 3,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        delete: ([Int64]) async throws -> Int
    ) async throws -> Int {
        var deleted = 0
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            do {
                deleted += try await retryOnBusy(attempts: attempts, sleep: sleep) {
                    try await delete(chunk)
                }
            } catch {
                throw PartialDeleteFailure(deleted: deleted, underlying: error)
            }
        }
        return deleted
    }

    /// What actually happened after delete + vacuum. `vacuumWarning` is non-nil exactly when
    /// `result.vacuumed` is false, and is reported by the caller (never printed from here, so
    /// this stays pure and testable with no real stderr involved).
    struct DestroyOutcome {
        let result: Result
        let vacuumWarning: String?
    }

    /// The destructive half of a purge: delete the selection, then reclaim the freed pages.
    /// Injectable `delete`/`vacuum` so the lock-retry and vacuum-failure paths are unit-testable
    /// without racing a real SQLite lock.
    ///
    /// A vacuum failure is reported very differently from a delete failure. A delete that never
    /// completes is a no-op the user can safely retry, so it throws and stops. A vacuum that
    /// fails *after* a successful delete is not: the rows are already gone from the table, and a
    /// VACUUM is what actually removes deleted content from the file — until it succeeds, that
    /// content survives in SQLite's free pages and is recoverable with a hex editor. That is a
    /// privacy property, not housekeeping, so this never reports an unqualified success when it
    /// happens: `vacuumed` comes back false and `vacuumWarning` explains what to do next.
    static func destroy(
        selected: [RawEvent], deleteAttempts: Int = 3, vacuumAttempts: Int = 3,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        delete: ([Int64]) async throws -> Int,
        vacuum: () async throws -> Void
    ) async throws -> DestroyOutcome {
        let matched = selected.count
        let deleted: Int
        do {
            deleted = try await deleteWithRetry(
                ids: selected.compactMap(\.id), attempts: deleteAttempts, sleep: sleep,
                delete: delete)
        } catch let failure as PartialDeleteFailure {
            guard isLockedError(failure.underlying) else { throw failure.underlying }
            throw CLIError(
                code: "database_locked",
                message: lockedMessage(failure: failure, matched: matched),
                hint: "Wait for other openrhyme activity to finish, then re-run purge",
                exitCode: 1)
        }

        do {
            try await retryOnBusy(attempts: vacuumAttempts, sleep: sleep) { try await vacuum() }
        } catch {
            return DestroyOutcome(
                result: Result(matched: matched, deleted: deleted, vacuumed: false, dryRun: false),
                vacuumWarning: vacuumFailureWarning(
                    deleted: deleted, matched: matched, error: error)
            )
        }
        return DestroyOutcome(
            result: Result(matched: matched, deleted: deleted, vacuumed: true, dryRun: false),
            vacuumWarning: nil)
    }

    private static func lockedMessage(failure: PartialDeleteFailure, matched: Int) -> String {
        guard failure.deleted > 0 else {
            return
                "The database stayed locked after retrying; none of the \(matched) matching "
                + "row(s) were deleted. Nothing changed."
        }
        let remaining = matched - failure.deleted
        return
            "The database stayed locked after retrying: \(failure.deleted) of \(matched) "
            + "matching row(s) were deleted before that, but \(remaining) row(s) were not. "
            + "Re-run purge to finish removing the rest."
    }

    private static func vacuumFailureWarning(deleted: Int, matched: Int, error: Error) -> String {
        "warning: purge deleted \(deleted) of \(matched) matching row(s), but VACUUM did not "
            + "complete (\(error)). That deleted content is NOT actually removed from disk yet — "
            + "it can still be recovered from SQLite's free pages until a VACUUM succeeds. "
            + "Re-run `openrhyme purge` (with --yes) to retry the VACUUM, or run "
            + "`sqlite3 <database> VACUUM` directly."
    }

    func run() async throws {
        try await runJSON(json: json, human: Self.humanLines) {
            // Checked inside the JSON-wrapped body (not before it) so this reports through the
            // same envelope/exit-code path as every other usage error, in both --json and human
            // mode. `--all` and an empty filter set are deliberately not the same thing: with no
            // filters at all, purging everything must be asked for explicitly.
            guard all || since != nil || app != nil || urlContains != nil || applyRules else {
                throw CLIError.usage(
                    "Specify what to purge: --since/--until, --app, --url-contains, --apply-rules, or --all"
                )
            }
            let paths = Paths.resolve()
            let config = try Config.load(from: paths.configURL)
            let policy = PrivacyPolicy(settings: config.privacy)

            // Spec privacy §5.7: the one operation that removes sensitive data on demand must
            // never be gated behind "stop your daemon first" — so a live daemon only earns a
            // warning, never a refusal.
            if let livePID = PIDFile(url: paths.pidFileURL).livePID {
                Output.stderr(
                    "warning: openrhyme daemon (pid \(livePID)) is currently running and may "
                        + "write events concurrently with this purge; proceeding anyway")
            }

            let store = try EventStore(url: paths.databaseURL, readOnly: false)
            let sinceTS = try since.map { try TimeSpec.parse($0) } ?? 0
            let untilTS = try until.map { try TimeSpec.parse($0) }
            let candidates = try await Self.fetchAllCandidates(
                store: store, since: sinceTS, until: untilTS)
            let selected = Self.select(
                events: candidates, app: app, urlContains: urlContains, applyRules: applyRules,
                policy: policy)

            guard !dryRun else {
                await store.close()
                return Result(matched: selected.count, deleted: 0, vacuumed: false, dryRun: true)
            }
            guard yes else {
                throw CLIError(
                    code: "confirmation_required",
                    message: "\(selected.count) rows match; deletion is permanent",
                    hint: "Re-run with --yes to delete, or --dry-run to see the selection",
                    exitCode: 2)
            }

            let outcome = try await Self.destroy(
                selected: selected,
                delete: { try await store.deleteEvents(ids: $0) },
                vacuum: { try await store.vacuum() })
            if let warning = outcome.vacuumWarning { Output.stderr(warning) }
            await store.close()
            return outcome.result
        }
    }

    static func humanLines(_ result: Result) -> String {
        if result.dryRun {
            return "\(result.matched) row(s) would be deleted (dry run; nothing changed)"
        }
        guard result.vacuumed else {
            return
                "deleted \(result.deleted) of \(result.matched) matching row(s) — WARNING: "
                + "VACUUM did not complete, so that content can still be recovered from disk "
                + "until a VACUUM succeeds; re-run `openrhyme purge` (with --yes) to retry it, "
                + "or run `sqlite3 <database> VACUUM` directly"
        }
        return "deleted \(result.deleted) of \(result.matched) matching row(s); database vacuumed"
    }
}
