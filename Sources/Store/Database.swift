// Store — the events table. The SQLite schema is a public contract read by the CLI and by
// the Python MCP server (read-only). Schema changes are versioned; see Schema.swift.

import Foundation
import SQLite3

public struct DatabaseError: Error, Sendable, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public var description: String { "sqlite error \(code): \(message)" }
}

public enum SQLValue: Sendable, Equatable {
    case text(String)
    case int(Int64)
    case real(Double)
    case null
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A single SQLite connection. Not thread-safe by design: owned by the `EventStore` actor
/// or by one CLI command.
public final class Database {
    public enum Mode: Sendable {
        case readWrite
        case readOnly
    }

    private var handle: OpaquePointer?
    public let url: URL

    public init(url: URL, mode: Mode) throws {
        self.url = url
        let flags =
            mode == .readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var opened: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &opened, flags, nil)
        guard rc == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let opened { sqlite3_close_v2(opened) }
            throw DatabaseError(code: rc, message: message)
        }
        handle = opened
        try exec("PRAGMA busy_timeout=2000")
        if mode == .readWrite {
            try exec("PRAGMA journal_mode=WAL")
            try exec("PRAGMA synchronous=NORMAL")
        }
    }

    deinit { close() }

    public func close() {
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
    }

    public func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &error)
        guard rc == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw DatabaseError(code: rc, message: message)
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else {
            throw DatabaseError(code: rc, message: errorMessage)
        }
        return Statement(statement)
    }

    /// First column of the first row, as text. `nil` when there is no row or it is NULL.
    public func scalarString(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        guard try statement.step() else { return nil }
        return statement.string(0)
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
}

public final class Statement {
    private let statement: OpaquePointer

    init(_ statement: OpaquePointer) {
        self.statement = statement
    }

    deinit { sqlite3_finalize(statement) }

    @discardableResult
    public func bind(_ values: [SQLValue]) -> Statement {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            case .int(let int): sqlite3_bind_int64(statement, index, int)
            case .real(let real): sqlite3_bind_double(statement, index, real)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return self
    }

    /// `true` when a row is available, `false` when the statement is done.
    public func step() throws -> Bool {
        let rc = sqlite3_step(statement)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            let db = sqlite3_db_handle(statement)
            throw DatabaseError(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    public func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    public func string(_ column: Int32) -> String? {
        guard !isNull(column), let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    public func int64(_ column: Int32) -> Int64? {
        isNull(column) ? nil : sqlite3_column_int64(statement, column)
    }

    public func double(_ column: Int32) -> Double? {
        isNull(column) ? nil : sqlite3_column_double(statement, column)
    }
}
