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

// `.serialized`: this suite spawns several real daemon subprocesses (one or more per test).
// Left to run in parallel with the rest of the suite, the combined CPU/scheduling load was
// observed to expose a pre-existing, unrelated timing race in `ObserverTests` (a different,
// untouched file) under a full `swift test` run — never reproduced when either suite ran alone.
// Serializing this suite's own tests bounds how many daemon subprocesses are ever live at once.
@Suite(.serialized) struct DaemonCommandTests {
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

    /// Like `launchDaemon`, but hands back the stderr pipe too — privacy fix round 1, J1 added
    /// a stderr echo of every retention log line specifically so a sweep is visible without
    /// Console.app; these tests are what actually proves that, on the real stderr stream of a
    /// real daemon process.
    private func launchDaemonCapturingStderr(
        dataDir: URL
    ) throws -> (process: Process, stderr: Pipe) {
        let process = Process()
        process.executableURL = CLIRunner.binaryURL
        process.arguments = ["daemon", "--no-prompt"]
        var env = ProcessInfo.processInfo.environment
        env["OPENRHYME_DATA_DIR"] = dataDir.path
        process.environment = env
        process.standardOutput = Pipe()
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        return (process, stderr)
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
    // `PurgeCommand.destroy`. `newestEventTS: { nil }` opts a test out of the J3 clock-skew
    // guard (below) when that isn't what it's testing — `nil` (an empty store) never triggers it.

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
                },
                newestEventTS: {
                    Issue.record("the clock-skew precheck must not run while retention is off")
                    return nil
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
            vacuum: {}, checkpoint: { true }, newestEventTS: { nil })
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
            }, newestEventTS: { nil })
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
            }, newestEventTS: { nil })
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
            }, newestEventTS: { nil },
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
            checkpoint: { true }, newestEventTS: { nil },
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
            checkpoint: { false }, newestEventTS: { nil },
            onError: { errors.value.append($0) })
        #expect(outcome == .reclaimIncomplete(removed: 3))
        #expect(errors.value.contains { $0.contains("checkpoint") })
    }

    // MARK: - J3: refuse a sweep when the cutoff is newer than the newest stored event (the
    // signature of a wrong system clock — daemon start is login time, exactly when a Mac's
    // clock is least trustworthy).

    @Test func retentionSweepRefusesWhenCutoffIsNewerThanTheNewestStoredEvent() async throws {
        let deleteCalled = TestBox(false)
        let vacuumCalled = TestBox(false)
        let errors = TestBox<[String]>([])
        // now is (falsely) a year ahead of the newest real event ever recorded.
        let outcome = await DaemonCommand.runRetentionSweep(
            retentionDays: 1, now: 1_000_000, sleep: noSleep,
            deleteOlderThan: { _ in
                deleteCalled.value = true
                return 0
            },
            vacuum: { vacuumCalled.value = true },
            checkpoint: { true },
            newestEventTS: { 1_000_000 - 400 * 86_400 },
            onError: { errors.value.append($0) })
        #expect(outcome == .refusedClockSkew)
        #expect(!deleteCalled.value, "must not delete anything when the clock looks wrong")
        #expect(!vacuumCalled.value)
        #expect(errors.value.count == 1)
        #expect(errors.value[0].contains("clock"))
    }

    /// A sane cutoff (well within the newest event's age) must sweep normally — the guard must
    /// not become a permanent no-op.
    @Test func retentionSweepProceedsWhenCutoffIsOlderThanTheNewestStoredEvent() async throws {
        let outcome = await DaemonCommand.runRetentionSweep(
            retentionDays: 1, now: 1_000_000, sleep: noSleep,
            deleteOlderThan: { _ in 4 },
            vacuum: {}, checkpoint: { true },
            newestEventTS: { 1_000_000 - 10 })
        #expect(outcome == .reclaimed(removed: 4))
    }

    @Test func retentionSweepReportsAPrecheckFailureWithoutThrowing() async throws {
        let errors = TestBox<[String]>([])
        let outcome = await DaemonCommand.runRetentionSweep(
            retentionDays: 1, now: 1_000_000, sleep: noSleep,
            deleteOlderThan: { _ in
                Issue.record("delete must not run when the newest-event precheck fails")
                return 0
            },
            vacuum: { Issue.record("vacuum must not run when the precheck fails") },
            checkpoint: {
                Issue.record("checkpoint must not run when the precheck fails")
                return true
            },
            newestEventTS: { throw DatabaseError(code: 5, message: "database is locked") },
            onError: { errors.value.append($0) })
        #expect(outcome == .precheckFailed)
        #expect(errors.value.count == 1)
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
            checkpoint: { try await sweeper.checkpointTruncate() },
            newestEventTS: { try await sweeper.lastEventTS() })
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
            checkpoint: { try await sweeper.checkpointTruncate() },
            newestEventTS: { try await sweeper.lastEventTS() })
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

    // MARK: - J2/J7: the periodic loop re-reads `retention_days` fresh every tick — not the
    // value captured at daemon start — and its own interval/cancellation logic is directly
    // testable without a real 24h wait or a real daemon process.

    /// Deterministic, not timing-based: the injected `sleep` itself throws (simulating
    /// cancellation) once exactly `responses.count` ticks have happened, so the loop stops after
    /// precisely three sweeps with no real wall-clock wait, no separate `Task`, and no race
    /// between a poll loop and the sweep loop over how many ticks land before cancellation is
    /// observed.
    @Test func periodicSweepRereadsRetentionDaysEveryTickInsteadOfTheStartupValue() async throws {
        let tick = TestBox(0)
        // Simulates: retention on (5 days), still on, then the user turns it off.
        let responses = [5, 5, 0]
        let seenDays = TestBox<[Int]>([])
        await DaemonCommand.runPeriodicRetentionSweeps(
            sleep: { _ in
                if tick.value >= responses.count { throw CancellationError() }
            },
            currentRetentionDays: {
                let index = tick.value
                tick.value += 1
                return responses[index]
            },
            sweep: { days in seenDays.value.append(days) })
        #expect(
            seenDays.value == [5, 5, 0],
            "must re-read the current config value on every tick, not the value captured once at task creation"
        )
    }

    @Test func periodicSweepStopsPromptlyOnCancellation() async throws {
        let sweepCalls = TestBox(0)
        let loop = Task {
            await DaemonCommand.runPeriodicRetentionSweeps(
                sleep: { _ in try await Task.sleep(for: .seconds(86_400)) },
                currentRetentionDays: { 1 },
                sweep: { _ in sweepCalls.value += 1 })
        }
        // Give the loop a moment to actually enter its sleep, then cancel — a real 24h interval
        // must never make cancellation itself slow.
        try await Task.sleep(for: .milliseconds(10))
        loop.cancel()
        await loop.value
        #expect(sweepCalls.value == 0, "cancelled while sleeping: must never have swept at all")
    }

    // MARK: - Wiring into `runDaemon()`: the sweep actually runs at startup, using the real
    // config, and `daemon.started` actually carries the posture.

    /// Seeds a *previous* `daemon.started` already recording `retentionDays > 0` so the
    /// safeguard below (retention going from off to on) does not apply here — this is
    /// specifically the "retention was already on" continuation path.
    @Test func daemonSweepsRetentionOnStartWhenAlreadyOnAndRecordsThePosture() async throws {
        let dir = try CLIRunner.tempDataDir()
        let dbURL = dir.appendingPathComponent("events.sqlite")
        let now = Date().timeIntervalSince1970
        let store = try EventStore(url: dbURL)
        try await store.append(
            RawEvent(
                ts: now - 5 * 86_400, kind: .daemonStarted,
                extra: [
                    "privacy": .object([
                        "enabled": .bool(true), "protectedRules": .number(1),
                        "retentionDays": .number(1),
                    ])
                ]))
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
            "a row past the retention window must be swept on daemon start when retention was already on"
        )
        #expect(
            events.contains { $0.windowTitle == "recent" },
            "a row inside the retention window must survive")

        // Two daemon.started rows now exist (the seeded one plus this run's); the posture must
        // be read from the latest.
        let started = try #require(events.last { $0.kind == .daemonStarted })
        let privacy = try #require(started.extra?["privacy"]?.objectValue)
        #expect(privacy["enabled"]?.boolValue == true, "J6: enabled must be carried explicitly")
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
    /// that exist but cannot fire. `enabled` (J6) is what actually lets a reader tell this case
    /// apart from "enabled with every rule removed", which also counts `0`.
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
        #expect(privacy["enabled"]?.boolValue == false)
        #expect(privacy["protectedRules"]?.doubleValue == 0)
        #expect(privacy["retentionDays"]?.doubleValue == 0)
    }

    /// J6, the actual defect: enabled with every rule *removed* counts `0` protected rules too
    /// — byte-identical to the disabled case on `protectedRules` alone. `enabled` is what tells
    /// them apart: redaction and the credential guard are live here, dead in the disabled case.
    @Test func daemonStartedDistinguishesEnabledWithNoRulesFromDisabled() async throws {
        let dir = try CLIRunner.tempDataDir()
        var settings = PrivacySettings()
        settings.enabled = true
        settings.protectedBundleIDs = []
        settings.protectedURLPatterns = []
        settings.protectedDocumentPatterns = []
        settings.protectedWindowTitlePatterns = []
        settings.credentialFieldPatterns = []
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
        #expect(privacy["protectedRules"]?.doubleValue == 0, "no rules configured, so 0 is correct")
        #expect(
            privacy["enabled"]?.boolValue == true,
            "must still say enabled — this is not the same posture as privacy being off")
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

    // MARK: - J5: the automatic sweep exempts daemon.started/daemon.stopped/permission.changed
    // — they carry no captured user content and are the evidence that answers "was redaction on
    // when this history was captured?", which retention makes more valuable to keep, not less.

    @Test func automaticSweepNeverDeletesAuditTrailRowsEvenWhenTheyAreOldestOfAll() async throws {
        let dir = try CLIRunner.tempDataDir()
        let dbURL = dir.appendingPathComponent("events.sqlite")
        let now = Date().timeIntervalSince1970
        let store = try EventStore(url: dbURL)
        // A previous daemon.started already recording retention on (so the first-enable
        // safeguard doesn't intercept this test) — also, itself, ancient: this IS the row under
        // test.
        try await store.append(
            RawEvent(
                ts: now - 100 * 86_400, kind: .daemonStarted,
                extra: ["privacy": .object(["retentionDays": .number(1)])]))
        try await store.append(
            RawEvent(ts: now - 100 * 86_400, kind: .daemonStopped))
        try await store.append(
            RawEvent(
                ts: now - 100 * 86_400, kind: .contextSnapshot, bundleID: "com.a",
                windowTitle: "ancient-content"))
        // A recent row too, so the newest-event-in-store clock-skew guard (J3) sees a sane
        // "newest" and doesn't refuse the sweep outright — this test is about the audit-trail
        // exemption, not about J3.
        try await store.append(
            RawEvent(
                ts: now - 100, kind: .contextSnapshot, bundleID: "com.a", windowTitle: "recent"))
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
            events.contains { $0.ts == now - 100 * 86_400 && $0.kind == .daemonStarted },
            "an ancient daemon.started must survive the automatic sweep")
        #expect(
            events.contains { $0.ts == now - 100 * 86_400 && $0.kind == .daemonStopped },
            "an ancient daemon.stopped must survive the automatic sweep")
        #expect(
            !events.contains { $0.windowTitle == "ancient-content" },
            "ordinary captured content is not exempt and must still be swept")
    }

    // MARK: - Safeguard (spec §2/§7.3 pattern, extended to retention): the first sweep after
    // `retention_days` goes from off to on is skipped, with a plain notice of what it would
    // have deleted, so an automatic, unattended deletion never silently removes a user's
    // pre-existing history the moment they opt in.

    @Test func firstEnableOfRetentionSkipsTheFirstSweepAndPreservesExistingHistory() async throws {
        let dir = try CLIRunner.tempDataDir()
        let dbURL = dir.appendingPathComponent("events.sqlite")
        let now = Date().timeIntervalSince1970
        let store = try EventStore(url: dbURL)
        // No previous daemon.started at all: a brand-new store turning retention on for the
        // first time, with history that already sits outside the new window.
        try await store.append(
            RawEvent(
                ts: now - 10 * 86_400, kind: .contextSnapshot, bundleID: "com.a",
                windowTitle: "already-old"))
        await store.close()

        var settings = CaptureSettings()
        settings.retentionDays = 1
        try Config(capture: settings).save(to: dir.appendingPathComponent("config.json"))

        let (daemon, stderr) = try launchDaemonCapturingStderr(dataDir: dir)
        #expect(await waitForPIDFile(dir), "daemon did not write daemon.pid")
        #expect(await waitForDaemonStarted(dir), "daemon did not record daemon.started")
        #expect(stopDaemon(daemon), "daemon did not exit within 10s of SIGTERM")
        let stderrText = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        let after = try EventStore(url: dbURL, readOnly: true)
        let events = try await after.query(EventQuery(since: 0))
        await after.close()
        #expect(
            events.contains { $0.windowTitle == "already-old" },
            "the first sweep after enabling retention must be skipped, not silently delete pre-existing history"
        )
        #expect(
            stderrText.contains("retention_days is now 1 (previously off)"),
            "expected the first-enable notice on stderr, got: \(stderrText)")
        #expect(stderrText.contains("openrhyme purge --until 1d --dry-run"))
    }

    /// The safeguard is a one-time thing: once a `daemon.started` has recorded retention on,
    /// the very next start proceeds normally even if there is still old content around —
    /// otherwise the safeguard would block every restart forever.
    @Test func secondStartWithRetentionAlreadyOnSweepsNormallyEvenWithOldContentPresent()
        async throws
    {
        let dir = try CLIRunner.tempDataDir()
        let dbURL = dir.appendingPathComponent("events.sqlite")
        let now = Date().timeIntervalSince1970
        let store = try EventStore(url: dbURL)
        try await store.append(
            RawEvent(
                ts: now - 2 * 86_400, kind: .daemonStarted,
                extra: ["privacy": .object(["retentionDays": .number(1)])]))
        try await store.append(
            RawEvent(
                ts: now - 10 * 86_400, kind: .contextSnapshot, bundleID: "com.a",
                windowTitle: "old-again"))
        // A recent row too, so the newest-event-in-store clock-skew guard (J3) doesn't refuse
        // the sweep — that guard is exercised by its own dedicated tests, not this one.
        try await store.append(
            RawEvent(
                ts: now - 100, kind: .contextSnapshot, bundleID: "com.a", windowTitle: "recent"))
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
            !events.contains { $0.windowTitle == "old-again" },
            "a second start with retention already on must sweep normally, not skip again")
    }

    // MARK: - String-typed `retention_days` (a silent-corruption trap: `"30"` parses to 0).

    @Test func stringTypedRetentionDaysWarnsAndTreatsRetentionAsOff() async throws {
        let dir = try CLIRunner.tempDataDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let configJSON = #"{"capture": {"retention_days": "30"}}"#
        try Data(configJSON.utf8).write(to: dir.appendingPathComponent("config.json"))
        let dbURL = dir.appendingPathComponent("events.sqlite")
        let store = try EventStore(url: dbURL)
        let now = Date().timeIntervalSince1970
        try await store.append(
            RawEvent(
                ts: now - 3650 * 86_400, kind: .contextSnapshot, bundleID: "com.a",
                windowTitle: "should-survive"))
        await store.close()

        let (daemon, stderr) = try launchDaemonCapturingStderr(dataDir: dir)
        #expect(await waitForPIDFile(dir), "daemon did not write daemon.pid")
        #expect(await waitForDaemonStarted(dir), "daemon did not record daemon.started")
        #expect(stopDaemon(daemon), "daemon did not exit within 10s of SIGTERM")
        let stderrText = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(
            stderrText.contains("retention_days in config.json is not a valid whole number"),
            "expected the string-typed retention_days warning on stderr, got: \(stderrText)")
        let after = try EventStore(url: dbURL, readOnly: true)
        let events = try await after.query(EventQuery(since: 0))
        await after.close()
        #expect(
            events.contains { $0.windowTitle == "should-survive" },
            "a string-typed retention_days must be treated as off (0), never silently parsed as a real window"
        )
    }
}
