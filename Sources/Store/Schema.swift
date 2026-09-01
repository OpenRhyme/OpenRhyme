import Foundation

public struct SchemaTooNewError: Error, Equatable, Sendable {
    public let found: Int
    public let supported: Int
}

/// Schema v1 (spec §7.1). Column order here is the JSON key order used by exports.
public enum Schema {
    public static let version = 1

    public static let ddl = """
        CREATE TABLE IF NOT EXISTS events (
          id            INTEGER PRIMARY KEY,
          ts            REAL    NOT NULL,
          kind          TEXT    NOT NULL,
          pid           INTEGER,
          bundle_id     TEXT,
          app_name      TEXT,
          window_title  TEXT,
          document      TEXT,
          url           TEXT,
          role          TEXT,
          subrole       TEXT,
          identifier    TEXT,
          element_title TEXT,
          value         TEXT,
          selected_text TEXT,
          extra         TEXT
        );
        CREATE INDEX IF NOT EXISTS events_ts      ON events (ts);
        CREATE INDEX IF NOT EXISTS events_kind_ts ON events (kind, ts);
        CREATE INDEX IF NOT EXISTS events_app_ts  ON events (bundle_id, ts);
        """

    private static let metaDDL =
        "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)"

    public static func currentVersion(_ db: Database) throws -> Int {
        let hasMeta = try db.scalarString(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='meta'")
        guard hasMeta != nil else { return 0 }
        let text = try db.scalarString("SELECT value FROM meta WHERE key='schema_version'")
        return text.flatMap(Int.init) ?? 0
    }

    /// For read-only connections: verifies the file is understood, returns its version.
    @discardableResult
    public static func check(_ db: Database) throws -> Int {
        let found = try currentVersion(db)
        if found > version { throw SchemaTooNewError(found: found, supported: version) }
        return found
    }

    /// For the writer: creates or upgrades to the current version.
    public static func migrate(_ db: Database) throws {
        let found = try check(db)
        guard found < version else { return }
        try db.exec("BEGIN")
        do {
            try db.exec(metaDDL)
            try db.exec(ddl)
            try db.exec(
                "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '\(version)')")
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }
}
