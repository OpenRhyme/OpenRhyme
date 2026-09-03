import Foundation

@testable import Capture

/// Scripted stand-in for the Accessibility API. Tests set its state between ticks.
@MainActor
final class FakeAXClient: AXReading {
    var trusted = true
    var running: [AppInfo] = []
    var frontmost: AppInfo?
    var contexts: [Int32: FocusedContext] = [:]
    var errors: [Int32: AXReadError] = [:]
    var idleSeconds: Double = 0

    private(set) var promptCount = 0
    private(set) var focusedContextCalls = 0
    private(set) var timeout: Float?
    private(set) var lastReusing: ContentCache?

    private(set) var observing: [Int32: @MainActor (ObservedChange) -> Void] = [:]
    private(set) var startObservingCalls: [Int32] = []
    private(set) var stopObservingCalls: [Int32] = []
    /// Fail the next N `startObserving` calls for a pid with `.cannotComplete`.
    var observeFailures: [Int32: Int] = [:]
    private(set) var lifecycleHandler: (@MainActor (LifecycleEvent) -> Void)?
    private(set) var electronCalls: [Int32] = []
    var electronResult = ElectronEnableResult(method: "AXManualAccessibility", result: "ok")

    func isTrusted(prompt: Bool) -> Bool {
        if prompt { promptCount += 1 }
        return trusted
    }

    func setGlobalMessagingTimeout(_ seconds: Float) {
        timeout = seconds
    }

    func runningApplications() -> [AppInfo] { running }

    func frontmostApplication() -> AppInfo? { frontmost }

    func focusedContext(of app: AppInfo, reusing cache: ContentCache?) throws -> FocusedContext {
        focusedContextCalls += 1
        lastReusing = cache
        if let error = errors[app.pid] { throw error }
        return contexts[app.pid] ?? FocusedContext(app: app, window: nil, element: nil)
    }

    func secondsSinceLastInput() -> Double { idleSeconds }

    func cache(from context: FocusedContext) -> ContentCache {
        ContentCache(
            role: context.element?.role, subrole: context.element?.subrole,
            identifier: context.element?.identifier, title: context.element?.title,
            windowTitle: context.window?.title, document: context.window?.document,
            url: context.window?.url, value: context.element?.value,
            textSource: context.element?.textSource)
    }

    func startObserving(
        _ app: AppInfo, handler: @escaping @MainActor (ObservedChange) -> Void
    ) throws {
        startObservingCalls.append(app.pid)
        if let remaining = observeFailures[app.pid], remaining > 0 {
            observeFailures[app.pid] = remaining - 1
            throw AXReadError.cannotComplete
        }
        observing[app.pid] = handler
    }

    func stopObserving(pid: Int32) {
        stopObservingCalls.append(pid)
        observing[pid] = nil
    }

    func stopObservingAll() {
        for pid in Array(observing.keys) { stopObserving(pid: pid) }
    }

    func startLifecycle(handler: @escaping @MainActor (LifecycleEvent) -> Void) {
        lifecycleHandler = handler
    }

    func stopLifecycle() { lifecycleHandler = nil }

    func enableElectronAccessibility(_ app: AppInfo) -> ElectronEnableResult {
        electronCalls.append(app.pid)
        return electronResult
    }

    /// Simulate an AXObserver notification for an observed pid.
    func deliver(_ change: ObservedChange) { observing[change.pid]?(change) }

    /// Simulate an NSWorkspace lifecycle notification.
    func deliverLifecycle(_ event: LifecycleEvent) { lifecycleHandler?(event) }

    // Convenience builders used by several test files.
    static func app(_ pid: Int32, _ bundleID: String, name: String? = nil) -> AppInfo {
        AppInfo(
            pid: pid, bundleID: bundleID,
            name: name ?? bundleID.split(separator: ".").last.map(String.init), bundleURL: nil)
    }

    func show(_ app: AppInfo, window: WindowInfo? = nil, element: ElementInfo? = nil) {
        frontmost = app
        contexts[app.pid] = FocusedContext(app: app, window: window, element: element)
    }
}
