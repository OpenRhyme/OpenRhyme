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
    /// attempt without actually waiting. `attempts < 1` is treated as `1` (always try at least
    /// once) rather than trapping on an invalid `1...0` range.
    static func retryOnBusy<T>(
        attempts: Int = 3, initialDelay: Duration = .milliseconds(300),
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        _ operation: () async throws -> T
    ) async throws -> T {
        let attempts = max(attempts, 1)
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

    /// Retries an operation that reports contention by returning `false` rather than throwing —
    /// `EventStore.checkpointTruncate()`'s `busy` result — with the same short backoff as
    /// `retryOnBusy`. Returns `false` (never throws for contention) once attempts are exhausted.
    static func retryUntilTrue(
        attempts: Int = 3, initialDelay: Duration = .milliseconds(300),
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        _ operation: () async throws -> Bool
    ) async throws -> Bool {
        let attempts = max(attempts, 1)
        var delay = initialDelay
        for attempt in 1...attempts {
            if try await operation() { return true }
            guard attempt < attempts else { return false }
            try? await sleep(delay)
            delay *= 2
        }
        return false
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
    ///
    /// Chunks are not wrapped in one transaction spanning the whole selection, deliberately: a
    /// single all-or-nothing transaction over a large purge would hold a write lock for as long
    /// as the purge takes, starving the daemon's own writes exactly when it must not be blocked.
    /// Id-based deletion is naturally resumable instead — a later purge (or retry) of the same
    /// selection just finds fewer rows left to remove.
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

    /// Runs `vacuum` then `checkpoint`, each with its own retry budget, and never throws: either
    /// step failing to fully complete just means the content is not yet reclaimed from disk,
    /// which the caller reports as `vacuumed: false` rather than as an operation failure. Returns
    /// `true` only when both genuinely completed, plus a human-readable reason when they didn't.
    private static func attemptVacuumAndCheckpoint(
        attempts: Int, sleep: (Duration) async throws -> Void,
        vacuum: () async throws -> Void, checkpoint: () async throws -> Bool
    ) async -> (reclaimed: Bool, detail: String) {
        do {
            try await retryOnBusy(attempts: attempts, sleep: sleep) { try await vacuum() }
        } catch {
            return (false, "VACUUM did not complete (\(error))")
        }
        do {
            let checkpointed = try await retryUntilTrue(attempts: attempts, sleep: sleep) {
                try await checkpoint()
            }
            guard checkpointed else {
                return (
                    false,
                    "the WAL checkpoint stayed busy — another connection (likely the daemon) is "
                        + "still holding the database open"
                )
            }
            return (true, "")
        } catch {
            return (false, "the WAL checkpoint failed (\(error))")
        }
    }

    /// The destructive half of a purge: delete the selection, then reclaim the freed pages.
    /// Injectable `delete`/`vacuum`/`checkpoint` so the lock-retry and incomplete-reclaim paths
    /// are unit-testable without racing a real SQLite lock.
    ///
    /// Every way this can finish short of "deleted everything asked for and reclaimed it from
    /// disk" throws, carrying `matched`/`deleted`/`vacuumed` as structured `CLIError.data` (so a
    /// script reading `ok: false` is never left guessing what state that left the store in) and
    /// a human message that says exactly what did and did not happen. A vacuum/checkpoint that
    /// never completes is not housekeeping — the rows are already gone from the table, but
    /// SQLite's free pages (and, until checkpointed, the WAL) still hold their plaintext content,
    /// recoverable with a hex editor — so it is reported as a failed purge (non-zero, `ok:
    /// false`), even though real, correct deletion happened.
    static func destroy(
        selected: [RawEvent], deleteAttempts: Int = 3, vacuumAttempts: Int = 3,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        delete: ([Int64]) async throws -> Int,
        vacuum: () async throws -> Void,
        checkpoint: () async throws -> Bool
    ) async throws -> Result {
        let matched = selected.count
        let deleted: Int
        do {
            deleted = try await deleteWithRetry(
                ids: selected.compactMap(\.id), attempts: deleteAttempts, sleep: sleep,
                delete: delete)
        } catch let failure as PartialDeleteFailure {
            guard isLockedError(failure.underlying) else { throw failure.underlying }
            // F2: a partial delete still leaves real, deleted-but-unreclaimed content behind —
            // attempt to reclaim it too, and say plainly whether that succeeded.
            let (reclaimed, detail) = await attemptVacuumAndCheckpoint(
                attempts: vacuumAttempts, sleep: sleep, vacuum: vacuum, checkpoint: checkpoint)
            throw CLIError(
                code: "database_locked",
                message: lockedMessage(
                    failure: failure, matched: matched, reclaimed: reclaimed, detail: detail),
                hint: "Wait for other openrhyme activity to finish, then re-run purge",
                exitCode: 1,
                data: purgeData(matched: matched, deleted: failure.deleted, vacuumed: reclaimed))
        }

        let (reclaimed, detail) = await attemptVacuumAndCheckpoint(
            attempts: vacuumAttempts, sleep: sleep, vacuum: vacuum, checkpoint: checkpoint)
        guard reclaimed else {
            throw CLIError(
                code: "vacuum_incomplete",
                message: incompleteVacuumMessage(
                    deleted: deleted, matched: matched, detail: detail),
                hint:
                    "Re-run `openrhyme purge` (with --yes) to retry, or run `sqlite3 <database> "
                    + "'VACUUM; PRAGMA wal_checkpoint(TRUNCATE);'` directly",
                exitCode: 1,
                data: purgeData(matched: matched, deleted: deleted, vacuumed: false))
        }
        return Result(matched: matched, deleted: deleted, vacuumed: true, dryRun: false)
    }

    private static func purgeData(matched: Int, deleted: Int, vacuumed: Bool) -> JSONValue {
        [
            "matched": .number(Double(matched)), "deleted": .number(Double(deleted)),
            "vacuumed": .bool(vacuumed),
        ]
    }

    private static func lockedMessage(
        failure: PartialDeleteFailure, matched: Int, reclaimed: Bool, detail: String
    ) -> String {
        guard failure.deleted > 0 else {
            return
                "The database stayed locked after retrying; none of the \(matched) matching "
                + "row(s) were deleted. Nothing changed."
        }
        let remaining = matched - failure.deleted
        let base =
            "The database stayed locked after retrying: \(failure.deleted) of \(matched) "
            + "matching row(s) were deleted before that, but \(remaining) row(s) were not. "
            + "Re-run purge to finish removing the rest."
        guard !reclaimed else { return base }
        return
            base
            + " Rows already removed from the table may still be recoverable on disk until a "
            + "successful VACUUM (\(detail))."
    }

    private static func incompleteVacuumMessage(
        deleted: Int, matched: Int, detail: String
    )
        -> String
    {
        "purge deleted \(deleted) of \(matched) matching row(s), but VACUUM did not complete: "
            + "\(detail). That deleted content is NOT actually removed from disk yet — it can "
            + "still be recovered until a VACUUM and checkpoint succeed. Re-run `openrhyme "
            + "purge` (with --yes) to retry, or run `sqlite3 <database> 'VACUUM; PRAGMA "
            + "wal_checkpoint(TRUNCATE);'` directly."
    }

    func run() async throws {
        try await runJSON(json: json, human: Self.humanLines) {
            // Checked inside the JSON-wrapped body (not before it) so this reports through the
            // same envelope/exit-code path as every other usage error, in both --json and human
            // mode. `--all` and an empty filter set are deliberately not the same thing: with no
            // filters at all, purging everything must be asked for explicitly.
            guard
                all || since != nil || until != nil || app != nil || urlContains != nil
                    || applyRules
            else {
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

            // A dry run must be genuinely read-only: opening read-write would create the
            // database (and its directory) even when nothing exists yet to report on.
            let store = try EventStore(url: paths.databaseURL, readOnly: dryRun)
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

            let result = try await Self.destroy(
                selected: selected,
                delete: { try await store.deleteEvents(ids: $0) },
                vacuum: { try await store.vacuum() },
                checkpoint: { try await store.checkpointTruncate() })
            await store.close()
            return result
        }
    }

    static func humanLines(_ result: Result) -> String {
        if result.dryRun {
            return "\(result.matched) row(s) would be deleted (dry run; nothing changed)"
        }
        // `destroy` throws rather than returning when reclaiming didn't fully complete, so a
        // `Result` reaching here always has `vacuumed == true` — this stays defensive rather
        // than assuming that invariant.
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
