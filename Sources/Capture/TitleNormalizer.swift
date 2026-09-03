import Foundation

/// Spec 2026-09-03 §5: a title with its volatile parts removed. Used only for comparing and
/// hashing — the stored title is always the raw one. Rules are ordered; each has a test.
public enum TitleNormalizer {
    /// Rule 2: glyphs apps animate in titles (cmux / Claude Code spinners, status bullets).
    static let statusGlyphs: Set<Character> = [
        "◐", "◑", "◒", "◓", "◌", "✳", "✶", "✷", "✸", "⏳", "⌛", "●", "○", "◉",
    ]
    /// Rule 1: a leading notification counter such as "(86) ".
    /// `Regex` isn't `Sendable`, but these literals are never mutated after creation — safe to
    /// share across threads for read-only matching.
    nonisolated(unsafe) private static let leadingCounter = #/^\(\d+\)\s+/#
    /// Rule 3: Chrome tab badges. Data-driven; extend here, with a test.
    nonisolated(unsafe) private static let chromeBadges = [
        #/ - Audio playing/#, #/ - Muted/#, #/ - High memory usage - [\d.,]+ [KMG]B/#,
    ]
    /// Rule 4.
    nonisolated(unsafe) private static let whitespace = #/\s+/#

    public static func normalize(_ title: String) -> String {
        var text = title.replacing(leadingCounter, with: "")
        text.removeAll(where: { statusGlyphs.contains($0) })
        for badge in chromeBadges { text = text.replacing(badge, with: "") }
        text = text.replacing(whitespace, with: " ")
        return text.trimmingCharacters(in: .whitespaces)
    }

    public static func normalize(_ title: String?) -> String? {
        title.map { normalize($0) }
    }
}
