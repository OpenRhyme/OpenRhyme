import Foundation
import Testing

@testable import Capture
@testable import Core

@Suite @MainActor struct CapturerTests {
    let safari = FakeAXClient.app(10, "com.apple.Safari")
    let finder = FakeAXClient.app(30, "com.apple.finder")

    private func makeCapturer(
        fake: FakeAXClient, allow: [String] = ["com.apple.Safari"], clock: Clock = Clock()
    ) throws -> (Capturer, Paths) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-cap-\(UUID().uuidString)", isDirectory: true)
        let paths = Paths(dataDir: dir)
        try paths.ensureDataDir()
        let config = Config(allowlist: allow)
        try config.save(to: paths.configURL)
        let capturer = Capturer(ax: fake, paths: paths, config: config, now: { clock.now })
        return (capturer, paths)
    }

    final class Clock: @unchecked Sendable {
        var now: Double = 1000
    }

    private func drain(_ capturer: Capturer) async -> [RawEvent] {
        capturer.stop()
        var out: [RawEvent] = []
        for await event in capturer.events { out.append(event) }
        return out
    }

    @Test func untrustedProducesNoReadsUntilGranted() async throws {
        let fake = FakeAXClient()
        fake.trusted = false
        fake.show(safari, window: WindowInfo(title: "Apple"))
        let (capturer, _) = try makeCapturer(fake: fake)

        capturer.tick()
        #expect(capturer.trust == .needsPermission)
        #expect(fake.focusedContextCalls == 0)

        fake.trusted = true
        capturer.tick()
        #expect(capturer.trust == .active)
        #expect(fake.focusedContextCalls == 1)

        let events = await drain(capturer)
        #expect(events.map(\.kind) == [.permissionChanged, .appActivated, .contextSnapshot])
        #expect(events[0].extra?["trusted"] == true)
        #expect(events[0].extra?["state"] == "active")
    }

    @Test func steadyStateEmitsNothing() async throws {
        let fake = FakeAXClient()
        fake.show(safari, window: WindowInfo(title: "Apple"))
        let (capturer, _) = try makeCapturer(fake: fake)
        capturer.tick()
        capturer.tick()
        capturer.tick()
        let events = await drain(capturer)
        #expect(events.map(\.kind) == [.permissionChanged, .appActivated, .contextSnapshot])
    }

    @Test func apiDisabledGoesStaleAndBacksOff() async throws {
        let fake = FakeAXClient()
        let clock = Clock()
        fake.show(safari)
        let (capturer, _) = try makeCapturer(fake: fake, clock: clock)
        capturer.tick()  // active
        fake.errors[safari.pid] = .apiDisabled
        capturer.tick()
        #expect(capturer.trust == .stale)
        let callsAfterStale = fake.focusedContextCalls

        clock.now += 1  // within back-off: no read attempted
        capturer.tick()
        #expect(fake.focusedContextCalls == callsAfterStale)

        fake.errors = [:]
        clock.now += 10  // past the first 5 s back-off
        capturer.tick()
        #expect(capturer.trust == .active)

        let events = await drain(capturer)
        let permission = events.filter { $0.kind == .permissionChanged }
        #expect(permission.map { $0.extra?["state"] } == ["active", "stale", "active"])
    }

    @Test func idleStartsAndEndsWithThreshold() async throws {
        let fake = FakeAXClient()
        let clock = Clock()
        fake.show(safari)
        let (capturer, _) = try makeCapturer(fake: fake, clock: clock)
        capturer.tick()
        fake.idleSeconds = 130
        capturer.tick()
        #expect(capturer.state.idle)
        clock.now += 60
        fake.idleSeconds = 2
        capturer.tick()
        #expect(!capturer.state.idle)

        let events = await drain(capturer)
        let idle = events.filter { $0.kind == .idleStarted || $0.kind == .idleEnded }
        #expect(idle.map(\.kind) == [.idleStarted, .idleEnded])
        #expect(idle[0].extra?["idleSeconds"] == 130)
        #expect(idle[1].extra?["idleSeconds"] == 190)  // 130 + 60 since idle began
    }

    @Test func configReloadPicksUpNewAllowlist() async throws {
        let fake = FakeAXClient()
        fake.show(finder, window: WindowInfo(title: "Desktop"))
        let (capturer, paths) = try makeCapturer(fake: fake, allow: ["com.apple.Safari"])
        capturer.tick()
        #expect(fake.focusedContextCalls == 0)

        try Config(allowlist: ["com.apple.finder"]).save(to: paths.configURL)
        // Ensure the mtime moves even on coarse filesystems.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: paths.configURL.path)
        capturer.tick()
        #expect(capturer.config.allowlist == ["com.apple.finder"])
        #expect(fake.focusedContextCalls == 1)

        let events = await drain(capturer)
        #expect(
            events.contains { $0.kind == .contextSnapshot && $0.bundleID == "com.apple.finder" })
    }

    @Test func readFailuresAreCountedButDoNotStopCapture() async throws {
        let fake = FakeAXClient()
        fake.show(safari)
        fake.errors[safari.pid] = .cannotComplete
        let (capturer, _) = try makeCapturer(fake: fake)
        capturer.tick()
        capturer.tick()
        #expect(capturer.trust == .active)
        #expect(capturer.readFailures[safari.pid] == 2)
        fake.errors = [:]
        capturer.tick()
        #expect(capturer.readFailures[safari.pid] == nil)
        let events = await drain(capturer)
        #expect(events.map(\.kind) == [.permissionChanged, .appActivated, .contextSnapshot])
    }
}
