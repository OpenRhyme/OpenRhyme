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
}

extension AXClient {
    /// Developer tool behind `openrhyme inspect`: attribute names of the focused element and
    /// a bounded subtree (`depth` ≤ 3, at most 200 nodes). The daemon never walks trees.
    public func focusedElementInspection(of app: AppInfo, depth: Int) throws -> ElementInspection {
        let application = AXUIElementCreateApplication(app.pid)
        guard let focused = try element(application, kAXFocusedUIElementAttribute) else {
            return ElementInspection(attributeNames: [], tree: nil)
        }
        var budget = 200
        let tree = try node(focused, depth: min(max(depth, 0), 3), budget: &budget)
        return ElementInspection(attributeNames: attributeNames(focused), tree: tree)
    }

    private func node(_ element: AXUIElement, depth: Int, budget: inout Int) throws -> ElementNode {
        budget -= 1
        let info = try readElement(element)
        var children: [ElementNode] = []
        if depth > 0, budget > 0 {
            for child in try elements(element, kAXChildrenAttribute) where budget > 0 {
                children.append(try node(child, depth: depth - 1, budget: &budget))
            }
        }
        return ElementNode(
            role: info.role, subrole: info.subrole, title: info.title, identifier: info.identifier,
            value: info.value.map { String($0.prefix(200)) }, children: children)
    }
}
