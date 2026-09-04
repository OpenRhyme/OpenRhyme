import Testing

@testable import Capture
@testable import Core

@Suite struct RedactionTests {
    @Test func secureFieldsNeverExposeText() {
        let element = ElementInfo(
            role: "AXTextField", subrole: "AXSecureTextField", value: "hunter2",
            selectedText: "hunter")
        #expect(element.isSecure)
        let redacted = Redaction.apply(element, maxValueBytes: 1000, policy: .disabled)
        #expect(
            redacted == RedactedText(value: nil, selectedText: nil, truncated: false, length: 0))
    }

    @Test func passesShortValuesThrough() {
        let element = ElementInfo(role: "AXTextArea", value: "héllo", selectedText: "é")
        let redacted = Redaction.apply(element, maxValueBytes: 1000, policy: .disabled)
        #expect(redacted.value == "héllo")
        #expect(redacted.selectedText == "é")
        #expect(redacted.truncated == false)
        #expect(redacted.length == 6)  // bytes, not characters
    }

    @Test func truncatesOnAUTF8Boundary() {
        let element = ElementInfo(role: "AXTextArea", value: "aé✓")  // 1 + 2 + 3 bytes
        let cut = Redaction.apply(element, maxValueBytes: 4, policy: .disabled)
        #expect(cut.value == "aé")
        #expect(cut.truncated == true)
        #expect(cut.length == 6)
        let exact = Redaction.apply(element, maxValueBytes: 6, policy: .disabled)
        #expect(exact.value == "aé✓")
        #expect(exact.truncated == false)
    }

    @Test func nilElementYieldsNothing() {
        #expect(
            Redaction.apply(nil, maxValueBytes: 10, policy: .disabled)
                == RedactedText(value: nil, selectedText: nil, truncated: false, length: 0))
    }

    @Test func nilValueTruncatesLongSelectedText() {
        let element = ElementInfo(role: "AXTextArea", value: nil, selectedText: "0123456789")
        let redacted = Redaction.apply(element, maxValueBytes: 4, policy: .disabled)
        #expect(redacted.value == nil)
        #expect(redacted.selectedText == "0123")
        #expect(redacted.truncated == true)
        #expect(redacted.length == 0)
    }

    @Test func neitherTruncatedWhenBothUnderCap() {
        let element = ElementInfo(role: "AXTextArea", value: "hi", selectedText: "h")
        let redacted = Redaction.apply(element, maxValueBytes: 100, policy: .disabled)
        #expect(redacted.value == "hi")
        #expect(redacted.selectedText == "h")
        #expect(redacted.truncated == false)
        #expect(redacted.length == 2)
    }

    @Test func zeroCapEmptiesBothFields() {
        let element = ElementInfo(role: "AXTextArea", value: "hi", selectedText: "h")
        let redacted = Redaction.apply(element, maxValueBytes: 0, policy: .disabled)
        #expect(redacted.value == "")
        #expect(redacted.selectedText == "")
        #expect(redacted.truncated == true)
        #expect(redacted.length == 2)
    }

    @Test func credentialFieldByNameIsTreatedLikeASecureField() {
        let policy = PrivacyPolicy(settings: PrivacySettings())
        let element = ElementInfo(
            role: "AXTextField", identifier: "current-password", value: "hunter2",
            selectedText: "hunter2")
        let out = Redaction.apply(element, maxValueBytes: 1000, policy: policy)
        #expect(out.value == nil)
        #expect(out.selectedText == nil)
        #expect(out.redactedRules.isEmpty)
    }

    @Test func secretsInOrdinaryTextAreRedactedAndReported() {
        let policy = PrivacyPolicy(settings: PrivacySettings())
        let element = ElementInfo(
            role: "AXTextArea", value: "deploy with AKIAQQQQWWWWEEEERRRR now")
        let out = Redaction.apply(element, maxValueBytes: 1000, policy: policy)
        #expect(out.value == "deploy with [redacted:aws-key] now")
        #expect(out.redactedRules == ["aws-key"])
        #expect(out.length == "deploy with AKIAQQQQWWWWEEEERRRR now".utf8.count)
    }

    @Test func capIsAppliedBeforeRedactionSoCostIsBounded() {
        let policy = PrivacyPolicy(settings: PrivacySettings())
        let filler = String(repeating: "x", count: 40)
        let element = ElementInfo(role: "AXTextArea", value: filler + "AKIAQQQQWWWWEEEERRRR")
        let out = Redaction.apply(element, maxValueBytes: 40, policy: policy)
        #expect(out.truncated)
        #expect(out.value == filler)  // the secret was past the cap, so nothing to redact
        #expect(out.redactedRules.isEmpty)
    }

    @Test func disabledPolicySkipsRedactionButNotTheSecureGuard() {
        let element = ElementInfo(role: "AXTextArea", value: "AKIAQQQQWWWWEEEERRRR")
        let out = Redaction.apply(element, maxValueBytes: 1000, policy: .disabled)
        #expect(out.value == "AKIAQQQQWWWWEEEERRRR")
        #expect(out.redactedRules.isEmpty)

        let secure = ElementInfo(
            role: "AXTextField", subrole: "AXSecureTextField", value: "hunter2")
        let secureOut = Redaction.apply(secure, maxValueBytes: 1000, policy: .disabled)
        #expect(secureOut.value == nil)  // unconditional, never disabled by config
    }
}
