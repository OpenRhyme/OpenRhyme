import Foundation
import Testing

@Suite struct AppsRunningTests {
    @Test func listsRunningAppsWithFlags() throws {
        let dir = try CLIRunner.tempDataDir()
        let env = ["OPENRHYME_DATA_DIR": dir.path]
        _ = try CLIRunner.run(["apps", "allow", "com.apple.finder"], env: env)
        let result = try CLIRunner.run(["apps", "running", "--json"], env: env)
        #expect(result.status == 0, "\(result.stderr)")
        let apps =
            (try CLIRunner.json(result.stdout)["data"] as? [String: Any])?["apps"]
            as? [[String: Any]]
        let finder = apps?.first { $0["bundle_id"] as? String == "com.apple.finder" }
        #expect(finder != nil, "Finder is always running in a logged-in session")
        #expect(finder?["allowlisted"] as? Bool == true)
        #expect(finder?["is_electron"] as? Bool == false)
        #expect((finder?["pid"] as? Int ?? 0) > 0)
    }
}
