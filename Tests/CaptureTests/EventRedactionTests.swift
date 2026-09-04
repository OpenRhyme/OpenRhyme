import Testing

@testable import Capture
@testable import Core

/// Whole-branch review H2: capture wrote `window_title`, `document`, `url` and `element_title`
/// verbatim while the read path redacted all six text columns plus `extra.previousTitle`, so an
/// API key in a URL query string sat on disk in the clear — invisible to `purge --apply-rules`,
/// counted as `0` by `openrhyme privacy`, and readable by anything that opens the SQLite file.
@Suite struct EventRedactionTests {
    private let policy = PrivacyPolicy(settings: PrivacySettings())
    private let key = "AKIAQQQQWWWWEEEERRRR"

    @Test func everyStoredTextColumnIsCoveredIncludingExtraPreviousTitle() {
        var event = RawEvent(
            ts: 1, kind: .contextSnapshot, bundleID: "com.apple.Safari",
            windowTitle: "title \(key)", document: "/tmp/\(key).txt",
            url: "https://ex.com/?token=\(key)", role: "AXWebArea", subrole: nil,
            identifier: "field-\(key)", elementTitle: "label \(key)", value: "body \(key)",
            selectedText: "sel \(key)",
            extra: ["previousTitle": .string("prev \(key)"), "fingerprint": .string("abc123")])

        let fired = EventRedaction.apply(to: &event, policy: policy)

        #expect(fired == ["aws-key"])
        #expect(event.windowTitle == "title [redacted:aws-key]")
        #expect(event.document == "/tmp/[redacted:aws-key].txt")
        #expect(event.url == "https://ex.com/?token=[redacted:aws-key]")
        #expect(event.elementTitle == "label [redacted:aws-key]")
        #expect(event.value == "body [redacted:aws-key]")
        #expect(event.selectedText == "sel [redacted:aws-key]")
        #expect(event.extra?["previousTitle"] == .string("prev [redacted:aws-key]"))
        // Identity/bookkeeping keys and the identity columns are deliberately untouched:
        // redacting a hash corrupts it rather than protecting anything.
        #expect(event.extra?["fingerprint"] == .string("abc123"))
        #expect(event.identifier == "field-\(key)")
        #expect(event.role == "AXWebArea")
    }

    @Test func redactionIsIdempotentSoTheReadPathCanReRunItOverACleanedRow() {
        var event = RawEvent(
            ts: 1, kind: .contextSnapshot, url: "https://ex.com/?token=\(key)")
        #expect(EventRedaction.apply(to: &event, policy: policy) == ["aws-key"])
        let once = event
        #expect(EventRedaction.apply(to: &event, policy: policy).isEmpty)
        #expect(event == once)
    }

    @Test func disabledPolicyChangesNothing() {
        var event = RawEvent(ts: 1, kind: .contextSnapshot, windowTitle: "title \(key)")
        #expect(EventRedaction.apply(to: &event, policy: .disabled).isEmpty)
        #expect(event.windowTitle == "title \(key)")
        #expect(
            EventRedaction.redact("title \(key)", coverage: .structuralOnly, policy: .disabled)
                == "title \(key)")
    }

    @Test func redactCoversTheSinglePieceCaseInspectUses() {
        #expect(
            EventRedaction.redact("open \(key)", coverage: .structuralOnly, policy: policy)
                == "open [redacted:aws-key]")
        #expect(EventRedaction.redact(nil, coverage: .structuralOnly, policy: policy) == nil)
    }
}
