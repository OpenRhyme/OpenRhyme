import Foundation
import Testing

@testable import Core

@Suite struct RawEventTests {
    @Test func usesSnakeCaseKeysAndOmitsNils() throws {
        let event = RawEvent(
            ts: 1_756_700_000.25, kind: .windowFocused, pid: 42,
            bundleID: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "notes.md",
            extra: ["reason": "heartbeat"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(event), as: UTF8.self)
        #expect(json.contains(#""bundle_id":"com.apple.TextEdit""#))
        #expect(json.contains(#""app_name":"TextEdit""#))
        #expect(json.contains(#""window_title":"notes.md""#))
        #expect(json.contains(#""kind":"window.focused""#))
        #expect(!json.contains("selected_text"))
        #expect(!json.contains(#""id""#))
    }

    @Test func roundTrips() throws {
        let event = RawEvent(
            ts: 1.5, kind: .elementValueChanged, pid: 7, bundleID: "b", appName: "a",
            windowTitle: "w", document: "file:///x", url: "https://e", role: "AXTextArea",
            subrole: "AXStandard", identifier: "id", elementTitle: "t", value: "v",
            selectedText: "s", extra: ["valueHash": "abc", "truncated": false, "length": 1])
        let data = try JSONEncoder().encode(event)
        let back = try JSONDecoder().decode(RawEvent.self, from: data)
        #expect(back == event)
    }

    @Test func everyKindHasDottedRawValue() {
        for kind in EventKind.allCases {
            #expect(kind.rawValue.contains("."), "\(kind) must be namespaced")
        }
        #expect(EventKind.allCases.count == 22)
        #expect(EventKind(rawValue: "context.snapshot") == .contextSnapshot)
    }
}
