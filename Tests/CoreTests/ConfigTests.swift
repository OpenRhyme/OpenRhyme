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
        // The diagnostic is never written as a config key...
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("unknown"))
        // ...and, since I5, an unchanged `capture` block is left exactly as the user wrote it,
        // typo included. Scrubbing the typo on an unrelated save was itself a silent rewrite of
        // the user's file; the daemon warns about it instead (`Capturer.warnAboutConfig`).
        #expect(again.capture.unknownNotificationNames == ["bogus"])
    }

    /// Whole-branch review I4: the natural form of a privacy list — a plain array — used to be
    /// discarded, giving the user zero protection and zero warning. It is now read as `add` (so
    /// the entry protects them) and flagged (so they learn the defaults are still in force too).
    @Test func aPrivacyListWrittenAsABareArrayIsAcceptedAsAddAndFlagged() throws {
        let url = tempURL()
        try """
        {"schema":1,"allowlist":[],"privacy":{
          "protected_bundle_ids":["com.example.MyVault"],
          "protected_document_patterns":["*.vault"]}}
        """.write(to: url, atomically: true, encoding: .utf8)
        let config = try Config.load(from: url)
        #expect(config.privacy.protectedBundleIDs.contains("com.example.MyVault"))
        #expect(config.privacy.protectedDocumentPatterns.contains("*.vault"))
        // Adding, not replacing: the built-in defaults are still in force.
        #expect(config.privacy.protectedBundleIDs.contains("com.1password.1password"))
        #expect(config.privacy.protectedDocumentPatterns.contains(".env"))
        #expect(
            config.privacy.listKeysWrittenAsArray
                == ["protected_bundle_ids", "protected_document_patterns"])
        #expect(config.privacy.listKeysIgnored.isEmpty)
        #expect(config.privacy.configWarnings.count == 1)
        #expect(config.privacy.configWarnings[0].contains("protected_bundle_ids"))
        #expect(config.privacy.configWarnings[0].contains("treated as \"add\""))
    }

    /// A shape nothing can be read from is reported too — it is the same silent no-op.
    @Test func anUnreadablePrivacyListShapeIsFlaggedRatherThanIgnoredSilently() throws {
        let url = tempURL()
        try """
        {"schema":1,"allowlist":[],"privacy":{
          "protected_url_patterns":"vault.example.com",
          "protected_window_title_patterns":{"added":["incognito"]}}}
        """.write(to: url, atomically: true, encoding: .utf8)
        let config = try Config.load(from: url)
        #expect(config.privacy.protectedURLPatterns == PrivacySettings.defaultURLPatterns)
        #expect(
            config.privacy.protectedWindowTitlePatterns
                == PrivacySettings.defaultWindowTitlePatterns)
        #expect(
            config.privacy.listKeysIgnored
                == ["protected_url_patterns", "protected_window_title_patterns"])
        #expect(config.privacy.configWarnings.count == 1)
        #expect(config.privacy.configWarnings[0].contains("ignored"))
    }

    @Test func aWellFormedPrivacyBlockProducesNoWarnings() throws {
        let url = tempURL()
        try """
        {"schema":1,"allowlist":[],"privacy":{
          "protected_bundle_ids":{"add":["com.example.MyVault"]},
          "protected_document_patterns":{"remove":[".env"]}}}
        """.write(to: url, atomically: true, encoding: .utf8)
        let config = try Config.load(from: url)
        #expect(config.privacy.configWarnings.isEmpty)
        #expect(config.privacy.protectedBundleIDs.contains("com.example.MyVault"))
        #expect(!config.privacy.protectedDocumentPatterns.contains(".env"))
    }

    /// I4 diagnostics follow the `unknownNotificationNames` contract: not compared for equality,
    /// and never written back as a config key.
    @Test func privacyDiagnosticsAreNotComparedForEqualityAndAreNotSaved() throws {
        let bare = PrivacySettings(json: ["protected_bundle_ids": .array([.string("com.x")])])
        let explicit = PrivacySettings(
            json: ["protected_bundle_ids": .object(["add": .array([.string("com.x")])])])
        #expect(bare == explicit)
        #expect(!bare.listKeysWrittenAsArray.isEmpty)
        #expect(explicit.listKeysWrittenAsArray.isEmpty)

        let url = tempURL()
        try Config(privacy: bare).save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("listKeys"))
        #expect(try Config.load(from: url).privacy == bare)
    }

    /// Whole-branch review I5: `openrhyme apps allow` turned `"retention_days":"30"` into `0`
    /// and a hand-written protect list into `{"add":[],"remove":[]}` — erasing a protect rule
    /// from an unrelated command. A section the caller did not change is now left alone.
    @Test func savingAnUnrelatedChangeLeavesHandWrittenSectionsUntouched() throws {
        let url = tempURL()
        try """
        {"schema":1,"allowlist":[],
         "capture":{"retention_days":"30","heartbeat_seconds":9,"mine":"keep"},
         "privacy":{"protected_bundle_ids":["com.example.MyVault"],"mine":"keep"}}
        """.write(to: url, atomically: true, encoding: .utf8)
        let before = try Config.load(from: url)
        try before.allowing("com.apple.TextEdit").save(to: url)

        let after = try Config.load(from: url)
        #expect(after.allowlist == ["com.apple.TextEdit"])
        // Byte-for-byte: the two sections re-encode to exactly what they were.
        #expect(after.raw["capture"] == before.raw["capture"])
        #expect(after.raw["privacy"] == before.raw["privacy"])
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(#""retention_days" : "30""#))  // not normalised to 0
        #expect(text.contains(#""com.example.MyVault""#))  // not replaced by add/remove
        #expect(!text.contains(#""remove""#))
        // And the diagnostics still fire on the reloaded config, so the user is still told.
        #expect(after.capture.retentionDaysInvalid)
        #expect(after.privacy.listKeysWrittenAsArray == ["protected_bundle_ids"])
    }

    /// The other half of I5: a section the caller *did* change is still written back, and a
    /// section absent from the file is still materialised on a first write.
    @Test func changedSectionsAreStillWrittenAndMissingOnesStillMaterialise() throws {
        let url = tempURL()
        try #"{"schema":1,"allowlist":[],"capture":{"retention_days":"30"}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        var config = try Config.load(from: url)
        config.capture.retentionDays = 7
        try config.save(to: url)
        let after = try Config.load(from: url)
        #expect(after.capture.retentionDays == 7)
        #expect(!after.capture.retentionDaysInvalid)
        // `privacy` was absent, so the defaults were materialised.
        #expect(after.raw["privacy"]?.objectValue?["enabled"] == true)
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

    @Test func privacyDefaultsAndAddRemoveSemantics() throws {
        let defaults = PrivacySettings()
        #expect(defaults.enabled)
        #expect(defaults.entropyRedaction)
        #expect(defaults.protectedBundleIDs.contains("com.1password.1password"))
        #expect(defaults.protectedDocumentPatterns.contains(".env"))
        #expect(CaptureSettings().retentionDays == 0)

        let url = tempURL()
        try """
        {"schema":1,"allowlist":[],
         "capture":{"retention_days":30},
         "privacy":{"entropy_redaction":false,
           "protected_bundle_ids":{"add":["com.example.Vault"],"remove":["com.apple.keychainaccess"]},
           "protected_document_patterns":{"add":["*.secret"],"remove":[".npmrc"]}}}
        """.write(to: url, atomically: true, encoding: .utf8)
        let config = try Config.load(from: url)
        #expect(config.capture.retentionDays == 30)
        #expect(!config.privacy.entropyRedaction)
        #expect(config.privacy.protectedBundleIDs.contains("com.example.Vault"))
        #expect(config.privacy.protectedBundleIDs.contains("com.1password.1password"))
        #expect(!config.privacy.protectedBundleIDs.contains("com.apple.keychainaccess"))
        #expect(config.privacy.protectedDocumentPatterns.contains("*.secret"))
        #expect(!config.privacy.protectedDocumentPatterns.contains(".npmrc"))

        try config.save(to: url)
        let again = try Config.load(from: url)
        #expect(again.privacy == config.privacy)
        #expect(again.capture.retentionDays == 30)
    }

    /// Privacy fix round 1, safeguard: a string-typed `retention_days` (e.g. `"30"`) is a
    /// silent-corruption trap otherwise — it fails to parse, falls back to the `0` default, and
    /// nothing signals that it did. `retentionDaysInvalid` is that signal.
    @Test func stringTypedRetentionDaysFallsBackToZeroAndIsFlaggedInvalid() throws {
        let url = tempURL()
        try #"{"schema":1,"allowlist":[],"capture":{"retention_days":"30"}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let config = try Config.load(from: url)
        #expect(config.capture.retentionDays == 0)
        #expect(config.capture.retentionDaysInvalid)
    }

    @Test func validRetentionDaysIsNotFlaggedInvalid() throws {
        let url = tempURL()
        try #"{"schema":1,"allowlist":[],"capture":{"retention_days":30}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let config = try Config.load(from: url)
        #expect(config.capture.retentionDays == 30)
        #expect(!config.capture.retentionDaysInvalid)
    }

    @Test func missingRetentionDaysIsNotFlaggedInvalid() throws {
        let config = try Config.load(from: tempURL())
        #expect(!config.capture.retentionDaysInvalid, "unset is not the same as invalid")
    }

    /// Privacy fix round 1, J9: a `config.json` that exists but fails to parse must fail closed
    /// with a distinct, mapped error — not be silently treated as "no privacy settings
    /// configured" (which is what falling through to `Config()`'s defaults would mean).
    @Test func malformedJSONThrowsConfigParseErrorRatherThanFallingBackToDefaults() throws {
        let url = tempURL()
        try "{not valid json".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: ConfigParseError.self) {
            try Config.load(from: url)
        }
    }

    @Test func privacyCanBeDisabledWholesale() throws {
        let url = tempURL()
        try #"{"schema":1,"allowlist":[],"privacy":{"enabled":false}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let config = try Config.load(from: url)
        #expect(!config.privacy.enabled)
    }
}
