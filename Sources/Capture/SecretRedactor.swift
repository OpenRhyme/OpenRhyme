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
    ///
    /// Fix round 1 (2026-09-03): none of these rely on `\b` at a secret's edges any more. Swift's
    /// `Regex` implements `\b` via Unicode word-segmentation, where `:` is a MidLetter — so
    /// `\bAKIA…` never matches `x-api-key:AKIA…` because no boundary is seen between `y` and `A`
    /// across the colon. This toolchain also rejects lookbehind (`(?<!…)`), confirmed with a
    /// throwaway `try Regex` probe, so the fix is: drop the leading edge check entirely (a
    /// leading `\b` becomes nothing) and replace a trailing `\b` with the negative lookahead
    /// `(?![A-Za-z0-9_\-])` (supported). Slightly over-matching a token that's glued to more
    /// identifier characters is the safe direction for a redactor; silently missing a credential
    /// glued to a label is not.
    /// `Regex` isn't `Sendable`, but these literals are never mutated after creation — safe to
    /// share across threads for read-only matching.
    nonisolated(unsafe) static let rules: [Rule] = [
        Rule(
            name: "private-key-block",
            regex: try! Regex(
                #"-----BEGIN[ A-Z]*PRIVATE KEY-----[\s\S]*?-----END[ A-Z]*PRIVATE KEY-----"#)),
        Rule(name: "aws-key", regex: try! Regex(#"(?:AKIA|ASIA)[0-9A-Z]{16}(?![A-Za-z0-9_\-])"#)),
        Rule(
            name: "github-token",
            regex: try! Regex(
                #"(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{20,})(?![A-Za-z0-9_\-])"#)
        ),
        Rule(
            name: "stripe-key",
            regex: try! Regex(#"sk_(?:live|test)_[A-Za-z0-9]{16,}(?![A-Za-z0-9_\-])"#)),
        Rule(name: "slack-token", regex: try! Regex(#"xox[baprs]-[A-Za-z0-9-]{10,}"#)),
        Rule(
            name: "google-api-key",
            regex: try! Regex(#"AIza[0-9A-Za-z_\-]{35}(?![A-Za-z0-9_\-])"#)),
        Rule(name: "anthropic-key", regex: try! Regex(#"sk-ant-[A-Za-z0-9_\-]{20,}"#)),
        Rule(
            name: "openai-key",
            regex: try! Regex(#"sk-(?!ant-)[A-Za-z0-9]{32,}(?![A-Za-z0-9_\-])"#)),
        Rule(
            name: "jwt",
            regex: try! Regex(
                #"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}(?![A-Za-z0-9_\-])"#
            )),
        Rule(
            name: "connection-string",
            regex: try! Regex(#"[a-z][a-z0-9+.\-]*://[^\s:@/]+:[^\s:@/]{6,}@"#)),
        /// Fix round 1: the unquoted tail excludes `&` and `#` as well as whitespace, quotes and
        /// brackets, so it stops at a URL parameter or fragment boundary. It used to run to the
        /// end of the query string — `?token=abcdefgh12345678&page=2&sort=name` redacted the
        /// page and sort parameters along with the token — which only cost a read before this
        /// slice but now writes the over-match to disk permanently. A real secret carried in a
        /// URL cannot contain a literal `&` (it would be percent-encoded), and one carried in a
        /// shell or config line containing `&` has to be quoted, which the two quoted
        /// alternatives above still match in full.
        Rule(
            name: "assignment-secret",
            regex: try! Regex(
                #"(?i)(?:api[_\-]?key|secret|token|password|passwd)(?![A-Za-z0-9_])"#
                    + #"['"]?\s*[:=]\s*(?:"[^"]{8,}"|'[^']{8,}'|[^\s'"\[\]&#]{8,})"#)),
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
