import Testing

@testable import Capture

@Suite struct FingerprintTests {
    @Test func canonicalFormIsTheContract() {
        let canonical = Fingerprint.canonical(
            bundleID: "com.google.Chrome",
            windowTitle: "(86) Foo - Audio playing - Google Chrome - Pragan", document: nil,
            url: "https://x.com/p#frag")
        #expect(
            canonical
                == "com.google.Chrome\u{1F}Foo - Google Chrome - Pragan\u{1F}\u{1F}https://x.com/p")
    }

    @Test func goldenHashes() {
        #expect(
            Fingerprint.compute(
                bundleID: "com.google.Chrome",
                windowTitle: "(86) Foo - Audio playing - Google Chrome - Pragan", document: nil,
                url: "https://x.com/p#frag") == "15c45e719bd57fb5")
        #expect(
            Fingerprint.compute(bundleID: nil, windowTitle: nil, document: nil, url: nil)
                == "c60b1f6ce4ac96cd")
        #expect(
            Fingerprint.compute(
                bundleID: "com.apple.TextEdit", windowTitle: "notes.md — Edited",
                document: "/Users/me/notes.md", url: nil) == "1ed05bf577992322")
    }

    @Test func badgeFlickerAndFragmentsDoNotChangeIt() {
        let a = Fingerprint.compute(
            bundleID: "com.google.Chrome", windowTitle: "Foo - Google Chrome - Pragan",
            document: nil,
            url: "https://x.com/p")
        let b = Fingerprint.compute(
            bundleID: "com.google.Chrome",
            windowTitle: "(2) Foo - Audio playing - Google Chrome - Pragan",
            document: nil, url: "https://x.com/p#section-3")
        #expect(a == b)
        #expect(a.count == 16)
        #expect(a.allSatisfy { $0.isHexDigit })
        let other = Fingerprint.compute(
            bundleID: "com.google.Chrome", windowTitle: "Bar - Google Chrome - Pragan",
            document: nil,
            url: "https://x.com/q")
        #expect(a != other)
    }
}
