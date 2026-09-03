# Observers — Event-Driven Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make capture event-driven — `AXObserver` notifications and `NSWorkspace` lifecycle events trigger the existing read-and-diff pipeline the instant something changes (instant app/window/element/title transitions, debounced real-time typing, menu selections, sleep/wake) — while the 5 s heartbeat stays as the safety net and both paths dedup through one `LastKnownState`.

**Architecture:** Notifications are doorbells, not data. `AXObserverHub` (per-pid `AXObserver`, sources on the main run loop) and `AppLifecycle` (`NSWorkspace`) turn callbacks into small `Sendable` values; `Capturer.handle(change:)` / `handle(lifecycle:)` run the shared `refresh(trigger:freshRead:)` — the heartbeat body factored out — and `HeartbeatDiff.compute` maps the trigger onto the emitted kind. Value changes are debounced per pid and bypass the content cache. Everything is `@MainActor`; `AXUIElement`/`AXObserver` never leave `Capture`.

**Tech Stack:** Swift 6 (tools 6.0), macOS 14+, ApplicationServices (AXObserver C API), AppKit (`NSWorkspace`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-02-observers-design.md` — read it; this plan implements §4–§9. API facts: `docs/accessibility-api.md` §5.1 and §7.

## Global Constraints

- Swift 6 language mode, macOS 14+. No new dependencies. No network code. Never read an `AXSecureTextField`'s value (inherited: every observer-path read goes through the existing ladder + `Redaction`).
- **No storage-schema change (stays v1), no `--json` output change, no change to the MCP repo.** Every emitted kind already exists in `Core.EventKind`.
- `AXUIElement`, `AXObserver`, `kAX…` constants and `NSWorkspace` stay inside `Sources/Capture`. Everything crossing an isolation boundary is a `Sendable` struct/enum. All AX work on the main actor; observer sources attach to `CFRunLoopGetMain()` (spec §4.1: verified pumped under async main — no daemon change).
- The only write into another process is the Electron enable (`AXManualAccessibility`, fallback `AXEnhancedUserInterface`), once per pid, only for allowlisted Electron bundles, logged, emitted as `app.ax_enabled`.
- Config keys reused, no new keys: `capture.value_debounce_ms` (500), `capture.heartbeat_seconds` (5), `capture.record_other_apps`. Constants (not config): observer retry delays 1 s, 3 s, 10 s; reconcile retry of a given-up pid at most once per 60 s.
- `make format` before every commit; CI runs `swift format lint --strict`. Line length 100, 4-space indent.
- Swift Testing only. Tests never need a TCC grant; anything live is gated behind `OPENRHYME_LIVE_AX=1` and never runs in CI.
- Commit messages: short single line, then exactly these two trailer lines:
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01BdcwpxNhK3QnZByv2nHgnN`.

---

## File structure

| Path | Responsibility |
|---|---|
| `Sources/Capture/AXTypes.swift` | + `ObservedKind`, `ObservedChange`, `LifecycleEvent`, `ElectronEnableResult` (Task 1); + six `AXReading` requirements (Task 3). |
| `Sources/Capture/HeartbeatDiff.swift` | + `Trigger`; `Input.trigger`; kind/`reason` mapping; `previousTitle` (Task 1). |
| `Sources/Capture/AXObserverHub.swift` | **New.** Per-pid `AXObserver`, C callback, value re-registration, menu title read (Task 2). |
| `Sources/Capture/AppLifecycle.swift` | **New.** `NSWorkspace` subscriptions → `LifecycleEvent` (Task 2). |
| `Sources/Capture/ElectronSupport.swift` | + the two enable attribute names (Task 3). |
| `Sources/Capture/AXClient.swift` | Owns a hub + lifecycle, forwards the protocol; `enableElectronAccessibility` (Task 3). |
| `Sources/Capture/Capturer.swift` | `refresh(trigger:freshRead:)`, `handle(change:)` (Task 4); lifecycle, observe/unobserve, Electron, retries, reconcile, trust/stop hooks (Task 5); value debounce + menu (Task 6). |
| `Tests/CaptureTests/FakeAXClient.swift` | Records/scripts the six new requirements; `deliver`, `deliverLifecycle` (Task 3). |
| `Tests/CaptureTests/HeartbeatDiffTests.swift` | Trigger mapping tests (Task 1). |
| `Tests/CaptureTests/ObserverTests.swift` | **New.** Capturer-level observer behaviour (Tasks 3–6). |
| `Tests/CaptureTests/LiveObserverTests.swift` | **New, gated.** Real `AXObserver` callback + activation latency (Task 7). |
| `docs/accessibility-api.md`, `CLAUDE.md`, `README.md` | As-shipped notes (Task 7). |

---

### Task 1: Sendable types + `HeartbeatDiff.Trigger` kind mapping (pure)

**Files:**
- Modify: `Sources/Capture/AXTypes.swift` (append after `ContentCache`)
- Modify: `Sources/Capture/HeartbeatDiff.swift`
- Test: `Tests/CaptureTests/HeartbeatDiffTests.swift`

**Interfaces:**
- Produces: `public enum ObservedKind: String, Sendable { focusedWindowChanged, focusedElementChanged, titleChanged, valueChanged, menuItemSelected }`; `public struct ObservedChange: Sendable, Equatable { pid: Int32; kind: ObservedKind; menuTitle: String?; ts: Double }`; `public enum LifecycleEvent: Sendable, Equatable { launched(AppInfo), terminated(AppInfo), activated(AppInfo), sleep, wake }` (note: `terminated` carries the `AppInfo` — the `NSWorkspace` notification still has bundle id/name after exit, so `app.terminated` can carry them; a deliberate refinement of spec §5.3's `terminated(pid:)`); `public struct ElectronEnableResult: Sendable, Equatable { method: String; result: String }`; `HeartbeatDiff.Trigger { case heartbeat, activation, observer(ObservedKind) }` with `var kind: EventKind` and `var reason: String`; `HeartbeatDiff.Input.trigger: Trigger` (init parameter, **last**, default `.heartbeat`).

- [ ] **Step 1: Write the failing tests**

In `Tests/CaptureTests/HeartbeatDiffTests.swift`, change the private `input(...)` helper to accept a trigger (add the last parameter and pass it through):
```swift
    private func input(
        _ app: AppInfo?, window: WindowInfo? = nil, element: ElementInfo? = nil,
        others: Bool = false, maxBytes: Int = 1000, now: Double = 100,
        trigger: HeartbeatDiff.Trigger = .heartbeat
    ) -> HeartbeatDiff.Input {
        HeartbeatDiff.Input(
            frontmost: app,
            context: app.map { FocusedContext(app: $0, window: window, element: element) },
            allowlist: allow, recordOtherApps: others, maxValueBytes: maxBytes, now: now,
            trigger: trigger)
    }
```
Add these tests to the suite:
```swift
    @Test func heartbeatTriggerIsUnchanged() {
        let out = HeartbeatDiff.compute(
            previous: LastKnownState(), input: input(safari, window: WindowInfo(title: "A")))
        #expect(out.events.last?.kind == .contextSnapshot)
        #expect(out.events.last?.extra?["reason"] == "heartbeat")
    }

    @Test func observerTriggersMapToTheirKindsWithObserverReason() {
        let cases: [(HeartbeatDiff.Trigger, EventKind)] = [
            (.activation, .contextSnapshot),
            (.observer(.focusedElementChanged), .elementFocused),
            (.observer(.focusedWindowChanged), .windowFocused),
            (.observer(.titleChanged), .windowTitleChanged),
            (.observer(.valueChanged), .elementValueChanged),
        ]
        for (trigger, kind) in cases {
            let out = HeartbeatDiff.compute(
                previous: LastKnownState(),
                input: input(
                    safari, window: WindowInfo(title: "A"), element: ElementInfo(value: "x"),
                    trigger: trigger))
            #expect(out.events.last?.kind == kind, "\(trigger)")
            #expect(out.events.last?.extra?["reason"] == "observer", "\(trigger)")
            #expect(out.events.last?.value == "x", "\(trigger)")
        }
    }

    @Test func titleChangedCarriesPreviousTitle() {
        let first = HeartbeatDiff.compute(
            previous: LastKnownState(), input: input(safari, window: WindowInfo(title: "Old")))
        let second = HeartbeatDiff.compute(
            previous: first.state,
            input: input(
                safari, window: WindowInfo(title: "New"), trigger: .observer(.titleChanged)))
        #expect(second.events.map(\.kind) == [.windowTitleChanged])
        #expect(second.events[0].extra?["previousTitle"] == "Old")
        #expect(second.events[0].windowTitle == "New")
    }

    @Test func observerTriggerWithUnchangedSignatureEmitsNothing() {
        let first = HeartbeatDiff.compute(
            previous: LastKnownState(), input: input(safari, window: WindowInfo(title: "A")))
        let second = HeartbeatDiff.compute(
            previous: first.state,
            input: input(
                safari, window: WindowInfo(title: "A"), trigger: .observer(.focusedElementChanged)))
        #expect(second.events.isEmpty)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter HeartbeatDiffTests`
Expected: build error — `HeartbeatDiff.Trigger` / `trigger:` not found.

- [ ] **Step 3: Implement the types and the mapping**

Append to `Sources/Capture/AXTypes.swift`:
```swift
/// Spec §5.3. What an `AXObserver` notification meant — AX-free, so the Capturer and tests never
/// see an `AXUIElement`.
public enum ObservedKind: String, Sendable {
    case focusedWindowChanged  // kAXFocusedWindowChanged and kAXMainWindowChanged
    case focusedElementChanged  // kAXFocusedUIElementChanged
    case titleChanged  // kAXTitleChanged
    case valueChanged  // kAXValueChanged, registered on the focused element
    case menuItemSelected  // kAXMenuItemSelected
}

public struct ObservedChange: Sendable, Equatable {
    public var pid: Int32
    public var kind: ObservedKind
    /// `menuItemSelected` only: the item's title, read once in the callback.
    public var menuTitle: String?
    public var ts: Double

    public init(pid: Int32, kind: ObservedKind, menuTitle: String? = nil, ts: Double) {
        self.pid = pid
        self.kind = kind
        self.menuTitle = menuTitle
        self.ts = ts
    }
}

/// Spec §5.2. `NSWorkspace` app lifecycle and power events.
public enum LifecycleEvent: Sendable, Equatable {
    case launched(AppInfo)
    case terminated(AppInfo)
    case activated(AppInfo)
    case sleep
    case wake
}

/// Spec §5.7. Outcome of the one write the daemon performs into another process.
public struct ElectronEnableResult: Sendable, Equatable {
    public var method: String  // "AXManualAccessibility" | "AXEnhancedUserInterface"
    public var result: String  // "ok" | "unsupported" | "failed"

    public init(method: String, result: String) {
        self.method = method
        self.result = result
    }
}
```

In `Sources/Capture/HeartbeatDiff.swift`, inside `public enum HeartbeatDiff`, add before `Input`:
```swift
    /// Spec §5.6: what caused this diff. It decides only the kind and `reason` of the emitted
    /// focused-context event; the dedup rule is identical for every trigger (spec §6.6).
    public enum Trigger: Sendable, Equatable {
        case heartbeat
        case activation
        case observer(ObservedKind)

        var kind: EventKind {
            switch self {
            case .heartbeat, .activation: return .contextSnapshot
            case .observer(.focusedElementChanged): return .elementFocused
            case .observer(.focusedWindowChanged): return .windowFocused
            case .observer(.titleChanged): return .windowTitleChanged
            case .observer(.valueChanged): return .elementValueChanged
            case .observer(.menuItemSelected): return .contextSnapshot  // never reaches compute
            }
        }

        var reason: String { self == .heartbeat ? "heartbeat" : "observer" }
    }
```
Add the field to `Input` — `public var trigger: Trigger` after `now`, and the init gains a **last** parameter `trigger: Trigger = .heartbeat` with `self.trigger = trigger`.

In `compute`, replace the extra construction and the event's kind:
```swift
            var extra: [String: JSONValue] = ["reason": .string(input.trigger.reason)]
```
and, after the existing `textSource` block and before `events.append(`:
```swift
            if case .observer(.titleChanged) = input.trigger,
                let previousTitle = previous.signature?.windowTitle
            {
                extra["previousTitle"] = .string(previousTitle)
            }
```
and in the `RawEvent(` call change `kind: .contextSnapshot` to `kind: input.trigger.kind`.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter HeartbeatDiffTests` then full `swift test`.
Expected: the 4 new tests pass; every pre-existing test passes unchanged (default trigger keeps heartbeat output byte-identical).

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Capture/AXTypes.swift Sources/Capture/HeartbeatDiff.swift Tests/CaptureTests/HeartbeatDiffTests.swift
git commit -m "Add observer types and trigger-based kind mapping to the heartbeat diff

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BdcwpxNhK3QnZByv2nHgnN"
```

---

### Task 2: `AXObserverHub` and `AppLifecycle` (the AX / AppKit glue)

**Files:**
- Create: `Sources/Capture/AXObserverHub.swift`
- Create: `Sources/Capture/AppLifecycle.swift`

**Interfaces:**
- Consumes: `ObservedKind`, `ObservedChange`, `LifecycleEvent`, `AppInfo.init(running:)` (exists in `AXClient.swift`), `AXReadError`.
- Produces: `@MainActor final class AXObserverHub { init(now:); var observedPids: Set<Int32>; func start(pid: Int32, handler: @escaping @MainActor (ObservedChange) -> Void) throws; func stop(pid: Int32); func stopAll() }`; `@MainActor final class AppLifecycle { func start(handler: @escaping @MainActor (LifecycleEvent) -> Void); func stop() }`. Both `internal` — `AXClient` (Task 3) owns and forwards to them.

There is no CI-testable behaviour here (real `AXObserver` / `NSWorkspace`); the gate for this task is a clean Swift 6 strict-concurrency build and an unchanged green suite. The end-to-end proof is the gated live test in Task 7.

- [ ] **Step 1: Write `Sources/Capture/AXObserverHub.swift`**

```swift
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
    private func add(_ name: String, on element: AXUIElement, entry: inout Entry, pid: Int32)
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
    MainActor.assumeIsolated {
        hub.handle(element: element, notification: notification as String)
    }
}
```

- [ ] **Step 2: Write `Sources/Capture/AppLifecycle.swift`**

```swift
import AppKit
import Foundation

/// Spec §5.2. `NSWorkspace` notifications (delivered on the main queue) → `LifecycleEvent`.
/// `didActivateApplication` fires for every app, which is what `capture.record_other_apps` needs.
@MainActor
final class AppLifecycle {
    typealias Handler = @MainActor (LifecycleEvent) -> Void

    private var tokens: [NSObjectProtocol] = []

    func start(handler: @escaping Handler) {
        guard tokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let mappings: [(Notification.Name, @MainActor @Sendable (Notification) -> LifecycleEvent?)] =
            [
                (NSWorkspace.didLaunchApplicationNotification,
                 { Self.app(in: $0).map(LifecycleEvent.launched) }),
                (NSWorkspace.didTerminateApplicationNotification,
                 { Self.app(in: $0).map(LifecycleEvent.terminated) }),
                (NSWorkspace.didActivateApplicationNotification,
                 { Self.app(in: $0).map(LifecycleEvent.activated) }),
                (NSWorkspace.willSleepNotification, { _ in .sleep }),
                (NSWorkspace.didWakeNotification, { _ in .wake }),
            ]
        for (name, map) in mappings {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    if let event = map(note) { handler(event) }
                }
            }
            tokens.append(token)
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens { center.removeObserver(token) }
        tokens = []
    }

    private static func app(in note: Notification) -> AppInfo? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            .map(AppInfo.init(running:))
    }
}
```

- [ ] **Step 3: Build and run the suite**

Run: `swift build && swift test`
Expected: clean build under Swift 6 strict concurrency (the two `MainActor.assumeIsolated` entries are the only isolation crossings, both justified by main-thread delivery); the existing suite passes unchanged (nothing calls the new types yet). If the compiler rejects the `mappings` tuple type, declare the closures with `let launched: @MainActor @Sendable (Notification) -> LifecycleEvent? = …` one by one — the behaviour must stay exactly as written.

- [ ] **Step 4: Format and commit**

```bash
make format && make lint
git add Sources/Capture/AXObserverHub.swift Sources/Capture/AppLifecycle.swift
git commit -m "Add AXObserverHub and AppLifecycle glue

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BdcwpxNhK3QnZByv2nHgnN"
```

---

### Task 3: `AXReading` additions, `AXClient` forwarding + Electron enable, `FakeAXClient`, test harness

**Files:**
- Modify: `Sources/Capture/AXTypes.swift` (the `AXReading` protocol)
- Modify: `Sources/Capture/ElectronSupport.swift`
- Modify: `Sources/Capture/AXClient.swift`
- Modify: `Tests/CaptureTests/FakeAXClient.swift`
- Create: `Tests/CaptureTests/ObserverTests.swift`

**Interfaces:**
- Consumes: `AXObserverHub`, `AppLifecycle` (Task 2); `ObservedChange`, `LifecycleEvent`, `ElectronEnableResult` (Task 1).
- Produces: on `AXReading` — `startObserving(_ app: AppInfo, handler: @escaping @MainActor (ObservedChange) -> Void) throws`, `stopObserving(pid: Int32)`, `stopObservingAll()`, `startLifecycle(handler: @escaping @MainActor (LifecycleEvent) -> Void)`, `stopLifecycle()`, `enableElectronAccessibility(_ app: AppInfo) -> ElectronEnableResult`. `ElectronSupport.enableAttributes: [String]`. On `FakeAXClient` — `startObservingCalls: [Int32]`, `stopObservingCalls: [Int32]`, `observeFailures: [Int32: Int]` (fail the next N `startObserving` calls for a pid with `.cannotComplete`), `lifecycleHandler`, `electronCalls: [Int32]`, `electronResult`, `deliver(_ change: ObservedChange)`, `deliverLifecycle(_ event: LifecycleEvent)`. Test harness in `ObserverTests`: `makeCapturer(fake:allow:debounceMs:clock:)`, `drain(_:)`, `Clock`.

- [ ] **Step 1: Write the failing tests (the harness + fake behaviour)**

`Tests/CaptureTests/ObserverTests.swift`:
```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ObserverTests`
Expected: build error — `startObserving`, `deliver`, etc. not found on `FakeAXClient`.

- [ ] **Step 3: Extend the protocol, `ElectronSupport`, `AXClient`, and the fake**

In `Sources/Capture/AXTypes.swift`, add to `AXReading` after `func cache(from context: FocusedContext) -> ContentCache`:
```swift
    // MARK: Observers (spec §5.4)

    /// Register for `app`'s in-app notifications. Throws `.cannotComplete` / `.invalidElement`
    /// while the app's AX tree is not ready — the caller retries (spec §6.2).
    func startObserving(
        _ app: AppInfo, handler: @escaping @MainActor (ObservedChange) -> Void) throws
    func stopObserving(pid: Int32)
    func stopObservingAll()
    func startLifecycle(handler: @escaping @MainActor (LifecycleEvent) -> Void)
    func stopLifecycle()
    /// Spec §5.7: the daemon's only write into another process.
    func enableElectronAccessibility(_ app: AppInfo) -> ElectronEnableResult
```

In `Sources/Capture/ElectronSupport.swift`, add inside the enum:
```swift
    /// Spec §5.7. Tried in order; the first accepted attribute wins.
    public static let enableAttributes = ["AXManualAccessibility", "AXEnhancedUserInterface"]
```

In `Sources/Capture/AXClient.swift`: add `import os`; add stored properties after `public init() {}`:
```swift
    private let hub = AXObserverHub()
    private let lifecycle = AppLifecycle()
    private let logger = Logger(subsystem: "org.openrhyme.engine", category: "ax")
```
and add the conformance (place after `secondsSinceLastInput`):
```swift
    // MARK: - Observers (spec §5.4)

    public func startObserving(
        _ app: AppInfo, handler: @escaping @MainActor (ObservedChange) -> Void
    ) throws {
        try hub.start(pid: app.pid, handler: handler)
    }

    public func stopObserving(pid: Int32) { hub.stop(pid: pid) }

    public func stopObservingAll() { hub.stopAll() }

    public func startLifecycle(handler: @escaping @MainActor (LifecycleEvent) -> Void) {
        lifecycle.start(handler: handler)
    }

    public func stopLifecycle() { lifecycle.stop() }

    /// Spec §5.7. `AXManualAccessibility` first; on `attributeUnsupported` fall back to
    /// `AXEnhancedUserInterface`. Logged: it is the only write the daemon makes into another
    /// process.
    public func enableElectronAccessibility(_ app: AppInfo) -> ElectronEnableResult {
        let application = AXUIElementCreateApplication(app.pid)
        for method in ElectronSupport.enableAttributes {
            let error = AXUIElementSetAttributeValue(
                application, method as CFString, kCFBooleanTrue)
            switch error {
            case .success:
                logger.info("set \(method) on pid \(app.pid) (\(app.bundleID ?? "?"))")
                return ElectronEnableResult(method: method, result: "ok")
            case .attributeUnsupported:
                continue
            default:
                logger.warning(
                    "\(method) on pid \(app.pid) failed: AXError \(error.rawValue)")
                return ElectronEnableResult(method: method, result: "failed")
            }
        }
        return ElectronEnableResult(
            method: ElectronSupport.enableAttributes.last ?? "", result: "unsupported")
    }
```

In `Tests/CaptureTests/FakeAXClient.swift`, add the state after `lastReusing`:
```swift
    private(set) var observing: [Int32: @MainActor (ObservedChange) -> Void] = [:]
    private(set) var startObservingCalls: [Int32] = []
    private(set) var stopObservingCalls: [Int32] = []
    /// Fail the next N `startObserving` calls for a pid with `.cannotComplete`.
    var observeFailures: [Int32: Int] = [:]
    private(set) var lifecycleHandler: (@MainActor (LifecycleEvent) -> Void)?
    private(set) var electronCalls: [Int32] = []
    var electronResult = ElectronEnableResult(method: "AXManualAccessibility", result: "ok")
```
and the conformance + delivery helpers after `cache(from:)`:
```swift
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ObserverTests` then full `swift test`.
Expected: the 2 harness tests pass; everything else unchanged (the `Capturer` does not call the new requirements yet).

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Capture/AXTypes.swift Sources/Capture/ElectronSupport.swift Sources/Capture/AXClient.swift Tests/CaptureTests/FakeAXClient.swift Tests/CaptureTests/ObserverTests.swift
git commit -m "Expose observer, lifecycle and Electron-enable through AXReading

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BdcwpxNhK3QnZByv2nHgnN"
```

---

### Task 4: `Capturer.refresh(trigger:freshRead:)` + `handle(change:)` for focus / window / title

**Files:**
- Modify: `Sources/Capture/Capturer.swift`
- Test: `Tests/CaptureTests/ObserverTests.swift` (existing `CapturerTests` must stay green)

**Interfaces:**
- Consumes: `HeartbeatDiff.Trigger` / `Input.trigger` (Task 1); `ObservedChange` (Task 1); the `ObserverTests` harness (Task 3).
- Produces: `Capturer.handle(change: ObservedChange)` (public — the hub's handler in Task 5 and tests drive it); private `refresh(trigger: HeartbeatDiff.Trigger, freshRead: Bool)` — the shared read-and-diff. `heartbeat()` is removed; `tick()` calls `refresh(trigger: .heartbeat, freshRead: false)`.

- [ ] **Step 1: Write the failing tests** (append inside `ObserverTests`)

```swift
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
        #expect(events.map(\.kind) == [.permissionChanged, .appActivated, .contextSnapshot, .elementFocused])
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
        #expect(events.map(\.kind) == [.permissionChanged, .appActivated, .contextSnapshot, .windowTitleChanged])
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
        #expect(events.map(\.kind) == [.permissionChanged, .appActivated, .contextSnapshot, .contextSnapshot])
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ObserverTests`
Expected: build error — `handle(change:)` not found.

- [ ] **Step 3: Implement**

In `Sources/Capture/Capturer.swift`, replace `tick()` and the whole `heartbeat()` method with:
```swift
    /// One heartbeat. Public so tests can drive it directly.
    public func tick() {
        reloadConfigIfChanged()
        checkTrust()
        guard trust == .active else { return }
        refresh(trigger: .heartbeat, freshRead: false)
        checkIdle()
    }

    /// Spec §6.3. A notification for the frontmost app triggers the shared refresh immediately;
    /// one from a background app costs nothing. Public so the hub's handler and tests drive it.
    public func handle(change: ObservedChange) {
        guard trust == .active, change.pid == ax.frontmostApplication()?.pid else { return }
        switch change.kind {
        case .focusedWindowChanged, .focusedElementChanged, .titleChanged:
            refresh(trigger: .observer(change.kind), freshRead: false)
        case .valueChanged, .menuItemSelected:
            return  // the debounce and menu paths are added with Task 6
        }
    }

    /// The read-and-diff every path shares (spec §6.3): heartbeat, activation, observer.
    /// `freshRead` bypasses the content cache so the ladder runs again (spec §6.4).
    private func refresh(trigger: HeartbeatDiff.Trigger, freshRead: Bool) {
        let frontmost = ax.frontmostApplication()
        var context: FocusedContext?
        if let frontmost, HeartbeatDiff.isAllowed(frontmost, config.allowlistSet) {
            do {
                context = try ax.focusedContext(
                    of: frontmost,
                    reusing: freshRead ? nil : lastContentCache[frontmost.pid])
                readFailures[frontmost.pid] = nil
                staleBackoff = 5
                if let context { lastContentCache[frontmost.pid] = ax.cache(from: context) }
            } catch AXReadError.apiDisabled {
                setTrust(.stale)
                scheduleStaleRetry()
                return
            } catch {
                readFailures[frontmost.pid, default: 0] += 1
                logger.warning(
                    "read failed for pid \(frontmost.pid): \(String(describing: error)) (\(self.readFailures[frontmost.pid] ?? 0)x)"
                )
            }
        }
        let output = HeartbeatDiff.compute(
            previous: state,
            input: HeartbeatDiff.Input(
                frontmost: frontmost, context: context, allowlist: config.allowlistSet,
                recordOtherApps: config.capture.recordOtherApps,
                maxValueBytes: config.capture.maxValueBytes, now: now(), trigger: trigger))
        for event in output.events { emit(event) }
        let idle = state.idle
        let idleSince = state.idleSince
        state = output.state
        state.idle = idle
        state.idleSince = idleSince
    }
```
The body of `refresh` is the old `heartbeat()` verbatim except for the `reusing:` expression and the `trigger:` argument — the heartbeat's behaviour is unchanged.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter "ObserverTests|CapturerTests"` then full `swift test`.
Expected: the 6 new tests pass; every pre-existing `CapturerTests` test passes unchanged.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Capture/Capturer.swift Tests/CaptureTests/ObserverTests.swift
git commit -m "Route observer changes through the shared refresh

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BdcwpxNhK3QnZByv2nHgnN"
```

---

### Task 5: Lifecycle, observe / unobserve, Electron enable, retries, reconcile, trust + stop hooks

**Files:**
- Modify: `Sources/Capture/Capturer.swift`
- Test: `Tests/CaptureTests/ObserverTests.swift`

**Interfaces:**
- Consumes: `LifecycleEvent`, `ElectronEnableResult`, `ElectronSupport.isElectronBundle`, the six `AXReading` requirements (Task 3), `refresh(trigger:freshRead:)` and `handle(change:)` (Task 4).
- Produces: `Capturer.init(..., retryDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(10)])` (new **last** parameter); `public private(set) var observed: Set<Int32>`; `public func handle(lifecycle: LifecycleEvent)`; internal `observe(_ app: AppInfo)`, `unobserve(_ pid: Int32)`; private `reconcileObservers()`; `static let reconcileRetrySeconds: Double = 60`.

- [ ] **Step 1: Write the failing tests**

First extend the harness in `ObserverTests`: add the parameter `retryDelays: [Duration] = [.milliseconds(5), .milliseconds(5), .milliseconds(5)]` (after `debounceMs`) to `makeCapturer` and pass `retryDelays: retryDelays` to the `Capturer` initializer. Then append:
```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ObserverTests`
Expected: build error — `retryDelays:`, `handle(lifecycle:)`, `observed` not found.

- [ ] **Step 3: Implement**

In `Sources/Capture/Capturer.swift`:

Add stored state after `lastContentCache`:
```swift
    /// Pids with a live observer (spec §5.5).
    public private(set) var observed: Set<Int32> = []
    private var electronEnabled: Set<Int32> = []
    private var observeFailedAt: [Int32: Double] = [:]
    private var observeRetries: [Int32: Task<Void, Never>] = [:]
    private let retryDelays: [Duration]
    /// Spec §6.2: a pid that exhausted its retries is re-attempted by reconcile at most this often.
    static let reconcileRetrySeconds: Double = 60
```
Add the init parameter (last) `retryDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(10)]` and `self.retryDelays = retryDelays`.

In `start()`, after `ax.setGlobalMessagingTimeout(0.25)`:
```swift
        ax.startLifecycle { [weak self] event in self?.handle(lifecycle: event) }
```
In `stop()`, before `continuation.finish()`:
```swift
        for task in observeRetries.values { task.cancel() }
        observeRetries = [:]
        ax.stopObservingAll()
        observed = []
        ax.stopLifecycle()
```
In `tick()`, after `checkIdle()`: `reconcileObservers()`. In `reloadConfigIfChanged()`, after the `logger.info("config reloaded…")` line: `reconcileObservers()`.

In `setTrust(_:)`, after `trust = new` and before `emit(`:
```swift
        if new != .active {
            for task in observeRetries.values { task.cancel() }
            observeRetries = [:]
            ax.stopObservingAll()
            observed = []
        }
```
Add the lifecycle handler and observer management (place after `handle(change:)`):
```swift
    /// Spec §6.1. Public so tests can drive it; the real source is `AppLifecycle`.
    public func handle(lifecycle event: LifecycleEvent) {
        switch event {
        case .launched(let app):
            guard HeartbeatDiff.isAllowed(app, config.allowlistSet) else { return }
            emit(appEvent(.appLaunched, app))
            observe(app)
        case .terminated(let app):
            if observed.contains(app.pid) { emit(appEvent(.appTerminated, app)) }
            unobserve(app.pid)
        case .activated:
            guard trust == .active else { return }
            refresh(trigger: .activation, freshRead: false)
        case .sleep:
            emit(RawEvent(ts: now(), kind: .systemSleep))
        case .wake:
            emit(RawEvent(ts: now(), kind: .systemWake))
        }
    }

    private func appEvent(_ kind: EventKind, _ app: AppInfo) -> RawEvent {
        RawEvent(ts: now(), kind: kind, pid: app.pid, bundleID: app.bundleID, appName: app.name)
    }

    /// Spec §5.5 / §6.2. Idempotent. An Electron app is enabled once per pid lifetime first.
    func observe(_ app: AppInfo) {
        guard trust == .active, HeartbeatDiff.isAllowed(app, config.allowlistSet),
            !observed.contains(app.pid), observeRetries[app.pid] == nil
        else { return }
        if ElectronSupport.isElectronBundle(app.bundleURL), !electronEnabled.contains(app.pid) {
            let result = ax.enableElectronAccessibility(app)
            electronEnabled.insert(app.pid)
            emit(
                RawEvent(
                    ts: now(), kind: .appAXEnabled, pid: app.pid, bundleID: app.bundleID,
                    appName: app.name,
                    extra: ["method": .string(result.method), "result": .string(result.result)]))
        }
        attemptObserve(app, attempt: 0)
    }

    private func attemptObserve(_ app: AppInfo, attempt: Int) {
        do {
            try ax.startObserving(app) { [weak self] change in self?.handle(change: change) }
            observed.insert(app.pid)
            observeFailedAt[app.pid] = nil
            observeRetries[app.pid] = nil
        } catch AXReadError.apiDisabled {
            setTrust(.stale)
            scheduleStaleRetry()
        } catch {
            guard attempt < retryDelays.count else {
                logger.warning("observer for pid \(app.pid) gave up after \(attempt) retries")
                observeFailedAt[app.pid] = now()
                observeRetries[app.pid] = nil
                return
            }
            let delay = retryDelays[attempt]
            observeRetries[app.pid] = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                self.observeRetries[app.pid] = nil
                self.attemptObserve(app, attempt: attempt + 1)
            }
        }
    }

    func unobserve(_ pid: Int32) {
        observeRetries[pid]?.cancel()
        observeRetries[pid] = nil
        if observed.contains(pid) { ax.stopObserving(pid: pid) }
        observed.remove(pid)
        electronEnabled.remove(pid)
        observeFailedAt[pid] = nil
        lastContentCache[pid] = nil
        readFailures[pid] = nil
    }

    /// Spec §6.5. Every active heartbeat and after a config reload: observe running allowlisted
    /// apps (initial grant, trust recovery, allowlist edits, given-up retries), drop gone ones.
    private func reconcileObservers() {
        guard trust == .active else { return }
        let running = ax.runningApplications().filter {
            HeartbeatDiff.isAllowed($0, config.allowlistSet)
        }
        let runningPids = Set(running.map(\.pid))
        for app in running where !observed.contains(app.pid) {
            if let failedAt = observeFailedAt[app.pid],
                now() - failedAt < Self.reconcileRetrySeconds
            {
                continue
            }
            observe(app)
        }
        for pid in Array(observed) where !runningPids.contains(pid) { unobserve(pid) }
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter "ObserverTests|CapturerTests"` then full `swift test`.
Expected: the 9 new tests pass; all pre-existing tests unchanged (`FakeAXClient.running` defaults to empty, so reconcile is a no-op for them).

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Capture/Capturer.swift Tests/CaptureTests/ObserverTests.swift
git commit -m "Observe allowlisted apps across their lifecycle with Electron enabling and retries

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BdcwpxNhK3QnZByv2nHgnN"
```

---

### Task 6: Value debounce (with drop and cache bypass) and menu selections

**Files:**
- Modify: `Sources/Capture/Capturer.swift`
- Test: `Tests/CaptureTests/ObserverTests.swift`

**Interfaces:**
- Consumes: `handle(change:)`, `refresh(trigger:freshRead:)` (Task 4); `handle(lifecycle:)`, `unobserve`, `stop`, `setTrust` (Task 5); `config.capture.valueDebounceMs`.
- Produces: the final `handle(change:)` (all five kinds); private `scheduleValueRefresh(for:)`, `dropPendingValueRefresh(for:)`, `dropAllPendingValueRefreshes()`.

- [ ] **Step 1: Write the failing tests** (append inside `ObserverTests`)

```swift
    @Test func rapidValueChangesCollapseIntoOneFreshRead() async throws {
        let fake = FakeAXClient()
        fake.show(
            safari, window: WindowInfo(title: "A"),
            element: ElementInfo(role: "AXTextArea", value: "h"))
        let capturer = try makeCapturer(fake: fake, debounceMs: 20)
        capturer.tick()
        let reads = fake.focusedContextCalls
        for text in ["he", "hel", "hello"] {
            fake.show(
                safari, window: WindowInfo(title: "A"),
                element: ElementInfo(role: "AXTextArea", value: text))
            capturer.handle(change: ObservedChange(pid: 10, kind: .valueChanged, ts: 1))
        }
        #expect(fake.focusedContextCalls == reads)  // still debouncing: nothing read
        try await Task.sleep(for: .milliseconds(80))
        #expect(fake.focusedContextCalls == reads + 1)
        #expect(fake.lastReusing == nil)  // the content cache was bypassed
        let events = await drain(capturer)
        let changes = events.filter { $0.kind == .elementValueChanged }
        #expect(changes.count == 1)
        #expect(changes.first?.value == "hello")
    }

    @Test func focusChangeDropsAPendingValueRefresh() async throws {
        let fake = FakeAXClient()
        fake.show(
            safari, window: WindowInfo(title: "A"),
            element: ElementInfo(role: "AXTextArea", value: "h"))
        let capturer = try makeCapturer(fake: fake, debounceMs: 20)
        capturer.tick()
        fake.show(
            safari, window: WindowInfo(title: "A"),
            element: ElementInfo(role: "AXTextArea", value: "hi"))
        capturer.handle(change: ObservedChange(pid: 10, kind: .valueChanged, ts: 1))
        fake.show(
            safari, window: WindowInfo(title: "A"),
            element: ElementInfo(role: "AXButton", title: "OK"))
        capturer.handle(change: ObservedChange(pid: 10, kind: .focusedElementChanged, ts: 2))
        try await Task.sleep(for: .milliseconds(80))
        let events = await drain(capturer)
        #expect(!events.map(\.kind).contains(.elementValueChanged))
        #expect(events.last?.kind == .elementFocused)
    }

    @Test func typeThenUndoIsSilent() async throws {
        let fake = FakeAXClient()
        fake.show(
            safari, window: WindowInfo(title: "A"),
            element: ElementInfo(role: "AXTextArea", value: "same"))
        let capturer = try makeCapturer(fake: fake, debounceMs: 20)
        capturer.tick()
        capturer.handle(change: ObservedChange(pid: 10, kind: .valueChanged, ts: 1))
        try await Task.sleep(for: .milliseconds(80))  // refresh runs, value hash unchanged
        let events = await drain(capturer)
        #expect(events.map(\.kind) == [.permissionChanged, .appActivated, .contextSnapshot])
    }

    @Test func menuSelectionEmitsTheTitleWithoutAContextRead() async throws {
        let fake = FakeAXClient()
        fake.show(safari, window: WindowInfo(title: "A"))
        let capturer = try makeCapturer(fake: fake)
        capturer.tick()
        let reads = fake.focusedContextCalls
        capturer.handle(
            change: ObservedChange(pid: 10, kind: .menuItemSelected, menuTitle: "Save", ts: 7))
        #expect(fake.focusedContextCalls == reads)
        let events = await drain(capturer)
        #expect(events.last?.kind == .menuItemSelected)
        #expect(events.last?.elementTitle == "Save")
        #expect(events.last?.ts == 7)
        #expect(events.last?.bundleID == "com.apple.Safari")
    }

    @Test func activationDropsPendingValueRefreshes() async throws {
        let fake = FakeAXClient()
        fake.show(
            safari, window: WindowInfo(title: "A"),
            element: ElementInfo(role: "AXTextArea", value: "h"))
        let capturer = try makeCapturer(fake: fake, debounceMs: 20)
        capturer.tick()
        fake.show(
            safari, window: WindowInfo(title: "A"),
            element: ElementInfo(role: "AXTextArea", value: "hi"))
        capturer.handle(change: ObservedChange(pid: 10, kind: .valueChanged, ts: 1))
        fake.show(textEdit, window: WindowInfo(title: "Doc"))
        capturer.handle(lifecycle: .activated(textEdit))
        try await Task.sleep(for: .milliseconds(80))
        let events = await drain(capturer)
        #expect(!events.map(\.kind).contains(.elementValueChanged))
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ObserverTests`
Expected: `rapidValueChangesCollapseIntoOneFreshRead`, `menuSelection…` fail (value/menu are still ignored by `handle(change:)`).

- [ ] **Step 3: Implement**

In `Sources/Capture/Capturer.swift`, add state after `observeRetries`:
```swift
    private var pendingValueRefresh: [Int32: Task<Void, Never>] = [:]
```
Replace the whole `handle(change:)` from Task 4 with:
```swift
    /// Spec §6.3. A notification for the frontmost app triggers the shared refresh immediately;
    /// one from a background app costs nothing. Public so the hub's handler and tests drive it.
    public func handle(change: ObservedChange) {
        guard trust == .active, let frontmost = ax.frontmostApplication(),
            change.pid == frontmost.pid
        else { return }
        switch change.kind {
        case .menuItemSelected:
            emit(
                RawEvent(
                    ts: change.ts, kind: .menuItemSelected, pid: frontmost.pid,
                    bundleID: frontmost.bundleID, appName: frontmost.name,
                    elementTitle: change.menuTitle))
        case .valueChanged:
            scheduleValueRefresh(for: change.pid)
        case .focusedWindowChanged, .focusedElementChanged, .titleChanged:
            dropPendingValueRefresh(for: change.pid)
            refresh(trigger: .observer(change.kind), freshRead: false)
        }
    }

    /// Spec §6.4. One pending refresh per pid; every value change restarts the quiet period.
    /// The refresh bypasses the content cache — the notification says the value changed.
    private func scheduleValueRefresh(for pid: Int32) {
        pendingValueRefresh[pid]?.cancel()
        let delay = Duration.milliseconds(config.capture.valueDebounceMs)
        pendingValueRefresh[pid] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pendingValueRefresh[pid] = nil
            guard self.trust == .active, self.ax.frontmostApplication()?.pid == pid else {
                return
            }
            self.refresh(trigger: .observer(.valueChanged), freshRead: true)
        }
    }

    /// Spec §6.4: a pending refresh is dropped, not run, once the focused context has moved.
    private func dropPendingValueRefresh(for pid: Int32) {
        pendingValueRefresh[pid]?.cancel()
        pendingValueRefresh[pid] = nil
    }

    private func dropAllPendingValueRefreshes() {
        for pid in Array(pendingValueRefresh.keys) { dropPendingValueRefresh(for: pid) }
    }
```
Wire the drops: in `handle(lifecycle:)` add `dropAllPendingValueRefreshes()` as the first line of the `.activated` case (before the trust guard) and of the `.sleep` case; in `unobserve(_:)` add `dropPendingValueRefresh(for: pid)` as the first line; in `stop()` and in the `if new != .active` block of `setTrust` add `dropAllPendingValueRefreshes()` as the first line.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ObserverTests` then full `swift test`.
Expected: the 5 new tests pass; the whole suite green. If a debounce test is timing-flaky on a loaded CI runner, raise the sleeps to 150 ms — never lower the 20 ms debounce below the sleep margin.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Capture/Capturer.swift Tests/CaptureTests/ObserverTests.swift
git commit -m "Debounce value changes and record menu selections

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BdcwpxNhK3QnZByv2nHgnN"
```

---

### Task 7: Gated live test, docs, final verification

**Files:**
- Create: `Tests/CaptureTests/LiveObserverTests.swift` (gated; never CI)
- Modify: `docs/accessibility-api.md` (§5.1 and §7), `CLAUDE.md` (State line), `README.md` (one line under "Running the MVP")

**Interfaces:**
- Consumes: `AXClient.startObserving` / `startLifecycle` (Task 3) — the real hub and lifecycle end to end.

- [ ] **Step 1: Write the gated live test**

`Tests/CaptureTests/LiveObserverTests.swift`:
```swift
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
            if case .activated = $0 { return true } else { return false }
        }
        print(
            "LIVE observers: activations=\(activations.count) changes=\(sink.changes.map(\.kind)) in \(Date().timeIntervalSince(started))s"
        )
        #expect(activations.count >= 2, "NSWorkspace activation events did not arrive")
        #expect(!sink.changes.isEmpty, "no AXObserver callback arrived — run loop or registration")
        #expect(sink.onMainThread)
    }
}
```
(If the SDK flags `activate()`, use `activate(options: [])` — the assertions stay as written.)

- [ ] **Step 2: Confirm it is skipped without the grant, then run it live**

Run: `swift test --filter LiveObserverTests` → suite disabled, 0 tests. Then, from a terminal with the Accessibility grant and TextEdit frontmost:
```bash
OPENRHYME_LIVE_AX=1 swift test --filter LiveObserverTests 2>&1 | grep -E 'LIVE|passed|failed'
```
Expected: the `LIVE observers:` line shows ≥ 2 activations and a non-empty `changes` list (e.g. `[focusedElementChanged, focusedWindowChanged]`), all on the main thread; the test passes. This is the end-to-end proof of spec §4.1 with a real `AXObserver`. Record the printed line in the commit message body.

- [ ] **Step 3: Daemon smoke**

```bash
swift build -c release            # the ~/.local/bin/openrhyme symlink points at the RELEASE binary
# restart the daemon from the trusted terminal (kill the old pid from `openrhyme status`, then `openrhyme daemon`)
# switch between two allowlisted apps a few times, type in TextEdit, pick a menu item, then:
openrhyme events --since 5m
```
Expected: `app.activated` / `app.deactivated` timestamped within a second of each switch; `element.focused` / `window.focused` / `window.title_changed` with `extra.reason: "observer"`; `element.value_changed` once per typing pause carrying the fresh text; `menu.item_selected` with the title; no duplicate `context.snapshot` for changes an observer already recorded; `context.snapshot` with `reason: "heartbeat"` only for unnotified changes.

- [ ] **Step 4: Update the docs**

- `docs/accessibility-api.md` §5.1, after the notification table: an "As shipped" paragraph — one `AXObserver` per allowlisted pid with its source on `CFRunLoopGetMain()`; registered on the app element: focused/main window changed, focused UI element changed, title changed, menu item selected; `kAXValueChanged` follows the focused element; app activation comes from `NSWorkspace` only; notifications trigger the shared read-and-diff (kinds `element.focused`, `window.focused`, `window.title_changed`, `element.value_changed`, `extra.reason: "observer"`); value changes debounced by `capture.value_debounce_ms` and re-run the content ladder; background-app notifications cost no read; the 5 s heartbeat remains the safety net. In §7 add: "Verified 2026-09-02 (macOS 26.5, Swift 6 async `main`): the main `CFRunLoop` is pumped while the daemon `await`s its signal, so observer sources on `CFRunLoopGetMain()` fire with no explicit pump."
- `CLAUDE.md` State line: append "Observers (event-driven capture: `AXObserver` + `NSWorkspace` lifecycle, debounced value changes, menu selections, Electron enabling) landed on top."
- `README.md` under "Running the MVP": one line — "Capture is event-driven: app, window, element and title changes, typing (debounced), menu selections and sleep/wake are recorded the moment they happen; the 5 s heartbeat is only the safety net."

- [ ] **Step 5: Full verification + commit**

```bash
make build && make test && make lint
git add Tests/CaptureTests/LiveObserverTests.swift docs/accessibility-api.md CLAUDE.md README.md
git commit -m "Add live observer test and document event-driven capture

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BdcwpxNhK3QnZByv2nHgnN"
```

---

## Self-review (against the spec)

| Spec section | Task |
|---|---|
| §4 / §4.1 one pipeline, main run loop | 4 (`refresh`), 2 (sources on `CFRunLoopGetMain()`), 7 (live proof) |
| §5.1 `AXObserverHub` | 2 |
| §5.2 `AppLifecycle` | 2 |
| §5.3 Sendable types | 1 (`terminated` carries `AppInfo` — a deliberate refinement so `app.terminated` keeps bundle id/name) |
| §5.4 `AXReading` additions | 3 |
| §5.5 `Capturer` state and hooks | 5 (observe/unobserve/reconcile/trust/stop), 6 (pending refresh) |
| §5.6 `HeartbeatDiff.Trigger` mapping, `previousTitle` | 1 |
| §5.7 Electron enable | 3 (write), 5 (once per pid lifetime, `app.ax_enabled`) |
| §6.1 lifecycle events | 5 |
| §6.2 creation retries, 60 s reconcile retry | 5 |
| §6.3 in-app changes, background ignore, menu | 4, 6 |
| §6.4 debounce, cache bypass, drop | 6 |
| §6.5 reconcile on heartbeat + config reload | 5 |
| §6.6 dedup both ways | 4 (tests), 1 (single rule) |
| §7 privacy / the one write | inherited ladder + `Redaction`; 3, 5 |
| §8 tests | 1, 3, 4, 5, 6 (unit), 7 (live) |
| §9 performance (no callback reads, background zero-cost, one ladder per debounce) | 2, 4, 6 |
| §10 docs | 7 |

**Placeholder scan:** none — Task 4's `handle(change:)` deliberately returns for `valueChanged` / `menuItemSelected` and Task 6 replaces that switch with the full version shown there. **Type consistency:** `ObservedKind` / `ObservedChange(pid:kind:menuTitle:ts:)` / `LifecycleEvent` / `ElectronEnableResult(method:result:)` (Task 1) are used with identical names in Tasks 2–7; `HeartbeatDiff.Trigger` and `Input(..., trigger:)` (Task 1) in Task 4; the six `AXReading` requirements (Task 3) match the `AXClient`, `FakeAXClient` and `Capturer` call sites in Tasks 3–5; `Capturer.init`'s new `retryDelays` is the last parameter and the `ObserverTests` harness passes it (Task 5); `handle(change:)` and `handle(lifecycle:)` are `public`, `refresh` / `scheduleValueRefresh` / `reconcileObservers` are `private`, `observe` / `unobserve` internal. Every exact-sequence assertion starts with `.permissionChanged` because a fresh `Capturer` reports the grant on its first tick.
