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

/// Spec §6.5: secure fields expose nothing; `value` and `selectedText` are both capped at a
/// UTF-8 boundary.
public enum Redaction {
    public static func apply(_ element: ElementInfo?, maxValueBytes: Int) -> RedactedText {
        guard let element, !element.isSecure else {
            return RedactedText(value: nil, selectedText: nil, truncated: false, length: 0)
        }

        let length = element.value?.utf8.count ?? 0
        var truncated = false

        var value = element.value
        if let text = value, text.utf8.count > maxValueBytes {
            value = truncate(text, toBytes: maxValueBytes)
            truncated = true
        }

        var selectedText = element.selectedText
        if let text = selectedText, text.utf8.count > maxValueBytes {
            selectedText = truncate(text, toBytes: maxValueBytes)
            truncated = true
        }

        return RedactedText(
            value: value, selectedText: selectedText, truncated: truncated, length: length)
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
