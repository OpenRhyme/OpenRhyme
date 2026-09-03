import Testing

@testable import Capture

@Suite struct ContentCacheTests {
    @Test func matchesOnIdenticalCheapIdentity() {
        let cache = ContentCache(
            role: "AXWebArea", subrole: nil, identifier: "id", title: "t",
            windowTitle: "Page", document: nil, url: "https://x", value: "body", textSource: "range"
        )
        #expect(
            cache.matches(
                role: "AXWebArea", subrole: nil, identifier: "id", title: "t",
                windowTitle: "Page", document: nil, url: "https://x"))
    }

    @Test func differsWhenAnyCheapFieldChanges() {
        let cache = ContentCache(
            role: "AXWebArea", subrole: nil, identifier: nil, title: nil,
            windowTitle: "Page A", document: nil, url: "https://a", value: "a", textSource: "range")
        #expect(
            !cache.matches(
                role: "AXWebArea", subrole: nil, identifier: nil, title: nil,
                windowTitle: "Page B", document: nil, url: "https://a"))
        #expect(
            !cache.matches(
                role: "AXWebArea", subrole: nil, identifier: nil, title: nil,
                windowTitle: "Page A", document: nil, url: "https://b"))
    }

    @Test func elementInfoCarriesTextSource() {
        var info = ElementInfo(role: "AXTextArea", value: "hi")
        #expect(info.textSource == nil)
        info.textSource = "value"
        #expect(info.textSource == "value")
    }

    @Test func matchesAcrossBadgeFlicker() {
        let cache = ContentCache(
            role: "AXWebArea", windowTitle: "Doc - Audio playing - Google Chrome - Pragan",
            url: "https://x")
        #expect(
            cache.matches(
                role: "AXWebArea", subrole: nil, identifier: nil, title: nil,
                windowTitle: "(4) Doc - Google Chrome - Pragan", document: nil, url: "https://x"))
    }
}
