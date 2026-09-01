public struct RedactedText: Sendable, Equatable {
    public var value: String?
    public var selectedText: String?
    public var truncated: Bool
    public var length: Int

    public init(value: String?, selectedText: String?, truncated: Bool, length: Int) {
        self.value = value
        self.selectedText = selectedText
        self.truncated = truncated
        self.length = length
    }
}

/// Spec §6.5: secure fields expose nothing; values are capped at a UTF-8 boundary.
public enum Redaction {
    public static func apply(_ element: ElementInfo?, maxValueBytes: Int) -> RedactedText {
        guard let element, !element.isSecure else {
            return RedactedText(value: nil, selectedText: nil, truncated: false, length: 0)
        }
        guard let value = element.value else {
            return RedactedText(
                value: nil, selectedText: element.selectedText, truncated: false, length: 0)
        }
        let length = value.utf8.count
        guard length > maxValueBytes else {
            return RedactedText(
                value: value, selectedText: element.selectedText, truncated: false, length: length)
        }
        return RedactedText(
            value: truncate(value, toBytes: maxValueBytes), selectedText: element.selectedText,
            truncated: true, length: length)
    }

    /// Longest prefix of `text` that is at most `bytes` long and ends on a scalar boundary.
    static func truncate(_ text: String, toBytes bytes: Int) -> String {
        var count = max(bytes, 0)
        while count > 0 {
            if let prefix = String(text.utf8.prefix(count)) { return prefix }
            count -= 1
        }
        return ""
    }
}
