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
        let dataDir: String
        let dbPath: String
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
        /// How many stored rows the *configured* rules match, evaluated as if `enabled` were
        /// `true` regardless of its actual value (privacy fix round 3, H1). If this were instead
        /// computed under the real, possibly-disabled policy, a disabled policy would always
        /// report `0` here — read by a worried user as "nothing sensitive is stored", when it
        /// actually means "not evaluated": re-enabling could match everything counted here. This
        /// way the field means the same thing in both states — "how many rows match these rule
        /// definitions" — and `enabled` alone tells you whether that's real or hypothetical.
        let storedRowsMatchingRules: Int
        /// Privacy fix round 1: `capture.retention_days` was reported by no command before this
        /// — `0` means unset/keep everything.
        let retentionDays: Int
        /// Whole-branch review I4: parts of `config.json` that did not mean what the user
        /// evidently intended — a protect list written as a bare array, a key whose shape could
        /// not be read at all, a non-numeric `retention_days`. Empty when the config parsed
        /// cleanly. The daemon logs the same strings (`Capturer.warnAboutConfig`); this is where
        /// a user who never reads the log finds out that a rule they wrote is not the rule in
        /// force.
        let configWarnings: [String]

        // Top-level CLI `--json` output is snake_case (see `status`/`events`/`apps`), unlike the
        // event `extra` blob (camelCase) — these two conventions are already both established
        // and must not be mixed within one command's envelope.
        enum CodingKeys: String, CodingKey {
            case enabled
            case dataDir = "data_dir"
            case dbPath = "db_path"
            case entropyRedaction = "entropy_redaction"
            case protectedBundleIDs = "protected_bundle_ids"
            case protectedURLPatterns = "protected_url_patterns"
            case protectedDocumentPatterns = "protected_document_patterns"
            case protectedWindowTitlePatterns = "protected_window_title_patterns"
            case credentialFieldPatterns = "credential_field_patterns"
            case frontmostApp = "frontmost_app"
            case frontmostVerdict = "frontmost_verdict"
            case storedRowsMatchingRules = "stored_rows_matching_rules"
            case retentionDays = "retention_days"
            case configWarnings = "config_warnings"
        }
    }

    func run() async throws {
        try await runJSON(json: json, human: Self.human) {
            let paths = Paths.resolve()
            let config = try Config.load(from: paths.configURL)
            let policy = PrivacyPolicy(settings: config.privacy)

            let (frontmostApp, frontmostVerdict) = await Self.frontmostVerdict(policy: policy)
            // H1: always count against the rules as configured, not the real (possibly
            // disabled) policy — see the doc comment on `Result.storedRowsMatchingRules`.
            var countingPolicy = policy
            countingPolicy.enabled = true
            let storedRowsMatchingRules = try await Self.countProtectedRows(
                databaseURL: paths.databaseURL, policy: countingPolicy)

            return Result(
                enabled: policy.enabled,
                dataDir: paths.dataDir.path,
                dbPath: paths.databaseURL.path,
                entropyRedaction: policy.entropyRedaction,
                protectedBundleIDs: policy.protectedBundleIDs.sorted(),
                protectedURLPatterns: policy.protectedURLPatterns,
                protectedDocumentPatterns: policy.protectedDocumentPatterns,
                protectedWindowTitlePatterns: policy.protectedWindowTitlePatterns,
                credentialFieldPatterns: policy.credentialFieldPatterns,
                frontmostApp: frontmostApp,
                frontmostVerdict: frontmostVerdict,
                storedRowsMatchingRules: storedRowsMatchingRules,
                retentionDays: config.capture.retentionDays,
                configWarnings: Self.configWarnings(for: config))
        }
    }

    /// I4: the config's own silent failures, in the same words the daemon logs. `retention_days`
    /// belongs here too — this command prints `retention: off (keep forever)` from a value that
    /// falls back to `0` when it was written as `"30"`, which is the same defect wearing a
    /// different key.
    static func configWarnings(for config: Config) -> [String] {
        var warnings = config.privacy.configWarnings
        if config.capture.retentionDaysInvalid {
            warnings.append(
                "capture.retention_days is not a whole number, so retention is off and nothing "
                    + "is being swept. Write it unquoted, e.g. \"retention_days\": 30.")
        }
        return warnings
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

    /// Whole-branch review, honesty defect: the old line read "stored rows matching current
    /// rules: 0", and a worried user reads a `0` there as "nothing sensitive is stored". It never
    /// meant that. It counts rows a *protect rule* matches — a row that merely contains a secret
    /// matches no rule and is not counted, and `purge --apply-rules` will not remove it either.
    /// The caveat rides on the number itself, in both the enabled and disabled wordings, so the
    /// count can never be quoted or skimmed without it.
    static let matchCountCaveat =
        " — a rule-match count ONLY. This is not a measure of how much sensitive data is stored: "
        + "a row no protect rule matches is not counted here even if it contains a secret, and "
        + "`purge --apply-rules` would not remove it either. To see what is actually in the "
        + "store, read it unredacted with: openrhyme events --since 7d --ignore-privacy"

    static func human(_ result: Result) -> String {
        var lines: [String] = []
        // The single word "disabled" reads exactly like "enabled" at a skim — this is the one
        // line most likely to answer "am I protected?", so it must be impossible to misread.
        if result.enabled {
            lines.append("privacy: ENABLED")
        } else {
            lines.append(
                "privacy: DISABLED — none of the rules below are being enforced right now")
        }
        // I4: directly under the enabled/disabled line, because everything printed below it is a
        // description of the rules in force — and a warning here means one of the rules the user
        // wrote is not among them.
        for warning in result.configWarnings {
            lines.append("WARNING: \(warning)")
        }
        lines.append("data dir: \(result.dataDir)")
        lines.append("db path:  \(result.dbPath)")
        lines.append(
            "retention: \(result.retentionDays > 0 ? "\(result.retentionDays) day(s)" : "off (keep forever)")"
        )
        // Unconditional, not just when something already matches: the one thing a first-time
        // reader must learn before trusting this report at all. Deliberately does NOT name
        // `purge --apply-rules` here (H2, privacy fix round 3): that command is only a safe,
        // actionable instruction while privacy is enabled — printing it unconditionally, next to
        // a disabled-state hypothetical count, would tell a worried user to run a command that
        // silently matches nothing and reports success, while every one of their sensitive rows
        // stays exactly where it was. The state-specific command (or its disabled-state caveat)
        // is given below, next to the count it actually applies to.
        lines.append(
            "note: protect rules only change what gets captured from now on — they never "
                + "remove or alter anything already stored.")
        if !result.enabled {
            lines.append("configured rules (listed for reference; inactive while disabled):")
        }
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
        // H1/H2 (privacy fix round 3): while disabled, the count is hypothetical (computed as
        // if enabled — see `Result.storedRowsMatchingRules`) and the removal command is not a
        // safe next step: `purge --apply-rules` matches nothing while the policy is off, so it
        // would report success (`deleted: 0`) while every row counted here stays untouched.
        if result.enabled {
            lines.append(
                "stored rows a protect rule matches: \(result.storedRowsMatchingRules)"
                    + Self.matchCountCaveat)
            if result.storedRowsMatchingRules > 0 {
                lines.append(
                    "\(result.storedRowsMatchingRules) stored rows match the current rules; "
                        + "remove them with: openrhyme purge --apply-rules --yes")
            }
        } else {
            lines.append(
                "stored rows a protect rule would match if enabled: "
                    + "\(result.storedRowsMatchingRules)" + Self.matchCountCaveat)
            lines.append(
                "privacy is OFF, so this is a hypothetical count — nothing is being matched "
                    + "right now, and `openrhyme purge --apply-rules` would remove nothing while "
                    + "it stays off. Enable privacy first (set \"enabled\": true under "
                    + "\"privacy\" in config.json), then re-run `openrhyme privacy` to confirm "
                    + "the real count before purging.")
        }
        return lines.joined(separator: "\n")
    }
}
