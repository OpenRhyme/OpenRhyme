// Capture — deep AX content extraction (spec §4). The `extract` ladder body lands in a
// follow-up task; this file declares the pure wire types it is built on.

/// Which rung of the content ladder produced an element's text (spec §4).
public enum TextSource: String, Sendable {
    case value
    case range
    case subtree
}

/// A minimal, AX-free view of an element for content extraction, so the ladder is
/// unit-testable over an in-memory tree. `AXClient` provides an `AXUIElement`-backed
/// conformance; tests provide a struct tree.
public protocol TextNode {
    var role: String? { get }
    var subrole: String? { get }
    /// The element's own `kAXValue` text, if any (rung 1).
    func ownValue() throws -> String?
    /// The element's visible text via a ranged read, if the element supports it (rung 2).
    func rangedText() throws -> String?
    /// Child nodes for the subtree harvest (rung 3).
    func children() throws -> [TextNode]
}

public struct ExtractedText: Sendable, Equatable {
    public var value: String?
    public var source: TextSource?

    public init(value: String? = nil, source: TextSource? = nil) {
        self.value = value
        self.source = source
    }
}

public enum ContentExtractor {
    private static let harvestRoles: Set<String> = [
        "AXStaticText", "AXHeading", "AXLink", "AXButton",
    ]

    /// Resolve an element's readable text by the spec §4 ladder: own value → ranged text →
    /// bounded subtree harvest. A secure focused element yields nothing. Never reads a secure
    /// field's value, at any depth. Pure: all reads go through the `TextNode` protocol.
    public static func extract(
        from node: TextNode, maxBytes: Int, nodeBudget: Int = 1500
    ) -> ExtractedText {
        if node.subrole == ElementInfo.secureSubrole {
            return ExtractedText()
        }
        // Rung 1: own value.
        if let own = try? node.ownValue(), !own.isEmpty {
            return ExtractedText(value: own, source: .value)
        }
        // Rung 2: ranged visible text.
        if let ranged = try? node.rangedText(), !ranged.isEmpty {
            return ExtractedText(value: ranged, source: .range)
        }
        // Rung 3: bounded subtree harvest.
        var pieces: [String] = []
        var bytes = 0
        var budget = nodeBudget
        harvest(node, maxBytes: maxBytes, budget: &budget, bytes: &bytes, into: &pieces)
        guard !pieces.isEmpty else { return ExtractedText() }
        return ExtractedText(value: pieces.joined(separator: "\n"), source: .subtree)
    }

    private static func harvest(
        _ node: TextNode, maxBytes: Int, budget: inout Int, bytes: inout Int,
        into pieces: inout [String]
    ) {
        guard budget > 0, bytes < maxBytes else { return }
        budget -= 1
        if node.subrole == ElementInfo.secureSubrole { return }  // never read a password's text
        if let role = node.role, harvestRoles.contains(role),
            let text = try? node.ownValue(), !text.isEmpty
        {
            // +1 for the joining newline, but only once a prior piece exists to join against.
            let addition = text.utf8.count + (pieces.isEmpty ? 0 : 1)
            if bytes + addition <= maxBytes {
                pieces.append(text)
                bytes += addition
            }
        }
        guard bytes < maxBytes, budget > 0 else { return }
        for child in (try? node.children()) ?? [] where budget > 0 && bytes < maxBytes {
            harvest(child, maxBytes: maxBytes, budget: &budget, bytes: &bytes, into: &pieces)
        }
    }
}
