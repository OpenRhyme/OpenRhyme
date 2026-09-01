import ArgumentParser

@main
struct OpenRhyme: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "openrhyme",
        abstract: "Local-first computer history for macOS: capture, store and query your activity.",
        version: "0.1.0",
        subcommands: [VersionCommand.self],
        defaultSubcommand: nil)
}
