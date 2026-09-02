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
