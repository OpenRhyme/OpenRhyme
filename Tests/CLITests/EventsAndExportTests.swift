import Foundation
import Testing

@testable import Core
@testable import Store

@Suite struct EventsAndExportTests {
    /// Seeds a store in a temp data dir and returns the env the CLI needs to find it.
    private func seeded() async throws -> [String: String] {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        let now = Date().timeIntervalSince1970
        try await store.append(RawEvent(ts: now - 7200, kind: .appActivated, bundleID: "com.a"))
        try await store.append(
            RawEvent(
                ts: now - 60, kind: .windowFocused, bundleID: "com.a",
                windowTitle: "T", extra: ["reason": "heartbeat"]))
        try await store.append(RawEvent(ts: now - 30, kind: .elementFocused, bundleID: "com.b"))
        await store.close()
        return ["OPENRHYME_DATA_DIR": dir.path]
    }

    @Test func eventsFiltersAndWrapsInEnvelope() async throws {
        let env = try await seeded()
        let result = try CLIRunner.run(["events", "--since", "1h", "--json"], env: env)
        #expect(result.status == 0, "\(result.stderr)")
        let envelope = try CLIRunner.json(result.stdout)
        let data = envelope["data"] as? [String: Any]
        #expect(data?["count"] as? Int == 2)
        let events = data?["events"] as? [[String: Any]]
        #expect(events?.first?["kind"] as? String == "window.focused")
        #expect(events?.first?["window_title"] as? String == "T")
        #expect((events?.first?["extra"] as? [String: Any])?["reason"] as? String == "heartbeat")

        let byApp = try CLIRunner.run(
            ["events", "--since", "1d", "--app", "com.b", "--json"], env: env)
        #expect((try CLIRunner.json(byApp.stdout)["data"] as? [String: Any])?["count"] as? Int == 1)

        let byKind = try CLIRunner.run(
            [
                "events", "--since", "1d", "--kind", "app.activated", "--kind", "element.focused",
                "--limit", "1", "--json",
            ], env: env)
        #expect(
            (try CLIRunner.json(byKind.stdout)["data"] as? [String: Any])?["count"] as? Int == 1)
    }

    @Test func eventsHumanOutputIsOneLinePerEvent() async throws {
        let env = try await seeded()
        let result = try CLIRunner.run(["events", "--since", "1d"], env: env)
        #expect(result.status == 0)
        #expect(result.stdout.split(separator: "\n").count == 3)
        #expect(result.stdout.contains("window.focused"))
    }

    @Test func exportWritesJSONLToStdoutAndFile() async throws {
        let env = try await seeded()
        let result = try CLIRunner.run(["export", "--since", "1d"], env: env)
        #expect(result.status == 0, "\(result.stderr)")
        let lines = result.stdout.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix(#"{"id":1,"ts":"#))
        #expect(lines[1].contains(#""extra":{"reason":"heartbeat"}"#))

        let out = try CLIRunner.tempDataDir().appendingPathComponent("day.jsonl")
        let toFile = try CLIRunner.run(
            ["export", "--since", "1d", "--out", out.path], env: env)
        #expect(toFile.status == 0)
        #expect(toFile.stdout.isEmpty)
        #expect(try String(contentsOf: out, encoding: .utf8).split(separator: "\n").count == 3)
    }

    @Test func exportPagesInInsertionOrderEvenWithNonMonotonicTimestamps() async throws {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        let now = Date().timeIntervalSince1970
        // ts values are NOT monotonic in insertion order (e.g. a backward clock
        // correction between two appends): id 1 has the latest ts, id 3 the earliest.
        try await store.append(RawEvent(ts: now - 100, kind: .appActivated, bundleID: "com.a"))
        try await store.append(RawEvent(ts: now - 50, kind: .windowFocused, bundleID: "com.a"))
        try await store.append(RawEvent(ts: now - 75, kind: .elementFocused, bundleID: "com.b"))
        await store.close()
        let env = ["OPENRHYME_DATA_DIR": dir.path]

        let result = try CLIRunner.run(["export", "--since", "1d"], env: env)
        #expect(result.status == 0, "\(result.stderr)")
        let lines = result.stdout.split(separator: "\n")
        #expect(lines.count == 3)
        let ids = lines.compactMap { line -> Int? in
            guard let match = line.range(of: #""id":"#) else { return nil }
            let rest = line[match.upperBound...]
            return Int(rest.prefix(while: { $0.isNumber }))
        }
        #expect(ids == [1, 2, 3])
    }

    @Test func missingDatabaseIsAStableError() throws {
        let env = ["OPENRHYME_DATA_DIR": try CLIRunner.tempDataDir().path]
        let result = try CLIRunner.run(["events", "--since", "1h", "--json"], env: env)
        #expect(result.status == 1)
        let envelope = try CLIRunner.json(result.stdout)
        #expect(envelope["ok"] as? Bool == false)
        #expect((envelope["error"] as? [String: Any])?["code"] as? String == "db_not_found")
    }

    @Test func badTimeIsAUsageError() throws {
        let result = try CLIRunner.run(["events", "--since", "yesterday", "--json"])
        #expect(result.status == 2)
        #expect(
            (try CLIRunner.json(result.stdout)["error"] as? [String: Any])?["code"] as? String
                == "usage")
    }
}
