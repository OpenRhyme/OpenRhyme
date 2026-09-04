import Capture
import Core
import Foundation
import Testing

@testable import openrhyme

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

    // MARK: - Privacy §5.4: `inspect` must not be a bypass.
    //
    // A protected `Inspection` (produced when either AXClient call sees a non-nil `protectedBy`)
    // must render nothing else: no window, no element, no attribute names, no tree. Exercising
    // the actual live AX wiring end-to-end (both `focusedContext` and `focusedElementInspection`
    // called with the *same*, real policy) needs a genuinely protected frontmost context, which
    // `InspectPrivacyLiveTests` below covers under `OPENRHYME_LIVE_AX=1`. These two tests pin the
    // presentation contract without needing live AX: given a protected `Inspection`, the human
    // and JSON output must carry only the rule, never window/document/url/element content.

    @Test func protectedInspectionHumanOutputIsOnlyTheRuleLine() {
        let inspection = InspectCommand.Inspection(
            app: nil, window: nil, element: nil, attributeNames: [], tree: nil,
            protectedBy: "bundle-id")
        #expect(InspectCommand.human(inspection) == "protected by rule 'bundle-id' — nothing read")
    }

    @Test func protectedInspectionJSONCarriesOnlyTheRuleNoLeakedFields() throws {
        let inspection = InspectCommand.Inspection(
            app: nil, window: nil, element: nil, attributeNames: [], tree: nil, protectedBy: "url")
        let object =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(inspection))
            as? [String: Any]
        #expect(object?["protectedBy"] as? String == "url")
        #expect(object?["window"] == nil || object?["window"] is NSNull)
        #expect(object?["element"] == nil || object?["element"] is NSNull)
        #expect(object?["tree"] == nil || object?["tree"] is NSNull)
        #expect((object?["attribute_names"] as? [String])?.isEmpty == true)
    }
}

/// Live AX tests. Require a TCC grant on the terminal; never run in CI (see
/// `Tests/CaptureTests/LiveContentTests.swift`).
/// Deterministic without controlling what's on screen: the frontmost app is made to protect
/// *itself* by adding its own bundle id to `protected_bundle_ids`, exactly like
/// `LiveContentTests.aProtectedContextPerformsNoContentRead`.
///
/// OPENRHYME_LIVE_AX=1 swift test --filter InspectPrivacyLiveTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENRHYME_LIVE_AX"] == "1"))
@MainActor struct InspectPrivacyLiveTests {
    @Test func plainInspectLeaksNothingForAProtectedContextAndIgnorePrivacyIsTheOnlyBypass()
        throws
    {
        let client = AXClient()
        #expect(client.isTrusted(prompt: false), "grant Accessibility to the terminal first")
        let app = try #require(client.frontmostApplication())
        let bundleID = try #require(app.bundleID)

        let dir = try CLIRunner.tempDataDir()
        var settings = PrivacySettings()
        settings.protectedBundleIDs = [bundleID]
        try Config(privacy: settings).save(to: dir.appendingPathComponent("config.json"))
        let env = ["OPENRHYME_DATA_DIR": dir.path]

        // Plain `inspect`: must protect the context and print/emit nothing else.
        let plain = try CLIRunner.run(["inspect", "--json"], env: env)
        #expect(plain.status == 0, "\(plain.stderr)")
        #expect(plain.stderr.isEmpty)
        let plainData = try #require(try CLIRunner.json(plain.stdout)["data"] as? [String: Any])
        #expect(plainData["protectedBy"] as? String == "bundle-id")
        #expect(plainData["window"] == nil || plainData["window"] is NSNull)
        #expect(plainData["element"] == nil || plainData["element"] is NSNull)
        #expect(plainData["tree"] == nil || plainData["tree"] is NSNull)
        #expect((plainData["attribute_names"] as? [String])?.isEmpty == true)

        let plainHuman = try CLIRunner.run(["inspect"], env: env)
        #expect(plainHuman.status == 0, "\(plainHuman.stderr)")
        #expect(
            plainHuman.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "protected by rule 'bundle-id' — nothing read")
        for leaked in ["window:", "document:", "url:", "element:", "value:", "selected:"] {
            #expect(!plainHuman.stdout.contains(leaked), "human output leaked '\(leaked)'")
        }

        // `--ignore-privacy` is the only way to see through it, and it must warn on stderr.
        let bypass = try CLIRunner.run(["inspect", "--ignore-privacy", "--json"], env: env)
        #expect(bypass.status == 0, "\(bypass.stderr)")
        #expect(
            bypass.stderr.contains(
                "warning: --ignore-privacy bypasses the protect rules for this read"))
        let bypassData = try #require(try CLIRunner.json(bypass.stdout)["data"] as? [String: Any])
        #expect(bypassData["protectedBy"] == nil || bypassData["protectedBy"] is NSNull)
        #expect(bypassData["window"] != nil && !(bypassData["window"] is NSNull))
    }
}
