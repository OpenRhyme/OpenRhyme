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

    @Test func queryReClampsLimitMutatedAfterInit() async throws {
        let store = try EventStore(url: tempURL())
        for i in 1...3 {
            try await store.append(event(Double(i), .appActivated))
        }
        var q = EventQuery(since: 0)
        q.limit = 999_999
        #expect(try await store.query(q).count == 3)
        q.limit = 0
        #expect(try await store.query(q).count == 1)
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

    @Test func afterIDPagingOrdersByIDSoNonMonotonicTSNeverSkipsRows() async throws {
        let store = try EventStore(url: tempURL())
        // ts values are NOT monotonic in insertion order (e.g. a backward clock
        // correction between two appends), so ts-ordered paging would drop rows.
        for ts in [10.0, 30.0, 20.0, 50.0, 40.0] {
            try await store.append(event(ts, .appActivated))
        }

        var ids: [Int64] = []
        // Start the id-ordered cursor at 0 (ids are 1-based), not nil: `afterID == nil`
        // means "no cursor, ts-ordered" per EventQuery.afterID's contract, so a fresh
        // id-ordered paging scan must supply an explicit starting cursor.
        var afterID: Int64? = 0
        while true {
            let page = try await store.query(EventQuery(since: 0, limit: 2, afterID: afterID))
            ids += page.compactMap(\.id)
            guard page.count == 2, let last = page.last?.id else { break }
            afterID = last
        }
        #expect(ids == [1, 2, 3, 4, 5])

        let rows = try await store.query(EventQuery(since: 0))
        #expect(rows.map(\.id) == [1, 3, 2, 5, 4])
    }

    @Test func deletesByIDAndByAge() async throws {
        let url = tempURL()
        let store = try EventStore(url: url)
        var ids: [Int64] = []
        for (index, ts) in [100.0, 200.0, 300.0].enumerated() {
            ids.append(
                try await store.append(event(ts, .contextSnapshot, app: "app\(index)")))
        }
        #expect(try await store.count() == 3)

        #expect(try await store.deleteEvents(ids: [ids[1]]) == 1)
        #expect(try await store.count() == 2)
        #expect(try await store.deleteEvents(ids: [ids[1]]) == 0)  // idempotent

        #expect(try await store.deleteEvents(olderThan: 250) == 1)  // removes ts=100
        #expect(try await store.count() == 1)
        let remaining = try await store.query(EventQuery(since: 0))
        #expect(remaining.map(\.ts) == [300])
        try await store.vacuum()
        #expect(try await store.count() == 1)
        await store.close()
    }

    @Test func deleteEventsWithEmptyIDsIsANoOp() async throws {
        let store = try EventStore(url: tempURL())
        try await store.append(event(1, .appActivated))
        #expect(try await store.deleteEvents(ids: []) == 0)
        #expect(try await store.count() == 1)
    }

    /// Privacy fix round 1, J5: the automatic retention sweep exempts kinds that carry no
    /// captured user content — `excludingKinds` is what makes that possible without a second
    /// deletion code path.
    @Test func deleteEventsOlderThanExcludesTheGivenKinds() async throws {
        let store = try EventStore(url: tempURL())
        try await store.append(event(1, .daemonStarted))
        try await store.append(event(1, .daemonStopped))
        try await store.append(event(1, .permissionChanged))
        try await store.append(event(1, .contextSnapshot))
        #expect(try await store.count() == 4)

        let removed = try await store.deleteEvents(
            olderThan: 100,
            excludingKinds: [.daemonStarted, .daemonStopped, .permissionChanged])
        #expect(removed == 1, "only the non-exempt kind should be removed")

        let remaining = try await store.query(EventQuery(since: 0))
        #expect(
            Set(remaining.map(\.kind)) == [.daemonStarted, .daemonStopped, .permissionChanged])
    }

    /// `deleteEvents(olderThan:)` without `excludingKinds` (the default) is unchanged — every
    /// existing caller (and this same test file's `deletesByIDAndByAge`) must keep deleting
    /// everything older, exemption-free.
    @Test func deleteEventsOlderThanWithNoExclusionsDeletesEverythingOlder() async throws {
        let store = try EventStore(url: tempURL())
        try await store.append(event(1, .daemonStarted))
        try await store.append(event(1, .contextSnapshot))
        #expect(try await store.deleteEvents(olderThan: 100) == 2)
        #expect(try await store.count() == 0)
    }

    /// `countEvents(olderThan:excludingKinds:)` previews exactly what
    /// `deleteEvents(olderThan:excludingKinds:)` would remove, without removing it — used by the
    /// retention safeguard to report what a first sweep would delete before skipping it.
    @Test func countEventsOlderThanMatchesWhatDeleteWouldRemoveAndChangesNothing() async throws {
        let store = try EventStore(url: tempURL())
        try await store.append(event(1, .daemonStarted))
        try await store.append(event(1, .contextSnapshot))
        try await store.append(event(1, .contextSnapshot))

        let count = try await store.countEvents(olderThan: 100, excludingKinds: [.daemonStarted])
        #expect(count == 2)
        #expect(try await store.count() == 3, "counting must not delete anything")

        let removed = try await store.deleteEvents(
            olderThan: 100, excludingKinds: [.daemonStarted])
        #expect(removed == count, "the preview count must match the real deletion exactly")
    }

    @Test func databaseFileIsOwnerOnly() async throws {
        let url = tempURL()
        let store = try EventStore(url: url)
        _ = try await store.append(event(1, .daemonStarted))
        await store.close()
        let mode =
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            as? NSNumber
        #expect(mode?.int16Value == 0o600)
    }

    @Test func existingLoosePermissionedDatabaseIsTightenedOnOpen() async throws {
        // Simulate an install from before this change: a world-readable database (and its
        // WAL sidecars) already on disk. Opening it read-write must tighten every one of
        // them, not just files created fresh by this run.
        let url = tempURL()
        do {
            let store = try EventStore(url: url)
            try await store.append(event(1, .daemonStarted))
            await store.close()
        }
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o644))], ofItemAtPath: path)
        }
        let looseMode =
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            as? NSNumber
        #expect(looseMode?.int16Value == 0o644)

        let reopened = try EventStore(url: url)
        _ = try await reopened.append(event(2, .daemonStarted))
        await reopened.close()

        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let mode =
                try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
                as? NSNumber
            #expect(mode?.int16Value == 0o600, "\(path) was not tightened")
        }
    }
}
