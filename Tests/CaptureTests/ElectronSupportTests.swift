import Foundation
import Testing

@testable import Capture

@Suite struct ElectronSupportTests {
    @Test func detectsElectronFrameworkInsideBundle() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fake-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
            withIntermediateDirectories: true)
        #expect(ElectronSupport.isElectronBundle(bundle))
    }

    @Test func nativeBundleIsNotElectron() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("Native-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        #expect(!ElectronSupport.isElectronBundle(bundle))
        #expect(!ElectronSupport.isElectronBundle(nil))
    }
}
