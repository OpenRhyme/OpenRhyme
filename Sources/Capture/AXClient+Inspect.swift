import ApplicationServices
import Foundation

public struct ElementNode: Sendable, Encodable {
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var identifier: String?
    public var value: String?
    public var children: [ElementNode]
}

public struct ElementInspection: Sendable, Encodable {
    public var attributeNames: [String]
    public var tree: ElementNode?
    public var protectedBy: String?

    public init(attributeNames: [String], tree: ElementNode?, protectedBy: String? = nil) {
        self.attributeNames = attributeNames
        self.tree = tree
        self.protectedBy = protectedBy
    }
}

extension AXClient {
    /// Developer tool behind `openrhyme inspect`: attribute names of the focused element and
    /// a bounded subtree (`depth` ≤ 3, at most 200 nodes). The daemon never walks trees.
    public func focusedElementInspection(
        of app: AppInfo, depth: Int, policy: PrivacyPolicy
    ) throws -> ElementInspection {
        let application = AXUIElementCreateApplication(app.pid)
        // Whole-branch review I6: the protect-rule pair (configured rules, then the windowless
        // fail-closed guard) is evaluated by the one shared helper `focusedContext` uses, not a
        // hand-copy — copying it is how these two diverged in privacy fix round 2 and leaked a
        // windowless context's focused element.
        let window = try focusedWindowInfo(of: application)
        if case .protected(let rule) = policy.evaluateFocusedContext(
            bundleID: app.bundleID, window: window)
        {
            // Privacy §5.4: `inspect` is not a bypass. `--ignore-privacy` passes `.disabled`.
            return ElementInspection(attributeNames: [], tree: nil, protectedBy: rule)
        }
        guard let focused = try element(application, kAXFocusedUIElementAttribute) else {
            return ElementInspection(attributeNames: [], tree: nil)
        }
        var budget = 200
        let tree = try node(focused, depth: min(max(depth, 0), 3), budget: &budget, policy: policy)
        return ElementInspection(attributeNames: attributeNames(focused), tree: tree)
    }

    private func node(
        _ element: AXUIElement, depth: Int, budget: inout Int, policy: PrivacyPolicy
    ) throws -> ElementNode {
        budget -= 1
        let info = try readElement(element)
        var children: [ElementNode] = []
        if depth > 0, budget > 0 {
            for child in try elements(element, kAXChildrenAttribute) where budget > 0 {
                children.append(
                    try node(child, depth: depth - 1, budget: &budget, policy: policy))
            }
        }
        // Whole-branch review I7: a subtree node is captured content like any other, so it gets
        // the credential-field guard and secret redaction the daemon applies — the README says
        // `inspect` honours the same policy as capture, and a node is exactly where an unmarked
        // password field or a pasted key shows up. Redaction runs before the 200-character
        // display cut so a secret is never chopped into a shape no rule matches; the byte cap
        // keeps its cost bounded on a node holding a whole document.
        let redacted = Redaction.apply(info, maxValueBytes: Self.nodeRedactionBytes, policy: policy)
        return ElementNode(
            role: info.role, subrole: info.subrole,
            title: EventRedaction.redact(info.title, coverage: .structuralOnly, policy: policy),
            identifier: info.identifier,
            value: redacted.value.map { String($0.prefix(200)) }, children: children)
    }

    /// Far more than the 200 characters a node displays, so redaction always sees whole secrets
    /// around the cut, and still bounded so a document-sized node cannot make `inspect` crawl.
    static let nodeRedactionBytes = 8192
}
