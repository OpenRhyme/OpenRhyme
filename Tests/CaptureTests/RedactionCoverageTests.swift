import Testing

@testable import Capture
@testable import Core

/// Fix round 1. Extending capture-time redaction to `url`/`document`/`window_title`/
/// `element_title` (H2) also dragged the Shannon-entropy backstop onto them, and the backstop's
/// gate — 20+ characters, mixed case, a digit, high entropy — is an exact description of an opaque
/// resource id. Capture was therefore permanently rewriting the one part of a Google Docs / Notion
/// / Dropbox / S3 URL that says *which document the person was looking at*, in a tool whose whole
/// job is to record that. The backstop is now `.full`-coverage only (`value`, `selected_text`);
/// every structural rule still runs on every column, so a credential in a query string is still
/// caught.
@Suite @MainActor struct RedactionCoverageTests {
    private let safari = FakeAXClient.app(10, "com.apple.Safari")
    private let allow: Set<String> = ["com.apple.Safari"]
    private let policy = PrivacyPolicy(settings: PrivacySettings())
    /// Google's own published sample document id: 44 characters, mixed case, digits.
    private let docID = "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms"

    private func capture(
        window: WindowInfo?, element: ElementInfo? = nil, policy: PrivacyPolicy? = nil
    ) -> RawEvent {
        let out = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: HeartbeatDiff.Input(
                frontmost: safari,
                context: FocusedContext(app: safari, window: window, element: element),
                allowlist: allow, recordOtherApps: false, maxValueBytes: 1000, now: 100,
                policy: policy ?? self.policy))
        return out.events[1]
    }

    // MARK: - Identifying columns keep their ids

    @Test func aGoogleDocsURLSurvivesCaptureWithItsDocumentIdIntact() {
        // The id really does clear the backstop's gate — without this, the test below would pass
        // for the wrong reason.
        #expect(SecretRedactor.isHighEntropySecret(docID))

        let url = "https://docs.google.com/document/d/\(docID)/edit"
        let row = capture(
            window: WindowInfo(
                title: "Q3 Planning — Google Docs", document: "/Users/me/Docs/\(docID).gdoc",
                url: url))

        #expect(row.url == url)
        #expect(row.document == "/Users/me/Docs/\(docID).gdoc")
        #expect(row.windowTitle == "Q3 Planning — Google Docs")
        #expect(row.extra?["redacted"] == nil)
    }

    @Test func anOpaqueIdInAnElementTitleAlsoSurvives() {
        let row = capture(
            window: WindowInfo(title: "Files"),
            element: ElementInfo(role: "AXRow", title: "report-\(docID).pdf"))
        #expect(row.elementTitle == "report-\(docID).pdf")
    }

    // MARK: - …but every structural rule still runs on those same columns

    @Test func anAWSKeyInAURLIsStillRedactedAtCapture() {
        let row = capture(
            window: WindowInfo(
                title: "console AKIAQQQQWWWWEEEERRRR",
                document: "/tmp/AKIAQQQQWWWWEEEERRRR.txt",
                url: "https://ex.com/logs/AKIAQQQQWWWWEEEERRRR"))
        #expect(row.url == "https://ex.com/logs/[redacted:aws-key]")
        #expect(row.document == "/tmp/[redacted:aws-key].txt")
        #expect(row.windowTitle == "console [redacted:aws-key]")
        #expect(row.extra?["redacted"] == .array([.string("aws-key")]))
    }

    @Test func aTokenQueryParameterIsStillRedactedAndOnlyTheTokenIs() {
        let row = capture(
            window: WindowInfo(
                url: "https://api.example.com/v1/items?token=abcdefgh12345678&page=2&sort=name"))
        // The credential goes…
        #expect(row.url?.contains("abcdefgh12345678") == false)
        #expect(row.extra?["redacted"] == .array([.string("assignment-secret")]))
        // …and the parameters after it stay, so the URL is still a usable record of the request.
        #expect(
            row.url == "https://api.example.com/v1/items?[redacted:assignment-secret]"
                + "&page=2&sort=name")
    }

    @Test func aGitHubTokenInADocumentPathIsStillRedactedAtCapture() {
        let row = capture(
            window: WindowInfo(
                document: "/tmp/ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.log"))
        #expect(row.document == "/tmp/[redacted:github-token].log")
    }

    // MARK: - Narrowing must not disable the backstop where it belongs

    @Test func valueAndSelectedTextStillGetTheEntropyBackstop() {
        let row = capture(
            window: WindowInfo(title: "notes"),
            element: ElementInfo(
                role: "AXTextArea", value: "session \(docID)", selectedText: "sel \(docID)"))
        #expect(row.value == "session [redacted:high-entropy]")
        #expect(row.selectedText == "sel [redacted:high-entropy]")
        #expect(row.extra?["redacted"] == .array([.string("high-entropy")]))
    }

    /// The same string, in two columns, in one row: redacted in the free-text one and intact in
    /// the identifying one. This is the whole rule in a single assertion pair.
    @Test func theSameOpaqueIdIsRedactedInValueAndKeptInTheURL() {
        let row = capture(
            window: WindowInfo(url: "https://docs.google.com/document/d/\(docID)/edit"),
            element: ElementInfo(role: "AXTextArea", value: "paste \(docID)"))
        #expect(row.value == "paste [redacted:high-entropy]")
        #expect(row.url == "https://docs.google.com/document/d/\(docID)/edit")
    }

    @Test func theBackstopStillHonoursEntropyRedactionBeingTurnedOff() {
        var settings = PrivacySettings()
        settings.entropyRedaction = false
        let row = capture(
            window: WindowInfo(title: "notes"),
            element: ElementInfo(role: "AXTextArea", value: "session \(docID)"),
            policy: PrivacyPolicy(settings: settings))
        #expect(row.value == "session \(docID)")
    }
}
