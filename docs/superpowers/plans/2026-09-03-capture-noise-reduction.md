# Capture Noise Reduction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the observer-era event volume by ~60 % of rows and ~35 % of stored bytes at the source — without losing any distinct content version or real transition — by comparing identities (two hashes) instead of raw strings, classifying notifications as user-driven vs ambient, and fixing five measured noise sources.

**Architecture:** A pure `TitleNormalizer` (ordered rule table) and a pure `Fingerprint` (16-hex SHA-256 over a canonical place string) feed `HeartbeatDiff`, whose change signature now compares normalized titles, carries a per-pid recent-content memory, and treats anonymous elements as transparent. `Capturer.handle(change:)` classifies each notification by `secondsSinceLastInput()` and drops ambient title/value notifications (the heartbeat samples instead), debounces user-driven titles, and settles activations. The notification set becomes configurable globally and per app, enforced by the hub. Everything stays in `Capture` + two config keys in `Core`; schema v1; the MCP repo untouched.

**Tech Stack:** Swift 6 (tools 6.0), macOS 14+, Swift Regex literals (`#/…/#`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-03-capture-noise-reduction-design.md` — read it; this plan implements §4–§7 and §9.

## Global Constraints

- Swift 6 language mode, macOS 14+. No new dependencies. No network code. No new permissions — the input signal is the existing grant-free `secondsSinceLastInput()`.
- **No storage-schema change (stays v1), no `--json` change, no MCP change.** Only additive keys inside the existing `extra` JSON: `fingerprint`, `input`.
- **Normalization never changes what is stored** — `RawEvent.windowTitle` / `elementTitle` / `value` stay raw; only what is *compared and hashed* is normalized. Every distinct content hash is stored (no similarity collapsing).
- Secure fields keep every existing guard and still emit their role-only `element.focused` row (MVP §6.5).
- Config defaults (spec §7): `user_input_window_seconds` 2.0, `content_memory_seconds` 1800, `activation_settle_ms` 200, `notifications` = all five, `apps` = none. Constant: 32 hashes per pid. `value ⇒ focus`.
- The fingerprint canonical form is a contract: `bundleID ␟ normalize(windowTitle) ␟ document ␟ urlWithoutFragment`, `␟` = U+001F, absent = empty, first 16 hex chars of SHA-256 — pinned by golden tests.
- `make format` before every commit; CI runs `swift format lint --strict`. Line length 100, 4-space indent. Swift Testing only; nothing needs a TCC grant.
- Commit messages: short single line, then exactly these two trailer lines:
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01BdcwpxNhK3QnZByv2nHgnN`.

---

## File structure

| Path | Responsibility |
|---|---|
| `Sources/Core/Config.swift` | `CaptureSettings` gains the §7 keys + `effectiveNotifications(for:)` (Task 1). |
| `Sources/Capture/TitleNormalizer.swift` | **New.** §5 rule table (Task 1). |
| `Sources/Capture/Fingerprint.swift` | **New.** §4 canonical string + hash (Task 1). |
| `Sources/Capture/AXTypes.swift` | `ElementInfo.readoutRoles` / `isReadout` / `isAnonymous`; `ContentCache.matches` on normalized titles; `ObservedKind.configName` + `kinds(fromConfig:)`; `AXReading.startObserving(_:kinds:handler:)` (Tasks 2, 5). |
| `Sources/Capture/ContentExtractor.swift` | readout short-circuit in `extract` / `resolveHit` (Task 2). |
| `Sources/Capture/HeartbeatDiff.swift` | `InputClass`; normalized signature; `fingerprint` / `input` extras; raw `lastWindowTitle` for `previousTitle`; anonymous transparency (Task 2); `RecentValueHashes` + memory (Task 3). |
| `Sources/Capture/Capturer.swift` | input classification, generalized pending refresh, activation settle (Task 4); effective kinds + re-registration (Task 5). |
| `Sources/Capture/AXObserverHub.swift`, `AXClient.swift` | register only requested kinds (Task 5). |
| `Tests/CoreTests/ConfigTests.swift`, `Tests/CaptureTests/{TitleNormalizerTests,FingerprintTests}.swift` (new), `ContentExtractorTests`, `ContentCacheTests`, `HeartbeatDiffTests`, `ObserverTests`, `FakeAXClient` | §9. |
| `docs/accessibility-api.md`, `README.md`, `CLAUDE.md` | rule table + config documented (Task 6). |

---

### Task 1: Config keys, `TitleNormalizer`, `Fingerprint` (pure)

**Files:**
- Modify: `Sources/Core/Config.swift`
- Create: `Sources/Capture/TitleNormalizer.swift`, `Sources/Capture/Fingerprint.swift`
- Test: `Tests/CoreTests/ConfigTests.swift`, `Tests/CaptureTests/TitleNormalizerTests.swift`, `Tests/CaptureTests/FingerprintTests.swift`

**Interfaces:**
- Consumes: `Core.Hashing.sha256Hex(_:)`, `JSONValue` accessors (`doubleValue`, `boolValue`, `arrayValue`, `stringValue`, `objectValue`).
- Produces: `CaptureSettings.userInputWindowSeconds: Double`, `.contentMemorySeconds: Double`, `.activationSettleMs: Int`, `.notifications: Set<String>`, `.appNotifications: [String: Set<String>]`, `CaptureSettings.allNotifications`, `func effectiveNotifications(for bundleID: String?) -> Set<String>`; `TitleNormalizer.normalize(_ title: String) -> String` and `normalize(_ title: String?) -> String?`; `Fingerprint.canonical(bundleID:windowTitle:document:url:) -> String`, `Fingerprint.compute(bundleID:windowTitle:document:url:) -> String` (16 hex).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/CoreTests/ConfigTests.swift` (inside `ConfigTests`):
```swift
    @Test func noiseReductionKeysDefaultAndParse() throws {
        let defaults = CaptureSettings()
        #expect(defaults.userInputWindowSeconds == 2)
        #expect(defaults.contentMemorySeconds == 1800)
        #expect(defaults.activationSettleMs == 200)
        #expect(defaults.notifications == CaptureSettings.allNotifications)
        #expect(defaults.appNotifications.isEmpty)

        let url = tempURL()
        try """
        {"schema":1,"allowlist":[],"capture":{
          "user_input_window_seconds":3.5,"content_memory_seconds":60,"activation_settle_ms":50,
          "notifications":["window","title","bogus"],
          "apps":{"com.cmuxterm.app":{"notifications":["value"],"note":"keep"}}}}
        """.write(to: url, atomically: true, encoding: .utf8)
        let config = try Config.load(from: url)
        #expect(config.capture.userInputWindowSeconds == 3.5)
        #expect(config.capture.contentMemorySeconds == 60)
        #expect(config.capture.activationSettleMs == 50)
        #expect(config.capture.notifications == ["window", "title"])  // unknown names dropped
        #expect(config.capture.appNotifications == ["com.cmuxterm.app": ["value"]])
        // value ⇒ focus, per app and globally
        #expect(config.capture.effectiveNotifications(for: "com.cmuxterm.app") == ["value", "focus"])
        #expect(config.capture.effectiveNotifications(for: "com.google.Chrome") == ["window", "title"])
        #expect(config.capture.effectiveNotifications(for: nil) == ["window", "title"])

        try config.save(to: url)
        let again = try Config.load(from: url)
        #expect(again.capture == config.capture)
        #expect(again.raw["capture"]?.objectValue?["apps"]?.objectValue?["com.cmuxterm.app"]?
            .objectValue?["note"]?.stringValue == "keep")  // unknown per-app keys survive
    }
```

`Tests/CaptureTests/TitleNormalizerTests.swift`:
```swift
import Testing

@testable import Capture

@Suite struct TitleNormalizerTests {
    @Test func stripsLeadingNotificationCounter() {
        #expect(TitleNormalizer.normalize("(86) Indiana State Sycamores") == "Indiana State Sycamores")
        #expect(TitleNormalizer.normalize("(1) Inbox") == "Inbox")
    }

    @Test func stripsStatusGlyphs() {
        #expect(TitleNormalizer.normalize("◑ Set up DGX Sparks hardware") == "Set up DGX Sparks hardware")
        #expect(TitleNormalizer.normalize("◐ Set up DGX Sparks hardware") == "Set up DGX Sparks hardware")
        #expect(TitleNormalizer.normalize("✳ cmux session event query") == "cmux session event query")
    }

    @Test func stripsChromeBadgesButKeepsTheAppSuffix() {
        let raw =
            "(86) Highlights | FOX College Football - YouTube - Audio playing"
            + " - High memory usage - 807 MB - Google Chrome - Pragan"
        #expect(
            TitleNormalizer.normalize(raw)
                == "Highlights | FOX College Football - YouTube - Google Chrome - Pragan")
        #expect(
            TitleNormalizer.normalize("Docs - Muted - High memory usage - 1.0 GB - Google Chrome - Pragan")
                == "Docs - Google Chrome - Pragan")
        #expect(
            TitleNormalizer.normalize("New Tab - Google Chrome - Pragan") == "New Tab - Google Chrome - Pragan")
    }

    @Test func keepsMeaningfulState() {
        #expect(TitleNormalizer.normalize("notes.md — Edited") == "notes.md — Edited")
    }

    @Test func collapsesWhitespaceAndIsIdempotent() {
        #expect(TitleNormalizer.normalize("  a   b \t c ") == "a b c")
        let once = TitleNormalizer.normalize("(3) ◐  Foo - Audio playing - Google Chrome - Pragan")
        #expect(TitleNormalizer.normalize(once) == once)
        #expect(TitleNormalizer.normalize(nil as String?) == nil)
    }
}
```

`Tests/CaptureTests/FingerprintTests.swift` (golden values computed with `shasum -a 256` over the exact canonical bytes):
```swift
import Testing

@testable import Capture

@Suite struct FingerprintTests {
    @Test func canonicalFormIsTheContract() {
        let canonical = Fingerprint.canonical(
            bundleID: "com.google.Chrome",
            windowTitle: "(86) Foo - Audio playing - Google Chrome - Pragan", document: nil,
            url: "https://x.com/p#frag")
        #expect(canonical == "com.google.Chrome\u{1F}Foo - Google Chrome - Pragan\u{1F}\u{1F}https://x.com/p")
    }

    @Test func goldenHashes() {
        #expect(
            Fingerprint.compute(
                bundleID: "com.google.Chrome",
                windowTitle: "(86) Foo - Audio playing - Google Chrome - Pragan", document: nil,
                url: "https://x.com/p#frag") == "15c45e719bd57fb5")
        #expect(
            Fingerprint.compute(bundleID: nil, windowTitle: nil, document: nil, url: nil)
                == "c60b1f6ce4ac96cd")
        #expect(
            Fingerprint.compute(
                bundleID: "com.apple.TextEdit", windowTitle: "notes.md — Edited",
                document: "/Users/me/notes.md", url: nil) == "1ed05bf577992322")
    }

    @Test func badgeFlickerAndFragmentsDoNotChangeIt() {
        let a = Fingerprint.compute(
            bundleID: "com.google.Chrome", windowTitle: "Foo - Google Chrome - Pragan", document: nil,
            url: "https://x.com/p")
        let b = Fingerprint.compute(
            bundleID: "com.google.Chrome", windowTitle: "(2) Foo - Audio playing - Google Chrome - Pragan",
            document: nil, url: "https://x.com/p#section-3")
        #expect(a == b)
        #expect(a.count == 16)
        #expect(a.allSatisfy { $0.isHexDigit })
        let other = Fingerprint.compute(
            bundleID: "com.google.Chrome", windowTitle: "Bar - Google Chrome - Pragan", document: nil,
            url: "https://x.com/q")
        #expect(a != other)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter "ConfigTests|TitleNormalizerTests|FingerprintTests"`
Expected: build errors — `userInputWindowSeconds`, `TitleNormalizer`, `Fingerprint` not found.

- [ ] **Step 3: Implement**

In `Sources/Core/Config.swift`, replace the whole `CaptureSettings` struct with:
```swift
public struct CaptureSettings: Sendable, Equatable {
    public var heartbeatSeconds: Double = 5
    public var idleSeconds: Double = 120
    public var valueDebounceMs: Int = 500
    public var maxValueBytes: Int = 524_288
    public var recordOtherApps: Bool = false
    /// Spec 2026-09-03 §6.1: input within this many seconds ⇒ a notification is user-driven.
    public var userInputWindowSeconds: Double = 2
    /// Spec §6.3: how long a stored value's hash suppresses re-storing the same body.
    public var contentMemorySeconds: Double = 1800
    /// Spec §6.6: how long to wait after an app activation before reading the focused context.
    public var activationSettleMs: Int = 200
    /// Spec §6.7: the global notification set. Names: window, focus, title, value, menu.
    public var notifications: Set<String> = CaptureSettings.allNotifications
    /// Spec §6.7: per-app overrides by bundle id.
    public var appNotifications: [String: Set<String>] = [:]

    public static let allNotifications: Set<String> = ["window", "focus", "title", "value", "menu"]

    public init() {}

    static let keys = (
        heartbeat: "heartbeat_seconds", idle: "idle_seconds", debounce: "value_debounce_ms",
        maxValue: "max_value_bytes", others: "record_other_apps",
        inputWindow: "user_input_window_seconds", contentMemory: "content_memory_seconds",
        settle: "activation_settle_ms", notifications: "notifications", apps: "apps"
    )

    init(json: [String: JSONValue]) {
        self.init()
        if let v = json[Self.keys.heartbeat]?.doubleValue { heartbeatSeconds = v }
        if let v = json[Self.keys.idle]?.doubleValue { idleSeconds = v }
        if let v = json[Self.keys.debounce]?.doubleValue, let exact = Int(exactly: v) {
            valueDebounceMs = exact
        }
        if let v = json[Self.keys.maxValue]?.doubleValue, let exact = Int(exactly: v) {
            maxValueBytes = exact
        }
        if let v = json[Self.keys.others]?.boolValue { recordOtherApps = v }
        if let v = json[Self.keys.inputWindow]?.doubleValue { userInputWindowSeconds = v }
        if let v = json[Self.keys.contentMemory]?.doubleValue { contentMemorySeconds = v }
        if let v = json[Self.keys.settle]?.doubleValue, let exact = Int(exactly: v) {
            activationSettleMs = exact
        }
        if let names = json[Self.keys.notifications]?.arrayValue {
            notifications = Self.knownNames(names)
        }
        if let apps = json[Self.keys.apps]?.objectValue {
            for (bundleID, value) in apps {
                if let names = value.objectValue?[Self.keys.notifications]?.arrayValue {
                    appNotifications[bundleID] = Self.knownNames(names)
                }
            }
        }
    }

    private static func knownNames(_ values: [JSONValue]) -> Set<String> {
        Set(values.compactMap(\.stringValue)).intersection(allNotifications)
    }

    /// The set in force for a bundle id: its override if present, else the global default, with
    /// `value ⇒ focus` — value changes are registered on the focused element and must follow it.
    public func effectiveNotifications(for bundleID: String?) -> Set<String> {
        var set = bundleID.flatMap { appNotifications[$0] } ?? notifications
        if set.contains("value") { set.insert("focus") }
        return set
    }

    func merged(into json: [String: JSONValue]) -> [String: JSONValue] {
        var out = json
        out[Self.keys.heartbeat] = .number(heartbeatSeconds)
        out[Self.keys.idle] = .number(idleSeconds)
        out[Self.keys.debounce] = .number(Double(valueDebounceMs))
        out[Self.keys.maxValue] = .number(Double(maxValueBytes))
        out[Self.keys.others] = .bool(recordOtherApps)
        out[Self.keys.inputWindow] = .number(userInputWindowSeconds)
        out[Self.keys.contentMemory] = .number(contentMemorySeconds)
        out[Self.keys.settle] = .number(Double(activationSettleMs))
        out[Self.keys.notifications] = .array(notifications.sorted().map(JSONValue.string))
        var apps = json[Self.keys.apps]?.objectValue ?? [:]
        for (bundleID, names) in appNotifications {
            var entry = apps[bundleID]?.objectValue ?? [:]
            entry[Self.keys.notifications] = .array(names.sorted().map(JSONValue.string))
            apps[bundleID] = .object(entry)
        }
        out[Self.keys.apps] = .object(apps)
        return out
    }
}
```

`Sources/Capture/TitleNormalizer.swift`:
```swift
import Foundation

/// Spec 2026-09-03 §5: a title with its volatile parts removed. Used only for comparing and
/// hashing — the stored title is always the raw one. Rules are ordered; each has a test.
public enum TitleNormalizer {
    /// Rule 2: glyphs apps animate in titles (cmux / Claude Code spinners, status bullets).
    static let statusGlyphs: Set<Character> = [
        "◐", "◑", "◒", "◓", "◌", "✳", "✶", "✷", "✸", "⏳", "⌛", "●", "○", "◉",
    ]
    /// Rule 1: a leading notification counter such as "(86) ".
    private static let leadingCounter = #/^\(\d+\)\s+/#
    /// Rule 3: Chrome tab badges. Data-driven; extend here, with a test.
    private static let chromeBadges = [
        #/ - Audio playing/#, #/ - Muted/#, #/ - High memory usage - [\d.,]+ [KMG]B/#,
    ]
    /// Rule 4.
    private static let whitespace = #/\s+/#

    public static func normalize(_ title: String) -> String {
        var text = title.replacing(leadingCounter, with: "")
        text.removeAll(where: { statusGlyphs.contains($0) })
        for badge in chromeBadges { text = text.replacing(badge, with: "") }
        text = text.replacing(whitespace, with: " ")
        return text.trimmingCharacters(in: .whitespaces)
    }

    public static func normalize(_ title: String?) -> String? {
        title.map { normalize($0) }
    }
}
```

`Sources/Capture/Fingerprint.swift`:
```swift
import Core
import Foundation

/// Spec 2026-09-03 §4: the place-level identity of what is on screen — app + normalized window
/// title + document + URL without fragment — as the first 16 hex characters of SHA-256 over a
/// canonical string. A contract: Compact groups entities and visits by it, so its form is
/// pinned by golden tests. Deliberately never includes element identity.
public enum Fingerprint {
    static let separator = "\u{1F}"

    public static func canonical(
        bundleID: String?, windowTitle: String?, document: String?, url: String?
    ) -> String {
        [
            bundleID ?? "", TitleNormalizer.normalize(windowTitle) ?? "", document ?? "",
            withoutFragment(url) ?? "",
        ].joined(separator: separator)
    }

    public static func compute(
        bundleID: String?, windowTitle: String?, document: String?, url: String?
    ) -> String {
        let digest = Hashing.sha256Hex(
            canonical(bundleID: bundleID, windowTitle: windowTitle, document: document, url: url))
        return String(digest.prefix(16))
    }

    static func withoutFragment(_ url: String?) -> String? {
        guard let url, let hash = url.firstIndex(of: "#") else { return url }
        return String(url[..<hash])
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter "ConfigTests|TitleNormalizerTests|FingerprintTests"` then the full `swift test`.
Expected: the new tests pass (the golden hashes match exactly); every pre-existing test unchanged (all new config fields have defaults, so `CaptureSettings()` equality in `missingFileYieldsDefaults` still holds).

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Core/Config.swift Sources/Capture/TitleNormalizer.swift Sources/Capture/Fingerprint.swift Tests/CoreTests/ConfigTests.swift Tests/CaptureTests/TitleNormalizerTests.swift Tests/CaptureTests/FingerprintTests.swift
git commit -m "Add noise-reduction config keys, title normalizer, and place fingerprint

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BdcwpxNhK3QnZByv2nHgnN"
```

---

### Task 2: Normalized signature, `fingerprint` / `input` extras, anonymous transparency, readout roles

**Files:**
- Modify: `Sources/Capture/AXTypes.swift`, `Sources/Capture/ContentExtractor.swift`, `Sources/Capture/HeartbeatDiff.swift`
- Test: `Tests/CaptureTests/HeartbeatDiffTests.swift`, `ContentExtractorTests.swift`, `ContentCacheTests.swift`

**Interfaces:**
- Consumes: `TitleNormalizer.normalize`, `Fingerprint.compute` (Task 1); `Redaction.apply`, `Hashing.sha256Hex`.
- Produces: `ElementInfo.readoutRoles: Set<String>`, `.isReadout`, `.isAnonymous`; `ContentCache.matches` comparing normalized titles; `InputClass { user, ambient }` (raw values `"user"` / `"ambient"`); `HeartbeatDiff.Input.input: InputClass?` (new **last** init parameter, default nil); `LastKnownState.lastWindowTitle: String?` (raw title of the last seen state); `ContextSignature.windowTitle` / `.elementTitle` now hold **normalized** titles; `extra.fingerprint` on every focused-context event; `extra.input` when given; `extra.previousTitle` is the **raw** previous title.

- [ ] **Step 1: Write the failing tests**

In `Tests/CaptureTests/HeartbeatDiffTests.swift`, give the private `input(...)` helper one more trailing parameter `input: InputClass? = nil` and pass `input: input` to `HeartbeatDiff.Input(...)`. Then add:
```swift
    @Test func badgeFlickerIsNotAChangeAndRawTitleIsStored() {
        let raw = "Doc - Audio playing - Google Chrome - Pragan"
        let first = HeartbeatDiff.compute(
            previous: LastKnownState(), input: input(safari, window: WindowInfo(title: raw)))
        #expect(first.events.last?.windowTitle == raw)
        let second = HeartbeatDiff.compute(
            previous: first.state,
            input: input(
                safari, window: WindowInfo(title: "(3) Doc - Google Chrome - Pragan"),
                trigger: .observer(.titleChanged)))
        #expect(second.events.isEmpty)
    }

    @Test func fingerprintIsPresentAndStableAcrossFlicker() {
        let out = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(
                safari,
                window: WindowInfo(title: "(9) Doc - Muted - Google Chrome - Pragan", url: "https://x.com/p#top")))
        let fingerprint = out.events.last?.extra?["fingerprint"]?.stringValue
        #expect(fingerprint?.count == 16)
        #expect(
            fingerprint
                == Fingerprint.compute(
                    bundleID: "com.apple.Safari", windowTitle: "Doc - Google Chrome - Pragan",
                    document: nil, url: "https://x.com/p"))
    }

    @Test func inputClassIsCarriedOnlyWhenGiven() {
        let tagged = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(
                safari, window: WindowInfo(title: "A"), trigger: .observer(.focusedElementChanged),
                input: .ambient))
        #expect(tagged.events.last?.extra?["input"] == "ambient")
        let plain = HeartbeatDiff.compute(
            previous: LastKnownState(), input: input(safari, window: WindowInfo(title: "A")))
        #expect(plain.events.last?.extra?["input"] == nil)
    }

    @Test func previousTitleIsTheRawTitle() {
        let old = "(2) Old - Audio playing - Google Chrome - Pragan"
        let first = HeartbeatDiff.compute(
            previous: LastKnownState(), input: input(safari, window: WindowInfo(title: old)))
        let second = HeartbeatDiff.compute(
            previous: first.state,
            input: input(
                safari, window: WindowInfo(title: "New - Google Chrome - Pragan"),
                trigger: .observer(.titleChanged)))
        #expect(second.events.map(\.kind) == [.windowTitleChanged])
        #expect(second.events[0].extra?["previousTitle"] == .string(old))
    }

    @Test func anonymousElementIsTransparentToChangeDetection() {
        let page = ElementInfo(role: "AXWebArea", value: "page body")
        let button = ElementInfo(role: "AXButton")
        let s1 = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(safari, window: WindowInfo(title: "A"), element: page))
        let s2 = HeartbeatDiff.compute(
            previous: s1.state,
            input: input(
                safari, window: WindowInfo(title: "A"), element: button,
                trigger: .observer(.focusedElementChanged)))
        #expect(s2.events.isEmpty)
        let s3 = HeartbeatDiff.compute(
            previous: s2.state,
            input: input(
                safari, window: WindowInfo(title: "A"), element: page,
                trigger: .observer(.focusedElementChanged)))
        #expect(s3.events.isEmpty)
    }

    @Test func anonymousClickThatNavigatesEmitsOneRow() {
        let s1 = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(
                safari, window: WindowInfo(title: "A"),
                element: ElementInfo(role: "AXWebArea", value: "page body")))
        let s2 = HeartbeatDiff.compute(
            previous: s1.state,
            input: input(
                safari, window: WindowInfo(title: "B"), element: ElementInfo(role: "AXButton"),
                trigger: .observer(.focusedWindowChanged)))
        #expect(s2.events.map(\.kind) == [.windowFocused])
        #expect(s2.events[0].value == nil)
    }

    @Test func secureFieldStillEmitsItsRoleOnlyRow() {
        let s1 = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(
                safari, window: WindowInfo(title: "Login"),
                element: ElementInfo(role: "AXWebArea", value: "form")))
        let secure = ElementInfo(role: "AXTextField", subrole: "AXSecureTextField", value: "hunter2")
        let s2 = HeartbeatDiff.compute(
            previous: s1.state,
            input: input(
                safari, window: WindowInfo(title: "Login"), element: secure,
                trigger: .observer(.focusedElementChanged)))
        #expect(s2.events.map(\.kind) == [.elementFocused])
        #expect(s2.events[0].subrole == "AXSecureTextField")
        #expect(s2.events[0].value == nil)
    }
```
Append to `ContentExtractorTests` (uses its private `Node` fake):
```swift
    @Test func readoutRolesYieldNoText() {
        let slider = Node(role: "AXSlider", value: "0 Minutes 1 Seconds of 8 Minutes 20 Seconds")
        #expect(ContentExtractor.extract(from: slider, maxBytes: 1000) == ExtractedText())
        #expect(
            ContentExtractor.resolveHit(from: slider, cachedValue: "old", cachedSource: .value)
                == ExtractedText())
    }
```
Append to `ContentCacheTests`:
```swift
    @Test func matchesAcrossBadgeFlicker() {
        let cache = ContentCache(
            role: "AXWebArea", windowTitle: "Doc - Audio playing - Google Chrome - Pragan",
            url: "https://x")
        #expect(
            cache.matches(
                role: "AXWebArea", subrole: nil, identifier: nil, title: nil,
                windowTitle: "(4) Doc - Google Chrome - Pragan", document: nil, url: "https://x"))
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter "HeartbeatDiffTests|ContentExtractorTests|ContentCacheTests"`
Expected: build error (`InputClass`, `input:` label) and the new assertions failing.

- [ ] **Step 3: Implement**

`Sources/Capture/AXTypes.swift` — inside `ElementInfo`, after `isSecure`:
```swift
    /// Spec 2026-09-03 §6.5: controls whose value is a numeric readout, never content.
    public static let readoutRoles: Set<String> = [
        "AXSlider", "AXProgressIndicator", "AXValueIndicator", "AXScrollBar",
    ]
    public var isReadout: Bool { role.map(Self.readoutRoles.contains) ?? false }

    /// Spec §6.4: nothing identifies this element — no title, identifier, value or selection.
    /// A secure field is never anonymous: its role-only row is a deliberate signal (MVP §6.5).
    public var isAnonymous: Bool {
        !isSecure && (title ?? "").isEmpty && (identifier ?? "").isEmpty
            && (value ?? "").isEmpty && (selectedText ?? "").isEmpty
    }
```
Replace the body of `ContentCache.matches` with:
```swift
        self.role == role && self.subrole == subrole && self.identifier == identifier
            && TitleNormalizer.normalize(self.title) == TitleNormalizer.normalize(title)
            && TitleNormalizer.normalize(self.windowTitle) == TitleNormalizer.normalize(windowTitle)
            && self.document == document && self.url == url
```

`Sources/Capture/ContentExtractor.swift` — in BOTH `extract` and `resolveHit`, right after the `secureSubrole` check, add:
```swift
        if let role = node.role, ElementInfo.readoutRoles.contains(role) { return ExtractedText() }
```

`Sources/Capture/HeartbeatDiff.swift`:
- Add after the `ContextSignature` struct: 
```swift
/// Spec 2026-09-03 §6.1: whether the user's input caused an observer notification.
public enum InputClass: String, Sendable {
    case user
    case ambient
}
```
  and make `HeartbeatDiff.Input` reference it as `InputClass` (top-level, `Capture` module). Update the `ContextSignature` doc comment to say `windowTitle` / `elementTitle` are **normalized** (`TitleNormalizer`).
- In `LastKnownState`, add `public var lastWindowTitle: String?` (doc: raw title of the last seen state, for `previousTitle`).
- In `Input`, add `public var input: InputClass?` and the **last** init parameter `input: InputClass? = nil` with `self.input = input`.
- In `compute`, replace everything from `let redacted = Redaction.apply(...)` down to (and including) `state.signature = signature` with:
```swift
        let element = context.element
        let redacted = Redaction.apply(element, maxValueBytes: input.maxValueBytes)
        let hash = redacted.value.map(Hashing.sha256Hex)
        var signature = ContextSignature(
            pid: app.pid, windowTitle: TitleNormalizer.normalize(context.window?.title),
            document: context.window?.document, url: context.window?.url, role: element?.role,
            subrole: element?.subrole, identifier: element?.identifier,
            elementTitle: TitleNormalizer.normalize(element?.title),
            selectedText: redacted.selectedText, valueHash: hash)
        // Spec §6.4: an anonymous element is transparent — the previous element carries forward.
        if let element, element.isAnonymous, let prev = previous.signature, prev.pid == app.pid {
            signature.role = prev.role
            signature.subrole = prev.subrole
            signature.identifier = prev.identifier
            signature.elementTitle = prev.elementTitle
            signature.selectedText = prev.selectedText
            signature.valueHash = prev.valueHash
        }

        if appChanged || signature != state.signature {
            let valueUnchanged = hash != nil && hash == state.signature?.valueHash
            var extra: [String: JSONValue] = ["reason": .string(input.trigger.reason)]
            extra["fingerprint"] = .string(
                Fingerprint.compute(
                    bundleID: app.bundleID, windowTitle: context.window?.title,
                    document: context.window?.document, url: context.window?.url))
            if let inputClass = input.input { extra["input"] = .string(inputClass.rawValue) }
            if let hash {
                extra["valueHash"] = .string(hash)
                extra["truncated"] = .bool(redacted.truncated)
                extra["length"] = .number(Double(redacted.length))
            }
            if valueUnchanged { extra["valueUnchanged"] = true }
            if let textSource = element?.textSource {
                extra["textSource"] = .string(textSource)
            }
            if case .observer(.titleChanged) = input.trigger,
                let previousTitle = previous.lastWindowTitle
            {
                extra["previousTitle"] = .string(previousTitle)
            }
            events.append(
                RawEvent(
                    ts: input.now, kind: input.trigger.kind, pid: app.pid, bundleID: app.bundleID,
                    appName: app.name, windowTitle: context.window?.title,
                    document: context.window?.document, url: context.window?.url,
                    role: element?.role, subrole: element?.subrole,
                    identifier: element?.identifier, elementTitle: element?.title,
                    value: valueUnchanged ? nil : redacted.value,
                    selectedText: redacted.selectedText, extra: extra))
        }
        state.signature = signature
        state.lastWindowTitle = context.window?.title
```
(The `RawEvent` is still built from the **raw** `context.window?.title` and `element?.title`; only the signature and the fingerprint use normalized forms.)

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter "HeartbeatDiffTests|ContentExtractorTests|ContentCacheTests"` then full `swift test`.
Expected: the 9 new tests pass; every pre-existing test still passes (raw ≡ normalized for all existing fixture titles such as `"Apple"` and `"a.md — Edited"`; `previousTitle` for `"Old"`→`"New"` unchanged).

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Capture/AXTypes.swift Sources/Capture/ContentExtractor.swift Sources/Capture/HeartbeatDiff.swift Tests/CaptureTests/HeartbeatDiffTests.swift Tests/CaptureTests/ContentExtractorTests.swift Tests/CaptureTests/ContentCacheTests.swift
git commit -m "Compare normalized identities and stamp fingerprints on context events

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BdcwpxNhK3QnZByv2nHgnN"
```

---

### Task 3: Recent-content memory

**Files:**
- Modify: `Sources/Capture/HeartbeatDiff.swift`, `Sources/Capture/Capturer.swift` (one argument)
- Test: `Tests/CaptureTests/HeartbeatDiffTests.swift`

**Interfaces:**
- Consumes: `compute` as left by Task 2; `config.capture.contentMemorySeconds` (Task 1).
- Produces: `RecentValueHashes` (`capacity = 32`, `entries`, `contains(_:now:ttl:)`, `insert(_:now:ttl:)`); `LastKnownState.recentHashes: [Int32: RecentValueHashes]`; `HeartbeatDiff.Input.contentMemorySeconds: Double` (new **last** init parameter, default 1800); `valueUnchanged` is now true when the hash equals the previous state's **or** was stored for this pid within the memory window.

- [ ] **Step 1: Write the failing tests** (append to `HeartbeatDiffTests`; the helper's existing `now:` parameter is used)

```swift
    @Test func recentlyStoredBodyIsNotStoredAgain() {
        let a = ElementInfo(role: "AXWebArea", value: "page A body")
        let b = ElementInfo(role: "AXWebArea", value: "page B body")
        let s1 = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(safari, window: WindowInfo(title: "A"), element: a, now: 100))
        let s2 = HeartbeatDiff.compute(
            previous: s1.state,
            input: input(safari, window: WindowInfo(title: "B"), element: b, now: 110))
        let s3 = HeartbeatDiff.compute(
            previous: s2.state,
            input: input(safari, window: WindowInfo(title: "A"), element: a, now: 120))
        #expect(s1.events.last?.value == "page A body")
        #expect(s2.events.last?.value == "page B body")
        #expect(s3.events.map(\.kind) == [.contextSnapshot])
        #expect(s3.events[0].value == nil)
        #expect(s3.events[0].extra?["valueUnchanged"] == true)
        #expect(s3.events[0].extra?["valueHash"] == .string(Hashing.sha256Hex("page A body")))
    }

    @Test func memoryExpiresAfterTheWindow() {
        let a = ElementInfo(role: "AXWebArea", value: "page A body")
        let b = ElementInfo(role: "AXWebArea", value: "page B body")
        let s1 = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(safari, window: WindowInfo(title: "A"), element: a, now: 100))
        let s2 = HeartbeatDiff.compute(
            previous: s1.state,
            input: input(safari, window: WindowInfo(title: "B"), element: b, now: 110))
        let s3 = HeartbeatDiff.compute(
            previous: s2.state,
            input: input(safari, window: WindowInfo(title: "A"), element: a, now: 100 + 1801))
        #expect(s3.events[0].value == "page A body")
        #expect(s3.events[0].extra?["valueUnchanged"] == nil)
    }

    @Test func memoryIsBoundedAtThirtyTwoPerPid() {
        var state = LastKnownState()
        for i in 0..<33 {
            state = HeartbeatDiff.compute(
                previous: state,
                input: input(
                    safari, window: WindowInfo(title: "T\(i)"),
                    element: ElementInfo(role: "AXWebArea", value: "body \(i)"),
                    now: Double(100 + i))
            ).state
        }
        #expect(state.recentHashes[10]?.entries.count == 32)
        // "body 1" is still remembered; "body 0" was evicted by the 33rd insert.
        let back1 = HeartbeatDiff.compute(
            previous: state,
            input: input(
                safari, window: WindowInfo(title: "T1"),
                element: ElementInfo(role: "AXWebArea", value: "body 1"), now: 200))
        #expect(back1.events[0].value == nil)
        let back0 = HeartbeatDiff.compute(
            previous: back1.state,
            input: input(
                safari, window: WindowInfo(title: "T0"),
                element: ElementInfo(role: "AXWebArea", value: "body 0"), now: 201))
        #expect(back0.events[0].value == "body 0")
    }

    @Test func memoryIsPerPid() {
        let body = ElementInfo(role: "AXWebArea", value: "shared body")
        let s1 = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(safari, window: WindowInfo(title: "A"), element: body, now: 100))
        let s2 = HeartbeatDiff.compute(
            previous: s1.state,
            input: input(textEdit, window: WindowInfo(title: "A"), element: body, now: 101))
        #expect(s2.events.last?.value == "shared body")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter HeartbeatDiffTests`
Expected: build error — `recentHashes` not found; then the new assertions fail.

- [ ] **Step 3: Implement**

In `Sources/Capture/HeartbeatDiff.swift`, add after `ContextSignature`:
```swift
/// Spec 2026-09-03 §6.3: the hashes of values recently stored for one pid, so a body already in
/// the store is not stored again. Bounded: at most `capacity` entries; entries older than the
/// memory window are pruned on insert.
public struct RecentValueHashes: Sendable, Equatable {
    public static let capacity = 32

    public struct Entry: Sendable, Equatable {
        public var hash: String
        public var ts: Double
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public func contains(_ hash: String, now: Double, ttl: Double) -> Bool {
        entries.contains { $0.hash == hash && now - $0.ts <= ttl }
    }

    public mutating func insert(_ hash: String, now: Double, ttl: Double) {
        entries.removeAll { $0.hash == hash || now - $0.ts > ttl }
        entries.append(Entry(hash: hash, ts: now))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    var newest: Double? { entries.last?.ts }
}
```
In `LastKnownState`, add `public var recentHashes: [Int32: RecentValueHashes] = [:]` and:
```swift
    /// Forget pids whose newest stored hash is older than the memory window.
    mutating func pruneRecentHashes(now: Double, ttl: Double) {
        recentHashes = recentHashes.filter { _, recent in
            recent.newest.map { now - $0 <= ttl } ?? false
        }
    }
```
In `Input`, add `public var contentMemorySeconds: Double` and the **last** init parameter `contentMemorySeconds: Double = 1800` with `self.contentMemorySeconds = contentMemorySeconds`.

In `compute`, inside `if appChanged || signature != state.signature {`, replace the `valueUnchanged` line with:
```swift
            let recentlyStored =
                hash.map {
                    state.recentHashes[app.pid]?.contains(
                        $0, now: input.now, ttl: input.contentMemorySeconds) ?? false
                } ?? false
            let valueUnchanged =
                hash != nil && (hash == state.signature?.valueHash || recentlyStored)
```
and, after `events.append(RawEvent(...))` but still inside the `if`, add:
```swift
            if !valueUnchanged, let hash {
                state.recentHashes[app.pid, default: RecentValueHashes()].insert(
                    hash, now: input.now, ttl: input.contentMemorySeconds)
            }
```
After `state.lastWindowTitle = context.window?.title`, add:
```swift
        state.pruneRecentHashes(now: input.now, ttl: input.contentMemorySeconds)
```
In `Sources/Capture/Capturer.swift`'s `refresh`, add `contentMemorySeconds: config.capture.contentMemorySeconds` to the `HeartbeatDiff.Input(...)` call (after `trigger: trigger`; the `input:` argument is added in Task 4 — keep the parameter order `trigger`, `input`, `contentMemorySeconds` when both exist).

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter HeartbeatDiffTests` then full `swift test`.
Expected: the 4 new tests pass; pre-existing tests unchanged (`valueUnchanged` for the immediately previous state behaves exactly as before).

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Capture/HeartbeatDiff.swift Sources/Capture/Capturer.swift Tests/CaptureTests/HeartbeatDiffTests.swift
git commit -m "Remember recently stored values per pid and stop re-storing them

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BdcwpxNhK3QnZByv2nHgnN"
```

---

### Task 4: Input-gated classification, debounced titles, activation settle

**Files:**
- Modify: `Sources/Capture/Capturer.swift`
- Test: `Tests/CaptureTests/ObserverTests.swift` (harness + 5 existing tests updated + 6 new)

**Interfaces:**
- Consumes: `InputClass`, `Input.input` (Task 2); `config.capture.userInputWindowSeconds` / `.activationSettleMs` (Task 1); `ax.secondsSinceLastInput()`.
- Produces: `handle(change:)` classifies every notification; private `scheduleRefresh(for:freshRead:input:)`, `dropPendingRefresh(for:)`, `dropAllPendingRefreshes()` replace the value-only versions; private `scheduleActivationRefresh()` + `pendingActivation`; `refresh(trigger:freshRead:input:)` gains `input: InputClass? = nil`.

- [ ] **Step 1: Update the harness and the five tests whose timing changes; add the six new tests**

In `ObserverTests.makeCapturer`, add the parameter `settleMs: Int = 5` (after `debounceMs`) and set `config.capture.activationSettleMs = settleMs` next to the debounce line.

Existing tests — exact edits (user-driven titles are now debounced, activations settle):
1. `windowAndTitleChangesMapToTheirKinds`: after the `.titleChanged` `handle(change:)` line, insert `#expect(await waitUntil { fake.focusedContextCalls == 2 })` (the first tick did one read; the debounced title refresh makes two). Assertions unchanged.
2. `observerThenHeartbeatDoesNotDuplicate`: after the `.titleChanged` `handle(change:)` line, insert `#expect(await waitUntil { fake.focusedContextCalls == 2 })` before `capturer.tick()`. Assertions unchanged.
3. `heartbeatThenLateObserverDoesNotDuplicate`: after the late `.titleChanged` `handle(change:)`, insert `#expect(await waitUntil { fake.focusedContextCalls == 3 })` before `drain` (the debounced refresh runs and finds no change). Assertions unchanged.
4. `activationEmitsAppEventsAndSnapshotInstantly` → rename to `activationEmitsAppEventsAndSnapshotAfterSettle`; after `handle(lifecycle: .activated(textEdit))`, insert `#expect(await waitUntil { fake.focusedContextCalls == 2 })` before `drain`. Assertions unchanged.
5. Replace the whole body of `activationDropsPendingValueRefreshes` with:
```swift
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
        let before = fake.focusedContextCalls
        capturer.handle(lifecycle: .activated(textEdit))
        #expect(await waitUntil { fake.focusedContextCalls == before + 1 })  // settled read
        let reads = fake.focusedContextCalls
        try await Task.sleep(for: .milliseconds(150))
        #expect(fake.focusedContextCalls == reads)  // the pending value refresh never ran
        let events = await drain(capturer)
        #expect(!events.map(\.kind).contains(.elementValueChanged))
    }
```
New tests (append):
```swift
    @Test func ambientTitleChangeIsDroppedAndTheHeartbeatSamplesIt() async throws {
        let fake = FakeAXClient()
        fake.show(safari, window: WindowInfo(title: "One"))
        let capturer = try makeCapturer(fake: fake, debounceMs: 20)
        capturer.tick()
        fake.idleSeconds = 30  // no input for 30 s ⇒ ambient
        fake.show(safari, window: WindowInfo(title: "Two"))
        let reads = fake.focusedContextCalls
        capturer.handle(change: ObservedChange(pid: 10, kind: .titleChanged, ts: 1))
        try await Task.sleep(for: .milliseconds(80))
        #expect(fake.focusedContextCalls == reads)  // dropped: no read at all
        capturer.tick()  // the safety net samples it
        let events = await drain(capturer)
        #expect(events.last?.kind == .contextSnapshot)
        #expect(events.last?.extra?["reason"] == "heartbeat")
        #expect(events.last?.windowTitle == "Two")
    }

    @Test func ambientValueChangeIsDropped() async throws {
        let fake = FakeAXClient()
        fake.show(
            safari, window: WindowInfo(title: "A"),
            element: ElementInfo(role: "AXTextArea", value: "0:01"))
        let capturer = try makeCapturer(fake: fake, debounceMs: 20)
        capturer.tick()
        fake.idleSeconds = 30
        fake.show(
            safari, window: WindowInfo(title: "A"),
            element: ElementInfo(role: "AXTextArea", value: "0:02"))
        let reads = fake.focusedContextCalls
        capturer.handle(change: ObservedChange(pid: 10, kind: .valueChanged, ts: 1))
        try await Task.sleep(for: .milliseconds(80))
        #expect(fake.focusedContextCalls == reads)
        _ = await drain(capturer)
    }

    @Test func userDrivenTitleChangeIsDebouncedAndTaggedUser() async throws {
        let fake = FakeAXClient()
        fake.show(safari, window: WindowInfo(title: "One"))
        let capturer = try makeCapturer(fake: fake, debounceMs: 20)
        capturer.tick()
        let reads = fake.focusedContextCalls
        for title in ["Loading…", "Two"] {
            fake.show(safari, window: WindowInfo(title: title))
            capturer.handle(change: ObservedChange(pid: 10, kind: .titleChanged, ts: 1))
        }
        #expect(fake.focusedContextCalls == reads)  // still debouncing
        #expect(await waitUntil { fake.focusedContextCalls == reads + 1 })
        let events = await drain(capturer)
        #expect(events.last?.kind == .windowTitleChanged)
        #expect(events.last?.windowTitle == "Two")
        #expect(events.last?.extra?["input"] == "user")
    }

    @Test func focusChangeRefreshesEvenWhenAmbient() async throws {
        let fake = FakeAXClient()
        fake.show(
            safari, window: WindowInfo(title: "A"),
            element: ElementInfo(role: "AXWebArea", value: "page"))
        let capturer = try makeCapturer(fake: fake)
        capturer.tick()
        fake.idleSeconds = 30
        fake.show(
            safari, window: WindowInfo(title: "A"),
            element: ElementInfo(role: "AXTextField", title: "Search", value: "q"))
        capturer.handle(change: ObservedChange(pid: 10, kind: .focusedElementChanged, ts: 1))
        let events = await drain(capturer)
        #expect(events.last?.kind == .elementFocused)
        #expect(events.last?.extra?["input"] == "ambient")
    }

    @Test func pendingValueRefreshSubsumesATitleChange() async throws {
        let fake = FakeAXClient()
        fake.show(
            safari, window: WindowInfo(title: "A"),
            element: ElementInfo(role: "AXTextArea", value: "h"))
        let capturer = try makeCapturer(fake: fake, debounceMs: 20)
        capturer.tick()
        let reads = fake.focusedContextCalls
        fake.show(
            safari, window: WindowInfo(title: "A — Edited"),
            element: ElementInfo(role: "AXTextArea", value: "hi"))
        capturer.handle(change: ObservedChange(pid: 10, kind: .valueChanged, ts: 1))
        capturer.handle(change: ObservedChange(pid: 10, kind: .titleChanged, ts: 2))
        #expect(await waitUntil { fake.focusedContextCalls == reads + 1 })
        #expect(fake.lastReusing == nil)  // the fresh read won
        let events = await drain(capturer)
        #expect(events.last?.kind == .elementValueChanged)
        #expect(events.last?.value == "hi")
    }

    @Test func activationSettleCollapsesTwoActivationsIntoOneRead() async throws {
        let fake = FakeAXClient()
        fake.show(safari, window: WindowInfo(title: "A"))
        let capturer = try makeCapturer(fake: fake, settleMs: 30)
        capturer.tick()
        let reads = fake.focusedContextCalls
        fake.show(textEdit, window: WindowInfo(title: "Doc"))
        capturer.handle(lifecycle: .activated(textEdit))
        fake.show(safari, window: WindowInfo(title: "A"))
        capturer.handle(lifecycle: .activated(safari))  // inside the window: restarts the wait
        #expect(await waitUntil { fake.focusedContextCalls == reads + 1 })
        try await Task.sleep(for: .milliseconds(60))
        #expect(fake.focusedContextCalls == reads + 1)
        let events = await drain(capturer)
        #expect(!events.map(\.kind).contains(.appDeactivated))  // never actually left Safari
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ObserverTests`
Expected: build error (`settleMs:`), then the new tests fail (ambient changes are still refreshed, titles are immediate, activations don't settle).

- [ ] **Step 3: Implement** (`Sources/Capture/Capturer.swift`)

State: replace `private var pendingValueRefresh: [Int32: Task<Void, Never>] = [:]` with:
```swift
    private var pendingRefresh: [Int32: Task<Void, Never>] = [:]
    private var pendingFreshRead: [Int32: Bool] = [:]
    private var pendingActivation: Task<Void, Never>?
```
Replace `handle(change:)`, `scheduleValueRefresh`, `dropPendingValueRefresh`, `dropAllPendingValueRefreshes` with:
```swift
    /// Spec 2026-09-03 §6.1. Every notification for the frontmost app is classified by input
    /// recency: user-driven changes are recorded now (titles/values after one debounce); ambient
    /// title and value changes are dropped — the heartbeat samples them. Focus and window changes
    /// always refresh. Public so the hub's handler and tests drive it.
    public func handle(change: ObservedChange) {
        guard trust == .active, let frontmost = ax.frontmostApplication(),
            change.pid == frontmost.pid
        else { return }
        let input: InputClass =
            ax.secondsSinceLastInput() <= config.capture.userInputWindowSeconds ? .user : .ambient
        switch change.kind {
        case .menuItemSelected:
            guard HeartbeatDiff.isAllowed(frontmost, config.allowlistSet) else { return }
            emit(
                RawEvent(
                    ts: change.ts, kind: .menuItemSelected, pid: frontmost.pid,
                    bundleID: frontmost.bundleID, appName: frontmost.name,
                    elementTitle: change.menuTitle))
        case .valueChanged:
            guard input == .user else { return }  // a ticking slider or timer: sampled instead
            scheduleRefresh(for: change.pid, freshRead: true, input: input)
        case .titleChanged:
            guard input == .user else { return }  // a badge or spinner flicker: sampled instead
            scheduleRefresh(for: change.pid, freshRead: false, input: input)
        case .focusedWindowChanged, .focusedElementChanged:
            dropPendingRefresh(for: change.pid)
            refresh(trigger: .observer(change.kind), freshRead: false, input: input)
        }
    }

    /// Spec §6.1 / §6.4. One pending refresh per pid; every user-driven title or value change
    /// restarts the quiet period. A pending value refresh (fresh read) subsumes a title one.
    private func scheduleRefresh(for pid: Int32, freshRead: Bool, input: InputClass) {
        let fresh = freshRead || (pendingFreshRead[pid] ?? false)
        pendingRefresh[pid]?.cancel()
        pendingFreshRead[pid] = fresh
        let delay = Duration.milliseconds(config.capture.valueDebounceMs)
        pendingRefresh[pid] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pendingRefresh[pid] = nil
            self.pendingFreshRead[pid] = nil
            guard self.trust == .active, self.ax.frontmostApplication()?.pid == pid else {
                return
            }
            self.refresh(
                trigger: .observer(fresh ? .valueChanged : .titleChanged), freshRead: fresh,
                input: input)
        }
    }

    /// Spec §6.4: a pending refresh is dropped, not run, once the focused context has moved.
    private func dropPendingRefresh(for pid: Int32) {
        pendingRefresh[pid]?.cancel()
        pendingRefresh[pid] = nil
        pendingFreshRead[pid] = nil
    }

    private func dropAllPendingRefreshes() {
        for pid in Array(pendingRefresh.keys) { dropPendingRefresh(for: pid) }
    }

    /// Spec §6.6: wait for the activated app's AX tree to settle before reading, so the focused
    /// window and element agree. Another activation inside the window restarts the wait.
    private func scheduleActivationRefresh() {
        pendingActivation?.cancel()
        let delay = Duration.milliseconds(config.capture.activationSettleMs)
        pendingActivation = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pendingActivation = nil
            guard self.trust == .active else { return }
            self.refresh(trigger: .activation, freshRead: false)
        }
    }
```
Rename the remaining call sites: `dropAllPendingValueRefreshes()` → `dropAllPendingRefreshes()` in `stop()`, in `handle(lifecycle:)`'s `.sleep` case, and in `setTrust`; `dropPendingValueRefresh(for: pid)` → `dropPendingRefresh(for: pid)` in `unobserve`. In `handle(lifecycle:)` replace the `.activated` case with:
```swift
        case .activated:
            dropAllPendingRefreshes()
            scheduleActivationRefresh()
```
In `stop()` and in `setTrust`'s `if new != .active` block, add `pendingActivation?.cancel()` and `pendingActivation = nil` next to the drop-all call.
Change `refresh`'s signature to `private func refresh(trigger: HeartbeatDiff.Trigger, freshRead: Bool, input: InputClass? = nil)` and pass `input: input` into `HeartbeatDiff.Input(...)` right after `trigger: trigger` (before `contentMemorySeconds:`).

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ObserverTests` three times (parallel default), then full `swift test`.
Expected: all `ObserverTests` (existing, updated, and 6 new) pass on every run; `CapturerTests` untouched and green.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Capture/Capturer.swift Tests/CaptureTests/ObserverTests.swift
git commit -m "Classify notifications by input recency and settle activations

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BdcwpxNhK3QnZByv2nHgnN"
```

---

### Task 5: Configurable notification set (global + per app), enforced by the hub

**Files:**
- Modify: `Sources/Capture/AXTypes.swift`, `AXObserverHub.swift`, `AXClient.swift`, `Capturer.swift`
- Modify: `Tests/CaptureTests/FakeAXClient.swift`, `ObserverTests.swift`, `LiveObserverTests.swift`

**Interfaces:**
- Consumes: `CaptureSettings.effectiveNotifications(for:)` (Task 1); `handle(change:)` (Task 4).
- Produces: `ObservedKind: CaseIterable` + `var configName: String` + `static func kinds(fromConfig: Set<String>) -> Set<ObservedKind>`; `AXReading.startObserving(_ app: AppInfo, kinds: Set<ObservedKind>, handler:) throws` (replaces the two-argument form); `AXObserverHub.start(pid:kinds:handler:)`; `Capturer.paths` (public); `Capturer.enabledKinds(for:)`; `FakeAXClient.observedKinds: [Int32: Set<ObservedKind>]`; harness `makeCapturer(..., configure: (inout Config) -> Void = { _ in })`.

- [ ] **Step 1: Update call sites and write the failing tests**

Call-site edits (the protocol signature changes):
- `Tests/CaptureTests/LiveObserverTests.swift`: `try client.startObserving(original) { … }` → `try client.startObserving(original, kinds: Set(ObservedKind.allCases)) { … }`.
- `ObserverTests.fakeDeliversObservedChangesToTheRegisteredHandler` and `fakeScriptsObserveFailuresLifecycleAndElectron`: every `fake.startObserving(safari) { … }` → `fake.startObserving(safari, kinds: Set(ObservedKind.allCases)) { … }`.
- Harness: add `configure: (inout Config) -> Void = { _ in }` as the **last** `makeCapturer` parameter and call `configure(&config)` right before `try config.save(to: paths.configURL)`.

New tests (append to `ObserverTests`):
```swift
    @Test func observesOnlyTheConfiguredKindsGloballyAndPerApp() throws {
        let fake = FakeAXClient()
        fake.running = [safari, textEdit]
        let capturer = try makeCapturer(fake: fake) {
            $0.capture.notifications = ["window", "title"]
            $0.capture.appNotifications["com.apple.TextEdit"] = ["value"]
        }
        capturer.tick()
        #expect(fake.observedKinds[10] == [.focusedWindowChanged, .titleChanged])
        #expect(fake.observedKinds[20] == [.valueChanged, .focusedElementChanged])  // value ⇒ focus
    }

    @Test func aDeliveredKindOutsideTheSetIsIgnored() async throws {
        let fake = FakeAXClient()
        fake.show(safari, window: WindowInfo(title: "One"))
        let capturer = try makeCapturer(fake: fake) { $0.capture.notifications = ["window", "focus"] }
        capturer.tick()
        let reads = fake.focusedContextCalls
        fake.show(safari, window: WindowInfo(title: "Two"))
        capturer.handle(change: ObservedChange(pid: 10, kind: .titleChanged, ts: 1))
        try await Task.sleep(for: .milliseconds(80))
        #expect(fake.focusedContextCalls == reads)
        _ = await drain(capturer)
    }

    @Test func configChangeReRegistersObserversWithTheNewKinds() throws {
        let fake = FakeAXClient()
        fake.running = [safari]
        let capturer = try makeCapturer(fake: fake)
        capturer.tick()
        #expect(fake.observedKinds[10] == Set(ObservedKind.allCases))
        var edited = capturer.config
        edited.capture.appNotifications["com.apple.Safari"] = ["window"]
        try edited.save(to: capturer.paths.configURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 10)],
            ofItemAtPath: capturer.paths.configURL.path)
        capturer.tick()  // reload → reconcile → re-register with the new set
        #expect(fake.stopObservingCalls == [10])
        #expect(fake.startObservingCalls == [10, 10])
        #expect(fake.observedKinds[10] == [.focusedWindowChanged])
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ObserverTests`
Expected: build error — `kinds:` label / `observedKinds` / `paths` / `configure:` not found.

- [ ] **Step 3: Implement**

`Sources/Capture/AXTypes.swift` — make `ObservedKind` `CaseIterable` (`public enum ObservedKind: String, Sendable, CaseIterable`) and add inside it:
```swift
    /// Spec 2026-09-03 §6.7: the config name of the family this kind belongs to.
    public var configName: String {
        switch self {
        case .focusedWindowChanged: return "window"
        case .focusedElementChanged: return "focus"
        case .titleChanged: return "title"
        case .valueChanged: return "value"
        case .menuItemSelected: return "menu"
        }
    }

    /// The kinds a config set enables (`CaptureSettings.effectiveNotifications(for:)`).
    public static func kinds(fromConfig names: Set<String>) -> Set<ObservedKind> {
        Set(ObservedKind.allCases.filter { names.contains($0.configName) })
    }
```
Change the protocol requirement to:
```swift
    /// Register for the given families of `app`'s in-app notifications (spec 2026-09-03 §6.7).
    func startObserving(
        _ app: AppInfo, kinds: Set<ObservedKind>,
        handler: @escaping @MainActor (ObservedChange) -> Void) throws
```

`Sources/Capture/AXObserverHub.swift`:
- In `Entry` add `let kinds: Set<ObservedKind>` and `var registered: [String] = []`.
- Replace the `applicationNotifications` constant with:
```swift
    /// App-element notifications per family (spec §6.7). App activation is deliberately absent —
    /// `AppLifecycle` (NSWorkspace) is the single source for it, so it cannot double-fire.
    private static func applicationNotifications(for kinds: Set<ObservedKind>) -> [String] {
        var names: [String] = []
        if kinds.contains(.focusedWindowChanged) {
            names += [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]
        }
        if kinds.contains(.focusedElementChanged) { names.append(kAXFocusedUIElementChangedNotification) }
        if kinds.contains(.titleChanged) { names.append(kAXTitleChangedNotification) }
        if kinds.contains(.menuItemSelected) { names.append(kAXMenuItemSelectedNotification) }
        return names
    }
```
- `start(pid:kinds:handler:)`: construct `Entry(observer:application:focused:handler:kinds:)`; register `Self.applicationNotifications(for: kinds)`, appending each name to `entry.registered` after a successful `add`; register `kAXValueChangedNotification` on the focused element **only if** `kinds.contains(.valueChanged)`.
- `stop(pid:)`: remove the value registration (if `entry.focused != nil`) and then `for name in entry.registered { AXObserverRemoveNotification(entry.observer, entry.application, name as CFString) }` (instead of the static list).
- `handle(element:notification:)`: after the `switch` resolves `kind`, add `guard entry.kinds.contains(kind) else { return }` before calling the handler; in the `.focusedElementChanged` case call `moveValueRegistration` only if `entry.kinds.contains(.valueChanged)`.

`Sources/Capture/AXClient.swift`: `startObserving(_ app: AppInfo, kinds: Set<ObservedKind>, handler:)` → `try hub.start(pid: app.pid, kinds: kinds, handler: handler)`.

`Tests/CaptureTests/FakeAXClient.swift`: add `private(set) var observedKinds: [Int32: Set<ObservedKind>] = [:]`; change `startObserving` to the new signature and set `observedKinds[app.pid] = kinds` right after `observing[app.pid] = handler`; `stopObserving` also does `observedKinds[pid] = nil`.

`Sources/Capture/Capturer.swift`:
- Make `paths` public: `public let paths: Paths`.
- Add `private var observedKinds: [Int32: Set<ObservedKind>] = [:]` and:
```swift
    /// Spec 2026-09-03 §6.7: the notification families in force for an app.
    func enabledKinds(for app: AppInfo) -> Set<ObservedKind> {
        ObservedKind.kinds(fromConfig: config.capture.effectiveNotifications(for: app.bundleID))
    }
```
- In `handle(change:)`'s guard add `enabledKinds(for: frontmost).contains(change.kind)` (config is the source of truth, so tests that never call `observe` still work; the hub's own guard is the second line).
- In `attemptObserve`: `let kinds = enabledKinds(for: app)`, call `try ax.startObserving(app, kinds: kinds) { … }`, and on success `observedKinds[app.pid] = kinds`.
- In `unobserve`: `observedKinds[pid] = nil`.
- In `reconcileObservers`, before the "observe running apps not yet observed" loop, add:
```swift
        // Spec §6.7: a config edit changed an observed app's set → re-register with the new one.
        for app in running where observed.contains(app.pid) && observedKinds[app.pid] != enabledKinds(for: app) {
            let electron = electronEnabled.contains(app.pid)
            unobserve(app.pid)
            if electron { electronEnabled.insert(app.pid) }  // same pid lifetime: no second write
            observe(app)
        }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter "ObserverTests|LiveObserverTests"` (live suite stays skipped) then full `swift test`.
Expected: the 3 new tests pass; every existing test passes (the default set is all five kinds, so behaviour is unchanged unless configured).

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Capture/AXTypes.swift Sources/Capture/AXObserverHub.swift Sources/Capture/AXClient.swift Sources/Capture/Capturer.swift Tests/CaptureTests/FakeAXClient.swift Tests/CaptureTests/ObserverTests.swift Tests/CaptureTests/LiveObserverTests.swift
git commit -m "Make the observed notification set configurable globally and per app

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BdcwpxNhK3QnZByv2nHgnN"
```

---

### Task 6: Docs, full verification, and the dogfood measurement handoff

**Files:**
- Modify: `docs/accessibility-api.md` (§6.2 area), `README.md` (configuration), `CLAUDE.md` (State line)

- [ ] **Step 1: Update the docs**

- `docs/accessibility-api.md`, after the content-extraction "As shipped" paragraph in §6.2, add a short **"Noise reduction (as shipped)"** paragraph: change detection compares two identities, not raw strings — `extra.valueHash` (SHA-256 of the redacted value) and `extra.fingerprint` (16 hex of SHA-256 over `bundleID ␟ normalized window title ␟ document ␟ URL-without-fragment`, place-level, a contract for Compact); titles are compared after `TitleNormalizer` (rule table: leading `(N) ` counters, status glyphs, Chrome `Audio playing` / `Muted` / `High memory usage` badges, whitespace — stored titles stay raw); every observer notification is classified by `secondsSinceLastInput()` as `user` (≤ `user_input_window_seconds`) or `ambient`, recorded in `extra.input`; ambient title/value notifications are dropped and sampled by the heartbeat; user-driven titles debounce like values; readout roles (`AXSlider`, `AXProgressIndicator`, `AXValueIndicator`, `AXScrollBar`) never yield a value; anonymous elements (no title/identifier/value/selection, non-secure) are transparent to change detection; a value whose hash was stored within `content_memory_seconds` (32 per pid) is emitted as `valueUnchanged` without a body; app activations are read after `activation_settle_ms`; the notification set is configurable (`capture.notifications`, `capture.apps.<bundle>.notifications`; `value ⇒ focus`).
- `README.md`: in the configuration section (add one under "Running the MVP" if none exists), list the new `capture` keys with defaults: `user_input_window_seconds` (2), `content_memory_seconds` (1800), `activation_settle_ms` (200), `notifications` (`["window","focus","title","value","menu"]`), `apps` (per-bundle-id `{ "notifications": [...] }`), with the one-line example from spec §6.7 and the note that `value` implies `focus`.
- `CLAUDE.md` State line: append "Capture noise reduction (normalized-title fingerprints, input-gated notifications, recent-content memory, configurable notification set) landed on top."

- [ ] **Step 2: Full verification**

```bash
make build && make test && make lint
```
Expected: all green (unit tests ≈ 141 + 30 new; live suites skipped).

- [ ] **Step 3: Commit**

```bash
git add docs/accessibility-api.md README.md CLAUDE.md
git commit -m "Document capture noise reduction and its config keys

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BdcwpxNhK3QnZByv2nHgnN"
```

- [ ] **Step 4: Dogfood measurement (the user, after merge)**

Rebuild release (`swift build -c release`), restart the daemon from the trusted terminal, use the Mac for a comparable window, then through the MCP `events` tool compare rows/hour and stored bytes/hour against the pre-slice window (spec §3.9 targets: rows −60 %, bytes −35 %); confirm cmux spinner rows are gone, `extra.input: "ambient"` rows are near zero, and re-focused pages arrive as `valueUnchanged`.

---

## Self-review (against the spec)

| Spec section | Task |
|---|---|
| §4 two hashes, place-level fingerprint contract, normalized comparison | 1 (`Fingerprint`, goldens), 2 (signature + `extra.fingerprint`, `ContentCache.matches`) |
| §5 normalizer rule table (+ what is not stripped) | 1 |
| §6.1 input-gated classification, `extra.input`, drop-vs-debounce table | 4 |
| §6.2 normalized signature + gate | 2 |
| §6.3 recent-content memory (32 / pid, TTL, `valueUnchanged` widened) | 3 |
| §6.4 anonymous transparency, secure exemption | 2 |
| §6.5 readout roles | 2 |
| §6.6 activation settle | 4 |
| §6.7 configurable set, `value ⇒ focus`, live re-registration | 1 (config), 5 (protocol/hub/Capturer) |
| §7 config keys | 1 |
| §8 privacy (no new reads; secure guards intact) | 2 (tests), 4 |
| §9 tests | 1–5 |
| §10 docs | 6 |

**Placeholder scan:** none. **Type consistency:** `InputClass` is a top-level enum in `Capture` (Task 2) and is referenced as `InputClass` everywhere (the `HeartbeatDiffTests` helper parameter, Task 4's `Capturer`); `HeartbeatDiff.Input` init parameters are added in order `trigger` (existing) → `input` (Task 2) → `contentMemorySeconds` (Task 3), and Task 4 passes them in that order; `startObserving(_:kinds:handler:)` has the same labels in the protocol, `AXClient`, `FakeAXClient`, `Capturer.attemptObserve`, and `LiveObserverTests`; the harness signature ends up `makeCapturer(fake:allow:debounceMs:settleMs:clock:retryDelays:configure:)`, all defaulted, every call site uses labels; `Fingerprint.compute(bundleID:windowTitle:document:url:)` labels match between `HeartbeatDiff`, its tests, and `FingerprintTests`; `RecentValueHashes.entries` is `public private(set)` for the bounded-capacity test; `ObservedKind` gains `CaseIterable` before `allCases` is used (Task 5).
