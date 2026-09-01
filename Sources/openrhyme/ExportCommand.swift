import ArgumentParser
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
            let store = try EventStore(url: Paths.resolve().databaseURL, readOnly: true)
            let handle: FileHandle
            if let out {
                FileManager.default.createFile(atPath: out, contents: nil)
                handle = try FileHandle(forWritingTo: URL(fileURLWithPath: out))
            } else {
                handle = FileHandle.standardOutput
            }
            var afterID: Int64?
            while true {
                let page = try await store.query(
                    EventQuery(
                        since: sinceTS, until: untilTS, limit: EventQuery.maxLimit, afterID: afterID
                    ))
                for event in page {
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
