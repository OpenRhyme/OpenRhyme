import Foundation
import Testing

@testable import Capture

/// Live AX tests. Require a TCC grant on the terminal; never run in CI.
/// Bring a text-heavy Chrome page (a Wikipedia article) and an open TextEdit doc to the front,
/// then: OPENRHYME_LIVE_AX=1 swift test --filter LiveContentTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENRHYME_LIVE_AX"] == "1"))
@MainActor struct LiveContentTests {
    @Test func extractsTextFromFrontmostApp() throws {
        let client = AXClient()
        #expect(client.isTrusted(prompt: false), "grant Accessibility to the terminal first")
        let app = try #require(client.frontmostApplication())
        let ctx = try client.focusedContext(of: app, reusing: nil, policy: .disabled)
        let el = try #require(ctx.element)
        print(
            "LIVE \(app.bundleID ?? "?"): role=\(el.role ?? "-") textSource=\(el.textSource ?? "nil") len=\(el.value?.count ?? 0)"
        )
        // On a text-bearing frontmost app we expect *some* content and a recorded source.
        if let value = el.value, !value.isEmpty {
            #expect(el.textSource != nil)
        }
    }

    @Test func unchangedContextDoesNotReExtract() throws {
        let client = AXClient()
        #expect(client.isTrusted(prompt: false))
        let app = try #require(client.frontmostApplication())
        let first = try client.focusedContext(of: app, reusing: nil, policy: .disabled)
        let count = client.contentReadCount
        // Feed the first result back as the cache; an unchanged context must be a cache hit.
        let cache = client.cache(from: first)
        _ = try client.focusedContext(of: app, reusing: cache, policy: .disabled)
        #expect(client.contentReadCount == count, "unchanged context re-ran the content read")
    }
}
