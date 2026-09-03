# The macOS Accessibility API, from a capture daemon's point of view

Status: research notes, 2026-09-01. Purpose: explain what the API *is*, what a request and a response look like, which pieces OpenRhyme's `Capture` module needs, and the traps verified while researching. Constant and function names were taken from the macOS 26.5 SDK headers (`HIServices.framework/Headers/AX*.h`, `CoreGraphics.framework/Headers/CGEvent*.h`), not from memory.

## 1. Mental model

- Every app built on AppKit/SwiftUI (and Chromium, WebKit, Electron once enabled) maintains an **accessibility tree** mirroring its UI: application → windows → groups → controls and text → … It exists so VoiceOver can read the screen aloud, which is why it must be able to expose on-screen text.
- Your process never touches that tree directly. You hold an `AXUIElementRef` — an **opaque handle** (target pid + token). Every attribute read is a **synchronous Mach IPC round-trip** into the target app, answered on *its* main thread. That is why calls can hang (busy app), fail (`kAXErrorCannotComplete`), and why walking a tree is expensive: N elements × M attributes = N×M round-trips.
- Two ways to get data: **pull** (ask an element for an attribute) and **push** (register an `AXObserver`, get told when something changed, then pull the details). A good always-on daemon is push-first.
- Coverage is per-app and volunteered by the app. AppKit provides it for free. Chromium/Electron build the tree lazily, only once they believe an assistive client is present (§6.1). Custom-rendered UIs (games, some Qt/OpenGL/Flutter apps, many terminals) expose little beyond a window.
- Separate from AX: **CGEvent taps** (CoreGraphics) deliver raw input events — keys, clicks, scroll — system-wide. Different API, different permission (§5.2).

## 2. Permissions: two grants, not one

| Grant (System Settings → Privacy & Security) | Unlocks | Check | Request |
|---|---|---|---|
| **Accessibility** | reading any app's AX tree; `AXObserver`; *active* (modifying) event taps | `AXIsProcessTrustedWithOptions(nil)` | `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` — shows the system dialog once |
| **Input Monitoring** | *listen-only* `CGEventTap` for keyboard/mouse | `CGPreflightListenEventAccess()` | `CGRequestListenEventAccess()` |

The spec (§2, §5.2) only discusses Accessibility. Facts to design around:

- Accessibility is **all-or-nothing** across apps. Scoping must be implemented by us (the allowlist), and macOS will not help enforce it.
- A process holding Accessibility already passes the Input Monitoring check for listen-only taps, but request both explicitly so the status UI tells the truth.
- **Identity is the code signature.** TCC stores a code-signing requirement next to each grant. An ad-hoc-signed binary (what `swift build` produces) is identified by its `cdhash`, which changes on every build → the grant silently vanishes after each rebuild. Fixes: sign with a stable self-signed certificate or a Developer ID; during development, `tccutil reset Accessibility` and re-grant.
- **Responsible process.** Launched from Terminal / iTerm / an IDE's terminal, TCC attributes the request to *that terminal app*. Granting Accessibility to Terminal makes `swift run openrhyme` work; that is a dev convenience, not the product path. Under `launchd` the binary is its own responsible process.
- `kAXErrorAPIDisabled` (−25211) is what you get when the grant is missing **or the TCC cache went stale after a macOS update**. Treat it as a *state*, not an error: re-check trust, back off exponentially, surface it in `status`, and never spin.

## 3. The request/response model

### 3.1 Getting a handle

| Call | Returns |
|---|---|
| `AXUIElementCreateSystemWide()` | the system-wide element. Ask it `kAXFocusedApplicationAttribute` / `kAXFocusedUIElementAttribute` to find where the user is *right now* |
| `AXUIElementCreateApplication(pid)` | the root element of one app; its children are windows, the menu bar, … |
| `AXUIElementCopyElementAtPosition(app, x, y, &out)` | hit-test: the element under a screen point (pair with click events) |
| `AXUIElementGetPid(element, &pid)` | which process an element belongs to |

### 3.2 The core request

**Request = (element, attribute name). Response = (AXError, CFTypeRef value).**

```c
AXError AXUIElementCopyAttributeValue(AXUIElementRef element,
                                      CFStringRef    attribute,
                                      CFTypeRef     *value);
```

| Variant | Use it for |
|---|---|
| `AXUIElementCopyAttributeNames(element, &names)` | discover what an element supports; cache per (app, role) |
| `AXUIElementCopyMultipleAttributeValues(element, names, options, &values)` | **one IPC for N attributes** — what the capture loop should use |
| `AXUIElementGetAttributeValueCount` / `AXUIElementCopyAttributeValues(element, attr, index, maxCount, &out)` | paged access to large arrays (children, rows) |
| `AXUIElementCopyParameterizedAttributeNames` / `…CopyParameterizedAttributeValue(element, attr, parameter, &out)` | attributes that take an argument, e.g. the text for a character range |
| `AXUIElementIsAttributeSettable` / `AXUIElementSetAttributeValue` | the write path; the daemon uses it only to set `AXManualAccessibility` / `AXEnhancedUserInterface` (§6.1) |
| `AXUIElementCopyActionNames` / `AXUIElementPerformAction` | not needed for read-only capture |
| `AXUIElementSetMessagingTimeout(element, seconds)` | per-element IPC timeout; pass the system-wide element to set it globally for this process. **Always set it** — one hung app must not stall capture |

### 3.3 Response value types

The `CFTypeRef` is one of `CFString`, `CFNumber` / `CFBoolean`, `AXUIElementRef`, `CFArray` (of elements or strings), `CFURL`, `CFAttributedString`, or an **`AXValueRef`** box. Unbox with `AXValueGetValue(value, type, &out)` where `type` ∈ `kAXValueTypeCGPoint`, `…CGSize`, `…CGRect`, `…CFRange`, `…AXError`. In Swift, switch on `CFGetTypeID(v)` against `AXUIElementGetTypeID()`, `AXValueGetTypeID()`, `CFStringGetTypeID()` …, or wrap it in a small enum.

### 3.4 Errors — the complete list from `AXError.h`

| Constant | Value | Meaning | Daemon response |
|---|---|---|---|
| `kAXErrorSuccess` | 0 | | |
| `kAXErrorFailure` | −25200 | generic failure | log, skip this read |
| `kAXErrorIllegalArgument` | −25201 | bad arguments | our bug |
| `kAXErrorInvalidUIElement` | −25202 | element no longer exists (window closed) | drop the cached element |
| `kAXErrorInvalidUIElementObserver` | −25203 | observer is invalid | recreate the observer |
| `kAXErrorCannotComplete` | −25204 | target busy, hung, or has no AX support (Qt, OpenGL) | it is a timeout; after N in a row mark the app *degraded* |
| `kAXErrorAttributeUnsupported` | −25205 | element lacks this attribute | expected — fall through to the next attribute (§6.2) |
| `kAXErrorActionUnsupported` | −25206 | | n/a |
| `kAXErrorNotificationUnsupported` | −25207 | app does not emit this notification | skip that subscription |
| `kAXErrorNotImplemented` | −25208 | app has no accessibility at all | mark the app *opaque* |
| `kAXErrorNotificationAlreadyRegistered` | −25209 | | treat as success |
| `kAXErrorNotificationNotRegistered` | −25210 | | ignore on removal |
| `kAXErrorAPIDisabled` | −25211 | **no trust, or stale TCC cache** | recovery loop (§2) |
| `kAXErrorNoValue` | −25212 | attribute exists but is empty | nil |
| `kAXErrorParameterizedAttributeUnsupported` | −25213 | | fall back to the non-parameterized read |
| `kAXErrorNotEnoughPrecision` | −25214 | | rare |

## 4. What to ask for

`AXAttributeConstants.h` defines 152 attribute constants; roughly 25 matter here.

**Identity / structure** — `kAXRoleAttribute`, `kAXSubroleAttribute`, `kAXRoleDescriptionAttribute`, `kAXIdentifierAttribute` (developer-set, stable across runs), `kAXParentAttribute`, `kAXChildrenAttribute`, `kAXVisibleChildrenAttribute`, `kAXTopLevelUIElementAttribute`, `kAXWindowAttribute`.

**What / where** — `kAXTitleAttribute`, `kAXDescriptionAttribute`, `kAXHelpAttribute`, `kAXPlaceholderValueAttribute`, `kAXURLAttribute` (browsers: the page URL on the web area or address field), `kAXDocumentAttribute` (the file URL a window shows — editors, IDEs, Preview), `kAXFilenameAttribute`.

**Content** — `kAXValueAttribute` (text fields/areas: the text; sliders: a number; checkboxes: 0/1), `kAXSelectedTextAttribute`, `kAXSelectedTextRangeAttribute`, `kAXNumberOfCharactersAttribute`, `kAXVisibleCharacterRangeAttribute`, `kAXInsertionPointLineNumberAttribute`, plus parameterized `kAXStringForRangeParameterizedAttribute` / `kAXBoundsForRangeParameterizedAttribute` to read a *window* of text instead of a multi-megabyte buffer.

**Focus / app state** (ask the app element or the system-wide element) — `kAXFocusedApplicationAttribute`, `kAXFocusedUIElementAttribute`, `kAXFocusedWindowAttribute`, `kAXMainWindowAttribute`, `kAXWindowsAttribute`, `kAXFrontmostAttribute`, `kAXHiddenAttribute`, `kAXMinimizedAttribute`, `kAXEnabledAttribute`, `kAXFocusedAttribute`, `kAXPositionAttribute`, `kAXSizeAttribute`.

**Roles you will meet most** (`AXRoleConstants.h`) — `kAXApplicationRole`, `kAXWindowRole`, `kAXGroupRole`, `kAXTextFieldRole`, `kAXTextAreaRole`, `kAXStaticTextRole`, `kAXButtonRole`, `kAXMenuBarRole` / `kAXMenuItemRole`, `kAXTabGroupRole`, `kAXTableRole` / `kAXOutlineRole` / `kAXRowRole` / `kAXCellRole`, `kAXScrollAreaRole`, `kAXBrowserRole`, `kAXUnknownRole`. Web content appears under the role string `AXWebArea` (WebKit/Chromium); the web-specific constants live in `AXWebConstants.h` (e.g. `kAXDOMIdentifierAttribute`, `kAXLoadCompleteNotification`, `kAXWebApplicationSubrole`).

**Secure fields** — subrole `kAXSecureTextFieldSubrole` (`"AXSecureTextField"`). Never read its value; suspend content capture while one is focused.

### 4.1 What a real answer looks like

TextEdit with a document open; the attributes you would pull, as pseudo-JSON:

```
systemWide.focusedApplication      → AXUIElement(pid 4123, com.apple.TextEdit)
app.focusedWindow                  → window
  window.role                      = "AXWindow"
  window.title                     = "notes.md — Edited"
  window.document                  = "file:///Users/me/notes.md"
app.focusedUIElement               → textArea
  textArea.role                    = "AXTextArea"
  textArea.numberOfCharacters      = 9120
  textArea.selectedTextRange       = {location: 1840, length: 24}
  textArea.selectedText            = "the phrase I highlighted"
  textArea.stringForRange(visible) = "…the ~2 screens of text currently visible…"
  textArea.value                   = "…entire document…"     ← avoid; use stringForRange
```

Safari/Chrome: the focused element sits inside an `AXWebArea`; the page URL is `kAXURLAttribute` on the web area, the tab title is the window title. Electron apps look like Chrome — *after* §6.1.

## 5. The event stream

### 5.1 AX notifications (`AXObserver`)

```c
AXObserverCreate(pid, callback, &observer);                        // one observer per target app
AXObserverAddNotification(observer, element, notification, refcon); // element: app root or a window/field
CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), kCFRunLoopDefaultMode);
```

- Callback type: `void (*)(AXObserverRef, AXUIElementRef element, CFStringRef notification, void *refcon)`. It is a **C function pointer**: in Swift it must be `@convention(c)` and cannot capture context — pass `self` through `refcon` with `Unmanaged.passUnretained(self).toOpaque()`.
- `AXObserverCreateWithInfoCallback` adds a `CFDictionaryRef info` argument with extra detail for some notifications.
- It fires **on the thread whose run loop you added the source to**. That thread must be spinning a `CFRunLoop` (§7).
- Observers are per-pid. Use `NSWorkspace.shared.runningApplications` at startup and `NSWorkspace.shared.notificationCenter` (`didLaunchApplicationNotification`, `didTerminateApplicationNotification`, `didActivateApplicationNotification`) to create / tear down observers.
- Registering on the **app root** element gets most app-wide notifications; value/selection changes must be registered on the *specific element* (the focused one), so re-register them on every `kAXFocusedUIElementChangedNotification`.
- Apps that don't emit a given notification answer `kAXErrorNotificationUnsupported` — subscribe opportunistically.

The 37 notifications are listed in `AXNotificationConstants.h`; the ones that matter:

| Notification | Why we care |
|---|---|
| `kAXApplicationActivatedNotification` / `kAXApplicationDeactivatedNotification` | app switch — the strongest sessionization signal |
| `kAXFocusedWindowChangedNotification`, `kAXMainWindowChangedNotification` | window / document switch |
| `kAXFocusedUIElementChangedNotification` | which control the user is in; re-subscribe value/selection here |
| `kAXTitleChangedNotification` | tab and document changes surface as *title* changes — this is how you see browser navigation |
| `kAXValueChangedNotification` | text edited: the "typing" signal, *with* content and *field-aware* |
| `kAXSelectedTextChangedNotification` | reading / highlighting |
| `kAXWindowCreatedNotification`, `kAXUIElementDestroyedNotification`, `kAXWindowMiniaturizedNotification` / `…Deminiaturized…` | window lifecycle; invalidate cached elements |
| `kAXMenuOpenedNotification` / `kAXMenuClosedNotification` / `kAXMenuItemSelectedNotification` | explicit user actions (Save, Build, Commit…) |
| `kAXLayoutChangedNotification`, `kAXRowCountChangedNotification`, `kAXSheetCreatedNotification` | noisy; probably ignore |

**As shipped** (`Sources/Capture/AXObserverHub.swift`, `AppLifecycle.swift`, `Capturer.swift`): one `AXObserver` per allowlisted pid, its source added to `CFRunLoopGetMain()`; the hub tracks the registered set and tears an observer down on `stopObserving(pid:)` / `stopObservingAll()`. Registered on the app element: focused/main window changed, focused UI element changed, title changed, menu item selected; `kAXValueChangedNotification` is re-registered to follow the focused element rather than being fixed to one control. App activation is not an `AXObserver` notification at all — it comes from `NSWorkspace` via `AppLifecycle`, alongside launch/terminate/sleep/wake. Every notification funnels into the same read-and-diff `refresh` the heartbeat uses, tagged with the trigger kind (`element.focused`, `window.focused`, `window.title_changed`, `element.value_changed`) and `extra.reason: "observer"`; value changes are debounced by `capture.value_debounce_ms` and, once the quiet period elapses, bypass the content cache so the content ladder (§6.2) re-runs. A notification for a pid that is not frontmost costs no read at all — the callback returns immediately. The 5 s heartbeat keeps running underneath as the safety net for apps or changes an observer never announced.

### 5.2 Input events (`CGEventTap`)

```swift
let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,              // this login session
    place: .headInsertEventTap,
    options: .listenOnly,                 // → Input Monitoring; cannot modify events
    eventsOfInterest: mask(.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .scrollWheel),
    callback: cCallback, userInfo: refcon)
CFRunLoopAddSource(runLoop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
```

- The callback gets `(proxy, type, event, refcon)` and returns the event unchanged (`Unmanaged.passUnretained(event)`).
- macOS **disables your tap** if the callback is slow (`kCGEventTapDisabledByTimeout`) or after certain user input (`kCGEventTapDisabledByUserInput`). Handle both event types by calling `tapEnable` again. Do nothing heavy in the callback: timestamp + type into a channel, return.
- `kCGEventMouseMoved` is a firehose — don't subscribe. Idle detection is cheaper by polling `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType:)` every few seconds.
- **Policy for OpenRhyme:** record *that* input happened (per-second key/click counts, burst boundaries), never key codes. Text already arrives through `kAXValueChangedNotification`, which is field-aware and lets secure fields be excluded. Raw key logging is a keylogger; OpenHistory made the same call ("no low-level keyboard events").

## 6. Known terrain — spec §5, re-verified 2026-09-01

### 6.1 Electron / Chromium

Chromium builds its accessibility tree only when it believes an assistive technology is present. From outside, in order:

1. Set the Electron-specific attribute **`AXManualAccessibility`** = `true` on the app element with `AXUIElementSetAttributeValue`. The spec cites electron/electron#37465 (`kAXErrorAttributeUnsupported`) as an open bug — **it is closed**: fixed by PR #38102 and shipped in Electron 23.3.2 / 24.2.0 (April 2023). Apps still on older Electron fail exactly as the spec describes, so keep the fallback.
2. Fallback: set **`AXEnhancedUserInterface`** = `true` on the app element. VoiceOver sets this; Chromium honours it. It also changes some apps' window behaviour (animation / scrolling glitches are reported), so use it only where #1 returns unsupported.
3. Chrome / Chromium also enable accessibility when they detect assistive-technology activity, and can be forced with `--force-renderer-accessibility` — not something a daemon can rely on.

Either attribute is a *write* into another process — the one place the daemon is not read-only. Make it per-app opt-in, log it, and document it in `status`.

### 6.2 Text extraction order

No single attribute works everywhere. First non-empty result wins:

1. `kAXValueAttribute` (AppKit and most native apps)
2. `kAXStringForRangeParameterizedAttribute` over `kAXVisibleCharacterRangeAttribute` (large documents), then `kAXSelectedTextAttribute`
3. `kAXDescriptionAttribute` / `kAXTitleAttribute` for static text and controls
4. Literal legacy names `"AXValueAttribute"` (old WebKit) and `"AXText"` (some Electron / CEF builds) — keep a per-app table for these

**As shipped** (`Sources/Capture/ContentExtractor.swift`, `AXClient.focusedContext(of:reusing:)`): the above collapsed into a three-rung ladder — own value (`kAXValueAttribute`, falling back to a stringified number or, for `AXStaticText`, `kAXDescriptionAttribute`/`kAXTitleAttribute`) → `kAXStringForRangeParameterizedAttribute` over `kAXVisibleCharacterRangeAttribute` → a bounded subtree harvest of `AXStaticText`/`AXHeading`/`AXLink`/`AXButton` descendants (node budget 1500, byte-capped, secure subrole skipped at every depth so a password field's text is never read even nested inside a harvested subtree). Whichever rung produces the value is recorded in `extra.textSource` (`value` / `range` / `subtree`); absent when no rung found anything.

Rungs 2–3 are the expensive part — a browser's own `value` is typically empty, so without a guard they would re-run on every heartbeat over the same page. `focusedContext` is passed the previous heartbeat's cheap identity (window title/document/url plus the focused element's role/subrole/identifier/title, all already read anyway) and only re-runs the ladder when that identity changed; on a match it reuses the cached `value`/`textSource` instead. A static page is harvested once per focus/navigation, not every heartbeat.

### 6.3 Coverage failures

Qt, Java/Swing without the AX bridge, OpenGL/Metal games, Flutter (partial), many terminal emulators (the screen is one giant `AXTextArea`, or nothing). Expect `kAXErrorCannotComplete` / `kAXErrorNotImplemented`; after N failures classify the app *opaque* and fall back to app + window title (ActivityWatch level). Report the classification in `status` so the user knows what is and isn't covered.

### 6.4 Performance rules

- Notifications first; polling only as a slow heartbeat (≥ 5 s) for apps that don't notify.
- Never walk a whole tree. Pull a fixed bundle of attributes from the focused element / window with `AXUIElementCopyMultipleAttributeValues`.
- Always set `AXUIElementSetMessagingTimeout` (something like 0.25 s on the system-wide element).
- Read big text lazily and windowed.
- Cache `AXUIElementRef`s per window; invalidate on `kAXUIElementDestroyedNotification` or `kAXErrorInvalidUIElement`.

## 7. Swift 6 concurrency and this API

- `AXUIElement`, `AXObserver`, `CFMachPort` are Core Foundation types imported as non-`Sendable` classes; the compiler will refuse to move them across isolation domains. System constants such as `kAXTrustedCheckOptionPrompt` are imported as global `let`s that strict concurrency also flags.
- Observer / tap callbacks are C function pointers that run on the run-loop thread they were registered on.
- Working pattern (chosen for the MVP, see `docs/superpowers/specs/2026-09-01-mvp-capture-engine-design.md` §3): **do all AX and `NSWorkspace` work on the main thread**. The daemon runs `RunLoop.main`; observers' sources attach there; the capture object is `@MainActor`. In a headless daemon the main thread is otherwise idle, so this is the simplest model the compiler can enforce. Hand results outward through an `AsyncStream<RawEvent>`, where `RawEvent` is a plain `Sendable` struct (pid, bundle id, kind, strings, timestamps) — never an `AXUIElement`. A dedicated capture thread behind a custom global actor remains an option if the main thread ever gets other duties (a menu-bar UI).
- If a wrapper must cross the boundary anyway, mark it `@unchecked Sendable` and document the invariant (touched only on the capture thread). Use `Unmanaged` for `refcon`.
- Verified 2026-09-02 (macOS 26.5, Swift 6 async `main`): the main `CFRunLoop` is pumped while the daemon `await`s its signal, so observer sources on `CFRunLoopGetMain()` fire with no explicit pump.

## 8. The capture loop, in prose

1. **Trust.** `AXIsProcessTrustedWithOptions` and `CGPreflightListenEventAccess`. Either false → state `needsPermission`; prompt once; poll every 5 s. Any later `kAXErrorAPIDisabled` → state `stale`; back off; tell the user to relaunch.
2. **Discover apps.** `NSWorkspace.shared.runningApplications` filtered by the allowlist (bundle id). Subscribe to workspace launch / terminate / activate.
3. **Per allowed app.** `AXUIElementCreateApplication(pid)`; set the messaging timeout; if Electron and opted in, set `AXManualAccessibility`. `AXObserverCreate`; add the §5.1 notifications on the app element; add the source to the capture run loop.
4. **On notification.** Identify (element, name) → pull one attribute bundle (role, subrole, title, document / URL, window title, windowed text or selection) → emit a `RawEvent`. Skip content for secure fields and denylisted apps.
5. **Input tap.** Listen-only; aggregate into per-second counters → emit `activity` events; feed idle detection.
6. **Emit** to `Store` (HOT). `Compact` reads from there; `Capture` knows nothing about sessions.

## 9. Exploring before coding

- **Accessibility Inspector** (Xcode → Open Developer Tool → Accessibility Inspector): point at any element and see its exact attributes, values, and the notifications it emits. This is how to learn a specific app's shape before writing a per-app rule.
- The first thing `openrhyme inspect` should do is dump `AXUIElementCopyAttributeNames` plus the §4 bundle for the focused element — a portable Accessibility Inspector for the terminal.
- Try it on: TextEdit (best case), Safari (web area), VS Code / Slack (Electron, before and after §6.1), Terminal, and one Qt app. That sample covers every failure class in §6.

## Sources

- macOS 26.5 SDK headers: `$(xcrun --show-sdk-path)/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Headers/{AXUIElement,AXError,AXAttributeConstants,AXNotificationConstants,AXRoleConstants,AXWebConstants}.h` and `CoreGraphics.framework/Versions/A/Headers/{CGEvent,CGEventTypes}.h`
- Electron issue #37465 (closed via PR #38102) — https://github.com/electron/electron/issues/37465 ; Electron accessibility tutorial (`AXManualAccessibility`) — https://github.com/electron/electron/blob/main/docs/tutorial/accessibility.md
- Input Monitoring vs Accessibility for event taps — https://github.com/philptr/EventTapCore , https://developer.apple.com/forums/thread/122492
- TCC identity / cdhash / self-signed certificates — https://evoleinik.com/posts/macos-dev-signing-preserve-permissions/ , https://docs.mumbli.app/for-developers/accessibility-permissions
- Production failure modes (stale TCC, `kAXErrorCannotComplete`, `apiDisabled`) — https://fazm.ai/t/macos-accessibility-automation
- OpenHistory's capture policy (no low-level keyboard events) — https://openhistory.sh/
