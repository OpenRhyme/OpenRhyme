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

    @Test func noHintWhenNothingStoredMatchesTheRules() async throws {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        try await store.append(
            RawEvent(ts: 1, kind: .contextSnapshot, bundleID: "com.example.NotProtected"))
        await store.close()
        let result = try CLIRunner.run(["privacy"], env: ["OPENRHYME_DATA_DIR": dir.path])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("stored rows matching current rules: 0"))
        #expect(!result.stdout.contains("openrhyme purge --apply-rules"))
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
