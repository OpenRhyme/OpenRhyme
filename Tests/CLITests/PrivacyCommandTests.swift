import Foundation
import Testing

@testable import Core
@testable import Store

@Suite struct PrivacyCommandTests {
    /// Seeds one row a default policy protects by bundle id, and one row that looks just like a
    /// stored protected-context marker (bundle id only, no url/document/title) but is NOT itself
    /// on the protected list — a nil-matches-all bug in the counter would count this one too.
    private func seeded() async throws -> URL {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        try await store.append(
            RawEvent(ts: 1, kind: .contextSnapshot, bundleID: "com.1password.1password"))
        try await store.append(
            RawEvent(ts: 2, kind: .contextSnapshot, bundleID: "com.example.NotProtected"))
        await store.close()
        try Config().save(to: dir.appendingPathComponent("config.json"))
        return dir
    }

    @Test func privacyJSONReportsTheRulesAndTheStoredMatchCount() async throws {
        let dir = try await seeded()
        let result = try CLIRunner.run(
            ["privacy", "--json"], env: ["OPENRHYME_DATA_DIR": dir.path])
        #expect(result.status == 0, "\(result.stderr)")
        let data = try #require(try CLIRunner.json(result.stdout)["data"] as? [String: Any])
        #expect(data["enabled"] as? Bool == true)
        #expect(data["entropy_redaction"] as? Bool == true)
        #expect(
            (data["protected_bundle_ids"] as? [String])?.contains("com.1password.1password")
                == true)
        #expect((data["protected_url_patterns"] as? [String])?.contains("1password.com") == true)
        #expect((data["protected_document_patterns"] as? [String])?.contains(".env") == true)
        #expect(
            (data["protected_window_title_patterns"] as? [String])?.contains("private browsing")
                == true)
        #expect((data["credential_field_patterns"] as? [String])?.contains("password") == true)
        #expect(data["stored_rows_matching_rules"] as? Int == 1)
        // G4: a report that doesn't say which store it describes can't be acted on with
        // confidence — must match `status`'s spelling exactly.
        #expect(data["data_dir"] as? String == dir.path)
        #expect(
            data["db_path"] as? String
                == dir.appendingPathComponent("events.sqlite").path)
    }

    @Test func humanOutputListsCountsAndTheRemovalHintWhenSomethingMatches() async throws {
        let dir = try await seeded()
        let result = try CLIRunner.run(["privacy"], env: ["OPENRHYME_DATA_DIR": dir.path])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("stored rows matching current rules: 1"))
        #expect(
            result.stdout.contains(
                "1 stored rows match the current rules; remove them with: openrhyme purge --apply-rules --yes"
            ))
    }

    @Test func noRemovalHintWhenNothingStoredMatchesTheRulesButTheFutureCaveatAlwaysAppears()
        async throws
    {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        try await store.append(
            RawEvent(ts: 1, kind: .contextSnapshot, bundleID: "com.example.NotProtected"))
        await store.close()
        let result = try CLIRunner.run(["privacy"], env: ["OPENRHYME_DATA_DIR": dir.path])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("stored rows matching current rules: 0"))
        // The per-match removal sentence is conditional...
        #expect(
            !result.stdout.contains(
                "stored rows match the current rules; remove them with: openrhyme purge"))
        // ...but G3's unconditional "rules are forward-looking only" note must always be there,
        // match count aside — it's the one principle a first-time reader must learn regardless.
        #expect(result.stdout.contains("only change what gets captured from now on"))
        #expect(result.stdout.contains("openrhyme purge --apply-rules --yes"))
    }

    @Test func disabledStateIsUnmistakableNotJustTheWordDisabled() async throws {
        let dir = try CLIRunner.tempDataDir()
        var settings = PrivacySettings()
        settings.enabled = false
        try Config(privacy: settings).save(to: dir.appendingPathComponent("config.json"))
        let env = ["OPENRHYME_DATA_DIR": dir.path]

        let jsonResult = try CLIRunner.run(["privacy", "--json"], env: env)
        #expect(jsonResult.status == 0, "\(jsonResult.stderr)")
        let data = try #require(try CLIRunner.json(jsonResult.stdout)["data"] as? [String: Any])
        #expect(data["enabled"] as? Bool == false)

        let humanResult = try CLIRunner.run(["privacy"], env: env)
        #expect(humanResult.status == 0, "\(humanResult.stderr)")
        // G2: not just a lowercase "disabled" sitting next to otherwise-normal-looking output —
        // must be visually unmistakable and say plainly that the rules below do nothing.
        #expect(humanResult.stdout.contains("DISABLED"))
        #expect(humanResult.stdout.contains("none of the rules below are being enforced"))
        #expect(!humanResult.stdout.contains("privacy: enabled"))
        #expect(!humanResult.stdout.contains("privacy: ENABLED"))
    }

    @Test func reportsCleanlyWithNoDatabaseAndNeverCreatesOne() throws {
        let dir = try CLIRunner.tempDataDir()
        let env = ["OPENRHYME_DATA_DIR": dir.path]
        let dbURL = dir.appendingPathComponent("events.sqlite")
        #expect(!FileManager.default.fileExists(atPath: dbURL.path))

        let result = try CLIRunner.run(["privacy", "--json"], env: env)
        #expect(result.status == 0, "\(result.stderr)")
        let data = try #require(try CLIRunner.json(result.stdout)["data"] as? [String: Any])
        #expect(data["stored_rows_matching_rules"] as? Int == 0)
        #expect(!FileManager.default.fileExists(atPath: dbURL.path))

        let humanResult = try CLIRunner.run(["privacy"], env: env)
        #expect(humanResult.status == 0, "\(humanResult.stderr)")
        #expect(!FileManager.default.fileExists(atPath: dbURL.path))
    }

    @Test func theDatabaseIsByteIdenticalAfterRunningPrivacy() async throws {
        let dir = try CLIRunner.tempDataDir()
        let dbURL = dir.appendingPathComponent("events.sqlite")
        let store = try EventStore(url: dbURL)
        try await store.append(RawEvent(ts: 1, kind: .contextSnapshot, bundleID: "com.a"))
        try await store.append(
            RawEvent(ts: 2, kind: .contextSnapshot, bundleID: "com.1password.1password"))
        await store.close()

        let before = try Data(contentsOf: dbURL)
        let result = try CLIRunner.run(
            ["privacy", "--json"], env: ["OPENRHYME_DATA_DIR": dir.path])
        #expect(result.status == 0, "\(result.stderr)")
        let after = try Data(contentsOf: dbURL)
        #expect(before == after, "openrhyme privacy must open the store read-only")
    }
}
