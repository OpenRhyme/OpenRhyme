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
        debounceMs: Int = 20, clock: Clock = Clock(),
        retryDelays: [Duration] = [.milliseconds(5), .milliseconds(5), .milliseconds(5)]
    ) throws -> Capturer {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-obs-\(UUID().uuidString)", isDirectory: true)
        let paths = Paths(dataDir: dir)
        try paths.ensureDataDir()
        var config = Config(allowlist: allow)
        config.capture.valueDebounceMs = debounceMs
        try config.save(to: paths.configURL)
        return Capturer(
            ax: fake, paths: paths, config: config, now: { clock.now }, retryDelays: retryDelays)
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

    @Test func focusChangeTriggersAnImmediateElementFocused() async throws {
        let fake = FakeAXClient()
        fake.show(
            safari, window: WindowInfo(title: "Apple"),
            element: ElementInfo(role: "AXTextField", value: "a"))
        let capturer = try makeCapturer(fake: fake)
        capturer.tick()  // heartbeat: app.activated + context.snapshot
        fake.show(
            safari, window: WindowInfo(title: "Apple"),
            element: ElementInfo(role: "AXTextArea", value: "b"))
        capturer.handle(change: ObservedChange(pid: 10, kind: .focusedElementChanged, ts: 1))
        let events = await drain(capturer)
        #expect(
            events.map(\.kind) == [
                .permissionChanged, .appActivated, .contextSnapshot, .elementFocused,
            ])
        #expect(events[3].extra?["reason"] == "observer")
        #expect(events[3].value == "b")
        #expect(fake.focusedContextCalls == 2)
    }

    @Test func windowAndTitleChangesMapToTheirKinds() async throws {
        let fake = FakeAXClient()
        fake.show(safari, window: WindowInfo(title: "One"))
        let capturer = try makeCapturer(fake: fake)
        capturer.tick()
        fake.show(safari, window: WindowInfo(title: "Two"))
        capturer.handle(change: ObservedChange(pid: 10, kind: .titleChanged, ts: 1))
        fake.show(safari, window: WindowInfo(title: "Three", url: "https://x"))
        capturer.handle(change: ObservedChange(pid: 10, kind: .focusedWindowChanged, ts: 2))
        let events = await drain(capturer)
        #expect(
            events.map(\.kind)
                == [
                    .permissionChanged, .appActivated, .contextSnapshot, .windowTitleChanged,
                    .windowFocused,
                ])
        #expect(events[3].extra?["previousTitle"] == "One")
        #expect(events[4].windowTitle == "Three")
    }

    @Test func observerThenHeartbeatDoesNotDuplicate() async throws {
        let fake = FakeAXClient()
        fake.show(safari, window: WindowInfo(title: "One"))
        let capturer = try makeCapturer(fake: fake)
        capturer.tick()
        fake.show(safari, window: WindowInfo(title: "Two"))
        capturer.handle(change: ObservedChange(pid: 10, kind: .titleChanged, ts: 1))
        capturer.tick()  // sees the signature the observer path already stored
        let events = await drain(capturer)
        #expect(
            events.map(\.kind) == [
                .permissionChanged, .appActivated, .contextSnapshot, .windowTitleChanged,
            ])
    }

    @Test func heartbeatThenLateObserverDoesNotDuplicate() async throws {
        let fake = FakeAXClient()
        fake.show(safari, window: WindowInfo(title: "One"))
        let capturer = try makeCapturer(fake: fake)
        capturer.tick()
        fake.show(safari, window: WindowInfo(title: "Two"))
        capturer.tick()  // the heartbeat wins the race
        capturer.handle(change: ObservedChange(pid: 10, kind: .titleChanged, ts: 1))  // late
        let events = await drain(capturer)
        #expect(
            events.map(\.kind) == [
                .permissionChanged, .appActivated, .contextSnapshot, .contextSnapshot,
            ])
    }

    @Test func backgroundAppChangesCostNothing() async throws {
        let fake = FakeAXClient()
        fake.show(safari, window: WindowInfo(title: "One"))
        let capturer = try makeCapturer(fake: fake)
        capturer.tick()
        let reads = fake.focusedContextCalls
        // TextEdit (pid 20) is in the background: no read, no event.
        capturer.handle(change: ObservedChange(pid: 20, kind: .titleChanged, ts: 1))
        #expect(fake.focusedContextCalls == reads)
        let events = await drain(capturer)
        #expect(events.map(\.kind) == [.permissionChanged, .appActivated, .contextSnapshot])
    }

    @Test func heartbeatStillCatchesAnUnnotifiedChange() async throws {
        let fake = FakeAXClient()
        fake.show(safari, window: WindowInfo(title: "One"))
        let capturer = try makeCapturer(fake: fake)
        capturer.tick()
        fake.show(safari, window: WindowInfo(title: "Two"))  // nobody notifies
        capturer.tick()
        let events = await drain(capturer)
        #expect(events.last?.kind == .contextSnapshot)
        #expect(events.last?.extra?["reason"] == "heartbeat")
    }

    @Test func launchedAllowlistedAppIsObservedAndLogged() async throws {
        let fake = FakeAXClient()
        let capturer = try makeCapturer(fake: fake)
        capturer.tick()  // trust becomes active
        capturer.handle(lifecycle: .launched(safari))
        capturer.handle(lifecycle: .launched(finder))  // not allowlisted
        #expect(fake.startObservingCalls == [10])
        #expect(capturer.observed == [10])
        let events = await drain(capturer)
        #expect(events.first { $0.kind == .appLaunched }?.pid == 10)
        #expect(events.filter { $0.kind == .appLaunched }.count == 1)
    }

    @Test func observerCreationRetriesWhileTheAppIsNotReady() async throws {
        let fake = FakeAXClient()
        fake.observeFailures[10] = 2
        let capturer = try makeCapturer(fake: fake)
        capturer.tick()
        capturer.handle(lifecycle: .launched(safari))
        #expect(capturer.observed.isEmpty)
        try await Task.sleep(for: .milliseconds(60))  // two 5 ms retries
        #expect(fake.startObservingCalls == [10, 10, 10])
        #expect(capturer.observed == [10])
        _ = await drain(capturer)
    }

    @Test func givesUpThenReconcileRetriesAfterAMinute() async throws {
        let fake = FakeAXClient()
        fake.observeFailures[10] = 10
        fake.running = [safari]
        let clock = Clock()
        let capturer = try makeCapturer(fake: fake, clock: clock)
        capturer.tick()  // reconcile → observe: 1 attempt + 3 retries, then give up
        try await Task.sleep(for: .milliseconds(60))
        #expect(fake.startObservingCalls.count == 4)
        #expect(capturer.observed.isEmpty)
        capturer.tick()  // within 60 s: not retried
        #expect(fake.startObservingCalls.count == 4)
        clock.now += 61
        fake.observeFailures[10] = 0
        capturer.tick()  // after 60 s: retried, succeeds
        #expect(capturer.observed == [10])
        _ = await drain(capturer)
    }

    @Test func terminationStopsObservingAndForgetsState() async throws {
        let fake = FakeAXClient()
        fake.show(safari, window: WindowInfo(title: "A"), element: ElementInfo(value: "x"))
        fake.running = [safari]
        let capturer = try makeCapturer(fake: fake)
        capturer.tick()  // observed via reconcile; content cache primed
        #expect(capturer.observed == [10])
        capturer.handle(lifecycle: .terminated(safari))
        #expect(fake.stopObservingCalls == [10])
        #expect(capturer.observed.isEmpty)
        capturer.tick()  // the cache was forgotten: this read passes no `reusing`
        #expect(fake.lastReusing == nil)
        let events = await drain(capturer)
        #expect(events.first { $0.kind == .appTerminated }?.bundleID == "com.apple.Safari")
    }

    @Test func activationEmitsAppEventsAndSnapshotInstantly() async throws {
        let fake = FakeAXClient()
        fake.show(safari, window: WindowInfo(title: "A"))
        let capturer = try makeCapturer(fake: fake)
        capturer.tick()
        fake.show(textEdit, window: WindowInfo(title: "Doc"), element: ElementInfo(value: "hi"))
        capturer.handle(lifecycle: .activated(textEdit))
        let events = await drain(capturer)
        #expect(
            Array(events.map(\.kind).suffix(3))
                == [.appDeactivated, .appActivated, .contextSnapshot])
        #expect(events.last?.extra?["reason"] == "observer")
        #expect(events.last?.value == "hi")
    }

    @Test func electronAppIsEnabledOncePerPidLifetime() async throws {
        let fake = FakeAXClient()
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-electron-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent(
                "Contents/Frameworks/Electron Framework.framework", isDirectory: true),
            withIntermediateDirectories: true)
        let code = AppInfo(
            pid: 40, bundleID: "com.microsoft.VSCode", name: "Code", bundleURL: bundle)
        let capturer = try makeCapturer(
            fake: fake, allow: ["com.microsoft.VSCode", "com.apple.Safari"])
        capturer.tick()
        capturer.handle(lifecycle: .launched(code))
        capturer.handle(lifecycle: .launched(code))  // already observed: no second write
        capturer.handle(lifecycle: .launched(safari))  // not Electron: never written to
        #expect(fake.electronCalls == [40])
        capturer.handle(lifecycle: .terminated(code))
        capturer.handle(lifecycle: .launched(code))  // a new lifetime of the pid: enabled again
        #expect(fake.electronCalls == [40, 40])
        let events = await drain(capturer)
        let enabled = events.filter { $0.kind == .appAXEnabled }
        #expect(enabled.count == 2)
        #expect(enabled[0].extra?["method"] == "AXManualAccessibility")
        #expect(enabled[0].extra?["result"] == "ok")
        #expect(enabled[0].bundleID == "com.microsoft.VSCode")
    }

    @Test func reconcileObservesRunningAllowlistedAppsAndDropsGoneOnes() async throws {
        let fake = FakeAXClient()
        fake.running = [safari, finder]  // finder is not allowlisted
        let capturer = try makeCapturer(fake: fake)
        capturer.tick()
        #expect(capturer.observed == [10])
        fake.running = [textEdit]
        capturer.tick()
        #expect(fake.stopObservingCalls == [10])
        #expect(capturer.observed == [20])
        _ = await drain(capturer)
    }

    @Test func trustLossStopsObserversAndRecoveryRecreatesThem() async throws {
        let fake = FakeAXClient()
        fake.show(safari, window: WindowInfo(title: "A"))
        fake.running = [safari]
        let clock = Clock()
        let capturer = try makeCapturer(fake: fake, clock: clock)
        capturer.tick()
        #expect(capturer.observed == [10])
        fake.errors[10] = .apiDisabled
        capturer.tick()
        #expect(capturer.trust == .stale)
        #expect(fake.stopObservingCalls == [10])
        #expect(capturer.observed.isEmpty)
        fake.errors[10] = nil
        clock.now += 6  // past the 5 s stale backoff
        capturer.tick()
        #expect(capturer.trust == .active)
        #expect(capturer.observed == [10])
        _ = await drain(capturer)
    }

    @Test func sleepAndWakeAreRecordedAndStopTearsEverythingDown() async throws {
        let fake = FakeAXClient()
        fake.running = [safari]
        let capturer = try makeCapturer(fake: fake)
        capturer.start()  // registers the lifecycle handler
        capturer.tick()
        fake.deliverLifecycle(.sleep)
        fake.deliverLifecycle(.wake)
        let events = await drain(capturer)  // stop(): observers and lifecycle torn down
        #expect(events.map(\.kind).contains(.systemSleep))
        #expect(events.map(\.kind).contains(.systemWake))
        #expect(fake.stopObservingCalls.contains(10))
        #expect(fake.lifecycleHandler == nil)
    }
}
