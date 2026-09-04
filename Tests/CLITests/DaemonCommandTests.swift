import Foundation
import Testing

@testable import Capture
@testable import Core
@testable import Store
@testable import openrhyme

/// `runRetentionSweep`'s injected dependencies are `@Sendable` (the real call site crosses from
/// the daemon's `@MainActor` body into a nonisolated static function), so a plain captured `var`
/// cannot be mutated from inside them — even in these tests, where every call is sequential and
/// there is never any actual concurrency. A reference-type box sidesteps that: the closure
/// captures the box itself (a `let`), not the `var` inside it.
private final class TestBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@Suite struct DaemonCommandTests {
    private func launchDaemon(dataDir: URL) throws -> Process {
        let process = Process()
        process.executableURL = CLIRunner.binaryURL
        process.arguments = ["daemon", "--no-prompt"]
        var env = ProcessInfo.processInfo.environment
        env["OPENRHYME_DATA_DIR"] = dataDir.path
        process.environment = env
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        return process
    }

    private func waitForPIDFile(
        _ dir: URL, timeout: TimeInterval = 10, poll: Duration = .milliseconds(100)
    ) async -> Bool {
        let pidfile = PIDFile(url: dir.appendingPathComponent("daemon.pid"))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pidfile.livePID != nil { return true }
            try? await Task.sleep(for: poll)
        }
        return false
    }

    /// Polls the store for a `daemon.started` row — proof that startup (including the
    /// retention sweep, which runs before it's appended) has actually completed, not just that
    /// the pidfile exists (written earlier, before the store is even opened).
    private func waitForDaemonStarted(
        _ dir: URL, timeout: TimeInterval = 10, poll: Duration = .milliseconds(100)
    ) async -> Bool {
        let dbURL = dir.appendingPathComponent("events.sqlite")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let store = try? EventStore(url: dbURL, readOnly: true) {
                let events = (try? await store.query(EventQuery(since: 0))) ?? []
                await store.close()
                if events.contains(where: { $0.kind == .daemonStarted }) { return true }
            }
            try? await Task.sleep(for: poll)
        }
        return false
    }

    /// SIGTERMs the daemon and waits for it, but never longer than `timeout`: a daemon that
    /// ignores the signal is SIGKILLed and reported, so a regression fails loudly instead of
    /// hanging the suite. Returns whether SIGTERM alone was enough.
    @discardableResult
    private func stopDaemon(_ process: Process, timeout: TimeInterval = 10) -> Bool {
        guard process.isRunning else {
            process.waitUntilExit()
            return true
        }
        process.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        guard !process.isRunning else {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return false
        }
        process.waitUntilExit()
        return true
    }

    @Test func startsWritesPidfileAndStopsCleanlyOnSIGTERM() async throws {
        let dir = try CLIRunner.tempDataDir()
        let daemon = try launchDaemon(dataDir: dir)
        #expect(await waitForPIDFile(dir), "daemon did not write daemon.pid")

        #expect(stopDaemon(daemon), "daemon did not exit within 10s of SIGTERM")
        #expect(daemon.terminationStatus == 0)
        #expect(
            !FileManager.default.fileExists(atPath: dir.appendingPathComponent("daemon.pid").path))

        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"), readOnly: true)
        let events = try await store.query(EventQuery(since: 0))
        await store.close()
        #expect(events.first?.kind == .daemonStarted)
        #expect(events.first?.extra?["version"] == "0.1.0")
        #expect(events.first?.extra?["schema"] == 1)
        #expect(events.last?.kind == .daemonStopped)
    }

    @Test func secondDaemonIsRefused() async throws {
        let dir = try CLIRunner.tempDataDir()
        let first = try launchDaemon(dataDir: dir)
        defer { stopDaemon(first) }
        #expect(await waitForPIDFile(dir))

        let second = try CLIRunner.run(
            ["daemon", "--no-prompt", "--json"], env: ["OPENRHYME_DATA_DIR": dir.path])
        #expect(second.status == 1)
        #expect(
            (try CLIRunner.json(second.stdout)["error"] as? [String: Any])?["code"] as? String
                == "daemon_already_running")
    }

    /// The waiter is installed before the pidfile is written, so a SIGTERM sent the instant the
    /// pidfile appears can land before `wait()` is reached. The latch must hold it: without it the
    /// daemon ignores the signal and this test SIGKILLs it, failing on both counts.
    @Test func signalDuringStartupIsNotLost() async throws {
        let dir = try CLIRunner.tempDataDir()
        let daemon = try launchDaemon(dataDir: dir)
        defer { stopDaemon(daemon) }
        #expect(
            await waitForPIDFile(dir, poll: .milliseconds(1)), "daemon did not write daemon.pid")

        #expect(stopDaemon(daemon), "daemon ignored a SIGTERM sent during startup")
        #expect(daemon.terminationStatus == 0)

        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"), readOnly: true)
        let events = try await store.query(EventQuery(since: 0))
        await store.close()
        #expect(events.first?.kind == .daemonStarted)
        #expect(events.last?.kind == .daemonStopped)
    }

    // MARK: - Bounded append retry (a concurrent `purge` VACUUM can hold the write lock past
    // SQLite's busy_timeout; a transient failure must be retried, not silently dropped).

    private func noSleep(_ delay: Duration) async throws {}

    @Test func appendWithRetrySucceedsAfterTransientFailures() async throws {
        var calls = 0
        try await DaemonCommand.appendWithRetry(attempts: 3, sleep: noSleep) {
            calls += 1
            if calls < 3 { throw DatabaseError(code: 5, message: "database is locked") }
        }
        #expect(calls == 3, "must have retried instead of dropping the event on the first failure")
    }

    @Test func appendWithRetryGivesUpAfterExhaustingAttemptsInsteadOfRetryingForever()
        async throws
    {
        var calls = 0
        await #expect(throws: DatabaseError.self) {
            try await DaemonCommand.appendWithRetry(attempts: 3, sleep: noSleep) {
                calls += 1
                throw DatabaseError(code: 5, message: "database is locked")
            }
        }
        #expect(calls == 3, "bounded: must give up rather than retry forever")
    }

    @Test func appendWithRetryDoesNotRetryAfterASuccess() async throws {
        var calls = 0
        try await DaemonCommand.appendWithRetry(attempts: 3, sleep: noSleep) {
            calls += 1
        }
        #expect(calls == 1)
    }

    /// F7: `1...attempts` traps when `attempts` is 0 (or negative) — an invalid `ClosedRange`.
    @Test func appendWithRetryDoesNotTrapWhenAttemptsIsZeroOrNegative() async throws {
        for attempts in [0, -1] {
            var calls = 0
            await #expect(throws: DatabaseError.self) {
                try await DaemonCommand.appendWithRetry(attempts: attempts, sleep: noSleep) {
                    calls += 1
                    throw DatabaseError(code: 5, message: "database is locked")
                }
            }
            #expect(calls == 1)
        }
    }

    // MARK: - Retention sweep (spec privacy §5.8/§7.7). `runRetentionSweep` is the pure,
    // injectable core `runDaemon()` calls at start and every 24h; these tests exercise it
    // directly with fake delete/vacuum/checkpoint, the same way `PurgeCommandTests` exercises
    // `PurgeCommand.destroy`.

    @Test func retentionSweepIsSkippedWhenRetentionDaysIsZeroOrNegative() async throws {
        for days in [0, -1] {
            let outcome = await DaemonCommand.runRetentionSweep(
                retentionDays: days, now: 1_000_000, sleep: noSleep,
                deleteOlderThan: { _ in
                    Issue.record("delete must not run while retention is off")
                    return 0
                },
                vacuum: { Issue.record("vacuum must not run while retention is off") },
                checkpoint: {
                    Issue.record("checkpoint must not run while retention is off")
                    return true
                })
            #expect(outcome == .skipped)
        }
    }

    @Test func retentionSweepComputesTheCutoffFromRetentionDaysAndNow() async throws {
        let seenCutoff = TestBox<Double?>(nil)
        let outcome = await DaemonCommand.runRetentionSweep(
            retentionDays: 30, now: 1_000_000, sleep: noSleep,
            deleteOlderThan: { cutoff in
                seenCutoff.value = cutoff
                return 0
            },
            vacuum: {}, checkpoint: { true })
        let expectedCutoff: Double = 1_000_000 - 30 * 86_400
        #expect(seenCutoff.value == expectedCutoff)
        #expect(outcome == .noRowsToSweep)
    }

    /// Mirrors `PurgeCommand`'s N1/N2: a sweep that deleted nothing has nothing to reclaim, so
    /// running VACUUM/checkpoint anyway would be pointless work that pushes retained plaintext
    /// through the WAL for no benefit.
    @Test func retentionSweepSkipsReclaimWhenNothingWasDeleted() async throws {
        let vacuumCalls = TestBox(0)
        let checkpointCalls = TestBox(0)
        let outcome = await DaemonCommand.runRetentionSweep(
            retentionDays: 1, now: 1_000_000, sleep: noSleep,
            deleteOlderThan: { _ in 0 },
            vacuum: { vacuumCalls.value += 1 },
            checkpoint: {
                checkpointCalls.value += 1
                return true
            })
        #expect(outcome == .noRowsToSweep)
        #expect(vacuumCalls.value == 0, "a no-op sweep must not run VACUUM at all")
        #expect(checkpointCalls.value == 0, "a no-op sweep must not run a checkpoint at all")
    }

    @Test func retentionSweepReclaimsAfterDeletingSomething() async throws {
        let vacuumCalls = TestBox(0)
        let checkpointCalls = TestBox(0)
        let outcome = await DaemonCommand.runRetentionSweep(
            retentionDays: 1, now: 1_000_000, sleep: noSleep,
            deleteOlderThan: { _ in 5 },
            vacuum: { vacuumCalls.value += 1 },
            checkpoint: {
                checkpointCalls.value += 1
                return true
            })
        #expect(outcome == .reclaimed(removed: 5))
        #expect(vacuumCalls.value == 1)
        #expect(checkpointCalls.value == 1)
    }

    /// A sweep failure must not take down the daemon or wedge the capture loop: every failure
    /// mode reports through `onError` (never thrown) and via a distinct `RetentionSweepOutcome`
    /// case, never silently upgraded to a quiet, misleading success.
    @Test func retentionSweepReportsADeleteFailureWithoutThrowing() async throws {
        let errors = TestBox<[String]>([])
        let outcome = await DaemonCommand.runRetentionSweep(
            retentionDays: 1, now: 1_000_000, deleteAttempts: 2, sleep: noSleep,
            deleteOlderThan: { _ in throw DatabaseError(code: 5, message: "database is locked") },
            vacuum: { Issue.record("vacuum must not run after a failed delete") },
            checkpoint: {
                Issue.record("checkpoint must not run after a failed delete")
                return true
            },
            onError: { errors.value.append($0) })
        #expect(outcome == .deleteFailed)
        #expect(errors.value.count == 1)
    }

    @Test func retentionSweepReportsAnIncompleteVacuumWithoutThrowing() async throws {
        let errors = TestBox<[String]>([])
        let outcome = await DaemonCommand.runRetentionSweep(
            retentionDays: 1, now: 1_000_000, vacuumAttempts: 2, sleep: noSleep,
            deleteOlderThan: { _ in 3 },
            vacuum: { throw DatabaseError(code: 5, message: "database is locked") },
            checkpoint: { true },
            onError: { errors.value.append($0) })
        #expect(outcome == .reclaimIncomplete(removed: 3))
        #expect(errors.value.contains { $0.contains("VACUUM") })
    }

    @Test func retentionSweepReportsABusyCheckpointWithoutThrowing() async throws {
        let errors = TestBox<[String]>([])
        let outcome = await DaemonCommand.runRetentionSweep(
            retentionDays: 1, now: 1_000_000, vacuumAttempts: 2, sleep: noSleep,
            deleteOlderThan: { _ in 3 },
            vacuum: {},
            checkpoint: { false },
            onError: { errors.value.append($0) })
        #expect(outcome == .reclaimIncomplete(removed: 3))
        #expect(errors.value.contains { $0.contains("checkpoint") })
    }

    /// Requirement: the sweep must never delete rows newer than the window, and its boundary
    /// must be unambiguous. `EventStore.deleteEvents(olderThan:)` uses strict `ts < cutoff`, so
    /// a row exactly at the cutoff is retained — this pins that through the composed sweep, not
    /// just the store method underneath it.
    @Test func retentionSweepBoundaryRowExactlyAtTheCutoffIsRetained() async throws {
        let dir = try CLIRunner.tempDataDir()
        let dbURL = dir.appendingPathComponent("events.sqlite")
        let now: Double = 1_000_000
        let retentionDays = 10
        let cutoff = now - Double(retentionDays) * 86_400
        let store = try EventStore(url: dbURL)
        // Exactly at the cutoff: inside the retained window, must survive.
        try await store.append(RawEvent(ts: cutoff, kind: .contextSnapshot, bundleID: "at-cutoff"))
        // One second older than the cutoff: outside the window, must be swept.
        try await store.append(
            RawEvent(ts: cutoff - 1, kind: .contextSnapshot, bundleID: "just-older"))
        // One second newer: well inside the window, must survive.
        try await store.append(
            RawEvent(ts: cutoff + 1, kind: .contextSnapshot, bundleID: "just-newer"))
        await store.close()

        let sweeper = try EventStore(url: dbURL)
        let outcome = await DaemonCommand.runRetentionSweep(
            retentionDays: retentionDays, now: now,
            deleteOlderThan: { try await sweeper.deleteEvents(olderThan: $0) },
            vacuum: { try await sweeper.vacuum() },
            checkpoint: { try await sweeper.checkpointTruncate() })
        #expect(outcome == .reclaimed(removed: 1))
        let remaining = try await sweeper.query(EventQuery(since: 0))
        await sweeper.close()
        #expect(Set(remaining.compactMap(\.bundleID)) == ["at-cutoff", "just-newer"])
    }

    /// F1-equivalent for the retention sweep — the mandatory regression test for the exact same
    /// defect first found in `purge`: in WAL mode `VACUUM` rewrites the database *into the WAL*,
    /// and `events.sqlite` only receives it at a checkpoint, which normally runs only when the
    /// *last* connection closes. A held-open second connection (what a lazily-connecting holder
    /// that never actually opens the file would fail to reproduce — it must genuinely connect,
    /// as `Database(url:mode:)` does here) means the sweep's own close is never last, so this
    /// reproduces the defect exactly: without the explicit checkpoint `runRetentionSweep` runs
    /// after VACUUM, swept content's plaintext would survive in `events.sqlite` indefinitely.
    /// Asserted on the raw bytes of the file, never on the reported outcome alone — that is
    /// exactly where this hid the first time.
    @Test
    func retentionSweepChecksPointsSoDeletedContentLeavesTheMainFileWithAHolderConnectionOpen()
        async throws
    {
        let dir = try CLIRunner.tempDataDir()
        let dbURL = dir.appendingPathComponent("events.sqlite")
        let oldMarker = "RETOLDMARKER\(UUID().uuidString.prefix(8))"
        let keptMarker = "RETKEPTMARKER\(UUID().uuidString.prefix(8))"
        let now = Date().timeIntervalSince1970
        let store = try EventStore(url: dbURL)
        for i in 0..<200 {
            try await store.append(
                RawEvent(
                    ts: now - 40 * 86_400, kind: .contextSnapshot, bundleID: "com.apple.Safari",
                    windowTitle: "\(oldMarker)_\(i)"))
        }
        try await store.append(
            RawEvent(
                ts: now - 1 * 86_400, kind: .contextSnapshot, bundleID: "com.apple.Safari",
                windowTitle: keptMarker))
        await store.close()
        #expect(try Data(contentsOf: dbURL).range(of: Data(oldMarker.utf8)) != nil)

        // Hold a second connection open for the rest of the test — this is what makes the bug
        // reproduce (see `EventStore.checkpointTruncate`'s doc comment).
        let holder = try Database(url: dbURL, mode: .readWrite)
        defer { holder.close() }

        let sweeper = try EventStore(url: dbURL)
        let outcome = await DaemonCommand.runRetentionSweep(
            retentionDays: 30, now: now,
            deleteOlderThan: { try await sweeper.deleteEvents(olderThan: $0) },
            vacuum: { try await sweeper.vacuum() },
            checkpoint: { try await sweeper.checkpointTruncate() })
        await sweeper.close()
        #expect(outcome == .reclaimed(removed: 200))

        let bytesAfter = try Data(contentsOf: dbURL)
        #expect(
            bytesAfter.range(of: Data(oldMarker.utf8)) == nil,
            "swept content's marker string must not survive in events.sqlite while a second connection is still open"
        )
        #expect(
            bytesAfter.range(of: Data(keptMarker.utf8)) != nil,
            "a row inside the retention window must not be touched by the sweep")
    }

    // MARK: - Wiring into `runDaemon()`: the sweep actually runs at startup, using the real
    // config, and `daemon.started` actually carries the posture.

    @Test func daemonSweepsRetentionOnStartAndRecordsThePostureOnDaemonStarted() async throws {
        let dir = try CLIRunner.tempDataDir()
        let dbURL = dir.appendingPathComponent("events.sqlite")
        let now = Date().timeIntervalSince1970
        let store = try EventStore(url: dbURL)
        try await store.append(
            RawEvent(
                ts: now - 2 * 86_400, kind: .contextSnapshot, bundleID: "com.a",
                windowTitle: "old"))
        try await store.append(
            RawEvent(
                ts: now - 1000, kind: .contextSnapshot, bundleID: "com.a", windowTitle: "recent"))
        await store.close()

        var settings = CaptureSettings()
        settings.retentionDays = 1
        try Config(capture: settings).save(to: dir.appendingPathComponent("config.json"))

        let daemon = try launchDaemon(dataDir: dir)
        #expect(await waitForPIDFile(dir), "daemon did not write daemon.pid")
        #expect(await waitForDaemonStarted(dir), "daemon did not record daemon.started")
        #expect(stopDaemon(daemon), "daemon did not exit within 10s of SIGTERM")

        let after = try EventStore(url: dbURL, readOnly: true)
        let events = try await after.query(EventQuery(since: 0))
        await after.close()
        #expect(
            !events.contains { $0.windowTitle == "old" },
            "a row past the retention window must be swept on daemon start")
        #expect(
            events.contains { $0.windowTitle == "recent" },
            "a row inside the retention window must survive")

        let started = try #require(events.first { $0.kind == .daemonStarted })
        let privacy = try #require(started.extra?["privacy"]?.objectValue)
        #expect(privacy["retentionDays"]?.doubleValue == 1)
        // Default privacy settings are enabled, so every configured rule counts.
        let defaults = PrivacyPolicy(settings: PrivacySettings())
        let expectedRules =
            defaults.protectedBundleIDs.count + defaults.protectedURLPatterns.count
            + defaults.protectedDocumentPatterns.count
            + defaults.protectedWindowTitlePatterns.count
            + defaults.credentialFieldPatterns.count
        #expect(privacy["protectedRules"]?.doubleValue == Double(expectedRules))
    }

    /// `protectedRules` must describe enforcement actually in force, not configuration merely on
    /// disk: with `privacy.enabled == false` every protect rule is inert (`evaluateContext`
    /// always returns `.open`), so the posture record must say `0`, never the count of patterns
    /// that exist but cannot fire.
    @Test func daemonStartedReportsZeroProtectedRulesWhenPrivacyIsDisabled() async throws {
        let dir = try CLIRunner.tempDataDir()
        var settings = PrivacySettings()
        settings.enabled = false
        try Config(privacy: settings).save(to: dir.appendingPathComponent("config.json"))

        let daemon = try launchDaemon(dataDir: dir)
        #expect(await waitForPIDFile(dir), "daemon did not write daemon.pid")
        #expect(await waitForDaemonStarted(dir), "daemon did not record daemon.started")
        #expect(stopDaemon(daemon), "daemon did not exit within 10s of SIGTERM")

        let store = try EventStore(
            url: dir.appendingPathComponent("events.sqlite"), readOnly: true)
        let events = try await store.query(EventQuery(since: 0))
        await store.close()
        let started = try #require(events.first { $0.kind == .daemonStarted })
        let privacy = try #require(started.extra?["privacy"]?.objectValue)
        #expect(privacy["protectedRules"]?.doubleValue == 0)
        #expect(privacy["retentionDays"]?.doubleValue == 0)
    }

    /// The other half of "must not run when unset or zero": with no `config.json` at all,
    /// `retention_days` defaults to `0` (keep forever), and an ancient row must survive a full
    /// daemon start/stop cycle untouched.
    @Test func daemonNeverSweepsWhenRetentionDaysIsUnset() async throws {
        let dir = try CLIRunner.tempDataDir()
        let dbURL = dir.appendingPathComponent("events.sqlite")
        let now = Date().timeIntervalSince1970
        let store = try EventStore(url: dbURL)
        try await store.append(
            RawEvent(
                ts: now - 3650 * 86_400, kind: .contextSnapshot, bundleID: "com.a",
                windowTitle: "ancient"))
        await store.close()

        let daemon = try launchDaemon(dataDir: dir)
        #expect(await waitForPIDFile(dir), "daemon did not write daemon.pid")
        #expect(await waitForDaemonStarted(dir), "daemon did not record daemon.started")
        #expect(stopDaemon(daemon), "daemon did not exit within 10s of SIGTERM")

        let after = try EventStore(url: dbURL, readOnly: true)
        let events = try await after.query(EventQuery(since: 0))
        await after.close()
        #expect(
            events.contains { $0.windowTitle == "ancient" },
            "retention_days unset must never delete anything")
    }
}
