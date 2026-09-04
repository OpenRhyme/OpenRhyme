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
    @Flag(
        name: .long,
        help: "Read even a protected context (prints a warning; never writes to the store).")
    var ignorePrivacy = false

    struct Inspection: Encodable {
        let app: AppInfo?
        let window: WindowInfo?
        let element: ElementInfo?
        let attributeNames: [String]
        let tree: ElementNode?
        /// Spec privacy §5.4: non-nil means the context was protected and nothing above was
        /// actually read — every other field stays empty/nil.
        let protectedBy: String?

        enum CodingKeys: String, CodingKey {
            case app, window, element, tree
            case attributeNames = "attribute_names"
            case protectedBy = "protected_by"
        }
    }

    func validate() throws {
        guard (0...3).contains(depth) else {
            throw ValidationError("--depth must be between 0 and 3")
        }
    }

    func run() async throws {
        let depth = self.depth
        let ignorePrivacy = self.ignorePrivacy
        try await runJSON(json: json, human: Self.human) {
            let paths = Paths.resolve()
            let config = try Config.load(from: paths.configURL)
            // Privacy §5.4: `inspect` is not a bypass. Both AX reads below must see the real
            // policy — passing `.disabled` to only one of them still leaks the other half
            // (window/document/url from `focusedContext`, or element content from
            // `focusedElementInspection`) even without `--ignore-privacy`.
            let policy =
                ignorePrivacy ? PrivacyPolicy.disabled : PrivacyPolicy(settings: config.privacy)
            if ignorePrivacy {
                Output.stderr("warning: --ignore-privacy bypasses the protect rules for this read")
            }
            return try await MainActor.run {
                let client = AXClient()
                guard client.isTrusted(prompt: false) else { throw CLIError.notTrusted }
                guard let app = client.frontmostApplication() else {
                    return Inspection(
                        app: nil, window: nil, element: nil, attributeNames: [], tree: nil,
                        protectedBy: nil)
                }
                let context = try client.focusedContext(of: app, reusing: nil, policy: policy)
                let inspection = try client.focusedElementInspection(
                    of: app, depth: depth, policy: policy)
                let protectedBy = Self.protectedBy(
                    context: context.protection, inspection: inspection.protectedBy)
                guard protectedBy == nil else {
                    return Inspection(
                        app: app, window: nil, element: nil, attributeNames: [], tree: nil,
                        protectedBy: protectedBy)
                }
                // I7: the protect rules were only ever half the policy. An open context still
                // goes through the credential-field guard and secret redaction, exactly as the
                // daemon's own capture path does.
                let visible = Self.applyPolicy(
                    element: context.element, window: context.window, policy: policy,
                    maxValueBytes: config.capture.maxValueBytes)
                return Inspection(
                    app: app, window: visible.window, element: visible.element,
                    attributeNames: inspection.attributeNames, tree: inspection.tree,
                    protectedBy: nil)
            }
        }
    }

    /// Privacy §5.4: `focusedContext` and `focusedElementInspection` evaluate the policy
    /// independently (two separate AX round-trips), so `inspect` must consult both signals
    /// and treat either one alone deciding "protected" as protected — never just one of them.
    /// Trusting only `inspection.protectedBy` is exactly the gap that let a windowless context
    /// leak its focused element even though `focusedContext` had already refused the same
    /// context (privacy fix round 2). Pure and separately testable so this combining rule can be
    /// pinned without live AX.
    static func protectedBy(context: Protection, inspection: String?) -> String? {
        if let inspection { return inspection }
        if case .protected(let rule) = context { return rule }
        return nil
    }

    /// Whole-branch review I7: `inspect` applied the protect rules and stopped there — it
    /// returned `context.element` verbatim and never called `Redaction.apply`, so a
    /// credential-named field the daemon refuses to read, and a secret the daemon redacts before
    /// storing, both printed in full. The README says `inspect` "honours the same policy as
    /// capture"; this is the rest of that policy: the credential-field guard and the
    /// `AXSecureTextField` guard on `value`/`selected_text` (via `Redaction.apply`, the same call
    /// `HeartbeatDiff` makes), plus secret redaction over the element title and the window's
    /// title/document/URL — the columns `EventRedaction` covers on a stored row.
    ///
    /// Pure, so it is pinnable without live AX. With `--ignore-privacy` the policy is
    /// `.disabled` and every step here is a pass-through, except the unconditional secure-field
    /// guard inside `Redaction.apply`, which `--ignore-privacy` has never overridden.
    static func applyPolicy(
        element: ElementInfo?, window: WindowInfo?, policy: PrivacyPolicy, maxValueBytes: Int
    ) -> (element: ElementInfo?, window: WindowInfo?) {
        var visibleWindow = window
        visibleWindow?.title = EventRedaction.redactText(window?.title, policy: policy)
        visibleWindow?.document = EventRedaction.redactText(window?.document, policy: policy)
        visibleWindow?.url = EventRedaction.redactText(window?.url, policy: policy)
        guard var visibleElement = element else { return (nil, visibleWindow) }
        let redacted = Redaction.apply(element, maxValueBytes: maxValueBytes, policy: policy)
        visibleElement.value = redacted.value
        visibleElement.selectedText = redacted.selectedText
        visibleElement.title = EventRedaction.redactText(visibleElement.title, policy: policy)
        return (visibleElement, visibleWindow)
    }

    static func human(_ inspection: Inspection) -> String {
        if let rule = inspection.protectedBy {
            return "protected by rule '\(rule)' — nothing read"
        }
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
