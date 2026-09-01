import Foundation
import Testing

@testable import Core

@Suite struct ConfigTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-\(UUID().uuidString).json")
    }

    @Test func missingFileYieldsDefaults() throws {
        let config = try Config.load(from: tempURL())
        #expect(config.allowlist.isEmpty)
        #expect(config.capture == CaptureSettings())
        #expect(config.capture.heartbeatSeconds == 5)
        #expect(config.capture.idleSeconds == 120)
        #expect(config.capture.valueDebounceMs == 500)
        #expect(config.capture.maxValueBytes == 524_288)
        #expect(config.capture.recordOtherApps == false)
    }

    @Test func loadsKnownKeysAndKeepsUnknownOnes() throws {
        let url = tempURL()
        try """
        {"schema":1,"note":"keep me","allowlist":["com.apple.Safari"],
         "capture":{"heartbeat_seconds":2,"custom":true}}
        """.write(to: url, atomically: true, encoding: .utf8)
        var config = try Config.load(from: url)
        #expect(config.allowlist == ["com.apple.Safari"])
        #expect(config.capture.heartbeatSeconds == 2)
        #expect(config.capture.idleSeconds == 120)

        config = config.allowing("com.apple.TextEdit").allowing("com.apple.Safari")
        try config.save(to: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(#""note" : "keep me""#))
        #expect(text.contains(#""custom" : true"#))
        let reloaded = try Config.load(from: url)
        #expect(reloaded.allowlist == ["com.apple.Safari", "com.apple.TextEdit"])
        #expect(reloaded.capture.heartbeatSeconds == 2)
    }

    @Test func allowAndDenyAreIdempotent() {
        let config = Config().allowing("a").allowing("a").allowing("b").denying("zzz")
        #expect(config.allowlist == ["a", "b"])
        #expect(config.denying("a").allowlist == ["b"])
        #expect(config.isAllowed("a"))
        #expect(!config.isAllowed("c"))
        #expect(!config.isAllowed(nil))
    }

    @Test func savedFileIsPrettyAndSorted() throws {
        let url = tempURL()
        try Config(allowlist: ["b", "a"]).save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("{\n"))
        #expect(
            text.range(of: "\"allowlist\"")!.lowerBound < text.range(of: "\"capture\"")!.lowerBound)
        #expect(text.contains(#""schema" : 1"#))
    }

    @Test func outOfRangeNumericValuesKeepDefaults() throws {
        let url = tempURL()
        try """
        {"schema":1,"capture":{"max_value_bytes":99999999999999999999,"value_debounce_ms":1.5}}
        """.write(to: url, atomically: true, encoding: .utf8)
        let config = try Config.load(from: url)
        #expect(config.capture.maxValueBytes == 524_288)
        #expect(config.capture.valueDebounceMs == 500)
    }
}
