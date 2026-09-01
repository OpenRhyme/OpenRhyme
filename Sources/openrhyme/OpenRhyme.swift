import ArgumentParser
import Darwin
import Foundation

@main
struct OpenRhyme: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "openrhyme",
        abstract: "Local-first computer history for macOS: capture, store and query your activity.",
        version: "0.1.0",
        subcommands: [
            AppsCommand.self, EventsCommand.self, ExportCommand.self, InspectCommand.self,
            VersionCommand.self,
        ],
        defaultSubcommand: nil)

    /// ArgumentParser exits 64 (EX_USAGE) on parse/validation failures; spec §9 says 2.
    static func main() async {
        do {
            var command = try await asyncParseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            let code = exitCode(for: error)
            let message = fullMessage(for: error)
            if code.isSuccess {
                if !message.isEmpty { print(message) }
            } else if !message.isEmpty {
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
            Darwin.exit(code.rawValue == 64 ? 2 : code.rawValue)
        }
    }
}
