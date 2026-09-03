import Foundation

public struct RedactionResult: Sendable, Equatable {
    public var text: String
    /// Sorted, de-duplicated names of the rules that fired.
    public var rules: [String]

    public init(text: String, rules: [String]) {
        self.text = text
        self.rules = rules
    }
}

/// Spec 2026-09-03 privacy §5.2. Patterns adapted from gitleaks (MIT) — the corpus is vendored,
/// not the dependency, because no Swift secret-scanning library exists worth taking on. Detection
/// is best-effort by nature: it is the second line of defence behind never capturing at all.
public enum SecretRedactor {
    struct Rule {
        let name: String
        let regex: Regex<AnyRegexOutput>
    }

    /// Order matters only for readability; every rule is applied.
    /// `Regex` isn't `Sendable`, but these literals are never mutated after creation — safe to
    /// share across threads for read-only matching.
    nonisolated(unsafe) static let rules: [Rule] = [
        Rule(
            name: "private-key-block",
            regex: try! Regex(
                #"-----BEGIN[ A-Z]*PRIVATE KEY-----[\s\S]*?-----END[ A-Z]*PRIVATE KEY-----"#)),
        Rule(name: "aws-key", regex: try! Regex(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#)),
        Rule(
            name: "github-token",
            regex: try! Regex(
                #"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{20,})\b"#)),
        Rule(name: "stripe-key", regex: try! Regex(#"\bsk_(?:live|test)_[A-Za-z0-9]{16,}\b"#)),
        Rule(name: "slack-token", regex: try! Regex(#"\bxox[baprs]-[A-Za-z0-9-]{10,}"#)),
        Rule(name: "google-api-key", regex: try! Regex(#"\bAIza[0-9A-Za-z_\-]{35,}\b"#)),
        Rule(name: "anthropic-key", regex: try! Regex(#"\bsk-ant-[A-Za-z0-9_\-]{20,}"#)),
        Rule(name: "openai-key", regex: try! Regex(#"\bsk-(?!ant-)[A-Za-z0-9]{32,}\b"#)),
        Rule(
            name: "jwt",
            regex: try! Regex(
                #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#)),
        Rule(
            name: "connection-string",
            regex: try! Regex(#"\b[a-z][a-z0-9+.\-]*://[^\s:@/]+:[^\s:@/]{6,}@"#)),
        Rule(
            name: "assignment-secret",
            regex: try! Regex(
                #"(?i)\b(?:api[_\-]?key|secret|token|password|passwd)\b\s*[:=]\s*[^\s'"]{8,}"#)),
    ]

    /// A run long enough and mixed enough to be a credential rather than prose or a path.
    /// `Regex` isn't `Sendable`, but this literal is never mutated after creation — safe to share
    /// across threads for read-only matching.
    nonisolated(unsafe) private static let entropyCandidate = try! Regex(
        #"[A-Za-z0-9+/=_\-]{20,}"#)
    static let entropyThreshold = 4.0

    public static func redact(_ text: String, entropyEnabled: Bool) -> RedactionResult {
        guard !text.isEmpty else { return RedactionResult(text: text, rules: []) }
        var output = text
        var fired: Set<String> = []

        for rule in rules where output.firstMatch(of: rule.regex) != nil {
            output = output.replacing(rule.regex, with: "[redacted:\(rule.name)]")
            fired.insert(rule.name)
        }

        if entropyEnabled {
            var rebuilt = ""
            var cursor = output.startIndex
            for match in output.matches(of: entropyCandidate) {
                let token = String(output[match.range])
                guard isHighEntropySecret(token) else { continue }
                rebuilt += output[cursor..<match.range.lowerBound] + "[redacted:high-entropy]"
                cursor = match.range.upperBound
                fired.insert("high-entropy")
            }
            if cursor != output.startIndex {
                rebuilt += output[cursor...]
                output = rebuilt
            }
        }

        return RedactionResult(text: output, rules: fired.sorted())
    }

    /// Mixed character classes plus high Shannon entropy. The mixed-class requirement is what
    /// keeps git SHAs (no uppercase), UUIDs, lowercase slugs and file paths out.
    static func isHighEntropySecret(_ token: String) -> Bool {
        guard token.count >= 20 else { return false }
        var hasUpper = false
        var hasLower = false
        var hasDigit = false
        for character in token {
            if character.isUppercase { hasUpper = true }
            if character.isLowercase { hasLower = true }
            if character.isNumber { hasDigit = true }
        }
        guard hasUpper, hasLower, hasDigit else { return false }
        return shannonEntropy(token) > entropyThreshold
    }

    static func shannonEntropy(_ token: String) -> Double {
        var counts: [Character: Int] = [:]
        for character in token { counts[character, default: 0] += 1 }
        let total = Double(token.count)
        return counts.values.reduce(into: 0.0) { entropy, count in
            let p = Double(count) / total
            entropy -= p * log2(p)
        }
    }
}
