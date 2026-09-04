import ArgumentParser
import Capture
import Core
import Foundation
import Store
import os

struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon", abstract: "Run capture in the foreground until SIGINT/SIGTERM.")

    @Flag(name: .long, help: "Do not show the Accessibility permission dialog.") var noPrompt =
        false
    @Flag(name: .long, help: "Log every stored event to stderr.") var verbose = false
    @Flag(name: .long, help: "Report startup failures as a JSON envelope.") var json = false

    func run() async throws {
        do {
            try await runDaemon()
        } catch {
            let cli = Output.cliError(error)
            if json { print(Output.envelope(cli)) } else { Output.stderr("error: \(cli.message)") }
            throw ExitCode(cli.exitCode)
        }
    }

    /// Everything that touches AX lives on the main actor; the store is an actor of its own.
    @MainActor
    private func runDaemon() async throws {
        // Installed first so a signal arriving during startup is latched, not lost to the
        // default terminate action.
        let waiter = SignalWaiter(signals: [SIGINT, SIGTERM])
        let logger = Logger(subsystem: "org.openrhyme.engine", category: "daemon")
        let paths = Paths.resolve()
        try paths.ensureDataDir()
        let config = try Config.load(from: paths.configURL)
        let pidfile = PIDFile(url: paths.pidFileURL)
        do {
            try pidfile.acquire()
        } catch let error as PIDFileError {
            throw CLIError(
                code: "daemon_already_running",
                message: "A daemon is already running (pid \(error.runningPID))",
                hint: "Stop it first, or remove \(paths.pidFileURL.path) if that pid is stale")
        }
        defer { pidfile.release() }

        let store = try EventStore(url: paths.databaseURL)
        let client = AXClient()
        if !client.isTrusted(prompt: !noPrompt) {
            Output.stderr(
                "Accessibility permission missing — enable it for the app that runs openrhyme in System Settings → Privacy & Security → Accessibility. Capture starts automatically once granted."
            )
        }
        let capturer = Capturer(ax: client, paths: paths, config: config)

        // Privacy fix round 1, J1: `os.Logger` string interpolation redacts any non-literal
        // value by default (renders as `<private>`), which made every retention log message —
        // including the ones warning that deleted content is NOT yet reclaimed from disk —
        // unreadable in Console.app. `privacy: .public` is safe here: every message this daemon
        // logs about retention is itself just counts, kind names and timestamps, never captured
        // user content. Also echoed to stderr (J1's second half) so a sweep is visible without
        // opening Console.app at all — matching how every other daemon event is already reported.
        let onInfo: @Sendable (String) -> Void = { message in
            logger.info("\(message, privacy: .public)")
            Output.stderr(message)
        }
        let onError: @Sendable (String) -> Void = { message in
            logger.error("\(message, privacy: .public)")
            Output.stderr("error: \(message)")
        }
        let onWarn: @Sendable (String) -> Void = { message in
            logger.warning("\(message, privacy: .public)")
            Output.stderr("warning: \(message)")
        }

        // Spec privacy §5.8/§7.7: sweep the retention window on start, before capture begins,
        // then re-checked every 24h for the life of the process (`runPeriodicRetentionSweeps`
        // below). Reclaims the space the same way `purge` does (VACUUM + an explicit WAL
        // checkpoint) — see `runRetentionSweep`'s doc comment for why the checkpoint cannot be
        // skipped. Never throws: a sweep failure must not take down the daemon or wedge the
        // capture loop that hasn't even started yet.
        let retentionDays = config.capture.retentionDays
        // Privacy fix round 1, safeguard: warn once, loudly, when the value on disk exists but
        // could not be parsed into a whole number (e.g. a quoted `"30"`) — silently falling back
        // to `0` (off) with no signal at all is exactly the kind of thing a user who set this
        // specifically to stop losing data would never discover on their own.
        if config.capture.retentionDaysInvalid {
            onWarn(
                "capture.retention_days in config.json is not a valid whole number (e.g. it's a "
                    + "quoted string) — retention is OFF until it's fixed to a bare integer")
        }
        await Self.runStartupRetentionSweep(
            retentionDays: retentionDays, now: Date().timeIntervalSince1970,
            previousDaemonStarted: { try await Self.mostRecentDaemonStarted(store: store) },
            countEligible: {
                try await store.countEvents(olderThan: $0, excludingKinds: Self.auditTrailKinds)
            },
            sweepNow: { days in
                await Self.sweepNow(
                    retentionDays: days, store: store, onInfo: onInfo, onError: onError)
            },
            onInfo: onInfo)

        // Spec privacy §5.8: "daemon.started" records the posture in force, so an auditor
        // reading history later can tell whether redaction was even switched on over a given
        // stretch — rather than only being able to infer it from what is (or isn't) missing.
        // `protectedRules` counts every configured rule entry across all five protect-rule
        // categories (bundle ids, URL/document/window-title patterns, credential field names)
        // that can actually fire right now: `0` whenever `privacy.enabled` is false, since a
        // disabled policy evaluates every context as open regardless of how many patterns are
        // configured — the count must describe enforcement in force, not configuration on disk.
        // `enabled` is carried alongside it (privacy fix round 1, J6): a fully-enabled policy
        // with every rule removed and a fully-disabled policy both count `0` protected rules,
        // but redaction/the credential guard are live in the first and dead in the second —
        // `protectedRules` alone cannot tell those apart, `enabled` can.
        let policy = PrivacyPolicy(settings: config.privacy)
        let protectedRules =
            policy.enabled
            ? policy.protectedBundleIDs.count + policy.protectedURLPatterns.count
                + policy.protectedDocumentPatterns.count
                + policy.protectedWindowTitlePatterns.count
                + policy.credentialFieldPatterns.count
            : 0

        try await store.append(
            RawEvent(
                ts: Date().timeIntervalSince1970, kind: .daemonStarted,
                extra: [
                    "version": .string(EngineVersion.string),
                    "schema": .number(Double(Schema.version)),
                    "allowlist": .array(config.allowlist.map(JSONValue.string)),
                    "privacy": .object([
                        "enabled": .bool(policy.enabled),
                        "protectedRules": .number(Double(protectedRules)),
                        "retentionDays": .number(Double(retentionDays)),
                    ]),
                ]))
        let allowed =
            config.allowlist.isEmpty
            ? "(none — run `openrhyme apps allow <bundle-id>`)"
            : config.allowlist.joined(separator: ", ")
        Output.stderr(
            "openrhyme daemon \(EngineVersion.string) — data dir \(paths.dataDir.path); allowlisted: \(allowed)"
        )

        // The consumer runs off the main thread; `events`, `store` and `logger` are Sendable.
        let events = capturer.events
        let verbose = self.verbose
        let consumer = Task.detached {
            for await event in events {
                do {
                    try await Self.appendWithRetry { try await store.append(event) }
                    if verbose { Output.stderr("\(event.kind.rawValue) \(event.bundleID ?? "")") }
                } catch {
                    logger.error("store append failed after retries: \(String(describing: error))")
                }
            }
        }
        capturer.start()

        // Spec privacy §5.8: re-checked every 24h for the life of the process, not just on
        // start — `runPeriodicRetentionSweeps` re-reads `capture.retention_days` from disk on
        // every tick (privacy fix round 1, J2) rather than the value captured at daemon start,
        // so turning retention off (or on, or to a different window) takes effect within one
        // interval instead of requiring a restart. Always spawned, even when retention starts
        // off, so turning it *on* later is picked up the same way — the loop itself costs one
        // sleeping task and one config read per day either way.
        let sweepTask = Task.detached {
            await Self.runPeriodicRetentionSweeps(
                currentRetentionDays: { Self.loadRetentionDays(paths: paths, onWarn: onWarn) },
                sweep: { days in
                    _ = await Self.sweepNow(
                        retentionDays: days, store: store, onInfo: onInfo, onError: onError)
                })
        }

        let sig = await waiter.wait()
        logger.info("signal \(sig) received, stopping")
        capturer.stop()
        await consumer.value
        sweepTask.cancel()
        await sweepTask.value
        try await store.append(RawEvent(ts: Date().timeIntervalSince1970, kind: .daemonStopped))
        await store.close()
        Output.stderr("stopped")
    }

    /// A concurrent long-running write elsewhere (`purge`'s VACUUM, measured at ~2.09s) can hold
    /// the write lock past SQLite's own 2s `busy_timeout`, so a bare `store.append` can transiently
    /// fail even though nothing is really wrong with the store. Dropping it immediately on the
    /// first failure silently and permanently loses the event; retrying forever would risk
    /// blocking shutdown. This is bounded on both ends: a few attempts with a short backoff, then
    /// give up and let the caller log the failure.
    static func appendWithRetry(
        attempts: Int = 3, initialDelay: Duration = .milliseconds(250),
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        _ append: () async throws -> Void
    ) async throws {
        let attempts = max(attempts, 1)
        var delay = initialDelay
        for attempt in 1...attempts {
            do {
                try await append()
                return
            } catch {
                guard attempt < attempts else { throw error }
                try? await sleep(delay)
                delay *= 2
            }
        }
    }

    // MARK: - Retention sweep (spec privacy §5.8/§7.7)

    /// Kinds the automatic retention sweep never deletes (privacy fix round 1, J5). They carry
    /// no captured user content — only configuration/permission posture — are tiny, and are the
    /// evidence that answers "was redaction on when this stretch of history was captured?",
    /// which retention makes *more* valuable to keep, not less. `openrhyme purge` (explicit,
    /// user-confirmed deletion) is not subject to this exemption — only the unattended sweep is.
    static let auditTrailKinds: Set<EventKind> = [
        .daemonStarted, .daemonStopped, .permissionChanged,
    ]

    /// How a retention sweep attempt ended, for tests — the daemon itself only ever consults
    /// `onInfo`/`onError`, never this return value.
    enum RetentionSweepOutcome: Equatable {
        /// `retentionDays <= 0`: retention is off, nothing was touched.
        case skipped
        /// Ran, but nothing was old enough to remove — no reclaim was attempted (mirrors
        /// `PurgeCommand`'s N1/N2: a no-op delete has nothing to reclaim, so running
        /// VACUUM/checkpoint anyway would just push retained plaintext through the WAL).
        case noRowsToSweep
        /// Rows were deleted and the space was fully reclaimed from disk (VACUUM + a completed
        /// checkpoint).
        case reclaimed(removed: Int)
        /// The delete itself failed (e.g. exhausted its lock retries).
        case deleteFailed
        /// Rows were deleted but VACUUM and/or the WAL checkpoint did not fully complete — the
        /// deleted content's plaintext may still be recoverable on disk until a later sweep (or
        /// `openrhyme purge`) succeeds.
        case reclaimIncomplete(removed: Int)
        /// Privacy fix round 1, J3: the computed cutoff was newer than the newest stored event,
        /// the signature of a wrong system clock. Refused outright; nothing was touched.
        case refusedClockSkew
        /// Could not determine whether sweeping was safe (the newest-event check itself failed);
        /// nothing was touched.
        case precheckFailed
        /// Privacy fix round 1, safeguard (spec §2/§7.3 pattern): the first sweep after
        /// `retention_days` went from off to a real value was skipped so the user can review
        /// what it would delete first. Carries how many rows would have gone.
        case firstEnableReviewSkipped(count: Int)
    }

    /// Spec privacy §5.8/§7.7. Deletes events older than `retentionDays` and reclaims the freed
    /// space the *same way `purge` does*: `VACUUM` followed by an explicit
    /// `PRAGMA wal_checkpoint(TRUNCATE)`, each with `PurgeCommand`'s bounded lock-retry.
    ///
    /// This step exists because of a defect first found in `purge`, and the retention sweep has
    /// the identical exposure: in WAL mode `VACUUM` rewrites the database *into the WAL*, not
    /// into `events.sqlite` itself — that only happens at a checkpoint, which SQLite normally
    /// only runs automatically when the *last* connection to the database closes. The daemon
    /// holds its own connection open for the entire life of the process, so that automatic,
    /// close-time checkpoint never fires here; without the explicit call below, a sweep would
    /// report rows "removed" while their plaintext silently persisted in the file. An idle
    /// second connection (another CLI command opening the store read-only, say) does not block
    /// an explicit `TRUNCATE` checkpoint — only an active read transaction elsewhere does — so
    /// this succeeds in the situations that would defeat the automatic, close-time checkpoint.
    ///
    /// Never throws. This runs unattended, on a timer, inside a long-lived daemon with nobody
    /// watching its output — a failure here must not take down the daemon or wedge the capture
    /// loop. Every failure is reported through `onError` instead, and success is never claimed
    /// for a reclaim that did not actually complete: `onInfo` only logs the delete count, never
    /// a "swept" message that would misrepresent an incomplete VACUUM/checkpoint as done.
    @discardableResult
    static func runRetentionSweep(
        retentionDays: Int, now: Double,
        deleteAttempts: Int = 3, vacuumAttempts: Int = 3,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        deleteOlderThan: @Sendable (Double) async throws -> Int,
        vacuum: @Sendable () async throws -> Void,
        checkpoint: @Sendable () async throws -> Bool,
        newestEventTS: @Sendable () async throws -> Double?,
        onInfo: @Sendable (String) -> Void = { _ in },
        onError: @Sendable (String) -> Void = { _ in }
    ) async -> RetentionSweepOutcome {
        guard retentionDays > 0 else { return .skipped }
        // Strict "<" (matching `EventStore.deleteEvents(olderThan:)`): a row exactly at the
        // cutoff is inside the retained window, not swept — the boundary is "older than N days
        // ago", never "N days ago or older".
        let cutoff = now - Double(retentionDays) * 86_400

        // Privacy fix round 1, J3: refuse when the cutoff is newer than the newest stored
        // event. In sane operation the newest event's ts is always >= cutoff; a cutoff beyond
        // everything ever recorded is the signature of a wrong system clock — daemon start is
        // login time, exactly when a Mac's clock is least trustworthy — and would otherwise
        // delete the *entire* store, then VACUUM and checkpoint it so it isn't even forensically
        // recoverable, and still report clean success.
        let newest: Double?
        do {
            newest = try await newestEventTS()
        } catch {
            onError(
                "retention: could not read the newest stored event before sweeping (\(error)); not deleting anything"
            )
            return .precheckFailed
        }
        if let newest, cutoff > newest {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            onError(
                "retention: refusing to sweep — the computed cutoff "
                    + "(\(formatter.string(from: Date(timeIntervalSince1970: cutoff)))) is newer "
                    + "than the newest stored event "
                    + "(\(formatter.string(from: Date(timeIntervalSince1970: newest)))); the "
                    + "system clock may be wrong. Not deleting anything; will re-check on the "
                    + "next sweep.")
            return .refusedClockSkew
        }

        let removed: Int
        do {
            removed = try await PurgeCommand.retryOnBusy(attempts: deleteAttempts, sleep: sleep) {
                try await deleteOlderThan(cutoff)
            }
        } catch {
            onError(
                "retention: failed to delete events older than \(retentionDays) day(s): \(error)")
            return .deleteFailed
        }
        guard removed > 0 else { return .noRowsToSweep }
        onInfo("retention: removed \(removed) event(s) older than \(retentionDays) day(s)")

        do {
            try await PurgeCommand.retryOnBusy(attempts: vacuumAttempts, sleep: sleep) {
                try await vacuum()
            }
        } catch {
            onError(
                "retention: removed \(removed) event(s) but VACUUM did not complete (\(error)) — "
                    + "that content is not yet reclaimed from disk and may still be recoverable "
                    + "until a later sweep or `openrhyme purge` succeeds")
            return .reclaimIncomplete(removed: removed)
        }
        do {
            let checkpointed = try await PurgeCommand.retryUntilTrue(
                attempts: vacuumAttempts, sleep: sleep
            ) { try await checkpoint() }
            guard checkpointed else {
                onError(
                    "retention: removed \(removed) event(s) but the WAL checkpoint stayed busy — "
                        + "another connection is holding the database open, so that content is "
                        + "not yet reclaimed from disk and may still be recoverable")
                return .reclaimIncomplete(removed: removed)
            }
        } catch {
            onError(
                "retention: removed \(removed) event(s) but the WAL checkpoint failed (\(error)) "
                    + "— that content is not yet reclaimed from disk and may still be recoverable")
            return .reclaimIncomplete(removed: removed)
        }
        return .reclaimed(removed: removed)
    }

    /// The startup half of the retention sweep — layered on top of `runRetentionSweep` with the
    /// safety notice spec §2 demands for automatic deletion: "Silently deleting a user's
    /// timeline because they typed a rule is a worse failure than the leak it fixes." Retention
    /// is the one setting that deletes on its own, and previously had no equivalent to §7.3's
    /// protect-rule notice.
    ///
    /// On the very first start after `retention_days` goes from off (0/unset) to a real value —
    /// detected from the most recently recorded `daemon.started` row, which is why this check
    /// only runs at startup, not on the periodic path — this counts what the new window would
    /// immediately delete and, if that count is nonzero, reports it plainly with a reviewable
    /// `openrhyme purge --dry-run` command and skips deleting anything this run. Every later
    /// start (once the *previous* `daemon.started` already shows a nonzero `retentionDays`) — or
    /// the periodic sweep later within this same run — proceeds normally.
    @discardableResult
    static func runStartupRetentionSweep(
        retentionDays: Int, now: Double,
        previousDaemonStarted: @Sendable () async throws -> RawEvent?,
        countEligible: @Sendable (Double) async throws -> Int,
        sweepNow: @Sendable (Int) async -> RetentionSweepOutcome,
        onInfo: @Sendable (String) -> Void = { _ in }
    ) async -> RetentionSweepOutcome {
        guard retentionDays > 0 else { return .skipped }
        let previous: RawEvent? = try? await previousDaemonStarted()
        let previousRetentionDays: Int = {
            guard let raw = previous?.extra?["privacy"]?.objectValue?["retentionDays"]?.doubleValue
            else { return 0 }
            return Int(exactly: raw) ?? 0
        }()
        if previousRetentionDays <= 0 {
            let cutoff = now - Double(retentionDays) * 86_400
            let wouldSweep = (try? await countEligible(cutoff)) ?? 0
            if wouldSweep > 0 {
                onInfo(
                    "retention: retention_days is now \(retentionDays) (previously off) — "
                        + "\(wouldSweep) stored event(s) are already outside this window. "
                        + "Skipping the first automatic sweep so you can review before anything "
                        + "is removed: run `openrhyme purge --until \(retentionDays)d --dry-run` "
                        + "to see them.")
                return .firstEnableReviewSkipped(count: wouldSweep)
            }
        }
        return await sweepNow(retentionDays)
    }

    /// The periodic half of the retention sweep: re-reads `capture.retention_days` from disk on
    /// every tick — not the value captured at daemon start — so turning retention off (or on,
    /// or to a different window) takes effect within one interval instead of requiring a
    /// restart (privacy fix round 1, J2). `interval`/`sleep`/`currentRetentionDays`/`sweep` are
    /// all injected so this loop's own behaviour — config re-read every tick, prompt
    /// cancellation — is unit-testable without a real 24h wait or a real daemon process
    /// (privacy fix round 1, J7).
    static func runPeriodicRetentionSweeps(
        interval: Duration = .seconds(86_400),
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        currentRetentionDays: @Sendable () async -> Int,
        sweep: @Sendable (Int) async -> Void
    ) async {
        while true {
            do {
                try await sleep(interval)
            } catch {
                return  // cancelled while sleeping
            }
            guard !Task.isCancelled else { return }
            let days = await currentRetentionDays()
            await sweep(days)
        }
    }

    /// Loads `capture.retention_days` fresh from disk — the source `runPeriodicRetentionSweeps`
    /// re-reads every tick (J2). Warns (never throws) on a config that fails to parse at all, or
    /// whose `retention_days` is present but not a valid whole number (e.g. a quoted string) —
    /// in both cases falls back to `0` (off): failing closed matches spec §2's "silently
    /// deleting a user's timeline is worse than the leak it fixes."
    static func loadRetentionDays(paths: Paths, onWarn: @Sendable (String) -> Void) -> Int {
        let config: Config
        do {
            config = try Config.load(from: paths.configURL)
        } catch {
            onWarn(
                "retention: config.json could not be read (\(error)) — retention treated as off until it's fixed"
            )
            return 0
        }
        if config.capture.retentionDaysInvalid {
            onWarn(
                "capture.retention_days in config.json is not a valid whole number (e.g. it's a "
                    + "quoted string) — retention is OFF until it's fixed to a bare integer")
        }
        return config.capture.retentionDays
    }

    /// The most recently recorded `daemon.started` row, if any — used by
    /// `runStartupRetentionSweep` to detect a transition from retention off to on. Pages up to
    /// `EventQuery.maxLimit` rows; in practice a daemon restarts far less than 10,000 times
    /// over a store's lifetime, so this always sees the true most recent one.
    private static func mostRecentDaemonStarted(store: EventStore) async throws -> RawEvent? {
        let rows = try await store.query(
            EventQuery(since: 0, kinds: [.daemonStarted], limit: EventQuery.maxLimit))
        return rows.last
    }

    /// The real, store-backed sweep operation — kept in exactly one place (privacy fix round 1,
    /// J7) so the startup and periodic call sites can never drift on how a sweep actually runs:
    /// both apply the audit-trail exemption (J5) and the clock-skew guard identically.
    private static func sweepNow(
        retentionDays: Int, store: EventStore,
        onInfo: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async -> RetentionSweepOutcome {
        await runRetentionSweep(
            retentionDays: retentionDays, now: Date().timeIntervalSince1970,
            deleteOlderThan: {
                try await store.deleteEvents(olderThan: $0, excludingKinds: Self.auditTrailKinds)
            },
            vacuum: { try await store.vacuum() },
            checkpoint: { try await store.checkpointTruncate() },
            newestEventTS: { try await store.lastEventTS() },
            onInfo: onInfo, onError: onError)
    }
}
