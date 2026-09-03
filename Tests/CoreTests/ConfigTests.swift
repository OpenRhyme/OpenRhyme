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

    @Test func allUnknownNotificationNamesFallBackToDefaults() throws {
        let url = tempURL()
        try """
        {"schema":1,"allowlist":[],"capture":{
          "notifications":["windows","focuss"],
          "apps":{"com.apple.Notes":{"notifications":["bogus"]},
                  "com.apple.TextEdit":{"notifications":[]}}}}
        """.write(to: url, atomically: true, encoding: .utf8)
        let config = try Config.load(from: url)
        // A non-empty all-unknown list is a typo, not "observe nothing".
        #expect(config.capture.notifications == CaptureSettings.allNotifications)
        #expect(config.capture.appNotifications["com.apple.Notes"] == nil)
        #expect(
            config.capture.effectiveNotifications(for: "com.apple.Notes")
                == CaptureSettings.allNotifications)
        // An explicit empty list still means "observe nothing".
        #expect(config.capture.appNotifications["com.apple.TextEdit"] == [])
        #expect(config.capture.effectiveNotifications(for: "com.apple.TextEdit") == [])
        #expect(config.capture.unknownNotificationNames == ["bogus", "focuss", "windows"])
    }

    @Test func unknownNamesAreDiagnosticsOnlyAndDoNotAffectEqualityOrSaving() throws {
        let url = tempURL()
        try """
        {"schema":1,"allowlist":[],"capture":{"notifications":["window","bogus"]}}
        """.write(to: url, atomically: true, encoding: .utf8)
        let config = try Config.load(from: url)
        #expect(config.capture.notifications == ["window"])  // partial-unknown: keep the valid ones
        #expect(config.capture.unknownNotificationNames == ["bogus"])
        try config.save(to: url)
        let again = try Config.load(from: url)
        #expect(again.capture == config.capture)  // equality ignores the diagnostics field
        #expect(again.capture.unknownNotificationNames.isEmpty)  // not persisted
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

    @Test func noiseReductionKeysDefaultAndParse() throws {
        let defaults = CaptureSettings()
        #expect(defaults.userInputWindowSeconds == 2)
        #expect(defaults.contentMemorySeconds == 1800)
        #expect(defaults.activationSettleMs == 200)
        #expect(defaults.notifications == CaptureSettings.allNotifications)
        #expect(defaults.appNotifications.isEmpty)

        let url = tempURL()
        try """
        {"schema":1,"allowlist":[],"capture":{
          "user_input_window_seconds":3.5,"content_memory_seconds":60,"activation_settle_ms":50,
          "notifications":["window","title","bogus"],
          "apps":{"com.cmuxterm.app":{"notifications":["value"],"note":"keep"}}}}
        """.write(to: url, atomically: true, encoding: .utf8)
        let config = try Config.load(from: url)
        #expect(config.capture.userInputWindowSeconds == 3.5)
        #expect(config.capture.contentMemorySeconds == 60)
        #expect(config.capture.activationSettleMs == 50)
        #expect(config.capture.notifications == ["window", "title"])  // unknown names dropped
        #expect(config.capture.appNotifications == ["com.cmuxterm.app": ["value"]])
        // value ⇒ focus, per app and globally
        #expect(
            config.capture.effectiveNotifications(for: "com.cmuxterm.app") == ["value", "focus"])
        #expect(
            config.capture.effectiveNotifications(for: "com.google.Chrome") == ["window", "title"])
        #expect(config.capture.effectiveNotifications(for: nil) == ["window", "title"])

        try config.save(to: url)
        let again = try Config.load(from: url)
        #expect(again.capture == config.capture)
        #expect(
            again.raw["capture"]?.objectValue?["apps"]?.objectValue?["com.cmuxterm.app"]?
                .objectValue?["note"]?.stringValue == "keep")  // unknown per-app keys survive
    }
}
