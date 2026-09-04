import AppKit
import Core
import Foundation
import Testing

@testable import Capture

@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENRHYME_LIVE_AX"] == "1"))
@MainActor struct LiveAXClientTests {
    @Test func readsFrontmostContextWithoutThrowing() throws {
        let client = AXClient()
        #expect(client.isTrusted(prompt: false), "grant Accessibility to the terminal first")
        let frontmost = try #require(client.frontmostApplication())
        let context = try client.focusedContext(of: frontmost, reusing: nil, policy: .disabled)
        #expect(context.app == frontmost)
        #expect(client.runningApplications().contains { $0.pid == frontmost.pid })
        #expect(client.secondsSinceLastInput() >= 0)
        let inspection = try client.focusedElementInspection(
            of: frontmost, depth: 1, policy: .disabled)
        #expect(!inspection.attributeNames.isEmpty || inspection.tree == nil)
    }

    /// Privacy fix round 2 (G1): `focusedContext` fails closed on a windowless context (added in
    /// round 1), but `focusedElementInspection` never got the same guard — so it fell through to
    /// a real content read via `node()`/`readElement()` for exactly the same context
    /// `focusedContext` had just refused. A real GUI app's frontmost state is not a reliable
    /// stand-in for "windowless" (it varies with whatever the user is doing), so this targets a
    /// fixed, always-running system service instead: `com.apple.controlcenter` participates in
    /// the accessibility server (queries return cleanly, never `.cannotComplete`, unlike a plain
    /// non-GUI Unix process) but has no `AXFocusedWindow` at all — verified empirically
    /// (`AXUIElementCopyAttributeValue` returns `kAXErrorNoValue`), deterministic and portable
    /// because it doesn't depend on anything the user happens to be doing on screen.
    @Test func windowlessContextIsProtectedIdenticallyByFocusedContextAndElementInspection()
        throws
    {
        let client = AXClient()
        #expect(client.isTrusted(prompt: false), "grant Accessibility to the terminal first")
        let controlCenter = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.apple.controlcenter"
        }
        let app = try #require(
            controlCenter.map(AppInfo.init(running:)),
            "com.apple.controlcenter is not running — expected on any normal macOS session")

        var settings = PrivacySettings()
        settings.protectedBundleIDs.remove(app.bundleID ?? "")
        let policy = PrivacyPolicy(settings: settings)

        let context = try client.focusedContext(of: app, reusing: nil, policy: policy)
        #expect(context.window == nil, "test fixture assumption: ControlCenter has no AX window")
        guard case .protected(let contextRule) = context.protection else {
            Issue.record("expected a windowless context to fail closed via focusedContext")
            return
        }
        #expect(contextRule == "unverifiable-context")

        let inspection = try client.focusedElementInspection(of: app, depth: 1, policy: policy)
        #expect(inspection.protectedBy == "unverifiable-context")
        #expect(inspection.attributeNames.isEmpty)
        #expect(inspection.tree == nil)
    }
}
