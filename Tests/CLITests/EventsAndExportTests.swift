import Foundation
import Testing

@testable import Core
@testable import Store

@Suite struct EventsAndExportTests {
    /// Seeds a store in a temp data dir and returns the env the CLI needs to find it.
    private func seeded() async throws -> [String: String] {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        let now = Date().timeIntervalSince1970
        try await store.append(RawEvent(ts: now - 7200, kind: .appActivated, bundleID: "com.a"))
        try await store.append(
            RawEvent(
                ts: now - 60, kind: .windowFocused, bundleID: "com.a",
                windowTitle: "T", extra: ["reason": "heartbeat"]))
        try await store.append(RawEvent(ts: now - 30, kind: .elementFocused, bundleID: "com.b"))
        await store.close()
        return ["OPENRHYME_DATA_DIR": dir.path]
    }

    @Test func eventsFiltersAndWrapsInEnvelope() async throws {
        let env = try await seeded()
        let result = try CLIRunner.run(["events", "--since", "1h", "--json"], env: env)
        #expect(result.status == 0, "\(result.stderr)")
        let envelope = try CLIRunner.json(result.stdout)
        let data = envelope["data"] as? [String: Any]
        #expect(data?["count"] as? Int == 2)
        let events = data?["events"] as? [[String: Any]]
        #expect(events?.first?["kind"] as? String == "window.focused")
        #expect(events?.first?["window_title"] as? String == "T")
        #expect((events?.first?["extra"] as? [String: Any])?["reason"] as? String == "heartbeat")

        let byApp = try CLIRunner.run(
            ["events", "--since", "1d", "--app", "com.b", "--json"], env: env)
        #expect((try CLIRunner.json(byApp.stdout)["data"] as? [String: Any])?["count"] as? Int == 1)

        let byKind = try CLIRunner.run(
            [
                "events", "--since", "1d", "--kind", "app.activated", "--kind", "element.focused",
                "--limit", "1", "--json",
            ], env: env)
        #expect(
            (try CLIRunner.json(byKind.stdout)["data"] as? [String: Any])?["count"] as? Int == 1)
    }

    @Test func eventsHumanOutputIsOneLinePerEvent() async throws {
        let env = try await seeded()
        let result = try CLIRunner.run(["events", "--since", "1d"], env: env)
        #expect(result.status == 0)
        #expect(result.stdout.split(separator: "\n").count == 3)
        #expect(result.stdout.contains("window.focused"))
    }

    @Test func exportWritesJSONLToStdoutAndFile() async throws {
        let env = try await seeded()
        let result = try CLIRunner.run(["export", "--since", "1d"], env: env)
        #expect(result.status == 0, "\(result.stderr)")
        let lines = result.stdout.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix(#"{"id":1,"ts":"#))
        #expect(lines[1].contains(#""extra":{"reason":"heartbeat"}"#))

        let out = try CLIRunner.tempDataDir().appendingPathComponent("day.jsonl")
        let toFile = try CLIRunner.run(
            ["export", "--since", "1d", "--out", out.path], env: env)
        #expect(toFile.status == 0)
        #expect(toFile.stdout.isEmpty)
        #expect(try String(contentsOf: out, encoding: .utf8).split(separator: "\n").count == 3)
    }

    @Test func exportPagesInInsertionOrderEvenWithNonMonotonicTimestamps() async throws {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        let now = Date().timeIntervalSince1970
        // ts values are NOT monotonic in insertion order (e.g. a backward clock
        // correction between two appends): id 1 has the latest ts, id 3 the earliest.
        try await store.append(RawEvent(ts: now - 100, kind: .appActivated, bundleID: "com.a"))
        try await store.append(RawEvent(ts: now - 50, kind: .windowFocused, bundleID: "com.a"))
        try await store.append(RawEvent(ts: now - 75, kind: .elementFocused, bundleID: "com.b"))
        await store.close()
        let env = ["OPENRHYME_DATA_DIR": dir.path]

        let result = try CLIRunner.run(["export", "--since", "1d"], env: env)
        #expect(result.status == 0, "\(result.stderr)")
        let lines = result.stdout.split(separator: "\n")
        #expect(lines.count == 3)
        let ids = lines.compactMap { line -> Int? in
            guard let match = line.range(of: #""id":"#) else { return nil }
            let rest = line[match.upperBound...]
            return Int(rest.prefix(while: { $0.isNumber }))
        }
        #expect(ids == [1, 2, 3])
    }

    @Test func missingDatabaseIsAStableError() throws {
        let env = ["OPENRHYME_DATA_DIR": try CLIRunner.tempDataDir().path]
        let result = try CLIRunner.run(["events", "--since", "1h", "--json"], env: env)
        #expect(result.status == 1)
        let envelope = try CLIRunner.json(result.stdout)
        #expect(envelope["ok"] as? Bool == false)
        #expect((envelope["error"] as? [String: Any])?["code"] as? String == "db_not_found")
    }

    @Test func badTimeIsAUsageError() throws {
        let result = try CLIRunner.run(
            ["events", "--since", "yesterday", "--json"], env: try CLIRunner.tempEnv())
        #expect(result.status == 2)
        #expect(
            (try CLIRunner.json(result.stdout)["error"] as? [String: Any])?["code"] as? String
                == "usage")
    }

    // MARK: - Read-time redaction (spec privacy §4/§5.7). Rows stored before a rule existed are
    // the reason this exists: redaction is re-applied on every read, not just at capture time.

    @Test func eventsRedactsSecretsAtReadTime() async throws {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        // Seeded directly, bypassing capture-time redaction entirely — this is exactly what a
        // row written before the rule existed looks like.
        try await store.append(
            RawEvent(
                ts: 100, kind: .contextSnapshot, bundleID: "com.apple.TextEdit",
                value: "token AKIAQQQQWWWWEEEERRRR end"))
        await store.close()
        let env = ["OPENRHYME_DATA_DIR": dir.path]

        let result = try CLIRunner.run(["events", "--since", "0", "--json"], env: env)
        #expect(result.status == 0, "\(result.stderr)")
        let data = try CLIRunner.json(result.stdout)["data"] as? [String: Any]
        let rows = try #require(data?["events"] as? [[String: Any]])
        #expect(rows.first?["value"] as? String == "token [redacted:aws-key] end")
    }

    @Test func eventsDoesNotRedactWhenPrivacyIsDisabled() async throws {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        try await store.append(
            RawEvent(
                ts: 100, kind: .contextSnapshot, bundleID: "com.apple.TextEdit",
                value: "token AKIAQQQQWWWWEEEERRRR end"))
        await store.close()
        var settings = PrivacySettings()
        settings.enabled = false
        try Config(privacy: settings).save(to: dir.appendingPathComponent("config.json"))
        let env = ["OPENRHYME_DATA_DIR": dir.path]

        let result = try CLIRunner.run(["events", "--since", "0", "--json"], env: env)
        #expect(result.status == 0, "\(result.stderr)")
        let rows = try #require(
            (try CLIRunner.json(result.stdout)["data"] as? [String: Any])?["events"]
                as? [[String: Any]])
        #expect(rows.first?["value"] as? String == "token AKIAQQQQWWWWEEEERRRR end")
    }

    @Test func maxValueCharsTruncatesAndZeroMeansFull() async throws {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        try await store.append(
            RawEvent(
                ts: 100, kind: .contextSnapshot, bundleID: "com.apple.TextEdit",
                value: String(repeating: "x", count: 5000)))
        await store.close()
        let env = ["OPENRHYME_DATA_DIR": dir.path]

        let capped = try CLIRunner.run(
            ["events", "--since", "0", "--max-value-chars", "10", "--json"], env: env)
        #expect(capped.status == 0, "\(capped.stderr)")
        let cappedRows = try #require(
            (try CLIRunner.json(capped.stdout)["data"] as? [String: Any])?["events"]
                as? [[String: Any]])
        #expect((cappedRows.first?["value"] as? String)?.count == 10)

        let full = try CLIRunner.run(
            ["events", "--since", "0", "--max-value-chars", "0", "--json"], env: env)
        #expect(full.status == 0, "\(full.stderr)")
        let fullRows = try #require(
            (try CLIRunner.json(full.stdout)["data"] as? [String: Any])?["events"]
                as? [[String: Any]])
        #expect((fullRows.first?["value"] as? String)?.count == 5000)
    }

    /// Export is a read path too — the same projection `events` applies must not be skipped
    /// here just because the JSONL writer is a different code path.
    @Test func exportRedactsSecretsAtReadTime() async throws {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        try await store.append(
            RawEvent(
                ts: 100, kind: .contextSnapshot, bundleID: "com.apple.TextEdit",
                value: "token AKIAQQQQWWWWEEEERRRR end"))
        await store.close()
        let env = ["OPENRHYME_DATA_DIR": dir.path]

        let result = try CLIRunner.run(["export", "--since", "0"], env: env)
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains(#""value":"token [redacted:aws-key] end""#))
        #expect(!result.stdout.contains("AKIAQQQQWWWWEEEERRRR"))
    }

    // MARK: - J8 (privacy fix round 1): read-time redaction covers every text-bearing column,
    // not just `value`/`selected_text` — a credential is just as real leaked in a URL query
    // string as it is in `value`.

    @Test func eventsRedactsSecretsInURLDocumentWindowTitleAndElementTitle() async throws {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        try await store.append(
            RawEvent(
                ts: 100, kind: .contextSnapshot, bundleID: "com.apple.Safari",
                windowTitle: "token AKIAQQQQWWWWEEEERRRR here",
                document: "/tmp/AKIAQQQQWWWWEEEERRRR.txt",
                url: "https://ex.com/?token=AKIAQQQQWWWWEEEERRRR",
                elementTitle: "field AKIAQQQQWWWWEEEERRRR"))
        await store.close()
        let env = ["OPENRHYME_DATA_DIR": dir.path]

        let result = try CLIRunner.run(["events", "--since", "0", "--json"], env: env)
        #expect(result.status == 0, "\(result.stderr)")
        let rows = try #require(
            (try CLIRunner.json(result.stdout)["data"] as? [String: Any])?["events"]
                as? [[String: Any]])
        let row = try #require(rows.first)
        #expect(row["window_title"] as? String == "token [redacted:aws-key] here")
        #expect(row["document"] as? String == "/tmp/[redacted:aws-key].txt")
        #expect(row["url"] as? String == "https://ex.com/?token=[redacted:aws-key]")
        #expect(row["element_title"] as? String == "field [redacted:aws-key]")
    }

    /// Read-time redaction only ever changes what is *returned* — it must never write back to
    /// the store, so capture-time artifacts computed from the original, unredacted text
    /// (`extra.fingerprint`, a value hash) are unaffected by what a later read redacts.
    @Test func redactionAtReadTimeNeverAffectsStoredFingerprintOrHashArtifacts() async throws {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        try await store.append(
            RawEvent(
                ts: 100, kind: .contextSnapshot, bundleID: "com.apple.TextEdit",
                value: "token AKIAQQQQWWWWEEEERRRR end",
                extra: ["fingerprint": "abc123", "valueHash": "def456"]))
        await store.close()
        let env = ["OPENRHYME_DATA_DIR": dir.path]

        let result = try CLIRunner.run(["events", "--since", "0", "--json"], env: env)
        #expect(result.status == 0, "\(result.stderr)")
        let rows = try #require(
            (try CLIRunner.json(result.stdout)["data"] as? [String: Any])?["events"]
                as? [[String: Any]])
        let row = try #require(rows.first)
        #expect(row["value"] as? String == "token [redacted:aws-key] end")
        let extra = try #require(row["extra"] as? [String: Any])
        #expect(extra["fingerprint"] as? String == "abc123")
        #expect(extra["valueHash"] as? String == "def456")

        // And the store itself was never touched — reading again (or exporting) sees the exact
        // same raw, unredacted bytes underneath.
        let raw = try EventStore(
            url: dir.appendingPathComponent("events.sqlite"), readOnly: true)
        let stored = try await raw.query(EventQuery(since: 0))
        await raw.close()
        #expect(stored.first?.value == "token AKIAQQQQWWWWEEEERRRR end")
    }

    // MARK: - S3 (privacy fix round 3): read-time redaction must also cover
    // `extra.previousTitle` — `HeartbeatDiff` copies the prior window title into it verbatim on
    // a `window.title_changed` row, so a secret redacted out of `window_title` on one row was
    // otherwise still sitting in plain text right next to it, in `extra`, on that very row.

    @Test func eventsAndExportRedactSecretsInExtraPreviousTitleWithoutTouchingHashes()
        async throws
    {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        try await store.append(
            RawEvent(
                ts: 100, kind: .windowTitleChanged, bundleID: "com.apple.Safari",
                windowTitle: "new title [redacted:aws-key]",
                extra: [
                    "reason": "titleChanged",
                    "previousTitle": "prev title AKIAQQQQWWWWEEEERRRR",
                    "fingerprint": "abc123", "valueHash": "def456",
                ]))
        await store.close()
        let env = ["OPENRHYME_DATA_DIR": dir.path]

        let eventsResult = try CLIRunner.run(["events", "--since", "0", "--json"], env: env)
        #expect(eventsResult.status == 0, "\(eventsResult.stderr)")
        let eventsRows = try #require(
            (try CLIRunner.json(eventsResult.stdout)["data"] as? [String: Any])?["events"]
                as? [[String: Any]])
        let eventsExtra = try #require(eventsRows.first?["extra"] as? [String: Any])
        #expect(eventsExtra["previousTitle"] as? String == "prev title [redacted:aws-key]")
        #expect(eventsExtra["fingerprint"] as? String == "abc123")
        #expect(eventsExtra["valueHash"] as? String == "def456")

        let exportResult = try CLIRunner.run(["export", "--since", "0"], env: env)
        #expect(exportResult.status == 0, "\(exportResult.stderr)")
        #expect(
            exportResult.stdout.contains(#""previousTitle":"prev title [redacted:aws-key]""#))
        #expect(exportResult.stdout.contains(#""fingerprint":"abc123""#))
        #expect(exportResult.stdout.contains(#""valueHash":"def456""#))
        #expect(!exportResult.stdout.contains("AKIAQQQQWWWWEEEERRRR"))
    }

    // MARK: - J9 (privacy fix round 1): a corrupt config.json must fail closed with a mapped
    // error, not leak a raw DecodingError as an unmapped internal_error.

    @Test func eventsWithACorruptConfigFailsClosedWithAMappedError() async throws {
        let dir = try CLIRunner.tempDataDir()
        try Data("{not valid json".utf8).write(to: dir.appendingPathComponent("config.json"))
        let result = try CLIRunner.run(
            ["events", "--since", "0", "--json"], env: ["OPENRHYME_DATA_DIR": dir.path])
        #expect(result.status != 0)
        let error = try #require(
            (try CLIRunner.json(result.stdout)["error"] as? [String: Any]))
        #expect(error["code"] as? String == "config_invalid")
        #expect(!(error["message"] as? String ?? "").isEmpty)
    }

    @Test func exportWithACorruptConfigFailsClosedWithAMappedError() async throws {
        let dir = try CLIRunner.tempDataDir()
        try Data("{not valid json".utf8).write(to: dir.appendingPathComponent("config.json"))
        let result = try CLIRunner.run(
            ["export", "--since", "0"], env: ["OPENRHYME_DATA_DIR": dir.path])
        #expect(result.status != 0)
        #expect(
            result.stderr.contains("config_invalid") || result.stderr.contains("not valid JSON"))
    }

    // MARK: - J11: `--max-value-chars` help says "0 = full" — a negative value is not a third
    // meaning and must be rejected, not silently treated as full.

    /// Privacy fix round 2, S6: this used the *space-separated* form, which ArgumentParser
    /// rejects at parse time as a missing option value — before `EventsCommand.validate()` is
    /// ever reached — so it exited 2 on the unfixed code too and tested nothing. The `=` form
    /// (how a script that computed a negative budget emits it) is what actually reaches
    /// `validate()`, and the store is seeded so that without the fix the command would succeed
    /// and return the full value rather than fail for some unrelated reason.
    @Test func negativeMaxValueCharsIsRejected() async throws {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        try await store.append(
            RawEvent(
                ts: 100, kind: .contextSnapshot, bundleID: "com.apple.TextEdit",
                value: String(repeating: "x", count: 50)))
        await store.close()

        let result = try CLIRunner.run(
            ["events", "--since", "0", "--max-value-chars=-1", "--json"],
            env: ["OPENRHYME_DATA_DIR": dir.path])
        #expect(result.status == 2 || result.status == 64)  // ArgumentParser uses EX_USAGE
        #expect(
            result.stderr.contains("--max-value-chars must be >= 0"),
            "expected the validation message, got: \(result.stderr)\(result.stdout)")
    }

    // MARK: - J12: when `--max-value-chars` actually cuts `value`/`selected_text`,
    // `extra.valueTruncated` says so. (Ruling R32: the default was changed 2000 → 0 in this same
    // fix round — see Task 12 docs — so this comment no longer claims otherwise.)

    @Test func truncatedValueIsFlaggedInExtraButAFullValueIsNot() async throws {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        try await store.append(
            RawEvent(
                ts: 100, kind: .contextSnapshot, bundleID: "com.apple.TextEdit",
                value: String(repeating: "x", count: 20)))
        try await store.append(
            RawEvent(
                ts: 200, kind: .contextSnapshot, bundleID: "com.apple.TextEdit",
                value: "short"))
        await store.close()
        let env = ["OPENRHYME_DATA_DIR": dir.path]

        let result = try CLIRunner.run(
            ["events", "--since", "0", "--max-value-chars", "10", "--json"], env: env)
        #expect(result.status == 0, "\(result.stderr)")
        let rows = try #require(
            (try CLIRunner.json(result.stdout)["data"] as? [String: Any])?["events"]
                as? [[String: Any]])
        #expect(rows.count == 2)
        let truncatedRow = try #require(rows.first { ($0["value"] as? String)?.count == 10 })
        #expect((truncatedRow["extra"] as? [String: Any])?["valueTruncated"] as? Bool == true)
        let shortRow = try #require(rows.first { $0["value"] as? String == "short" })
        #expect((shortRow["extra"] as? [String: Any])?["valueTruncated"] == nil)
    }

    @Test func maxValueCharsZeroNeverFlagsTruncationEvenForALongValue() async throws {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        try await store.append(
            RawEvent(
                ts: 100, kind: .contextSnapshot, bundleID: "com.apple.TextEdit",
                value: String(repeating: "x", count: 5000)))
        await store.close()
        let env = ["OPENRHYME_DATA_DIR": dir.path]

        let result = try CLIRunner.run(
            ["events", "--since", "0", "--max-value-chars", "0", "--json"], env: env)
        #expect(result.status == 0, "\(result.stderr)")
        let rows = try #require(
            (try CLIRunner.json(result.stdout)["data"] as? [String: Any])?["events"]
                as? [[String: Any]])
        #expect((rows.first?["extra"] as? [String: Any])?["valueTruncated"] == nil)
    }
}
