import Foundation
import Testing

@Suite struct AppsCommandTests {
    @Test func allowListDenyRoundTrip() throws {
        let dir = try CLIRunner.tempDataDir()
        let env = ["OPENRHYME_DATA_DIR": dir.path]

        var result = try CLIRunner.run(["apps", "list", "--json"], env: env)
        #expect(result.status == 0)
        #expect(
            (try CLIRunner.json(result.stdout)["data"] as? [String: Any])?["allowlist"] as? [String]
                == [])

        result = try CLIRunner.run(["apps", "allow", "com.apple.TextEdit", "--json"], env: env)
        #expect(result.status == 0, "\(result.stderr)")
        var data = try CLIRunner.json(result.stdout)["data"] as? [String: Any]
        #expect(data?["changed"] as? Bool == true)
        #expect(data?["allowlist"] as? [String] == ["com.apple.TextEdit"])

        result = try CLIRunner.run(["apps", "allow", "com.apple.TextEdit", "--json"], env: env)
        data = try CLIRunner.json(result.stdout)["data"] as? [String: Any]
        #expect(data?["changed"] as? Bool == false)

        #expect(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path))

        result = try CLIRunner.run(["apps", "deny", "com.apple.TextEdit"], env: env)
        #expect(result.status == 0)
        #expect(result.stdout.contains("(empty)"))
    }

    /// Whole-branch review I5: `apps allow` rewrote the whole file, turning
    /// `"retention_days":"30"` into `0` and a hand-written protect list into
    /// `{"add":[],"remove":[]}` — a user's protect rule erased with no trace by an unrelated
    /// command. Byte-identity is checked by re-encoding the `privacy` sub-tree of both files
    /// with the same canonical (sorted-key) encoder: same bytes in, same bytes out.
    @Test func allowLeavesAHandWrittenPrivacyBlockByteIdentical() throws {
        let dir = try CLIRunner.tempDataDir()
        let configURL = dir.appendingPathComponent("config.json")
        let handWritten = """
            {"schema":1,"allowlist":[],
             "capture":{"retention_days":"30"},
             "privacy":{"protected_bundle_ids":["com.example.MyVault"],
                        "protected_document_patterns":{"add":["*.vault"]},
                        "note":"my own key"}}
            """
        try handWritten.write(to: configURL, atomically: true, encoding: .utf8)
        let before = try Self.canonical(section: "privacy", inJSON: handWritten)

        let result = try CLIRunner.run(
            ["apps", "allow", "com.apple.TextEdit", "--json"],
            env: ["OPENRHYME_DATA_DIR": dir.path])
        #expect(result.status == 0, "\(result.stderr)")

        let saved = try String(contentsOf: configURL, encoding: .utf8)
        #expect(try Self.canonical(section: "privacy", inJSON: saved) == before)
        // The command's own change did land, and the unrelated `capture` block survived too.
        #expect(saved.contains(#""com.apple.TextEdit""#))
        #expect(saved.contains(#""retention_days" : "30""#))
        #expect(saved.contains(#""note" : "my own key""#))
    }

    /// Re-serialises one top-level section with sorted keys, so two configs can be compared as
    /// bytes without depending on the incidental whitespace either file was written with.
    private static func canonical(section: String, inJSON text: String) throws -> String {
        let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        guard let value = root?[section] else { return "<missing \(section)>" }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    @Test func allowRejectsObviouslyInvalidIdentifier() throws {
        let env = ["OPENRHYME_DATA_DIR": try CLIRunner.tempDataDir().path]
        let result = try CLIRunner.run(["apps", "allow", "TextEdit", "--json"], env: env)
        #expect(result.status == 2)
        #expect(
            (try CLIRunner.json(result.stdout)["error"] as? [String: Any])?["code"] as? String
                == "usage")
    }
}
