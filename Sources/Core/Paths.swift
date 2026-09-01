import Foundation

/// Where the engine keeps its files (spec §8). `OPENRHYME_DATA_DIR` overrides the default.
public struct Paths: Sendable, Equatable {
    public let dataDir: URL

    public init(dataDir: URL) {
        self.dataDir = dataDir
    }

    public var databaseURL: URL { dataDir.appendingPathComponent("events.sqlite") }
    public var configURL: URL { dataDir.appendingPathComponent("config.json") }
    public var pidFileURL: URL { dataDir.appendingPathComponent("daemon.pid") }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Paths {
        if let override = environment["OPENRHYME_DATA_DIR"], !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return Paths(dataDir: URL(fileURLWithPath: expanded, isDirectory: true))
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Paths(dataDir: support.appendingPathComponent("OpenRhyme", isDirectory: true))
    }

    public func ensureDataDir() throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }
}
