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

@Suite struct PathsPermissionTests {
    @Test func dataDirIsOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-perm-\(UUID().uuidString)", isDirectory: true)
        let paths = Paths(dataDir: dir)
        try paths.ensureDataDir()
        let mode =
            try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions]
            as? NSNumber
        #expect(mode?.int16Value == 0o700)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func anExistingLooseDirIsTightened() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-perm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o755))])
        let looseMode =
            try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions]
            as? NSNumber
        #expect(looseMode?.int16Value == 0o755)

        try Paths(dataDir: dir).ensureDataDir()
        let mode =
            try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions]
            as? NSNumber
        #expect(mode?.int16Value == 0o700)
        try? FileManager.default.removeItem(at: dir)
    }
}
