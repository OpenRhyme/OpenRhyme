# Observers — event-driven capture design

**Status:** approved design, 2026-09-02. Second post-MVP slice (after content extraction).
**Scope:** the Swift engine `Capture` module (+ one docs pass). **No storage-schema change (stays v1), no `--json` contract change, no change to the MCP repo** — every event kind this slice emits already exists in `Core.EventKind` and the MCP passes `kind`/`extra` through verbatim.
**Builds on:** `docs/superpowers/specs/2026-09-01-mvp-capture-engine-design.md` (§5 event model, §6.1–6.3 hybrid capture, §6.7 Electron, §6.8 recovery) and `docs/superpowers/specs/2026-09-01-content-extraction-design.md` (§6 the content-cache gate). API facts: `docs/accessibility-api.md` §5.1 (AXObserver), §7 (concurrency).

## 1. Problem

Capture today is heartbeat-only: every 5 s the daemon reads the focused context and diffs it. Consequences, all visible in the first dogfood day:
- **Transitions are late and coarse.** An app/window/tab switch is timestamped at the next heartbeat — up to 5 s after it happened — and two switches inside one interval collapse into one. App switch is the strongest sessionization signal (MVP §5.1), and its timing is currently the least precise thing we record.
- **Typing is sampled, not captured.** A native field's text is read only when the poll lands; the edit that ends 200 ms before a switch is lost, and there is no field-aware "the user is typing here now" signal.
- **Explicit actions are invisible.** Save / Commit / Build via menus leave no trace.

**Goal:** make capture event-driven — instant, precisely timestamped app/window/element/title transitions; real-time, debounced, field-aware typing; menu selections; sleep/wake boundaries — while keeping the 5 s heartbeat as the safety net for anything an app fails to notify (MVP §1: "precision of push, safety net of poll, one dedup path").

## 2. Non-goals

- **No `window.created` / `window.destroyed`, no `element.selection_changed`.** Noisy and low timeline value; the kinds stay defined for a later slice if the data ever asks for them.
- **No `app.opaque` detection.** The per-pid failure counter already exists in `Capturer`; turning it into events is its own tiny slice.
- **No change to the `status` command's output.** MVP §6.7 says Electron enabling is "visible in `status`"; the `--json` envelope is a public contract, so this slice makes it visible through the `app.ax_enabled` event and the daemon log only. A `status` field is deferred.
- **No element-held flush.** When focus leaves a field while a value refresh is still pending, the pending refresh is dropped (§6.4). The loss is bounded by `capture.value_debounce_ms` (default 500 ms) of trailing keystrokes and is accepted for one read path; an element-held flush is a later refinement if dogfood shows it matters.
- No event tap, no `launchd`, no schema v2.

## 3. Success criteria

1. Switching between two allowlisted apps produces `app.deactivated` + `app.activated` within **< 1 s** of the switch (today: ≤ 5 s), with a `context.snapshot` (`extra.reason: "observer"`) of the newly focused context.
2. Focus, window and title changes inside the frontmost allowlisted app produce `element.focused` / `window.focused` / `window.title_changed` events carrying the **same** focused context the heartbeat would (value + `textSource` via the content ladder, redaction, hashing) — no thinner `value` on the observer path.
3. Typing in a native text field produces `element.value_changed` events **once per typing pause** (not per keystroke), carrying the fresh value; typing in a web editor (contenteditable) refreshes too, because a value-changed refresh bypasses the content cache.
4. **No duplicates in either direction:** a change an observer captured is not re-emitted by the next heartbeat; a change the heartbeat captured first is not re-emitted by a late notification; a change nobody notified is still caught by the heartbeat as `context.snapshot` (`reason: "heartbeat"`).
5. Menu selections produce `menu.item_selected` with the item title. Sleep and wake produce `system.sleep` / `system.wake`.
6. The first observer created for an allowlisted **Electron** app sets `AXManualAccessibility` (fallback `AXEnhancedUserInterface`) and emits `app.ax_enabled` with `method` and `result`; non-Electron apps are never written to.
7. Lifecycle: launching an allowlisted app gets an observer (with retries while the app is not ready); terminating removes it and forgets that pid's state; an unsupported notification is logged once per (pid, notification) and skipped; a lost or revoked grant stops observers and a regained grant recreates them.
8. Daemon CPU stays within the MVP's ~2 % average target; a notification storm (e.g. 100 `valueChanged`/s) yields at most one content read per debounce window and no event flood; notifications from background apps cost **zero** reads.
9. `make build && make test && make lint` pass; CI green. Fake-driven unit tests cover kind mapping, dedup both ways, debounce and drop, cache bypass, background-app ignore, lifecycle and retries, Electron enabling, heartbeat reconcile and allowlist reload. One gated live test proves a real `AXObserver` callback fires in this daemon's run-loop model and measures activation latency.

## 4. Architecture — observers as triggers into the existing pipeline

The MVP heartbeat already owns the complete "read the focused context → diff → emit → remember" pipeline: the content-cache gate, the content ladder, redaction, hashing, and `LastKnownState` dedup. This slice makes **notifications trigger that same pipeline immediately**, instead of adding a second read path. An observer callback reads nothing itself (one exception: a menu item's title); it hands the `Capturer` a small `Sendable` value saying *what* changed in *which* pid, and the `Capturer` runs the existing read + diff with the notification's kind mapped onto the emitted event.

Why this shape: one read path means observer events carry exactly the heartbeat's content quality (criterion 2); one `LastKnownState` means the two paths dedup against each other for free (criterion 4); the gate makes a burst of notifications cheap (identity read + cache hit); and the fake AX client only has to *deliver* changes, so every behaviour is unit-testable without a grant.

```
 NSWorkspace notifications ─┐                     ┌─ AXObserver callbacks (C, main thread)
   launch/terminate/activate │                     │   focusedWindow / mainWindow / focusedUIElement
   willSleep/didWake         ▼                     ▼   title / value / menuItemSelected
                      AppLifecycle          AXObserverHub ── maps to ObservedChange(pid, kind)
                             │                     │            (+ re-registers valueChanged on the
                             └────── @MainActor ───┘             new focused element; reads a menu title)
                                          ▼
                                       Capturer
              lifecycle: observe/unobserve/Electron-enable/app switch/sleep-wake
              in-app change: frontmost check → debounce (value) → refresh(trigger)
                                          ▼
                     focusedContext(reusing: cache | nil)  ──►  HeartbeatDiff.compute(trigger)
                                          ▼                            (kind mapping, same dedup)
                                   AsyncStream<RawEvent>  ──►  Store
```

All of it runs on the **main actor / main thread**, as the MVP decided (MVP §3, `accessibility-api.md` §7). `AXUIElement` and `AXObserver` never leave `Capture`.

### 4.1 Run loop — verified
`AXObserver` delivers on the thread whose `CFRunLoop` owns its source. The daemon is an async `main` that `await`s a signal on the main actor. **Verified 2026-09-02 (macOS 26.5, Swift 6 async main): the main `CFRunLoop` is pumped during that await and run-loop callbacks execute on the main thread** — a `CFRunLoopTimer` added to `CFRunLoopGetMain()` fires while `await`ing. So observer sources attach to `CFRunLoopGetMain()` and the daemon needs no explicit run-loop pump. The gated live test (§8) re-proves this end to end with a real `AXObserver`.

## 5. Components

### 5.1 `AXObserverHub` (new, `Sources/Capture/AXObserverHub.swift`)
Owns, per observed pid: the `AXObserver`, its run-loop source, the application `AXUIElement`, the currently focused `AXUIElement` that carries the value registration, and the set of notifications already logged as unsupported.

- `start(pid, handler)`: `AXObserverCreate` → `check`; add the source to `CFRunLoopGetMain()`; register on the **application element**: `kAXFocusedWindowChangedNotification`, `kAXMainWindowChangedNotification`, `kAXFocusedUIElementChangedNotification`, `kAXTitleChangedNotification`, `kAXMenuItemSelectedNotification`. Then read `kAXFocusedUIElementAttribute` once and register `kAXValueChangedNotification` on it. Per registration: `kAXErrorNotificationUnsupported` → log once, skip; `kAXErrorNotificationAlreadyRegistered` → success; anything else → throw (the caller retries, §5.4).
  App activation is **not** registered here — `NSWorkspace` is the single source for it (§5.2), so it cannot double-fire.
- The callback is `@convention(c)`; `refcon` carries the hub via `Unmanaged.passUnretained`. It runs on the main thread (§4.1), so it enters the hub with `MainActor.assumeIsolated`. It does the minimum: map the notification name to an `ObservedKind`; on `focusedUIElementChanged` move the value registration from the previous focused element to the notified one (remove old, add new); on `menuItemSelected` read the notified element's `kAXTitleAttribute` (one read); then call the handler with an `ObservedChange`. No other reads happen in a callback.
- `stop(pid)`: remove the value registration, invalidate and remove the run-loop source, drop the observer and the pid's entries. Idempotent.
- `stopAll()` for daemon stop and trust loss.

### 5.2 `AppLifecycle` (new, `Sources/Capture/AppLifecycle.swift`)
Subscribes on `NSWorkspace.shared.notificationCenter` (delivered on the main thread): `didLaunchApplication`, `didTerminateApplication`, `didActivateApplication`, `willSleep`, `didWake`. Translates each into a `Sendable` `LifecycleEvent` and calls a handler. `didActivateApplication` fires for **every** app, so it also serves `capture.record_other_apps`. `stop()` removes the subscriptions.

### 5.3 Sendable types (in `AXTypes.swift`)
```swift
public enum ObservedKind: String, Sendable {
    case focusedWindowChanged    // kAXFocusedWindowChanged and kAXMainWindowChanged
    case focusedElementChanged   // kAXFocusedUIElementChanged
    case titleChanged            // kAXTitleChanged
    case valueChanged            // kAXValueChanged (on the focused element)
    case menuItemSelected        // kAXMenuItemSelected
}
public struct ObservedChange: Sendable, Equatable {
    public var pid: Int32; public var kind: ObservedKind
    public var menuTitle: String?    // menuItemSelected only
    public var ts: Double
}
public enum LifecycleEvent: Sendable, Equatable {
    case launched(AppInfo), terminated(AppInfo), activated(AppInfo), sleep, wake
}
public struct ElectronEnableResult: Sendable, Equatable {
    public var method: String     // "AXManualAccessibility" | "AXEnhancedUserInterface"
    public var result: String     // "ok" | "unsupported" | "failed"
}
```

### 5.4 `AXReading` protocol additions (implemented by `AXClient` — forwarding to the hub/lifecycle — and by `FakeAXClient`)
```swift
func startObserving(_ app: AppInfo, handler: @escaping @MainActor (ObservedChange) -> Void) throws
func stopObserving(pid: Int32)
func stopObservingAll()
func startLifecycle(handler: @escaping @MainActor (LifecycleEvent) -> Void)
func stopLifecycle()
func enableElectronAccessibility(_ app: AppInfo) -> ElectronEnableResult
```
`startObserving` throws `AXReadError.cannotComplete` / `.invalidElement` while an app is not ready (fresh launch); the `Capturer` retries (§6.2).

### 5.5 `Capturer` changes
New state: `observed: Set<Int32>`, `electronEnabled: Set<Int32>`, `pendingValueRefresh: [Int32: Task<Void, Never>]`, `observeFailedAt: [Int32: Double]`, injected `retryDelays: [Duration]` (default 1 s, 3 s, 10 s; tests pass milliseconds).

- **`start()`**: unchanged heartbeat loop, plus `ax.startLifecycle(handler:)`. Observers are created by the first active heartbeat's reconcile (§6.5), which also covers apps already running before the grant.
- **`observe(app)`** (§6.2): skip if not allowlisted, not trusted, or already observed. If `ElectronSupport.isElectronBundle(app.bundleURL)` and the pid is not in `electronEnabled`: call `ax.enableElectronAccessibility(app)`, record the pid, emit `app.ax_enabled`. Then `ax.startObserving(app, handler: handle(change:))`; on throw, retry per `retryDelays`, then record `observeFailedAt[pid]` and give up until reconcile.
- **`unobserve(pid)`**: cancel and drop the pending value refresh, `ax.stopObserving(pid)`, forget `lastContentCache[pid]`, `readFailures[pid]`, `observed`, `electronEnabled`, `observeFailedAt`.
- **Lifecycle handler** (§6.1). **In-app change handler** (§6.3). **`refresh(pid:trigger:freshRead:)`** (§6.3).
- **`setTrust`**: leaving `.active` → `ax.stopObservingAll()` and clear `observed` (a disabled API delivers nothing anyway); entering `.active` → the next reconcile recreates them.
- **`stop()`**: cancel all pending refreshes (dropped, not run — the daemon is exiting), `ax.stopObservingAll()`, `ax.stopLifecycle()`, then the existing finish.
- **Config reload**: after a successful reload, reconcile immediately (§6.5) so an allowlist edit takes effect without waiting for a heartbeat.

### 5.6 `HeartbeatDiff` changes
`Input` gains `trigger: Trigger = .heartbeat` where
```swift
public enum Trigger: Sendable, Equatable { case heartbeat, activation, observer(ObservedKind) }
```
`compute` is unchanged in *when* it emits the focused-context event (`appChanged || signature != state.signature`) and in how it builds the signature, hash, `valueHash` / `truncated` / `length` / `valueUnchanged` / `textSource` extras. It changes only *which kind and reason* that event carries:

| trigger | emitted kind | `extra.reason` | extra |
|---|---|---|---|
| `.heartbeat` | `context.snapshot` | `"heartbeat"` | as today |
| `.activation` | `context.snapshot` | `"observer"` | as today |
| `.observer(.focusedElementChanged)` | `element.focused` | `"observer"` | as today |
| `.observer(.focusedWindowChanged)` | `window.focused` | `"observer"` | as today |
| `.observer(.titleChanged)` | `window.title_changed` | `"observer"` | + `previousTitle` (from `previous.signature?.windowTitle`) |
| `.observer(.valueChanged)` | `element.value_changed` | `"observer"` | as today |

`app.activated` / `app.deactivated` come from the existing `appChanged` branch for every trigger. `menuItemSelected` never enters `compute` (§6.3).

### 5.7 `ElectronSupport` + `AXClient.enableElectronAccessibility`
Detection is unchanged. Enabling: `AXUIElementSetAttributeValue(appElement, "AXManualAccessibility", kCFBooleanTrue)`; on `kAXErrorAttributeUnsupported` retry with `"AXEnhancedUserInterface"`; map to `ok` / `unsupported` (both unsupported) / `failed` (any other error). This is the only write the daemon performs into another process; it is logged at info level with pid and bundle id.

## 6. Behaviour

### 6.1 Lifecycle events
- `launched(app)`: if allowlisted, emit `app.launched` and `observe(app)`.
- `terminated(app)`: if observed, emit `app.terminated` (the event keeps the app's bundle id/name) and `unobserve(app.pid)`; also drop `lastContentCache[app.pid]` even if it was never observed.
- `activated(app)`: drop any pending value refresh for the previously frontmost pid (§6.4), then `refresh(trigger: .activation, freshRead: false)`. `HeartbeatDiff`'s `appChanged` branch emits `app.deactivated` for the old allowlisted app and `app.activated` for the new one (or, with `record_other_apps`, for a non-allowlisted one with no content), followed by the new context's `context.snapshot` when the app is allowlisted. Non-allowlisted apps are never read (MVP §6.1) — `refresh` returns after the app events.
- `sleep`: drop pending value refreshes, emit `system.sleep`. `wake`: emit `system.wake`. (Observers are left in place; macOS keeps them valid across sleep.)

### 6.2 Observer creation and retries
`startObserving` for an app that has just launched commonly fails with `cannotComplete` / `invalidElement` until its AX tree is up. `observe` retries after `retryDelays` (1 s, 3 s, 10 s); each failure is logged at debug level. After the last failure it records `observeFailedAt[pid] = now` and stops; **reconcile** (§6.5) retries such a pid at most once per 60 s so a permanently unobservable app costs one attempt a minute, not one per heartbeat.

### 6.3 In-app changes
`handle(change:)`, for `ObservedChange` from the hub:
1. **Background apps cost nothing.** If `change.pid != ax.frontmostApplication()?.pid`, return. (A background tab finishing a load changes a title; it is not what the user is looking at. The next activation or heartbeat picks up the new title when it matters.)
2. `menuItemSelected`: emit `menu.item_selected` directly — app fields from the frontmost `AppInfo`, `elementTitle = change.menuTitle` — and return. No context read.
3. `valueChanged`: debounce (§6.4) and return.
4. Any other kind: drop a pending value refresh for this pid (§6.4), then `refresh(trigger: .observer(kind), freshRead: false)`.

`refresh(trigger:freshRead:)` is the heartbeat body factored out: guard `trust == .active`; `frontmost = ax.frontmostApplication()`; if allowlisted read `ax.focusedContext(of: frontmost, reusing: freshRead ? nil : lastContentCache[frontmost.pid])` — the cache is keyed on `frontmost.pid`, re-read from `ax.frontmostApplication()` on every call rather than passed in — update the cache, map `apiDisabled` → stale exactly as today; then `HeartbeatDiff.compute(previous: state, input: …, trigger:)`, emit, and merge state as today. The heartbeat itself becomes `refresh(trigger: .heartbeat, freshRead: false)` plus idle and reconcile.

### 6.4 Value debounce
Per frontmost pid, `valueChanged` starts (or restarts) a main-actor `Task` that sleeps `capture.value_debounce_ms` and then runs `refresh(trigger: .observer(.valueChanged), freshRead: true)`. `freshRead: true` bypasses the content cache: the notification itself says the value changed, so the ladder runs again and a web editor's contenteditable is re-harvested — at most once per debounce window, which bounds the cost of any storm. A refresh whose final value hashes equal to the previous one emits nothing (existing `valueUnchanged` dedup), so type-then-undo is silent.

A pending refresh is **dropped** (cancelled, not run) when focus leaves the element or the app is switched (the focused context has already moved, so a read now would attribute the wrong element), on `terminated`, on `sleep`, and on `stop`. Accepted loss: at most the trailing `value_debounce_ms` of keystrokes before a fast switch (§2).

### 6.5 Reconcile (every active heartbeat, and after a config reload)
`running = ax.runningApplications()` filtered by the allowlist. For each running allowlisted pid not in `observed` (and not within 60 s of `observeFailedAt`): `observe`. For each `observed` pid not running, or no longer allowlisted: `unobserve`. This is what creates observers for apps that were already running when the grant arrived, recreates them after a trust recovery, retries the given-up ones, and applies allowlist edits.

### 6.6 Dedup, stated once
Every path — heartbeat, activation, observer — reads the focused context and calls `HeartbeatDiff.compute` against the **same** `LastKnownState`, and the focused-context event is emitted only when `appChanged || signature != state.signature`. Therefore an observer-captured change leaves a signature the next heartbeat matches (no duplicate); a heartbeat-captured change leaves a signature a late notification matches (no duplicate); and a change no app notified still differs at the next heartbeat (`context.snapshot`, `reason: "heartbeat"` — the safety net). One mechanism, no cross-path bookkeeping.

## 7. Redaction, privacy, and writes

Unchanged and inherited: every observer-path event is built by the same `Redaction.apply` + content ladder as the heartbeat (secure fields never read, byte cap, `truncated`). `valueChanged` on a secure field triggers a refresh whose ladder yields nothing for it (secure guard), so no password text can be emitted by the debounce path either. The **only** write into another process is the Electron enable (§5.7), performed once per pid, only for allowlisted Electron bundles, logged, and recorded as `app.ax_enabled`. No network code.

## 8. Testing

**Fake (`FakeAXClient`)**: records `startObserving` calls (scriptable to throw N times, for retries), `stopObserving`, `startLifecycle`; stores handlers; `deliver(_ change: ObservedChange)` and `deliverLifecycle(_:)` invoke them; `enableElectronAccessibility` records calls and returns a scripted result; the existing `lastReusing` shows whether a refresh bypassed the cache. `Capturer` tests use `value_debounce_ms` ≤ 20 and `retryDelays` in milliseconds.

**Unit (CI, no grant):**
- `HeartbeatDiff`: each `Trigger` → expected kind and `reason`; `titleChanged` carries `previousTitle`; heartbeat output byte-identical to today for `.heartbeat`.
- Kind mapping end to end through `Capturer` for every `ObservedKind`.
- Dedup both ways: deliver a change then tick → one event; tick then deliver the same change → one event; a change with no notification → the heartbeat emits `context.snapshot`.
- Background app: a change for a pid ≠ frontmost → zero `focusedContext` calls, zero events.
- Debounce: three rapid `valueChanged` → exactly one `element.value_changed` with the final value and `lastReusing == nil`; a focus change with a refresh pending → the pending refresh never runs; type-then-undo → nothing.
- Activation via lifecycle → `app.deactivated`, `app.activated`, `context.snapshot(reason: observer)` in that order; `record_other_apps` for a non-allowlisted activation.
- Menu: `menu.item_selected` with the title, no `focusedContext` call. Sleep/wake events.
- Lifecycle: `launched` allowlisted → `app.launched` + observed; two scripted failures then success → observed after two retries; `terminated` → `app.terminated`, `stopObserving`, cache and failure counters forgotten.
- Electron: enable called once for an Electron `bundleURL` fixture, `app.ax_enabled` with method/result, never for a non-Electron app; a relaunch (new pid) enables again.
- Reconcile: newly running allowlisted app gets observed on the next tick; a gone pid is unobserved; a failed pid is not retried within 60 s and is after; allowlist reload observes/unobserves immediately; trust → stale stops all, → active recreates.

**Live (gated `OPENRHYME_LIVE_AX=1`, never CI):** start an observer on the frontmost app (use TextEdit or Finder as the target — both emit focus notifications on re-activation), then activate another app with `NSRunningApplication.activate` and re-activate the original; assert the lifecycle `activated` events and at least one `ObservedChange` arrive on the main thread within 2 s — the end-to-end proof of §4.1 with a real `AXObserver` — and print the measured activation latency.

## 9. Performance

Per in-app notification for the frontmost app: no read in the callback (menu: one title read); `refresh` = the gate's identity read plus a cache hit (~2–3 IPC) unless the cheap identity changed, in which case the ladder runs once — the same cost the heartbeat pays today, just sooner. `valueChanged`: at most one ladder run per `value_debounce_ms`. Background-app notifications: zero reads. Heartbeat: unchanged, plus one `runningApplications()` call for reconcile (an `NSWorkspace` query — no AX IPC). The MVP ≤ 2 % CPU target stands; the daemon does no tree walk beyond the bounded content harvest already accepted in the content-extraction slice.

## 10. Modules touched

| File | Change |
|---|---|
| `Sources/Capture/AXObserverHub.swift` | **New.** §5.1. |
| `Sources/Capture/AppLifecycle.swift` | **New.** §5.2. |
| `Sources/Capture/AXTypes.swift` | §5.3 types; §5.4 protocol additions. |
| `Sources/Capture/AXClient.swift` | Owns a hub + lifecycle; forwards §5.4; `enableElectronAccessibility`. |
| `Sources/Capture/ElectronSupport.swift` | `ElectronEnableResult`; the attribute names. |
| `Sources/Capture/Capturer.swift` | §5.5 / §6: observe/unobserve, lifecycle + change handlers, `refresh`, debounce, reconcile, trust/stop hooks. |
| `Sources/Capture/HeartbeatDiff.swift` | `Trigger` input; kind/reason mapping; `previousTitle`. |
| `Tests/CaptureTests/FakeAXClient.swift`, `CapturerTests.swift`, `HeartbeatDiffTests.swift`, new `ObserverTests.swift`, gated `LiveObserverTests.swift` | §8. |
| `docs/accessibility-api.md` §5.1, `CLAUDE.md` State, `README.md` | As-shipped notes incl. the §4.1 verified fact. |

Untouched: `Store`, schema (v1), CLI output, `Sources/openrhyme` (no run-loop pump needed, §4.1), the MCP repo.

## 11. Deferred, on purpose

`window.created`/`destroyed`, `element.selection_changed`, `app.opaque`, a `status` field for Electron enabling, element-held value flush, event tap, `launchd`, compaction tiers.
