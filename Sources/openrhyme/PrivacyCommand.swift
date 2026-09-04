import ArgumentParser
import Capture
import Core
import Foundation
import Store

/// Spec privacy §7.3: lets the user see the policy in force, the frontmost app's live verdict,
/// and how many stored rows the current rules would protect — a reporting command only. It never
/// creates, migrates, tightens or writes to the store: the database is opened `readOnly` and only
/// when it already exists.
struct PrivacyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "privacy",
        abstract:
            "Show the privacy policy in force, the frontmost app's verdict, and how many stored rows the current rules would protect."
    )

    @Flag(name: .long, help: "Emit a JSON envelope.") var json = false

    struct Result: Encodable {
        let enabled: Bool
        let entropyRedaction: Bool
        let protectedBundleIDs: [String]
        let protectedURLPatterns: [String]
        let protectedDocumentPatterns: [String]
        let protectedWindowTitlePatterns: [String]
        let credentialFieldPatterns: [String]
        let frontmostApp: String?
        /// "open", the rule name that protects the frontmost context, or `nil` when there is no
        /// context to evaluate at all (Accessibility not trusted, or no app is frontmost) — never
        /// a fabricated "open" for those cases.
        let frontmostVerdict: String?
        let storedRowsMatchingRules: Int

        // Top-level CLI `--json` output is snake_case (see `status`/`events`/`apps`), unlike the
        // event `extra` blob (camelCase) — these two conventions are already both established
        // and must not be mixed within one command's envelope.
        enum CodingKeys: String, CodingKey {
            case enabled
            case entropyRedaction = "entropy_redaction"
            case protectedBundleIDs = "protected_bundle_ids"
            case protectedURLPatterns = "protected_url_patterns"
            case protectedDocumentPatterns = "protected_document_patterns"
            case protectedWindowTitlePatterns = "protected_window_title_patterns"
            case credentialFieldPatterns = "credential_field_patterns"
            case frontmostApp = "frontmost_app"
            case frontmostVerdict = "frontmost_verdict"
            case storedRowsMatchingRules = "stored_rows_matching_rules"
        }
    }

    func run() async throws {
        try await runJSON(json: json, human: Self.human) {
            let paths = Paths.resolve()
            let config = try Config.load(from: paths.configURL)
            let policy = PrivacyPolicy(settings: config.privacy)

            let (frontmostApp, frontmostVerdict) = await Self.frontmostVerdict(policy: policy)
            let storedRowsMatchingRules = try await Self.countProtectedRows(
                databaseURL: paths.databaseURL, policy: policy)

            return Result(
                enabled: policy.enabled,
                entropyRedaction: policy.entropyRedaction,
                protectedBundleIDs: policy.protectedBundleIDs.sorted(),
                protectedURLPatterns: policy.protectedURLPatterns,
                protectedDocumentPatterns: policy.protectedDocumentPatterns,
                protectedWindowTitlePatterns: policy.protectedWindowTitlePatterns,
                credentialFieldPatterns: policy.credentialFieldPatterns,
                frontmostApp: frontmostApp,
                frontmostVerdict: frontmostVerdict,
                storedRowsMatchingRules: storedRowsMatchingRules)
        }
    }

    /// Evaluates the frontmost app's live context against the real policy. Reports honestly —
    /// `(nil, nil)` — when Accessibility is not trusted or no app is frontmost, rather than
    /// fabricating an "open" verdict for a context that was never actually read.
    private static func frontmostVerdict(
        policy: PrivacyPolicy
    ) async -> (
        app: String?, verdict: String?
    ) {
        await MainActor.run {
            let client = AXClient()
            guard client.isTrusted(prompt: false), let app = client.frontmostApplication() else {
                return (app: nil, verdict: nil)
            }
            guard let context = try? client.focusedContext(of: app, reusing: nil, policy: policy)
            else {
                return (app: app.bundleID, verdict: nil)
            }
            switch context.protection {
            case .open: return (app: app.bundleID, verdict: "open")
            case .protected(let rule): return (app: app.bundleID, verdict: rule)
            }
        }
    }

    /// Counts stored rows the current rules would protect, using the same pure selector `purge`
    /// uses so there is never a second matcher to drift. Pages the whole store id-ordered (the
    /// same cursor idiom as `PurgeCommand.fetchAllCandidates`/`ExportCommand`) one page at a time
    /// rather than accumulating every row in memory, since only a running count is needed.
    /// Marker rows for already-protected contexts carry no url/document/title (privacy §5.5);
    /// `PurgeCommand.select` already treats those nils as non-matches, never as matching
    /// everything.
    private static func countProtectedRows(
        databaseURL: URL, policy: PrivacyPolicy
    ) async throws
        -> Int
    {
        // A report must never create the database it's reporting on.
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return 0 }
        let store = try EventStore(url: databaseURL, readOnly: true)
        var count = 0
        var afterID: Int64? = 0
        while true {
            let page = try await store.query(
                EventQuery(since: 0, until: nil, limit: EventQuery.maxLimit, afterID: afterID))
            count +=
                PurgeCommand.select(
                    events: page, app: nil, urlContains: nil, applyRules: true, policy: policy
                ).count
            guard page.count == EventQuery.maxLimit, let last = page.last?.id else { break }
            afterID = last
        }
        await store.close()
        return count
    }

    static func human(_ result: Result) -> String {
        var lines: [String] = []
        lines.append("privacy: \(result.enabled ? "enabled" : "disabled")")
        lines.append("entropy redaction: \(result.entropyRedaction ? "on" : "off")")
        lines.append(
            "protected bundle IDs (\(result.protectedBundleIDs.count)): "
                + result.protectedBundleIDs.joined(separator: ", "))
        lines.append(
            "protected URL patterns (\(result.protectedURLPatterns.count)): "
                + result.protectedURLPatterns.joined(separator: ", "))
        lines.append(
            "protected document patterns (\(result.protectedDocumentPatterns.count)): "
                + result.protectedDocumentPatterns.joined(separator: ", "))
        lines.append(
            "protected window title patterns (\(result.protectedWindowTitlePatterns.count)): "
                + result.protectedWindowTitlePatterns.joined(separator: ", "))
        lines.append(
            "credential field patterns (\(result.credentialFieldPatterns.count)): "
                + result.credentialFieldPatterns.joined(separator: ", "))
        if let app = result.frontmostApp, let verdict = result.frontmostVerdict {
            lines.append("frontmost: \(app) — \(verdict)")
        } else {
            lines.append(
                "frontmost: - (not available: Accessibility not trusted, or no app is frontmost)")
        }
        lines.append("stored rows matching current rules: \(result.storedRowsMatchingRules)")
        if result.storedRowsMatchingRules > 0 {
            lines.append(
                "\(result.storedRowsMatchingRules) stored rows match the current rules; remove "
                    + "them with: openrhyme purge --apply-rules --yes")
        }
        return lines.joined(separator: "\n")
    }
}
