import ArgumentParser
import Capture
import Core
import Foundation
import Store

struct EventsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events", abstract: "Query raw events.")

    @Option(name: .long, help: "Start time: 2h, 30m, unix seconds, or ISO-8601.") var since: String
    @Option(name: .long, help: "End time (same grammar).") var until: String?
    @Option(name: .long, help: "Event kind filter, repeatable (e.g. window.focused).")
    var kind: [String] = []
    @Option(name: .long, help: "Bundle identifier filter.") var app: String?
    @Option(name: .long, help: "Maximum rows (default 1000, max 10000).") var limit: Int = 1000
    @Option(
        name: .long,
        help: "Truncate value/selected_text to this many characters (0 = full, the default)."
    ) var maxValueChars: Int = 0
    @Flag(name: .long, help: "Emit a JSON envelope.") var json = false
    @Flag(
        name: .long,
        help:
            "Return stored text unredacted, so you can audit what the store actually holds (prints a warning; reads only)."
    )
    var ignorePrivacy = false

    struct Result: Encodable {
        let events: [RawEvent]
        let count: Int
    }

    static func parseKinds(_ names: [String]) throws -> [EventKind]? {
        guard !names.isEmpty else { return nil }
        return try names.map { name in
            guard let kind = EventKind(rawValue: name) else {
                throw CLIError.usage("Unknown kind '\(name)'")
            }
            return kind
        }
    }

    /// Privacy fix round 1, J11: the help text says "0 = full" — a negative value is not a
    /// third meaning, it must be rejected rather than silently behaving like `0`.
    func validate() throws {
        guard maxValueChars >= 0 else {
            throw ValidationError("--max-value-chars must be >= 0 (0 = full)")
        }
    }

    /// Spec privacy §4: redaction is re-applied on the way out, so a rule added today also
    /// protects rows captured before it existed. The column list lives in
    /// `EventRedaction.apply`, which the capture path calls too (whole-branch review H2) — the
    /// two used to keep their own lists, and capture's was four columns shorter. Idempotent, so
    /// re-running it here over a row capture already cleaned changes nothing.
    ///
    /// Only ever changes what is *returned*: this never writes back to the store, so
    /// capture-time artifacts (`extra.fingerprint`, `extra.valueHash`, dedup) are computed from
    /// the original, unredacted text and are unaffected by what a later read redacts.
    ///
    /// Pass `PrivacyPolicy.disabled` to return stored text as-is — what `--ignore-privacy` does
    /// on `events`/`export` (whole-branch review H3). The default must stay redacted: the MCP
    /// server reads through `events`, so an agent must never get raw text without the user
    /// explicitly asking for it.
    ///
    /// When `maxValueChars > 0` actually cuts `value` or `selected_text`, `extra.valueTruncated`
    /// is set `true` (privacy fix round 1, J12) so a caller can tell a value was cut rather than
    /// silently ending mid-token. Shared with `ExportCommand`, the only other path that returns
    /// stored text to a caller.
    static func project(
        _ events: [RawEvent], policy: PrivacyPolicy, maxValueChars: Int
    )
        -> [RawEvent]
    {
        events.map { event in
            var copy = event
            EventRedaction.apply(to: &copy, policy: policy)
            if maxValueChars > 0 {
                var truncated = false
                if let value = copy.value, value.count > maxValueChars {
                    copy.value = String(value.prefix(maxValueChars))
                    truncated = true
                }
                if let selected = copy.selectedText, selected.count > maxValueChars {
                    copy.selectedText = String(selected.prefix(maxValueChars))
                    truncated = true
                }
                if truncated {
                    var extra = copy.extra ?? [:]
                    extra["valueTruncated"] = .bool(true)
                    copy.extra = extra
                }
            }
            return copy
        }
    }

    func run() async throws {
        try await runJSON(json: json, human: Self.humanLines) {
            let query = EventQuery(
                since: try TimeSpec.parse(since),
                until: try until.map { try TimeSpec.parse($0) },
                kinds: try Self.parseKinds(kind), bundleID: app, limit: limit)
            let paths = Paths.resolve()
            let config = try Config.load(from: paths.configURL)
            // H3: the owner must be able to audit their own history — to find out whether
            // something sensitive was captured at all, and to confirm a purge worked. Opt-in
            // only, warned on stderr so a `--json` stdout stays parseable, and named after the
            // precedent `inspect` already set.
            let policy =
                ignorePrivacy ? PrivacyPolicy.disabled : PrivacyPolicy(settings: config.privacy)
            if ignorePrivacy { Output.stderr(Self.ignorePrivacyWarning) }
            let store = try EventStore(url: paths.databaseURL, readOnly: true)
            let events = try await store.query(query)
            await store.close()
            let projected = Self.project(events, policy: policy, maxValueChars: maxValueChars)
            return Result(events: projected, count: projected.count)
        }
    }

    /// Shared with `export`, so both commands warn in exactly the same words. Goes to stderr,
    /// never stdout, so it can never end up inside a JSON envelope or a JSONL export file.
    static let ignorePrivacyWarning =
        "warning: --ignore-privacy returns stored text unredacted — any secret in the store is "
        + "printed in the clear"

    static func humanLines(_ result: Result) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return result.events.map { event in
            let time = formatter.string(from: Date(timeIntervalSince1970: event.ts))
            let app = event.bundleID ?? "-"
            let detail =
                event.windowTitle ?? event.elementTitle ?? event.value?.prefix(60).description ?? ""
            return "\(time)  \(event.kind.rawValue)  \(app)  \(detail)"
        }.joined(separator: "\n")
    }
}
