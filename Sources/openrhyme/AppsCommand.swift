import ArgumentParser
import Core
import Foundation

struct AppsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps", abstract: "Manage the capture allowlist.",
        subcommands: [List.self, Allow.self, Deny.self], defaultSubcommand: List.self)

    struct Allowlist: Encodable {
        let allowlist: [String]
        let changed: Bool?
    }

    static func humanAllowlist(_ result: Allowlist) -> String {
        result.allowlist.isEmpty ? "(empty)" : result.allowlist.joined(separator: "\n")
    }

    static func validated(_ bundleID: String) throws -> String {
        let trimmed = bundleID.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("."), !trimmed.contains(" ") else {
            throw CLIError.usage(
                "'\(bundleID)' is not a bundle identifier (expected e.g. com.apple.TextEdit; try `openrhyme apps running`)"
            )
        }
        return trimmed
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the allowlist.")
        @Flag(name: .long) var json = false

        func run() async throws {
            try await runJSON(json: json, human: AppsCommand.humanAllowlist) {
                Allowlist(
                    allowlist: try Config.load(from: Paths.resolve().configURL).allowlist,
                    changed: nil)
            }
        }
    }

    struct Allow: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add an app to the allowlist.")
        @Argument(help: "Bundle identifier, e.g. com.apple.Safari.") var bundleID: String
        @Flag(name: .long) var json = false

        func run() async throws {
            try await runJSON(json: json, human: AppsCommand.humanAllowlist) {
                let paths = Paths.resolve()
                let id = try AppsCommand.validated(bundleID)
                let before = try Config.load(from: paths.configURL)
                let after = before.allowing(id)
                if after != before { try after.save(to: paths.configURL) }
                return Allowlist(allowlist: after.allowlist, changed: after != before)
            }
        }
    }

    struct Deny: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove an app from the allowlist.")
        @Argument(help: "Bundle identifier.") var bundleID: String
        @Flag(name: .long) var json = false

        func run() async throws {
            try await runJSON(json: json, human: AppsCommand.humanAllowlist) {
                let paths = Paths.resolve()
                let id = try AppsCommand.validated(bundleID)
                let before = try Config.load(from: paths.configURL)
                let after = before.denying(id)
                if after != before { try after.save(to: paths.configURL) }
                return Allowlist(allowlist: after.allowlist, changed: after != before)
            }
        }
    }
}
