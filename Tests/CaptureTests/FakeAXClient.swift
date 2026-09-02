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
