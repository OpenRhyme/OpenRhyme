import ArgumentParser
import Capture
import Core
import Foundation

struct InspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Dump the focused app, window and element as the daemon sees them (dev tool).")

    @Option(name: .long, help: "Child levels to include under the focused element (0–3).")
    var depth: Int = 0
    @Flag(name: .long, help: "Emit a JSON envelope.") var json = false

    struct Inspection: Encodable {
        let app: AppInfo?
        let window: WindowInfo?
        let element: ElementInfo?
        let attributeNames: [String]
        let tree: ElementNode?

        enum CodingKeys: String, CodingKey {
            case app, window, element, tree
            case attributeNames = "attribute_names"
        }
    }

    func validate() throws {
        guard (0...3).contains(depth) else {
            throw ValidationError("--depth must be between 0 and 3")
        }
    }

    func run() async throws {
        let depth = self.depth
        try await runJSON(json: json, human: Self.human) {
            try await MainActor.run {
                let client = AXClient()
                guard client.isTrusted(prompt: false) else { throw CLIError.notTrusted }
                guard let app = client.frontmostApplication() else {
                    return Inspection(
                        app: nil, window: nil, element: nil, attributeNames: [], tree: nil)
                }
                let context = try client.focusedContext(of: app, reusing: nil)
                let inspection = try client.focusedElementInspection(of: app, depth: depth)
                return Inspection(
                    app: app, window: context.window, element: context.element,
                    attributeNames: inspection.attributeNames, tree: inspection.tree)
            }
        }
    }

    static func human(_ inspection: Inspection) -> String {
        var lines: [String] = []
        lines.append(
            "app:      \(inspection.app?.bundleID ?? "-") (pid \(inspection.app?.pid ?? 0))")
        lines.append("window:   \(inspection.window?.title ?? "-")")
        if let document = inspection.window?.document { lines.append("document: \(document)") }
        if let url = inspection.window?.url { lines.append("url:      \(url)") }
        if let element = inspection.element {
            lines.append(
                "element:  \(element.role ?? "-") / \(element.subrole ?? "-") \(element.title ?? "")"
            )
            if let value = element.value { lines.append("value:    \(value.prefix(200))") }
            if let selected = element.selectedText {
                lines.append("selected: \(selected.prefix(200))")
            }
        }
        lines.append("attributes: \(inspection.attributeNames.joined(separator: " "))")
        return lines.joined(separator: "\n")
    }
}
