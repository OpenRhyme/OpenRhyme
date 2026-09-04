public struct RedactedText: Sendable, Equatable {
    public var value: String?
    public var selectedText: String?
    public var truncated: Bool
    public var length: Int
    public var redactedRules: [String]

    public init(
        value: String?, selectedText: String?, truncated: Bool, length: Int,
        redactedRules: [String] = []
    ) {
        self.value = value
        self.selectedText = selectedText
        self.truncated = truncated
        self.length = length
        self.redactedRules = redactedRules
    }
}

/// Spec §6.5: secure fields expose nothing; `value` and `selectedText` are both capped at a
/// UTF-8 boundary. Spec 2026-09-03 privacy §7.2: a credential-named field is treated the same
/// way, and secrets found in ordinary text are redacted after the cap.
public enum Redaction {
    public static func apply(
        _ element: ElementInfo?, maxValueBytes: Int, policy: PrivacyPolicy
    ) -> RedactedText {
        guard let element, !element.isSecure else {
            return RedactedText(value: nil, selectedText: nil, truncated: false, length: 0)
        }
        // Spec privacy §7.2: a field whose name says credential is treated exactly like a secure
        // field, so a web form that skips `type=password` cannot leak.
        guard !policy.isCredentialField(identifier: element.identifier, title: element.title)
        else {
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

        // Redaction runs after the cap so its cost is bounded by `max_value_bytes`.
        var rules: Set<String> = []
        if policy.enabled {
            if let text = value {
                let result = SecretRedactor.redact(text, entropyEnabled: policy.entropyRedaction)
                value = result.text
                rules.formUnion(result.rules)
            }
            if let text = selectedText {
                let result = SecretRedactor.redact(text, entropyEnabled: policy.entropyRedaction)
                selectedText = result.text
                rules.formUnion(result.rules)
            }
        }

        return RedactedText(
            value: value, selectedText: selectedText, truncated: truncated, length: length,
            redactedRules: rules.sorted())
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
