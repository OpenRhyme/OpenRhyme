import Foundation
import Testing

@testable import Core

@Suite struct PIDFileTests {
    private func temp() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-\(UUID().uuidString).pid")
    }

    @Test func acquireWritesOwnPIDAndReleaseRemovesIt() throws {
        let file = PIDFile(url: temp())
        try file.acquire()
        #expect(file.read() == ProcessInfo.processInfo.processIdentifier)
        #expect(file.livePID == ProcessInfo.processInfo.processIdentifier)
        file.release()
        #expect(file.read() == nil)
    }

    @Test func staleFileIsOverwritten() throws {
        let file = PIDFile(url: temp())
        try "999999".write(to: file.url, atomically: true, encoding: .utf8)  // no such process
        #expect(file.livePID == nil)
        try file.acquire()
        #expect(file.read() == ProcessInfo.processInfo.processIdentifier)
        file.release()
    }

    @Test func liveFileRefusesAcquire() throws {
        let file = PIDFile(url: temp())
        try file.acquire()  // our own pid is alive
        #expect(throws: PIDFileError(runningPID: ProcessInfo.processInfo.processIdentifier)) {
            try file.acquire(pid: 12345)
        }
        file.release()
    }

    @Test func isAliveKnowsSelf() {
        #expect(PIDFile.isAlive(ProcessInfo.processInfo.processIdentifier))
        #expect(!PIDFile.isAlive(999_999))
    }
}
