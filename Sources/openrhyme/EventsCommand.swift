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
        help: "Truncate value/selected_text to this many characters (0 = full)."
    ) var maxValueChars: Int = 2000
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

    /// Spec privacy §4: redaction is re-applied on the way out, so a rule added today also
    /// protects rows captured before it existed. Idempotent — an already-redacted row is
    /// unchanged. Shared with `ExportCommand`, the only other path that returns stored
    /// `value`/`selected_text` to a caller.
    static func project(
        _ events: [RawEvent], policy: PrivacyPolicy, maxValueChars: Int
    )
        -> [RawEvent]
    {
        events.map { event in
            var copy = event
            if policy.enabled {
                if let value = copy.value {
                    copy.value =
                        SecretRedactor.redact(
                            value, entropyEnabled: policy.entropyRedaction
                        ).text
                }
                if let selected = copy.selectedText {
                    copy.selectedText =
                        SecretRedactor.redact(
                            selected, entropyEnabled: policy.entropyRedaction
                        ).text
                }
            }
            if maxValueChars > 0 {
                copy.value = copy.value.map { String($0.prefix(maxValueChars)) }
                copy.selectedText = copy.selectedText.map { String($0.prefix(maxValueChars)) }
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
