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

    @Test func allowRejectsObviouslyInvalidIdentifier() throws {
        let env = ["OPENRHYME_DATA_DIR": try CLIRunner.tempDataDir().path]
        let result = try CLIRunner.run(["apps", "allow", "TextEdit", "--json"], env: env)
        #expect(result.status == 2)
        #expect(
            (try CLIRunner.json(result.stdout)["error"] as? [String: Any])?["code"] as? String
                == "usage")
    }
}
