import Testing

@testable import Capture
@testable import Core

/// Whole-branch review H2, at the capture path. The row that reaches the store must carry the
/// redacted text, while every identity artifact computed alongside it (`extra.fingerprint`,
/// `extra.valueHash`, and the in-memory `ContextSignature` that drives dedup) must be exactly
/// what the same context produced before capture-time redaction existed — those are computed
/// from the raw text, before redaction touches the row.
@Suite @MainActor struct HeartbeatRedactionTests {
    private let safari = FakeAXClient.app(10, "com.apple.Safari")
    private let allow: Set<String> = ["com.apple.Safari"]
    private let policy = PrivacyPolicy(settings: PrivacySettings())
    private let key = "AKIAQQQQWWWWEEEERRRR"
    private let otherKey = "AKIAZZZZXXXXCCCCVVVV"

    private func input(
        window: WindowInfo?, element: ElementInfo? = nil, now: Double = 100,
        trigger: HeartbeatDiff.Trigger = .heartbeat
    ) -> HeartbeatDiff.Input {
        HeartbeatDiff.Input(
            frontmost: safari,
            context: FocusedContext(app: safari, window: window, element: element),
            allowlist: allow, recordOtherApps: false, maxValueBytes: 1000, now: now,
            trigger: trigger, policy: policy)
    }

    @Test func secretsInEveryTextColumnAreRedactedBeforeTheRowIsBuilt() {
        let window = WindowInfo(
            title: "Report \(key)", document: "/tmp/\(key).txt",
            url: "https://ex.com/?token=\(key)")
        let element = ElementInfo(
            role: "AXTextArea", title: "label \(key)", value: "body \(key)",
            selectedText: "sel \(key)")

        let out = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(
                window: window, element: element))

        let row = out.events[1]
        #expect(row.windowTitle == "Report [redacted:aws-key]")
        #expect(row.document == "/tmp/[redacted:aws-key].txt")
        #expect(row.url == "https://ex.com/?token=[redacted:aws-key]")
        #expect(row.elementTitle == "label [redacted:aws-key]")
        #expect(row.value == "body [redacted:aws-key]")
        #expect(row.selectedText == "sel [redacted:aws-key]")
        #expect(row.extra?["redacted"] == .array([.string("aws-key")]))
    }

    /// The load-bearing test: `extra.fingerprint` is the grouping key Compact will use, and it
    /// must be byte-identical to what this context produced before capture-time redaction. That
    /// only holds if identity is computed from the raw values and redaction runs afterwards.
    @Test func aRedactedRowKeepsTheFingerprintTheRawContextProduced() {
        let window = WindowInfo(
            title: "Report \(key)", document: "/tmp/\(key).txt",
            url: "https://ex.com/?token=\(key)")
        let element = ElementInfo(role: "AXTextArea", value: "body \(key)")

        let out = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(
                window: window, element: element))
        let row = out.events[1]

        let overRawText = Fingerprint.compute(
            bundleID: "com.apple.Safari", windowTitle: window.title, document: window.document,
            url: window.url)
        #expect(row.extra?["fingerprint"] == .string(overRawText))

        // …and specifically *not* the fingerprint of the redacted text, which is what redacting
        // before computing identity would have produced.
        let overRedactedText = Fingerprint.compute(
            bundleID: "com.apple.Safari", windowTitle: row.windowTitle, document: row.document,
            url: row.url)
        #expect(overRawText != overRedactedText)
        #expect(row.extra?["fingerprint"] != .string(overRedactedText))

        // `extra.valueHash` and the dedup signature stay in step with each other, over the value
        // as `Redaction.apply` produced it — unchanged by this slice.
        #expect(row.extra?["valueHash"] == .string(Hashing.sha256Hex("body [redacted:aws-key]")))
        #expect(out.state.signature?.valueHash == Hashing.sha256Hex("body [redacted:aws-key]"))
        #expect(out.state.signature?.windowTitle == TitleNormalizer.normalize(window.title))
    }

    /// Dedup must behave identically to before: it keys on the raw text, so two visits whose only
    /// difference is the secret are still two distinct contexts. Keying on the redacted text
    /// would collapse them into one row and lose the second visit entirely.
    @Test func dedupStillKeysOnRawTextSoTwoDistinctSecretsAreTwoRows() {
        let first = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(window: WindowInfo(title: "Key \(key)")))
        let second = HeartbeatDiff.compute(
            previous: first.state,
            input: input(window: WindowInfo(title: "Key \(otherKey)"), now: 105))

        #expect(second.events.count == 1)
        #expect(first.events[1].windowTitle == second.events[0].windowTitle)
        #expect(first.events[1].extra?["fingerprint"] != second.events[0].extra?["fingerprint"])
    }

    @Test func anUnchangedSecretBearingContextStillDedupsToNothing() {
        let window = WindowInfo(title: "Key \(key)", url: "https://ex.com/?token=\(key)")
        let first = HeartbeatDiff.compute(
            previous: LastKnownState(), input: input(window: window))
        let second = HeartbeatDiff.compute(
            previous: first.state, input: input(window: window, now: 105))
        #expect(second.events.isEmpty)
    }

    @Test func previousTitleIsRedactedAtCaptureTimeToo() {
        let first = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(window: WindowInfo(title: "old \(key)")))
        let second = HeartbeatDiff.compute(
            previous: first.state,
            input: input(
                window: WindowInfo(title: "new title"), now: 105,
                trigger: .observer(.titleChanged)))

        #expect(second.events[0].extra?["previousTitle"] == .string("old [redacted:aws-key]"))
        #expect(second.events[0].extra?["redacted"] == .array([.string("aws-key")]))
    }

    /// `extra.redacted` is the stored signal that something sensitive was caught. Before this
    /// fix it was `nil` for a row whose only secret was in the URL, so nothing on disk recorded
    /// that a credential had been captured at all.
    @Test func extraRedactedUnionsRulesFromTheValueAndTheOtherColumns() {
        let window = WindowInfo(title: "t", url: "https://ex.com/?token=\(key)")
        let element = ElementInfo(
            role: "AXTextArea", value: "ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let out = HeartbeatDiff.compute(
            previous: LastKnownState(), input: input(window: window, element: element))
        #expect(
            out.events[1].extra?["redacted"]
                == .array([.string("aws-key"), .string("github-token")]))
    }

    @Test func disabledPolicyStoresTheRawTextExactlyAsBefore() {
        let disabledInput = HeartbeatDiff.Input(
            frontmost: safari,
            context: FocusedContext(
                app: safari, window: WindowInfo(title: "Key \(key)"), element: nil),
            allowlist: allow, recordOtherApps: false, maxValueBytes: 1000, now: 100,
            policy: .disabled)
        let out = HeartbeatDiff.compute(previous: LastKnownState(), input: disabledInput)
        #expect(out.events[1].windowTitle == "Key \(key)")
        #expect(out.events[1].extra?["redacted"] == nil)
    }
}
