import ArgumentParser
import Capture
import Core
import Foundation

struct AppsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps", abstract: "Manage the capture allowlist.",
        subcommands: [List.self, Allow.self, Deny.self, Running.self], defaultSubcommand: List.self)

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

    struct RunningApp: Encodable {
        let pid: Int32
        let bundleID: String?
        let name: String?
        let allowlisted: Bool
        let isElectron: Bool

        enum CodingKeys: String, CodingKey {
            case pid, name, allowlisted
            case bundleID = "bundle_id"
            case isElectron = "is_electron"
        }
    }

    struct RunningList: Encodable {
        let apps: [RunningApp]
    }

    struct Running: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List running apps with their bundle identifiers.")
        @Flag(name: .long) var json = false

        func run() async throws {
            try await runJSON(json: json, human: Self.human) {
                let config = try Config.load(from: Paths.resolve().configURL)
                let apps = await MainActor.run { AXClient().runningApplications() }
                return RunningList(
                    apps: apps.sorted { ($0.name ?? "") < ($1.name ?? "") }.map { app in
                        RunningApp(
                            pid: app.pid, bundleID: app.bundleID, name: app.name,
                            allowlisted: config.isAllowed(app.bundleID),
                            isElectron: ElectronSupport.isElectronBundle(app.bundleURL))
                    })
            }
        }

        static func human(_ list: RunningList) -> String {
            list.apps.map { app in
                let flags = [app.allowlisted ? "allowed" : nil, app.isElectron ? "electron" : nil]
                    .compactMap { $0 }.joined(separator: ",")
                return "\(app.bundleID ?? "-")\t\(app.name ?? "-")\t\(flags)"
            }.joined(separator: "\n")
        }
    }
}
