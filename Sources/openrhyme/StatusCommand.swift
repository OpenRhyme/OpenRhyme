import ArgumentParser
import Capture
import Core
import Foundation
import Store

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Trust state, daemon liveness, store size, allowlist.")

    @Flag(name: .long, help: "Emit a JSON envelope.") var json = false

    struct Status: Encodable {
        let trusted: Bool
        let state: String
        let daemonRunning: Bool
        let pid: Int32?
        let dataDir: String
        let dbPath: String
        let eventCount: Int64
        let lastEventTS: Double?
        let allowlist: [String]
        let opaqueApps: [String]
        /// Privacy fix round 1: `capture.retention_days` was reported by no command before this
        /// — `0` means unset/keep everything.
        let retentionDays: Int

        enum CodingKeys: String, CodingKey {
            case trusted, state, pid, allowlist
            case daemonRunning = "daemon_running"
            case dataDir = "data_dir"
            case dbPath = "db_path"
            case eventCount = "event_count"
            case lastEventTS = "last_event_ts"
            case opaqueApps = "opaque_apps"
            case retentionDays = "retention_days"
        }
    }

    func run() async throws {
        try await runJSON(json: json, human: Self.human) {
            let paths = Paths.resolve()
            let trusted = await MainActor.run { AXClient().isTrusted(prompt: false) }
            let config = try Config.load(from: paths.configURL)
            let livePID = PIDFile(url: paths.pidFileURL).livePID
            var count: Int64 = 0
            var last: Double?
            if FileManager.default.fileExists(atPath: paths.databaseURL.path) {
                let store = try EventStore(url: paths.databaseURL, readOnly: true)
                count = try await store.count()
                last = try await store.lastEventTS()
                await store.close()
            }
            return Status(
                trusted: trusted,
                state: trusted ? TrustState.active.rawValue : TrustState.needsPermission.rawValue,
                daemonRunning: livePID != nil, pid: livePID, dataDir: paths.dataDir.path,
                dbPath: paths.databaseURL.path, eventCount: count, lastEventTS: last,
                allowlist: config.allowlist, opaqueApps: [],
                retentionDays: config.capture.retentionDays)
        }
    }

    static func human(_ status: Status) -> String {
        let last =
            status.lastEventTS.map {
                ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0))
            } ?? "-"
        return """
            trusted:  \(status.trusted) (\(status.state))
            daemon:   \(status.daemonRunning ? "running (pid \(status.pid ?? 0))" : "not running")
            data dir: \(status.dataDir)
            events:   \(status.eventCount) (last \(last))
            allowed:  \(status.allowlist.isEmpty ? "(none)" : status.allowlist.joined(separator: ", "))
            retention: \(status.retentionDays > 0 ? "\(status.retentionDays) day(s)" : "off (keep forever)")
            """
    }
}
