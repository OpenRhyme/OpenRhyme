import AppKit
import Foundation
import Testing

@testable import Capture

/// Live AX test — spec §8. Needs the Accessibility grant on the terminal; never runs in CI.
/// Bring TextEdit or Finder to the front (both emit focus notifications on re-activation), then:
///   OPENRHYME_LIVE_AX=1 swift test --filter LiveObserverTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENRHYME_LIVE_AX"] == "1"))
@MainActor struct LiveObserverTests {
    final class Sink {
        var changes: [ObservedChange] = []
        var lifecycle: [LifecycleEvent] = []
        var onMainThread = true
    }

    @Test func realObserverCallbackFiresOnTheMainRunLoop() async throws {
        let client = AXClient()
        #expect(client.isTrusted(prompt: false), "grant Accessibility to the terminal first")
        let original = try #require(client.frontmostApplication())
        let sink = Sink()
        try client.startObserving(original) { change in
            sink.changes.append(change)
            sink.onMainThread = sink.onMainThread && pthread_main_np() != 0
        }
        client.startLifecycle { event in sink.lifecycle.append(event) }
        defer {
            client.stopObserving(pid: original.pid)
            client.stopLifecycle()
        }
        let finder = try #require(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
                .first)
        let started = Date()
        _ = finder.activate()
        try await Task.sleep(for: .milliseconds(700))
        _ = try #require(NSRunningApplication(processIdentifier: original.pid)).activate()
        try await Task.sleep(for: .milliseconds(1300))
        let activations = sink.lifecycle.filter {
            guard case .activated = $0 else { return false }
            return true
        }
        print(
            "LIVE observers: activations=\(activations.count) changes=\(sink.changes.map(\.kind)) in \(Date().timeIntervalSince(started))s"
        )
        #expect(activations.count >= 2, "NSWorkspace activation events did not arrive")
        #expect(!sink.changes.isEmpty, "no AXObserver callback arrived — run loop or registration")
        #expect(sink.onMainThread)
    }
}
