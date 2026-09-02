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

    /// A read that keeps throwing `.apiDisabled` while `isTrusted()` still reports true (the
    /// documented macOS revoke-without-relaunch flap) must not reset the back-off ladder just
    /// because the gate reopened — only a successful read may reset it. Schedule, computed from
    /// the ladder (5, 10, 20, 40 s, capped at 60 s) starting when the tick at `t` first enters
    /// `.stale`: gate 1 opens at `t+5` (checked at `t+6`), gate 2 at `t+16` (10 s later, checked
    /// at `t+17`; `t+11` is still inside it), gate 3 at `t+37` (20 s later, checked at `t+38`;
    /// `t+30` is still inside it), gate 4 at `t+78` (40 s later, checked at `t+79` with the read
    /// now succeeding). A successful read resets the ladder to 5 s, so re-entering `.stale`
    /// right after opens a new gate at `+5 s`, confirmed by a flip at `+6 s`.
    @Test func apiDisabledFlapEscalatesBackoff() async throws {
        let fake = FakeAXClient()
        let clock = Clock()
        fake.show(safari)
        let (capturer, _) = try makeCapturer(fake: fake, clock: clock)

        capturer.tick()  // active
        fake.errors[safari.pid] = .apiDisabled
        capturer.tick()  // stale: gate 1 opens at t+5, backoff -> 10
        #expect(capturer.trust == .stale)
        let t = clock.now

        // past gate 1: flips active, fails again -> stale, gate 2 opens at t+16, backoff -> 20
        clock.now = t + 6
        capturer.tick()
        #expect(capturer.trust == .stale)

        let callsBeforeGate2 = fake.focusedContextCalls
        clock.now = t + 11  // inside gate 2: no read attempted
        capturer.tick()
        #expect(capturer.trust == .stale)
        #expect(fake.focusedContextCalls == callsBeforeGate2)

        // past gate 2: flips active, fails again -> stale, gate 3 opens at t+37, backoff -> 40
        clock.now = t + 17
        capturer.tick()
        #expect(capturer.trust == .stale)

        let callsBeforeGate3 = fake.focusedContextCalls
        clock.now = t + 30  // inside gate 3: no read attempted
        capturer.tick()
        #expect(capturer.trust == .stale)
        #expect(fake.focusedContextCalls == callsBeforeGate3)

        // past gate 3: flips active, fails again -> stale, gate 4 opens at t+78, backoff -> 60
        clock.now = t + 38
        capturer.tick()
        #expect(capturer.trust == .stale)

        fake.errors = [:]
        let callsBeforeRecovery = fake.focusedContextCalls
        clock.now = t + 79  // past gate 4: this time the read succeeds, so backoff resets to 5
        capturer.tick()
        #expect(capturer.trust == .active)
        #expect(fake.focusedContextCalls == callsBeforeRecovery + 1)

        fake.errors[safari.pid] = .apiDisabled
        capturer.tick()  // active -> stale is never gated; the new gate opens at (t+79)+5
        #expect(capturer.trust == .stale)

        clock.now = t + 85  // (t+79)+6: past the reset 5 s gate, not the escalated 60 s it would
        // have been without the fix
        capturer.tick()
        #expect(capturer.trust == .stale)

        let events = await drain(capturer)
        let permission = events.filter { $0.kind == .permissionChanged }
        #expect(
            permission.map { $0.extra?["state"] } == [
                "active", "stale",  // enter stale at t
                "active", "stale",  // gate 1 (5 s) at t+6
                "active", "stale",  // gate 2 (10 s) at t+17
                "active", "stale",  // gate 3 (20 s) at t+38
                "active",  // gate 4 (40 s) at t+79: successful read, ladder resets
                "stale",  // immediate re-entry after the reset
                "active", "stale",  // gate reopens at +5 s, confirmed by the flip at +6 s
            ])
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

    @Test func heartbeatThreadsTheContentCacheBackToTheReader() async throws {
        let fake = FakeAXClient()
        fake.show(
            safari, window: WindowInfo(title: "Apple"),
            element: ElementInfo(role: "AXWebArea", value: "page text"))
        let (capturer, _) = try makeCapturer(fake: fake)
        capturer.tick()  // first read: reusing is nil
        #expect(fake.lastReusing == nil)
        capturer.tick()  // second read: the capturer should pass back the cache it built
        #expect(fake.lastReusing != nil)
        #expect(fake.lastReusing?.value == "page text")
        _ = await drain(capturer)
    }
}
