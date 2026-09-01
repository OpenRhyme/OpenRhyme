import Foundation
import Testing

@testable import Core

@Suite struct PathsTests {
    @Test func environmentOverrideWins() {
        let paths = Paths.resolve(environment: ["OPENRHYME_DATA_DIR": "/tmp/orh-test"])
        #expect(paths.dataDir.path == "/tmp/orh-test")
        #expect(paths.databaseURL.lastPathComponent == "events.sqlite")
        #expect(paths.configURL.lastPathComponent == "config.json")
        #expect(paths.pidFileURL.lastPathComponent == "daemon.pid")
    }

    @Test func expandsTilde() {
        let paths = Paths.resolve(environment: ["OPENRHYME_DATA_DIR": "~/orh"])
        #expect(!paths.dataDir.path.hasPrefix("~"))
        #expect(paths.dataDir.path.hasSuffix("/orh"))
    }

    @Test func defaultIsApplicationSupport() {
        let paths = Paths.resolve(environment: [:])
        #expect(paths.dataDir.path.hasSuffix("/Library/Application Support/OpenRhyme"))
    }

    @Test func ensureDataDirCreatesDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-\(UUID().uuidString)", isDirectory: true)
        let paths = Paths(dataDir: dir)
        try paths.ensureDataDir()
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        try? FileManager.default.removeItem(at: dir)
    }
}
