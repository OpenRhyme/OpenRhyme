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
    /// protects rows captured before it existed. Idempotent — an already-redacted row is
    /// unchanged. Covers every text-bearing column — `value`, `selected_text`, `window_title`,
    /// `url`, `document`, `element_title` — not just `value`/`selected_text` (privacy fix round
    /// 1, J8): a credential is just as real leaked in a URL query string
    /// (`?token=AKIA…`) or a window title as it is in `value`. Only ever changes what is
    /// *returned*: this never writes back to the store, so capture-time artifacts
    /// (`extra.fingerprint`, `extra.valueHash`, dedup) are computed from the original,
    /// unredacted text and are unaffected by what a later read redacts.
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
            if policy.enabled {
                copy.value = redact(copy.value, policy: policy)
                copy.selectedText = redact(copy.selectedText, policy: policy)
                copy.windowTitle = redact(copy.windowTitle, policy: policy)
                copy.url = redact(copy.url, policy: policy)
                copy.document = redact(copy.document, policy: policy)
                copy.elementTitle = redact(copy.elementTitle, policy: policy)
            }
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

    private static func redact(_ text: String?, policy: PrivacyPolicy) -> String? {
        text.map { SecretRedactor.redact($0, entropyEnabled: policy.entropyRedaction).text }
    }

    func run() async throws {
        try await runJSON(json: json, human: Self.humanLines) {
            let query = EventQuery(
                since: try TimeSpec.parse(since),
                until: try until.map { try TimeSpec.parse($0) },
                kinds: try Self.parseKinds(kind), bundleID: app, limit: limit)
            let paths = Paths.resolve()
            let config = try Config.load(from: paths.configURL)
            let policy = PrivacyPolicy(settings: config.privacy)
            let store = try EventStore(url: paths.databaseURL, readOnly: true)
            let events = try await store.query(query)
            await store.close()
            let projected = Self.project(events, policy: policy, maxValueChars: maxValueChars)
            return Result(events: projected, count: projected.count)
        }
    }

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
