import Foundation
import Testing

@Suite struct InspectCommandTests {
    @Test func inspectEitherReportsContextOrNotTrusted() throws {
        let result = try CLIRunner.run(["inspect", "--json", "--depth", "1"])
        let envelope = try CLIRunner.json(result.stdout)
        if result.status == 3 {
            #expect(envelope["ok"] as? Bool == false)
            #expect((envelope["error"] as? [String: Any])?["code"] as? String == "not_trusted")
        } else {
            #expect(result.status == 0, "\(result.stderr)")
            let data = envelope["data"] as? [String: Any]
            #expect(data?["app"] != nil)
            #expect(data?["attribute_names"] is [String])
        }
    }

    @Test func inspectRejectsNegativeDepth() throws {
        let result = try CLIRunner.run(["inspect", "--depth", "-1", "--json"])
        #expect(result.status == 2 || result.status == 64)  // ArgumentParser uses EX_USAGE
    }
}
