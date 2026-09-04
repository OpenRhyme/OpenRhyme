import ArgumentParser
import Capture
import Core
import Foundation
import Store

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export", abstract: "Export raw events as JSON Lines.")

    @Option(name: .long, help: "Start time: 2h, 30m, unix seconds, or ISO-8601.") var since: String
    @Option(name: .long, help: "End time (same grammar).") var until: String?
    @Option(name: .long, help: "Write to this file instead of stdout.") var out: String?

    func run() async throws {
        do {
            let sinceTS = try TimeSpec.parse(since)
            let untilTS = try until.map { try TimeSpec.parse($0) }
            let paths = Paths.resolve()
            let config = try Config.load(from: paths.configURL)
            let policy = PrivacyPolicy(settings: config.privacy)
            let store = try EventStore(url: paths.databaseURL, readOnly: true)
            let handle: FileHandle
            if let out {
                FileManager.default.createFile(atPath: out, contents: nil)
                handle = try FileHandle(forWritingTo: URL(fileURLWithPath: out))
            } else {
                handle = FileHandle.standardOutput
            }
            // Page in insertion (id) order, not ts order, per spec §7.3: export is
            // documented as insertion order, and starting the cursor at 0 (ids are
            // 1-based) keeps every page id-ordered, including the first, so a
            // non-monotonic ts never lets a row fall through the paging cursor.
            var afterID: Int64? = 0
            while true {
                let page = try await store.query(
                    EventQuery(
                        since: sinceTS, until: untilTS, limit: EventQuery.maxLimit, afterID: afterID
                    ))
                // Export is a read path too (spec privacy §4/§5.7): the same projection
                // `events` applies runs here, un-truncated (`maxValueChars: 0`) since export
                // has no char-limit flag of its own.
                let projected = EventsCommand.project(page, policy: policy, maxValueChars: 0)
                for event in projected {
                    handle.write(Data((try JSONLExport.line(for: event) + "\n").utf8))
                }
                guard page.count == EventQuery.maxLimit, let last = page.last?.id else { break }
                afterID = last
            }
            if out != nil { try handle.close() }
            await store.close()
        } catch {
            let cli = Output.cliError(error)
            Output.stderr("error: \(cli.message)" + (cli.hint.map { "\nhint: \($0)" } ?? ""))
            throw ExitCode(cli.exitCode)
        }
    }
}
