import ApplicationServices
import Core
import Foundation
import os

/// Spec §5.1. One `AXObserver` per observed pid, its source on the main run loop (spec §4.1).
/// A callback reads nothing except a menu item's title: it maps the notification to an
/// `ObservedChange` and hands it to the handler. `AXUIElement` / `AXObserver` never leave here.
/// The owner must call `stopAll()` before dropping the hub — the C callback holds it unretained.
@MainActor
final class AXObserverHub {
    typealias Handler = @MainActor (ObservedChange) -> Void

    private struct Entry {
        let observer: AXObserver
        let application: AXUIElement
        var focused: AXUIElement?
        let handler: Handler
        var loggedUnsupported: Set<String> = []
    }

    /// Registered on the application element. App activation is deliberately absent —
    /// `AppLifecycle` (NSWorkspace) is the single source for it, so it cannot double-fire.
    static let applicationNotifications: [String] = [
        kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
        kAXFocusedUIElementChangedNotification, kAXTitleChangedNotification,
        kAXMenuItemSelectedNotification,
    ]

    private var entries: [Int32: Entry] = [:]
    private let logger = Logger(subsystem: "org.openrhyme.engine", category: "observer")
    private let now: @Sendable () -> Double

    init(now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.now = now
    }

    var observedPids: Set<Int32> { Set(entries.keys) }

    func start(pid: Int32, handler: @escaping Handler) throws {
        guard entries[pid] == nil else { return }
        var created: AXObserver?
        try check(AXObserverCreate(pid, observerCallback, &created))
        guard let observer = created else { throw AXReadError.cannotComplete }
        let application = AXUIElementCreateApplication(pid)
        var entry = Entry(
            observer: observer, application: application, focused: nil, handler: handler)
        for name in Self.applicationNotifications {
            try add(name, on: application, entry: &entry, pid: pid)
        }
        if let focused = focusedElement(of: application) {
            try add(kAXValueChangedNotification, on: focused, entry: &entry, pid: pid)
            entry.focused = focused
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        entries[pid] = entry
    }

    func stop(pid: Int32) {
        guard let entry = entries.removeValue(forKey: pid) else { return }
        if let focused = entry.focused {
            AXObserverRemoveNotification(
                entry.observer, focused, kAXValueChangedNotification as CFString)
        }
        for name in Self.applicationNotifications {
            AXObserverRemoveNotification(entry.observer, entry.application, name as CFString)
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(entry.observer), .defaultMode)
    }

    func stopAll() {
        for pid in Array(entries.keys) { stop(pid: pid) }
    }

    /// Entered from `observerCallback`, on the main thread (spec §4.1). Minimal work only.
    fileprivate func handle(element: AXUIElement, notification: String) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, var entry = entries[pid] else {
            return
        }
        let kind: ObservedKind
        var menuTitle: String?
        switch notification {
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            kind = .focusedWindowChanged
        case kAXFocusedUIElementChangedNotification:
            kind = .focusedElementChanged
            moveValueRegistration(to: element, entry: &entry, pid: pid)
            entries[pid] = entry
        case kAXTitleChangedNotification:
            kind = .titleChanged
        case kAXValueChangedNotification:
            kind = .valueChanged
        case kAXMenuItemSelectedNotification:
            kind = .menuItemSelected
            menuTitle = title(of: element)
        default:
            return
        }
        entry.handler(ObservedChange(pid: pid, kind: kind, menuTitle: menuTitle, ts: now()))
    }

    // MARK: - Registration

    /// Unsupported → logged once per (pid, name) and skipped; already registered → success;
    /// not-ready / disabled → thrown so the caller can retry (spec §6.2).
    private func add(
        _ name: String, on element: AXUIElement, entry: inout Entry, pid: Int32
    )
        throws
    {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let error = AXObserverAddNotification(entry.observer, element, name as CFString, refcon)
        switch error {
        case .success, .notificationAlreadyRegistered:
            return
        case .notificationUnsupported:
            if entry.loggedUnsupported.insert(name).inserted {
                logger.info("pid \(pid) does not emit \(name); skipped")
            }
        default:
            try check(error)
        }
    }

    /// Spec §5.1: value changes are element-level, so follow the focus.
    private func moveValueRegistration(to element: AXUIElement, entry: inout Entry, pid: Int32) {
        if let old = entry.focused {
            AXObserverRemoveNotification(
                entry.observer, old, kAXValueChangedNotification as CFString)
        }
        entry.focused = nil
        try? add(kAXValueChangedNotification, on: element, entry: &entry, pid: pid)
        entry.focused = element
    }

    private func focusedElement(of application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func title(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
                == .success,
            let value, CFGetTypeID(value) == CFStringGetTypeID()
        else { return nil }
        return (value as! CFString) as String
    }

    /// Observer-specific mapping; `AXClient.check` does not know the notification codes.
    private func check(_ error: AXError) throws {
        switch error {
        case .success: return
        case .apiDisabled: throw AXReadError.apiDisabled
        case .cannotComplete: throw AXReadError.cannotComplete
        case .notImplemented: throw AXReadError.notImplemented
        case .invalidUIElement, .invalidUIElementObserver: throw AXReadError.invalidElement
        default: throw AXReadError.other(error.rawValue)
        }
    }
}

/// The C callback (`docs/accessibility-api.md` §5.1): it cannot capture, so the hub travels in
/// `refcon`. It runs on the main thread because the source lives on the main run loop (§4.1),
/// which is what makes `assumeIsolated` valid here.
private func observerCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let hub = Unmanaged<AXObserverHub>.fromOpaque(refcon).takeUnretainedValue()
    nonisolated(unsafe) let element = element
    nonisolated(unsafe) let notification = notification
    MainActor.assumeIsolated {
        hub.handle(element: element, notification: notification as String)
    }
}
