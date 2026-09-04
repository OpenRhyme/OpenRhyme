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
}
