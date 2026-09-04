import Core
import Foundation

/// The one list of stored text columns that carry user-visible captured text, and the single
/// redaction pass over them.
///
/// Whole-branch review H2 (privacy fix round 4): capture redacted only `value`/`selected_text`
/// while the read path (`EventsCommand.project`) covered six columns plus `extra.previousTitle`,
/// so an API key in a URL query string — one of the most common real leak shapes — was written to
/// disk in the clear. That asymmetry had three consequences: `purge --apply-rules` could not
/// select such a row, `openrhyme privacy` counted it as `0`, and anything reading the SQLite file
/// without going through the CLI (a backup, the user's own `sqlite3`, the planned Compact layer)
/// saw the secret. Both paths now call this, so the column list cannot diverge again.
///
/// **This runs on the finished row, never on the inputs to identity.** `extra.fingerprint` is
/// computed by `HeartbeatDiff` over the *raw* bundle id / window title / document / URL, and
/// `extra.valueHash` over the value `Redaction.apply` produced, both before this pass touches the
/// row — so dedup (`ContextSignature`) and the grouping key Compact will use are byte-identical
/// to what the same context produced before capture-time redaction existed. Redacting first would
/// silently change both: two visits carrying different secrets in the same URL collapse to one
/// redacted string, and would start deduping into a single row.
public enum EventRedaction {
    /// How much of the redactor a piece of stored text gets. The column decides this — not a
    /// caller-supplied flag — because it is a property of what the column *means*, and both the
    /// capture path and the read path must answer it the same way.
    ///
    /// Fix round 1: extending capture-time redaction to `url`/`document`/`window_title`/
    /// `element_title` (H2) also dragged the Shannon-entropy backstop onto them, and the
    /// backstop's gate — 20+ characters, mixed case, a digit, high entropy — is an exact
    /// description of an opaque resource id. A Google Docs document id, a Notion page id, a
    /// Dropbox or S3 key all matched, so capture was permanently rewriting the one part of the
    /// URL that says *which document the person was looking at*. For a computer-history tool
    /// that is a bad trade: unlike a real secret there is nothing being protected, because an
    /// opaque id is a name, not a credential.
    public enum Coverage: Sendable {
        /// Structural rules plus the entropy backstop. For free text the user typed, pasted or
        /// selected, where an unrecognised credential shape is genuinely likely and
        /// over-redacting costs little.
        case full
        /// Structural rules only. For identifying text — a URL, a document path, a window or
        /// element title — where the entropy backstop destroys resource ids and protects
        /// nothing. **Every structural rule still runs here**: AWS, GitHub, Stripe, Slack,
        /// Google API key, Anthropic, OpenAI, JWT, private-key block, connection-string and
        /// `key=value` assignment. Those match on *shape*, not entropy, so `?token=AKIA…` is
        /// still caught — which was H2's whole point — while `/document/d/1BxiMVs0XRA5nFMdKv…`
        /// survives intact.
        case structuralOnly

        func entropyEnabled(_ policy: PrivacyPolicy) -> Bool {
            switch self {
            case .full: return policy.entropyRedaction
            case .structuralOnly: return false
            }
        }
    }

    /// Redacts every stored text column in place and returns the sorted rule names that fired.
    /// A no-op when the policy is off (`privacy.enabled: false`), matching `Redaction.apply`.
    /// Idempotent: an already-redacted row is unchanged and fires nothing, which is what lets
    /// the read path re-run it over rows the capture path already cleaned.
    ///
    /// The rest of `extra` is deliberately left alone — it carries hashes, counts, booleans and
    /// rule/enum names (`fingerprint`, `valueHash`, `textSource`, `protectedBy`, `redacted`,
    /// `reason`, `input`, `length`, `truncated`, …), none of which is user-visible captured text,
    /// and redacting one would corrupt it rather than protect anything.
    @discardableResult
    public static func apply(to event: inout RawEvent, policy: PrivacyPolicy) -> [String] {
        guard policy.enabled else { return [] }
        var fired: Set<String> = []
        redact(&event.value, coverage: .full, policy: policy, fired: &fired)
        redact(&event.selectedText, coverage: .full, policy: policy, fired: &fired)
        redact(&event.windowTitle, coverage: .structuralOnly, policy: policy, fired: &fired)
        redact(&event.url, coverage: .structuralOnly, policy: policy, fired: &fired)
        redact(&event.document, coverage: .structuralOnly, policy: policy, fired: &fired)
        redact(&event.elementTitle, coverage: .structuralOnly, policy: policy, fired: &fired)
        // `HeartbeatDiff` copies the prior window title into `extra.previousTitle` verbatim on a
        // `window.title_changed` row — the one place `extra` holds captured text. It is a window
        // title, so it gets a window title's coverage.
        if var extra = event.extra, let previousTitle = extra["previousTitle"]?.stringValue {
            var text: String? = previousTitle
            redact(&text, coverage: .structuralOnly, policy: policy, fired: &fired)
            extra["previousTitle"] = .string(text ?? previousTitle)
            event.extra = extra
        }
        return fired.sorted()
    }

    /// One piece of captured text, redacted under the same policy — for the paths that hand back
    /// text without building a `RawEvent` around it (`inspect`'s window fields, element title and
    /// subtree node titles, all of which are `.structuralOnly` identifying text). A no-op when
    /// the policy is off, so `--ignore-privacy` passes straight through.
    public static func redact(
        _ text: String?, coverage: Coverage, policy: PrivacyPolicy
    ) -> String? {
        guard policy.enabled, let text else { return text }
        return SecretRedactor.redact(text, entropyEnabled: coverage.entropyEnabled(policy)).text
    }

    private static func redact(
        _ text: inout String?, coverage: Coverage, policy: PrivacyPolicy, fired: inout Set<String>
    ) {
        guard let original = text else { return }
        let result = SecretRedactor.redact(
            original, entropyEnabled: coverage.entropyEnabled(policy))
        text = result.text
        fired.formUnion(result.rules)
    }
}
