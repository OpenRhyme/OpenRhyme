import Foundation
import Testing

@testable import Core
@testable import Store

@Suite struct StatusCommandTests {
    @Test func reportsEmptyStateWithoutDatabase() throws {
        let dir = try CLIRunner.tempDataDir()
        let result = try CLIRunner.run(["status", "--json"], env: ["OPENRHYME_DATA_DIR": dir.path])
        #expect(result.status == 0, "\(result.stderr)")
        let data = try CLIRunner.json(result.stdout)["data"] as? [String: Any]
        #expect(data?["daemon_running"] as? Bool == false)
        #expect(data?["event_count"] as? Int == 0)
        #expect(data?["last_event_ts"] == nil || data?["last_event_ts"] is NSNull)
        #expect(data?["data_dir"] as? String == dir.path)
        #expect(data?["allowlist"] as? [String] == [])
        #expect(data?["opaque_apps"] as? [String] == [])
        #expect(["active", "needsPermission"].contains(data?["state"] as? String ?? ""))
    }

    @Test func reportsCountsAndLiveDaemon() async throws {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        try await store.append(RawEvent(ts: 5, kind: .daemonStarted))
        try await store.append(RawEvent(ts: 9, kind: .appActivated, bundleID: "com.a"))
        await store.close()
        // The test process itself stands in for a live daemon.
        try PIDFile(url: dir.appendingPathComponent("daemon.pid")).acquire()
        try Config(allowlist: ["com.a"]).save(to: dir.appendingPathComponent("config.json"))

        let result = try CLIRunner.run(["status", "--json"], env: ["OPENRHYME_DATA_DIR": dir.path])
        #expect(result.status == 0, "\(result.stderr)")
        let data = try CLIRunner.json(result.stdout)["data"] as? [String: Any]
        #expect(data?["daemon_running"] as? Bool == true)
        #expect(data?["pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier))
        #expect(data?["event_count"] as? Int == 2)
        #expect(data?["last_event_ts"] as? Double == 9)
        #expect(data?["allowlist"] as? [String] == ["com.a"])

        let human = try CLIRunner.run(["status"], env: ["OPENRHYME_DATA_DIR": dir.path])
        #expect(human.stdout.contains("daemon:   running"))
    }
}
