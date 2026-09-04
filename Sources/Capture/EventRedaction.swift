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
        redact(&event.value, policy: policy, fired: &fired)
        redact(&event.selectedText, policy: policy, fired: &fired)
        redact(&event.windowTitle, policy: policy, fired: &fired)
        redact(&event.url, policy: policy, fired: &fired)
        redact(&event.document, policy: policy, fired: &fired)
        redact(&event.elementTitle, policy: policy, fired: &fired)
        // `HeartbeatDiff` copies the prior window title into `extra.previousTitle` verbatim on a
        // `window.title_changed` row — the one place `extra` holds captured text.
        if var extra = event.extra, let previousTitle = extra["previousTitle"]?.stringValue {
            var text: String? = previousTitle
            redact(&text, policy: policy, fired: &fired)
            extra["previousTitle"] = .string(text ?? previousTitle)
            event.extra = extra
        }
        return fired.sorted()
    }

    /// One piece of captured text, redacted under the same policy — for the paths that hand back
    /// text without building a `RawEvent` around it (`inspect`'s window fields, element title and
    /// subtree nodes). A no-op when the policy is off, so `--ignore-privacy` passes straight
    /// through.
    public static func redactText(_ text: String?, policy: PrivacyPolicy) -> String? {
        guard policy.enabled, let text else { return text }
        return SecretRedactor.redact(text, entropyEnabled: policy.entropyRedaction).text
    }

    private static func redact(
        _ text: inout String?, policy: PrivacyPolicy, fired: inout Set<String>
    ) {
        guard let original = text else { return }
        let result = SecretRedactor.redact(original, entropyEnabled: policy.entropyRedaction)
        text = result.text
        fired.formUnion(result.rules)
    }
}
