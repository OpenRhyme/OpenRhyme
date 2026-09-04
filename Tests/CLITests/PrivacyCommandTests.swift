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
        // Privacy fix round 1: `retention_days` was reported by no command before this.
        #expect(data["retention_days"] as? Int == 0)
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
        // The per-match removal sentence is conditional on a nonzero count, in either state...
        #expect(
            !result.stdout.contains(
                "stored rows match the current rules; remove them with: openrhyme purge"))
        // ...but the unconditional "rules are forward-looking only" principle must always be
        // there, match count aside. H2 (privacy fix round 3): it deliberately no longer names
        // the specific `purge --apply-rules` command — that command is only ever mentioned next
        // to the count it actually applies to (see the disabled-state tests below for why).
        #expect(result.stdout.contains("only change what gets captured from now on"))
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

    // MARK: - H1/H2 (privacy fix round 3)
    //
    // With privacy disabled, `PrivacyPolicy.evaluateContext` returns `.open` unconditionally, so
    // a naive "count under the real policy" is always 0 — read by a worried user as "nothing
    // sensitive is stored" when it actually means "not evaluated". And our own unconditional
    // note used to tell that same user to run `openrhyme purge --apply-rules --yes`, which would
    // silently match nothing and report success while every one of their rows stayed put. Both
    // seeded rows below WOULD be protected if privacy were on (one by bundle id, one by url),
    // so a bug reverting to the old bare-zero behavior would show `0` here instead of `2`.

    private func seededMatchingRowsWithPrivacyDisabled() async throws -> URL {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        try await store.append(
            RawEvent(ts: 1, kind: .contextSnapshot, bundleID: "com.1password.1password"))
        try await store.append(
            RawEvent(
                ts: 2, kind: .contextSnapshot, bundleID: "com.google.Chrome",
                url: "https://vault.internal/ui/vault/list"))
        try await store.append(
            RawEvent(ts: 3, kind: .contextSnapshot, bundleID: "com.example.NotProtected"))
        await store.close()
        var settings = PrivacySettings()
        settings.enabled = false
        try Config(privacy: settings).save(to: dir.appendingPathComponent("config.json"))
        return dir
    }

    @Test func disabledStateReportsAHypotheticalCountNotABareZero() async throws {
        let dir = try await seededMatchingRowsWithPrivacyDisabled()
        let env = ["OPENRHYME_DATA_DIR": dir.path]

        let jsonResult = try CLIRunner.run(["privacy", "--json"], env: env)
        #expect(jsonResult.status == 0, "\(jsonResult.stderr)")
        let data = try #require(try CLIRunner.json(jsonResult.stdout)["data"] as? [String: Any])
        #expect(data["enabled"] as? Bool == false)
        // H1: the real count these rules match (2 of the 3 seeded rows), not 0 — computed as if
        // enabled regardless of the actual (disabled) policy state.
        #expect(data["stored_rows_matching_rules"] as? Int == 2)

        let humanResult = try CLIRunner.run(["privacy"], env: env)
        #expect(humanResult.status == 0, "\(humanResult.stderr)")
        // Labelled plainly as hypothetical, not presented as "stored rows matching current
        // rules" — that phrasing is reserved for when the rules are actually in force.
        #expect(humanResult.stdout.contains("rows these rules would match if enabled: 2"))
        #expect(!humanResult.stdout.contains("stored rows matching current rules:"))
        #expect(humanResult.stdout.contains("hypothetical"))
    }

    @Test func disabledStateDoesNotPresentPurgeApplyRulesAsAnActionableStep() async throws {
        let dir = try await seededMatchingRowsWithPrivacyDisabled()
        let result = try CLIRunner.run(["privacy"], env: ["OPENRHYME_DATA_DIR": dir.path])
        #expect(result.status == 0, "\(result.stderr)")
        // H2: must never read as an instruction to run right now — `purge --apply-rules` would
        // silently match nothing while disabled and report success, leaving every counted row
        // untouched. The enabled-state actionable sentence must not appear here at all...
        #expect(
            !result.stdout.contains(
                "stored rows match the current rules; remove them with: openrhyme purge"))
        // ...and the disabled-state text must instead say plainly that purging would do nothing
        // right now, and that enabling privacy comes first.
        #expect(result.stdout.contains("would remove nothing"))
        #expect(result.stdout.contains("Enable privacy first"))
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

    /// Privacy fix round 1: `retention_days` was reported by no command before this.
    @Test func humanOutputReportsRetentionDays() async throws {
        let dir = try CLIRunner.tempDataDir()
        var settings = CaptureSettings()
        settings.retentionDays = 7
        try Config(capture: settings).save(to: dir.appendingPathComponent("config.json"))

        let result = try CLIRunner.run(["privacy"], env: ["OPENRHYME_DATA_DIR": dir.path])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("retention: 7 day(s)"))

        let json = try CLIRunner.run(
            ["privacy", "--json"], env: ["OPENRHYME_DATA_DIR": dir.path])
        let data = try #require(try CLIRunner.json(json.stdout)["data"] as? [String: Any])
        #expect(data["retention_days"] as? Int == 7)
    }
}
