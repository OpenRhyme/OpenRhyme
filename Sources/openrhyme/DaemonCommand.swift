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

        // Spec privacy §5.8/§7.7: sweep the retention window on start, before capture begins,
        // then once a day for the life of the process. Reclaims the space the same way `purge`
        // does (VACUUM + an explicit WAL checkpoint) — see `runRetentionSweep`'s doc comment for
        // why the checkpoint cannot be skipped. Never throws: a sweep failure must not take down
        // the daemon or wedge the capture loop that hasn't even started yet.
        let retentionDays = config.capture.retentionDays
        await Self.runRetentionSweep(
            retentionDays: retentionDays, now: Date().timeIntervalSince1970,
            deleteOlderThan: { try await store.deleteEvents(olderThan: $0) },
            vacuum: { try await store.vacuum() },
            checkpoint: { try await store.checkpointTruncate() },
            onInfo: { logger.info("\($0)") }, onError: { logger.error("\($0)") })

        // Spec privacy §5.8: "daemon.started" records the posture in force, so an auditor
        // reading history later can tell whether redaction was even switched on over a given
        // stretch — rather than only being able to infer it from what is (or isn't) missing.
        // `protectedRules` counts every configured rule entry across all five protect-rule
        // categories (bundle ids, URL/document/window-title patterns, credential field names)
        // that can actually fire right now: `0` whenever `privacy.enabled` is false, since a
        // disabled policy evaluates every context as open regardless of how many patterns are
        // configured — the count must describe enforcement in force, not configuration on disk.
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

        // Spec privacy §5.8: swept again every 24h for the life of the process — not just on
        // start — so a long-running daemon's history doesn't grow past the configured window
        // between restarts. `nil` (not merely a task that immediately returns) when retention is
        // off, so there is no timer to cancel or await at all in the common (disabled) case.
        let sweepTask: Task<Void, Never>? =
            retentionDays > 0
            ? Task.detached {
                while true {
                    do {
                        try await Task.sleep(for: .seconds(86_400))
                    } catch {
                        return  // cancelled while sleeping
                    }
                    guard !Task.isCancelled else { return }
                    await Self.runRetentionSweep(
                        retentionDays: retentionDays, now: Date().timeIntervalSince1970,
                        deleteOlderThan: { try await store.deleteEvents(olderThan: $0) },
                        vacuum: { try await store.vacuum() },
                        checkpoint: { try await store.checkpointTruncate() },
                        onInfo: { logger.info("\($0)") }, onError: { logger.error("\($0)") })
                }
            } : nil

        let sig = await waiter.wait()
        logger.info("signal \(sig) received, stopping")
        capturer.stop()
        await consumer.value
        sweepTask?.cancel()
        await sweepTask?.value
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
        onInfo: @Sendable (String) -> Void = { _ in },
        onError: @Sendable (String) -> Void = { _ in }
    ) async -> RetentionSweepOutcome {
        guard retentionDays > 0 else { return .skipped }
        // Strict "<" (matching `EventStore.deleteEvents(olderThan:)`): a row exactly at the
        // cutoff is inside the retained window, not swept — the boundary is "older than N days
        // ago", never "N days ago or older".
        let cutoff = now - Double(retentionDays) * 86_400
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
}
