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
    /// Cursor for id-ordered paging: when set, results are ordered by `id`
    /// (insertion order) so `id > afterID` never skips rows; without it,
    /// results are ordered by `ts, id`.
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
            Self.tighten(url)
        }
    }

    public func close() {
        db.close()
    }

    /// Owner-only, including the WAL sidecars SQLite may have created. Applied on every
    /// read-write open (spec privacy §5.6) so an already-existing, looser-permissioned
    /// database from before this change is tightened, not just newly created ones.
    private static func tighten(_ url: URL) {
        let manager = FileManager.default
        for path in [url.path, url.path + "-wal", url.path + "-shm"]
        where manager.fileExists(atPath: path) {
            try? manager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: path)
        }
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
        sql += query.afterID != nil ? " ORDER BY id LIMIT ?" : " ORDER BY ts, id LIMIT ?"
        let limit = min(max(query.limit, 1), EventQuery.maxLimit)
        binds.append(.int(Int64(limit)))

        let statement = try db.prepare(sql).bind(binds)
        var rows: [RawEvent] = []
        while try statement.step() {
            rows.append(try row(statement))
        }
        return rows
    }

    /// The single newest row of one `kind`, or `nil` when there is none — `ORDER BY ts DESC, id
    /// DESC LIMIT 1` directly, so the answer is exact no matter how many rows of that kind exist
    /// (privacy fix round 3, S5). `id` breaks ties on an equal `ts`, newest insertion first.
    ///
    /// Unlike paging through `query` with a bounded `limit` and taking the last page's last
    /// row — correct only up to `EventQuery.maxLimit` rows of that kind, silently wrong past
    /// it — this scales to any row count.
    public func mostRecentEvent(kind: EventKind) throws -> RawEvent? {
        let statement = try db.prepare(
            "SELECT \(Self.columns.joined(separator: ", ")) FROM events WHERE kind = ? "
                + "ORDER BY ts DESC, id DESC LIMIT 1"
        ).bind([.text(kind.rawValue)])
        guard try statement.step() else { return nil }
        return try row(statement)
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

    /// The newest `ts` in the store, or `nil` when it is empty.
    ///
    /// `excludingKinds` (privacy fix round 2, S1) exists for the retention sweep's clock-skew
    /// guard, which asks "what is the newest thing this store has actually observed?" and must
    /// not be answerable with rows the daemon wrote about *itself* at the very "now" the guard
    /// is trying to sanity-check — otherwise a single bad-clock start permanently widens what
    /// later starts are willing to delete. Defaults to empty, so `status` and every other
    /// existing caller is unchanged.
    public func lastEventTS(excludingKinds: Set<EventKind> = []) throws -> Double? {
        guard !excludingKinds.isEmpty else {
            return try db.scalarString("SELECT MAX(ts) FROM events").flatMap(Double.init)
        }
        let placeholders = Array(repeating: "?", count: excludingKinds.count).joined(
            separator: ", ")
        let statement = try db.prepare(
            "SELECT MAX(ts) FROM events WHERE kind NOT IN (\(placeholders))"
        ).bind(excludingKinds.map { .text($0.rawValue) })
        guard try statement.step() else { return nil }
        return statement.double(0)
    }

    /// Spec privacy §5.6/§5.7. Returns the number of rows actually removed, so a caller can
    /// tell "matched nothing" (0) apart from a failure (thrown `DatabaseError`).
    @discardableResult
    public func deleteEvents(ids: [Int64]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        var removed = 0
        // Chunked so a large purge cannot exceed SQLite's bound-variable limit.
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let statement = try db.prepare("DELETE FROM events WHERE id IN (\(placeholders))")
                .bind(chunk.map { SQLValue.int($0) })
            _ = try statement.step()
            removed += db.changes()
        }
        return removed
    }

    /// Spec privacy §5.6/§5.7. Returns the number of rows actually removed. `excludingKinds`
    /// (privacy fix round 1, J5) lets the automatic retention sweep exempt kinds that carry no
    /// captured user content — only configuration/permission posture — from ever being swept;
    /// defaults to empty so every existing caller (and `purge`, which does its own id-based
    /// deletion instead) is unaffected.
    @discardableResult
    public func deleteEvents(
        olderThan ts: Double, excludingKinds: Set<EventKind> = []
    ) throws
        -> Int
    {
        var sql = "DELETE FROM events WHERE ts < ?"
        var binds: [SQLValue] = [.real(ts)]
        if !excludingKinds.isEmpty {
            let placeholders = Array(repeating: "?", count: excludingKinds.count).joined(
                separator: ", ")
            sql += " AND kind NOT IN (\(placeholders))"
            binds += excludingKinds.map { .text($0.rawValue) }
        }
        let statement = try db.prepare(sql).bind(binds)
        _ = try statement.step()
        return db.changes()
    }

    /// Counts rows `deleteEvents(olderThan:excludingKinds:)` would remove, without removing
    /// them — used to preview a sweep before it runs (spec §2/§7.3's "never silently delete"
    /// pattern, extended to retention in privacy fix round 1).
    public func countEvents(
        olderThan ts: Double, excludingKinds: Set<EventKind> = []
    ) throws
        -> Int
    {
        var sql = "SELECT COUNT(*) FROM events WHERE ts < ?"
        var binds: [SQLValue] = [.real(ts)]
        if !excludingKinds.isEmpty {
            let placeholders = Array(repeating: "?", count: excludingKinds.count).joined(
                separator: ", ")
            sql += " AND kind NOT IN (\(placeholders))"
            binds += excludingKinds.map { .text($0.rawValue) }
        }
        let statement = try db.prepare(sql).bind(binds)
        guard try statement.step() else { return 0 }
        return Int(statement.int64(0) ?? 0)
    }

    /// Reclaims free pages so deleted text does not linger in the file. Must not be called
    /// while a transaction is open: SQLite refuses `VACUUM` inside one. `deleteEvents` never
    /// leaves one open — each `DELETE` runs and completes (auto-commits) before returning —
    /// so calling this right after a delete is always safe.
    ///
    /// In WAL mode (used for every read-write connection) this rewrite lands in the WAL, not
    /// `events.sqlite` itself, until something checkpoints it — call `checkpointTruncate()`
    /// afterward to actually get it onto disk; see there for why that step cannot be skipped.
    public func vacuum() throws {
        try db.exec("VACUUM")
    }

    /// Folds WAL frames — including a preceding `vacuum()`'s full rewrite — back into
    /// `events.sqlite` itself. Without this, deleted content can survive on disk indefinitely:
    /// SQLite only checkpoints automatically when the *last* connection to the database closes,
    /// and a live daemon holding its own connection open means a purge's own close is never
    /// last (measured: 200 marker rows survived a purge, 12,000 further inserts, and 1.7 MB of
    /// WAL growth with a second connection held open, dropping to zero only when it closed).
    ///
    /// `PRAGMA wal_checkpoint(TRUNCATE)` reports contention by returning a row rather than
    /// throwing: its first column ("busy") is `1` when another connection's active read
    /// transaction prevented a full checkpoint. Returns `true` only when the checkpoint fully
    /// completed (`busy == 0`); returns `false` — never claims success — when it was busy. Only
    /// a genuine SQL error throws.
    public func checkpointTruncate() throws -> Bool {
        let statement = try db.prepare("PRAGMA wal_checkpoint(TRUNCATE)")
        guard try statement.step() else { return true }  // no row: nothing pending
        // `busy` is documented as always 0 or 1 for this pragma, so this should never actually
        // be NULL — but comparing an `Int64?` with `!=` would silently read a genuinely
        // unexpected NULL as "not busy" (`nil != 1` is `true`). Treat that case explicitly, and
        // conservatively, as busy instead: never claim a checkpoint succeeded from a reading we
        // don't understand.
        guard let busy = statement.int64(0) else { return false }
        return busy == 0
    }
}
