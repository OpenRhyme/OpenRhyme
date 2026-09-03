import Foundation
import Testing

@testable import Capture
@testable import Core

/// Capturer-level observer behaviour, driven through `FakeAXClient.deliver…` — no TCC grant.
@Suite @MainActor struct ObserverTests {
    let safari = FakeAXClient.app(10, "com.apple.Safari")
    let textEdit = FakeAXClient.app(20, "com.apple.TextEdit")
    let finder = FakeAXClient.app(30, "com.apple.finder")

    final class Clock: @unchecked Sendable {
        var now: Double = 1000
    }

    func makeCapturer(
        fake: FakeAXClient, allow: [String] = ["com.apple.Safari", "com.apple.TextEdit"],
        debounceMs: Int = 20, clock: Clock = Clock()
    ) throws -> Capturer {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-obs-\(UUID().uuidString)", isDirectory: true)
        let paths = Paths(dataDir: dir)
        try paths.ensureDataDir()
        var config = Config(allowlist: allow)
        config.capture.valueDebounceMs = debounceMs
        try config.save(to: paths.configURL)
        return Capturer(ax: fake, paths: paths, config: config, now: { clock.now })
    }

    func drain(_ capturer: Capturer) async -> [RawEvent] {
        capturer.stop()
        var out: [RawEvent] = []
        for await event in capturer.events { out.append(event) }
        return out
    }

    @Test func fakeDeliversObservedChangesToTheRegisteredHandler() throws {
        let fake = FakeAXClient()
        var received: [ObservedChange] = []
        try fake.startObserving(safari) { received.append($0) }
        fake.deliver(ObservedChange(pid: 10, kind: .titleChanged, ts: 1))
        fake.deliver(ObservedChange(pid: 99, kind: .titleChanged, ts: 2))  // nobody observes 99
        #expect(received.map(\.pid) == [10])
        fake.stopObserving(pid: 10)
        fake.deliver(ObservedChange(pid: 10, kind: .titleChanged, ts: 3))
        #expect(received.count == 1)
        #expect(fake.startObservingCalls == [10])
        #expect(fake.stopObservingCalls == [10])
    }

    @Test func fakeScriptsObserveFailuresLifecycleAndElectron() throws {
        let fake = FakeAXClient()
        fake.observeFailures[10] = 1
        #expect(throws: AXReadError.self) { try fake.startObserving(safari) { _ in } }
        try fake.startObserving(safari) { _ in }  // the second attempt succeeds
        #expect(fake.startObservingCalls == [10, 10])

        var events: [LifecycleEvent] = []
        fake.startLifecycle { events.append($0) }
        fake.deliverLifecycle(.sleep)
        #expect(events == [.sleep])
        fake.stopLifecycle()
        fake.deliverLifecycle(.wake)
        #expect(events == [.sleep])

        #expect(fake.enableElectronAccessibility(safari).result == "ok")
        #expect(fake.electronCalls == [10])
    }
}
