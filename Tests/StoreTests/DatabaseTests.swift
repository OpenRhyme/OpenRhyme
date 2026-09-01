import Foundation
import Testing

@testable import Store

@Suite struct DatabaseTests {
    private func tempDB() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("t.sqlite")
    }

    @Test func opensInWALModeAndRoundTripsRows() throws {
        let url = tempDB()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try Database(url: url, mode: .readWrite)
        #expect(try db.scalarString("PRAGMA journal_mode") == "wal")

        try db.exec("CREATE TABLE t (a TEXT, b INTEGER, c REAL, d TEXT)")
        let insert = try db.prepare("INSERT INTO t VALUES (?, ?, ?, ?)")
        insert.bind([.text("x"), .int(7), .real(1.5), .null])
        #expect(try insert.step() == false)
        #expect(db.lastInsertRowID == 1)

        let select = try db.prepare("SELECT a, b, c, d FROM t")
        #expect(try select.step() == true)
        #expect(select.string(0) == "x")
        #expect(select.int64(1) == 7)
        #expect(select.double(2) == 1.5)
        #expect(select.string(3) == nil)
        #expect(try select.step() == false)
    }

    @Test func readOnlyRefusesWrites() throws {
        let url = tempDB()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let db = try Database(url: url, mode: .readWrite)
            try db.exec("CREATE TABLE t (a)")
            db.close()
        }
        let ro = try Database(url: url, mode: .readOnly)
        #expect(throws: DatabaseError.self) { try ro.exec("INSERT INTO t VALUES (1)") }
    }

    @Test func reportsSQLErrorsWithMessage() throws {
        let url = tempDB()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try Database(url: url, mode: .readWrite)
        do {
            try db.exec("SELEKT 1")
            Issue.record("expected a syntax error")
        } catch let error as DatabaseError {
            #expect(error.message.contains("syntax error"))
        }
    }

    @Test func missingFileInReadOnlyModeFails() {
        let url = tempDB()
        #expect(throws: DatabaseError.self) { try Database(url: url, mode: .readOnly) }
    }
}
