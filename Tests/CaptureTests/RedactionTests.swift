import Testing

@testable import Capture

@Suite struct RedactionTests {
    @Test func secureFieldsNeverExposeText() {
        let element = ElementInfo(
            role: "AXTextField", subrole: "AXSecureTextField", value: "hunter2",
            selectedText: "hunter")
        #expect(element.isSecure)
        let redacted = Redaction.apply(element, maxValueBytes: 1000)
        #expect(
            redacted == RedactedText(value: nil, selectedText: nil, truncated: false, length: 0))
    }

    @Test func passesShortValuesThrough() {
        let element = ElementInfo(role: "AXTextArea", value: "héllo", selectedText: "é")
        let redacted = Redaction.apply(element, maxValueBytes: 1000)
        #expect(redacted.value == "héllo")
        #expect(redacted.selectedText == "é")
        #expect(redacted.truncated == false)
        #expect(redacted.length == 6)  // bytes, not characters
    }

    @Test func truncatesOnAUTF8Boundary() {
        let element = ElementInfo(role: "AXTextArea", value: "aé✓")  // 1 + 2 + 3 bytes
        let cut = Redaction.apply(element, maxValueBytes: 4)
        #expect(cut.value == "aé")
        #expect(cut.truncated == true)
        #expect(cut.length == 6)
        let exact = Redaction.apply(element, maxValueBytes: 6)
        #expect(exact.value == "aé✓")
        #expect(exact.truncated == false)
    }

    @Test func nilElementYieldsNothing() {
        #expect(
            Redaction.apply(nil, maxValueBytes: 10)
                == RedactedText(value: nil, selectedText: nil, truncated: false, length: 0))
    }

    @Test func nilValueTruncatesLongSelectedText() {
        let element = ElementInfo(role: "AXTextArea", value: nil, selectedText: "0123456789")
        let redacted = Redaction.apply(element, maxValueBytes: 4)
        #expect(redacted.value == nil)
        #expect(redacted.selectedText == "0123")
        #expect(redacted.truncated == true)
        #expect(redacted.length == 0)
    }

    @Test func neitherTruncatedWhenBothUnderCap() {
        let element = ElementInfo(role: "AXTextArea", value: "hi", selectedText: "h")
        let redacted = Redaction.apply(element, maxValueBytes: 100)
        #expect(redacted.value == "hi")
        #expect(redacted.selectedText == "h")
        #expect(redacted.truncated == false)
        #expect(redacted.length == 2)
    }

    @Test func zeroCapEmptiesBothFields() {
        let element = ElementInfo(role: "AXTextArea", value: "hi", selectedText: "h")
        let redacted = Redaction.apply(element, maxValueBytes: 0)
        #expect(redacted.value == "")
        #expect(redacted.selectedText == "")
        #expect(redacted.truncated == true)
        #expect(redacted.length == 2)
    }
}
