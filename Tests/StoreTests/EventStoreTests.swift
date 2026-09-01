import Foundation
import Testing

@testable import Core
@testable import Store

@Suite struct EventStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("events.sqlite")
    }

    private func event(_ ts: Double, _ kind: EventKind, app: String = "com.a") -> RawEvent {
        RawEvent(ts: ts, kind: kind, pid: 1, bundleID: app, appName: "A", extra: ["n": 1])
    }

    @Test func appendAssignsIDsAndQueryReturnsOrderedRows() async throws {
        let store = try EventStore(url: tempURL())
        let first = try await store.append(event(10, .appActivated))
        let second = try await store.append(event(20, .windowFocused, app: "com.b"))
        #expect(first == 1 && second == 2)
        #expect(try await store.count() == 2)
        #expect(try await store.lastEventTS() == 20)

        let rows = try await store.query(EventQuery(since: 0))
        #expect(rows.map(\.id) == [1, 2])
        #expect(rows[0].kind == .appActivated)
        #expect(rows[0].extra == ["n": 1])
        #expect(rows[1].bundleID == "com.b")
    }

    @Test func filtersBySinceUntilKindsAppAndLimit() async throws {
        let store = try EventStore(url: tempURL())
        for i in 1...10 {
            try await store.append(
                event(
                    Double(i), i.isMultiple(of: 2) ? .windowFocused : .appActivated,
                    app: i <= 5 ? "com.a" : "com.b"))
        }
        #expect(try await store.query(EventQuery(since: 8)).map(\.ts) == [8, 9, 10])
        #expect(try await store.query(EventQuery(since: 3, until: 4)).map(\.ts) == [3, 4])
        #expect(
            try await store.query(EventQuery(since: 0, kinds: [.windowFocused])).count == 5)
        #expect(try await store.query(EventQuery(since: 0, bundleID: "com.b")).count == 5)
        #expect(try await store.query(EventQuery(since: 0, limit: 3)).map(\.ts) == [1, 2, 3])
        #expect(try await store.query(EventQuery(since: 0, afterID: 8)).map(\.ts) == [9, 10])
    }

    @Test func limitIsCapped() {
        #expect(EventQuery(since: 0, limit: 999_999).limit == EventQuery.maxLimit)
        #expect(EventQuery(since: 0, limit: 0).limit == 1)
    }

    @Test func readOnlyStoreCannotAppendButCanQuery() async throws {
        let url = tempURL()
        do {
            let writer = try EventStore(url: url)
            try await writer.append(event(1, .daemonStarted))
            await writer.close()
        }
        let reader = try EventStore(url: url, readOnly: true)
        #expect(try await reader.count() == 1)
        await #expect(throws: DatabaseError.self) {
            try await reader.append(event(2, .daemonStopped))
        }
    }

    @Test func readOnlyOnMissingFileThrowsStoreNotFound() {
        #expect(throws: StoreNotFoundError.self) {
            try EventStore(url: tempURL(), readOnly: true)
        }
    }

    @Test func lastEventTSIsNilWhenEmpty() async throws {
        let store = try EventStore(url: tempURL())
        #expect(try await store.lastEventTS() == nil)
    }
}
