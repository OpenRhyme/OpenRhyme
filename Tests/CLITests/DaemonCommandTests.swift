import Foundation
import Testing

@testable import Core
@testable import Store
@testable import openrhyme

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
}
