import Foundation
import Testing

@testable import Core
@testable import Store

@Suite struct JSONLExportTests {
    @Test func keysFollowColumnOrderAndNilsAreOmitted() throws {
        let event = RawEvent(
            id: 3, ts: 1_756_700_000.5, kind: .contextSnapshot, pid: 9, bundleID: "com.x",
            windowTitle: "a \"quoted\" title\nline2", value: "v/slash",
            extra: ["reason": "heartbeat", "truncated": false, "length": 7])
        let line = try JSONLExport.line(for: event)
        #expect(!line.contains("\n"))
        #expect(
            line
                == #"{"id":3,"ts":1756700000.5,"kind":"context.snapshot","pid":9,"bundle_id":"com.x","window_title":"a \"quoted\" title\nline2","value":"v/slash","extra":{"length":7,"reason":"heartbeat","truncated":false}}"#
        )
    }

    @Test func integralTimestampKeepsNoFraction() throws {
        let line = try JSONLExport.line(for: RawEvent(ts: 10, kind: .idleStarted))
        #expect(line == #"{"ts":10,"kind":"idle.started"}"#)
    }

    @Test func lineIsValidJSONThatDecodesBack() throws {
        let event = RawEvent(
            ts: 1, kind: .elementFocused, role: "AXTextArea", selectedText: "tab\there",
            extra: ["nested": ["a": [1, 2]]])
        let line = try JSONLExport.line(for: event)
        let back = try JSONDecoder().decode(RawEvent.self, from: Data(line.utf8))
        #expect(back == event)
    }

    @Test func nanTimestampThrows() {
        #expect(throws: (any Error).self) {
            try JSONLExport.line(for: RawEvent(ts: .nan, kind: .idleStarted))
        }
    }

    @Test func infiniteTimestampThrows() {
        #expect(throws: (any Error).self) {
            try JSONLExport.line(for: RawEvent(ts: .infinity, kind: .idleStarted))
        }
    }
}
