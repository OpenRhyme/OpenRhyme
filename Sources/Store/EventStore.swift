import Core
import Foundation

public struct StoreNotFoundError: Error, Sendable {
    public let url: URL
}

public struct EventQuery: Sendable, Equatable {
    public static let maxLimit = 10_000

    public var since: Double
    public var until: Double?
    public var kinds: [EventKind]?
    public var bundleID: String?
    public var limit: Int
    public var afterID: Int64?

    public init(
        since: Double, until: Double? = nil, kinds: [EventKind]? = nil,
        bundleID: String? = nil, limit: Int = 1000, afterID: Int64? = nil
    ) {
        self.since = since
        self.until = until
        self.kinds = kinds
        self.bundleID = bundleID
        self.limit = min(max(limit, 1), Self.maxLimit)
        self.afterID = afterID
    }
}

/// The single writer of `events.sqlite`. Readers open it with `readOnly: true`.
public actor EventStore {
    public let url: URL
    private let db: Database
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private let decoder = JSONDecoder()

    public init(url: URL, readOnly: Bool = false) throws {
        self.url = url
        if readOnly {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw StoreNotFoundError(url: url)
            }
            db = try Database(url: url, mode: .readOnly)
            try Schema.check(db)
        } else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            db = try Database(url: url, mode: .readWrite)
            try Schema.migrate(db)
        }
    }

    public func close() {
        db.close()
    }

    private static let columns = [
        "id", "ts", "kind", "pid", "bundle_id", "app_name", "window_title", "document", "url",
        "role", "subrole", "identifier", "element_title", "value", "selected_text", "extra",
    ]

    @discardableResult
    public func append(_ event: RawEvent) throws -> Int64 {
        let insert = try db.prepare(
            """
            INSERT INTO events (ts, kind, pid, bundle_id, app_name, window_title, document, url,
              role, subrole, identifier, element_title, value, selected_text, extra)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        let extra: SQLValue
        if let object = event.extra {
            extra = .text(String(decoding: try encoder.encode(object), as: UTF8.self))
        } else {
            extra = .null
        }
        insert.bind([
            .real(event.ts), .text(event.kind.rawValue), event.pid.map { .int(Int64($0)) } ?? .null,
            text(event.bundleID), text(event.appName), text(event.windowTitle),
            text(event.document), text(event.url), text(event.role), text(event.subrole),
            text(event.identifier), text(event.elementTitle), text(event.value),
            text(event.selectedText), extra,
        ])
        _ = try insert.step()
        return db.lastInsertRowID
    }

    private func text(_ value: String?) -> SQLValue {
        value.map(SQLValue.text) ?? .null
    }

    public func query(_ query: EventQuery) throws -> [RawEvent] {
        var sql = "SELECT \(Self.columns.joined(separator: ", ")) FROM events WHERE ts >= ?"
        var binds: [SQLValue] = [.real(query.since)]
        if let until = query.until {
            sql += " AND ts <= ?"
            binds.append(.real(until))
        }
        if let kinds = query.kinds, !kinds.isEmpty {
            sql +=
                " AND kind IN (\(Array(repeating: "?", count: kinds.count).joined(separator: ", ")))"
            binds += kinds.map { .text($0.rawValue) }
        }
        if let bundleID = query.bundleID {
            sql += " AND bundle_id = ?"
            binds.append(.text(bundleID))
        }
        if let afterID = query.afterID {
            sql += " AND id > ?"
            binds.append(.int(afterID))
        }
        sql += " ORDER BY ts, id LIMIT ?"
        binds.append(.int(Int64(query.limit)))

        let statement = try db.prepare(sql).bind(binds)
        var rows: [RawEvent] = []
        while try statement.step() {
            rows.append(try row(statement))
        }
        return rows
    }

    private func row(_ s: Statement) throws -> RawEvent {
        guard let kindRaw = s.string(2), let kind = EventKind(rawValue: kindRaw) else {
            throw DatabaseError(code: -1, message: "unknown kind in row \(s.int64(0) ?? -1)")
        }
        var extra: [String: JSONValue]?
        if let json = s.string(15) {
            extra = try decoder.decode([String: JSONValue].self, from: Data(json.utf8))
        }
        return RawEvent(
            id: s.int64(0), ts: s.double(1) ?? 0, kind: kind, pid: s.int64(3).map(Int32.init),
            bundleID: s.string(4), appName: s.string(5), windowTitle: s.string(6),
            document: s.string(7), url: s.string(8), role: s.string(9), subrole: s.string(10),
            identifier: s.string(11), elementTitle: s.string(12), value: s.string(13),
            selectedText: s.string(14), extra: extra)
    }

    public func count() throws -> Int64 {
        Int64(try db.scalarString("SELECT COUNT(*) FROM events") ?? "0") ?? 0
    }

    public func lastEventTS() throws -> Double? {
        try db.scalarString("SELECT MAX(ts) FROM events").flatMap(Double.init)
    }
}
