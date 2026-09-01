import Foundation
import Testing

@testable import Store

@Suite struct SchemaTests {
    private func freshDB() throws -> Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("events.sqlite")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try Database(url: url, mode: .readWrite)
    }

    @Test func migrateCreatesTablesAndRecordsVersion() throws {
        let db = try freshDB()
        #expect(try Schema.currentVersion(db) == 0)
        try Schema.migrate(db)
        #expect(try Schema.currentVersion(db) == 1)
        let tables = try db.prepare(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        var names: [String] = []
        while try tables.step() { names.append(tables.string(0)!) }
        #expect(names == ["events", "meta"])
        let indexes = try db.prepare(
            "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'events_%' ORDER BY name"
        )
        var indexNames: [String] = []
        while try indexes.step() { indexNames.append(indexes.string(0)!) }
        #expect(indexNames == ["events_app_ts", "events_kind_ts", "events_ts"])
    }

    @Test func migrateIsIdempotent() throws {
        let db = try freshDB()
        try Schema.migrate(db)
        try Schema.migrate(db)
        #expect(try Schema.currentVersion(db) == 1)
    }

    @Test func refusesNewerSchema() throws {
        let db = try freshDB()
        try Schema.migrate(db)
        try db.exec("UPDATE meta SET value='2' WHERE key='schema_version'")
        #expect(throws: SchemaTooNewError(found: 2, supported: 1)) { try Schema.migrate(db) }
        #expect(throws: SchemaTooNewError(found: 2, supported: 1)) { try Schema.check(db) }
    }

    @Test func eventsColumnsMatchSpec() throws {
        let db = try freshDB()
        try Schema.migrate(db)
        let info = try db.prepare("PRAGMA table_info(events)")
        var columns: [String] = []
        while try info.step() { columns.append(info.string(1)!) }
        #expect(
            columns == [
                "id", "ts", "kind", "pid", "bundle_id", "app_name", "window_title", "document",
                "url", "role", "subrole", "identifier", "element_title", "value", "selected_text",
                "extra",
            ])
    }
}
