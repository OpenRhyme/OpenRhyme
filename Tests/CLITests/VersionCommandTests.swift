import Foundation
import Testing

@Suite struct VersionCommandTests {
    @Test func versionJSONEnvelope() throws {
        let result = try CLIRunner.run(["version", "--json"])
        #expect(result.status == 0, "\(result.stderr)")
        let envelope = try CLIRunner.json(result.stdout)
        #expect(envelope["ok"] as? Bool == true)
        let data = envelope["data"] as? [String: Any]
        #expect(data?["engine"] as? String == "0.1.0")
        #expect(data?["schema"] as? Int == 1)
        #expect(result.stdout.filter { $0 == "\n" }.count == 1, "exactly one line")
    }

    @Test func versionHumanOutput() throws {
        let result = try CLIRunner.run(["version"])
        #expect(result.status == 0)
        #expect(result.stdout == "openrhyme 0.1.0 (schema 1)\n")
    }

    @Test func unknownCommandExitsWithUsageCode() throws {
        let result = try CLIRunner.run(["bogus"])
        #expect(result.status == 2)
    }

    @Test func helpExitsZeroWithUsageText() throws {
        let result = try CLIRunner.run(["--help"])
        #expect(result.status == 0)
        #expect(result.stdout.contains("USAGE") || result.stdout.contains("OVERVIEW"))
    }
}
