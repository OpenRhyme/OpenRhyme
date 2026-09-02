# Deep AX Content Extraction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture the readable on-screen text of the focused element (visible page/document/message body) for every allowlisted app, by adding a value → ranged-text → bounded-subtree-harvest ladder to the engine's AX reads — reusing the existing `value` field (no schema change), gated so the expensive read runs only when the focused context changes.

**Architecture:** A pure `ContentExtractor` (rung selection, subtree harvest, secure-skip, bounds) operating over a small `TextNode` protocol, unit-tested in CI with an in-memory fake tree; an `AXUIElement`-backed `TextNode` supplies the real reads. `AXClient.readElement` calls the extractor; `AXClient.focusedContext(of:reusing:)` gates the expensive rungs behind a cheap-identity `ContentCache` comparison; `Capturer` threads the cache per pid; `HeartbeatDiff` records `extra.textSource`.

**Tech Stack:** Swift 6 (tools 6.0), macOS 14+, ApplicationServices (AX C API), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-01-content-extraction-design.md` (read it — this plan implements §4–§8). Also skim `docs/accessibility-api.md` §3–4 before Task 3.

## Global Constraints

- Swift 6 language mode, macOS 14+. No new dependencies. No network code. Never read an `AXSecureTextField`'s value — including inside the subtree harvest.
- **No storage-schema change** (stays v1), **no change to the `Store`, CLI, or MCP repo.** Content rides in the existing `value` column; `textSource` rides inside the existing `extra` JSON.
- `AXUIElement` and `kAX…` constants stay inside `Sources/Capture`. Everything crossing an isolation boundary is a `Sendable` struct.
- `make format` before every commit; CI runs `swift format lint --strict`. Line length 100, 4-space indent.
- Swift Testing only (`@Test`, `#expect`, `#require`). Tests never require a TCC grant; anything touching live AX is gated behind `OPENRHYME_LIVE_AX=1` and never runs in CI.
- Commit messages: short single line, then two trailer lines exactly:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01V87i2D4tcSfTEKf14J5jii`.
- Config defaults reused: `capture.max_value_bytes` (524288). New extractor default: node budget 1500 (a constant, not a config key in this slice).

---

## File structure

| Path | Responsibility |
|---|---|
| `Sources/Capture/ContentExtractor.swift` | **New.** `TextSource`, `TextNode` protocol, `ExtractedText`, `ContentExtractor.extract(...)` — pure rung ladder + subtree harvest + secure-skip + bounds. |
| `Sources/Capture/AXTypes.swift` | `ElementInfo.textSource` field; `ContentCache` struct + `matches`. |
| `Sources/Capture/AXClient.swift` | `visibleCharacterRange`/`stringForRange` helpers; `AXUIElementTextNode`; `readElement` calls the extractor; `focusedContext(of:reusing:)` gate; `contentReadCount` (for the live gate test). |
| `Sources/Capture/AXTypes.swift` (protocol) | `AXReading.focusedContext(of:reusing:)`. |
| `Sources/Capture/Capturer.swift` | Hold last `ContentCache` per pid; thread it into `focusedContext`. |
| `Sources/Capture/HeartbeatDiff.swift` | Put `textSource` into the `context.snapshot` `extra`. |
| `Tests/CaptureTests/ContentExtractorTests.swift` | **New.** Full ladder/bounds/secure-skip coverage (CI). |
| `Tests/CaptureTests/FakeAXClient.swift` | New `focusedContext(of:reusing:)` signature; records the `reusing` argument. |
| `Tests/CaptureTests/LiveContentTests.swift` | **New, gated.** Real TextEdit + Chrome extraction, records `textSource`, asserts no re-harvest on an unchanged page. |

---

### Task 1: Wire types — `TextSource`, `ElementInfo.textSource`, `ContentCache`

**Files:**
- Modify: `Sources/Capture/AXTypes.swift`
- Create: `Sources/Capture/ContentExtractor.swift` (the `TextSource`/`TextNode`/`ExtractedText` declarations only; the `extract` body is Task 2)
- Test: `Tests/CaptureTests/ContentCacheTests.swift`

**Interfaces:**
- Produces: `public enum TextSource: String, Sendable { case value, range, subtree }`; `public protocol TextNode { var role: String? { get }; var subrole: String? { get }; func ownValue() throws -> String?; func rangedText() throws -> String?; func children() throws -> [TextNode] }`; `public struct ExtractedText: Sendable, Equatable { public var value: String?; public var source: TextSource? }`; `ElementInfo.textSource: String?` (new stored property, defaulted nil in the memberwise init); `public struct ContentCache: Sendable, Equatable { var role, subrole, identifier, title, windowTitle, document, url, value, textSource: String?; init(...) ; func matches(role:subrole:identifier:title:windowTitle:document:url:) -> Bool }`.

- [ ] **Step 1: Write the failing test**

`Tests/CaptureTests/ContentCacheTests.swift`:
```swift
import Testing

@testable import Capture

@Suite struct ContentCacheTests {
    @Test func matchesOnIdenticalCheapIdentity() {
        let cache = ContentCache(
            role: "AXWebArea", subrole: nil, identifier: "id", title: "t",
            windowTitle: "Page", document: nil, url: "https://x", value: "body", textSource: "range")
        #expect(
            cache.matches(
                role: "AXWebArea", subrole: nil, identifier: "id", title: "t",
                windowTitle: "Page", document: nil, url: "https://x"))
    }

    @Test func differsWhenAnyCheapFieldChanges() {
        let cache = ContentCache(
            role: "AXWebArea", subrole: nil, identifier: nil, title: nil,
            windowTitle: "Page A", document: nil, url: "https://a", value: "a", textSource: "range")
        #expect(
            !cache.matches(
                role: "AXWebArea", subrole: nil, identifier: nil, title: nil,
                windowTitle: "Page B", document: nil, url: "https://a"))
        #expect(
            !cache.matches(
                role: "AXWebArea", subrole: nil, identifier: nil, title: nil,
                windowTitle: "Page A", document: nil, url: "https://b"))
    }

    @Test func elementInfoCarriesTextSource() {
        var info = ElementInfo(role: "AXTextArea", value: "hi")
        #expect(info.textSource == nil)
        info.textSource = "value"
        #expect(info.textSource == "value")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ContentCacheTests`
Expected: build error — `ContentCache`, `ElementInfo.textSource` not found.

- [ ] **Step 3: Implement the types**

`Sources/Capture/ContentExtractor.swift` (declarations; `extract` comes in Task 2):
```swift
/// Which rung of the content ladder produced an element's text (spec §4).
public enum TextSource: String, Sendable {
    case value
    case range
    case subtree
}

/// A minimal, AX-free view of an element for content extraction, so the ladder is
/// unit-testable over an in-memory tree. `AXClient` provides an `AXUIElement`-backed
/// conformance; tests provide a struct tree.
public protocol TextNode {
    var role: String? { get }
    var subrole: String? { get }
    /// The element's own `kAXValue` text, if any (rung 1).
    func ownValue() throws -> String?
    /// The element's visible text via a ranged read, if the element supports it (rung 2).
    func rangedText() throws -> String?
    /// Child nodes for the subtree harvest (rung 3).
    func children() throws -> [TextNode]
}

public struct ExtractedText: Sendable, Equatable {
    public var value: String?
    public var source: TextSource?

    public init(value: String? = nil, source: TextSource? = nil) {
        self.value = value
        self.source = source
    }
}
```

In `Sources/Capture/AXTypes.swift`, add `textSource` to `ElementInfo` (new stored property + init parameter, defaulted nil so all existing call sites keep compiling):
```swift
    public var numberOfCharacters: Int?
    public var textSource: String?   // ADD after numberOfCharacters
```
and in the memberwise init add `textSource: String? = nil` as the last parameter and `self.textSource = textSource`.

Add `ContentCache` to `Sources/Capture/AXTypes.swift`:
```swift
/// The cheap-identity + resolved content of a focused element, cached across heartbeats so the
/// expensive content read (spec §6) is skipped when nothing user-visible changed.
public struct ContentCache: Sendable, Equatable {
    public var role: String?
    public var subrole: String?
    public var identifier: String?
    public var title: String?
    public var windowTitle: String?
    public var document: String?
    public var url: String?
    public var value: String?
    public var textSource: String?

    public init(
        role: String? = nil, subrole: String? = nil, identifier: String? = nil,
        title: String? = nil, windowTitle: String? = nil, document: String? = nil,
        url: String? = nil, value: String? = nil, textSource: String? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.windowTitle = windowTitle
        self.document = document
        self.url = url
        self.value = value
        self.textSource = textSource
    }

    /// True when the cheap identity is unchanged, so the cached `value`/`textSource` may be reused.
    public func matches(
        role: String?, subrole: String?, identifier: String?, title: String?,
        windowTitle: String?, document: String?, url: String?
    ) -> Bool {
        self.role == role && self.subrole == subrole && self.identifier == identifier
            && self.title == title && self.windowTitle == windowTitle
            && self.document == document && self.url == url
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ContentCacheTests`
Expected: 3 tests pass. Also `swift build` — all existing targets compile (the new `ElementInfo` field is defaulted, so no call site breaks).

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Capture/ContentExtractor.swift Sources/Capture/AXTypes.swift Tests/CaptureTests/ContentCacheTests.swift
git commit -m "Add content-extraction wire types and ContentCache

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01V87i2D4tcSfTEKf14J5jii"
```

---

### Task 2: `ContentExtractor.extract` — the ladder, harvest, secure-skip, bounds (pure)

**Files:**
- Modify: `Sources/Capture/ContentExtractor.swift`
- Test: `Tests/CaptureTests/ContentExtractorTests.swift`

**Interfaces:**
- Consumes: `TextSource`, `TextNode`, `ExtractedText` (Task 1); `ElementInfo.secureSubrole` (`"AXSecureTextField"`).
- Produces: `public enum ContentExtractor { public static func extract(from node: TextNode, maxBytes: Int, nodeBudget: Int = 1500) -> ExtractedText }`. Rungs: own value → ranged text → subtree harvest. Harvest skips `AXSecureTextField` nodes, collects text of `AXStaticText`/`AXHeading`/`AXLink`/`AXButton` roles, joins with `"\n"`, stops at `nodeBudget` nodes or once accumulated UTF-8 bytes reach `maxBytes`. A thrown `TextNode` read is swallowed (treated as "no text at this node") so one bad element never aborts the walk.

- [ ] **Step 1: Write the failing test**

`Tests/CaptureTests/ContentExtractorTests.swift`:
```swift
import Testing

@testable import Capture

/// In-memory TextNode for testing the ladder without AX.
private struct Node: TextNode {
    var role: String?
    var subrole: String?
    var value: String?
    var ranged: String?
    var kids: [Node] = []
    var throwsOnValue = false

    func ownValue() throws -> String? {
        if throwsOnValue { throw AXReadError.cannotComplete }
        return value
    }
    func rangedText() throws -> String? { ranged }
    func children() throws -> [TextNode] { kids }
}

@Suite struct ContentExtractorTests {
    @Test func rung1OwnValueWins() {
        let n = Node(role: "AXTextArea", value: "typed text", ranged: "should not be used")
        let r = ContentExtractor.extract(from: n, maxBytes: 1000)
        #expect(r == ExtractedText(value: "typed text", source: .value))
    }

    @Test func rung2RangedTextWhenValueEmpty() {
        let n = Node(role: "AXWebArea", value: nil, ranged: "visible page text")
        let r = ContentExtractor.extract(from: n, maxBytes: 1000)
        #expect(r == ExtractedText(value: "visible page text", source: .range))
    }

    @Test func rung3SubtreeHarvestWhenValueAndRangeEmpty() {
        let n = Node(
            role: "AXWebArea", value: nil, ranged: nil,
            kids: [
                Node(role: "AXHeading", value: "Title"),
                Node(role: "AXGroup", value: nil, kids: [Node(role: "AXStaticText", value: "Body line")]),
                Node(role: "AXLink", value: "a link"),
            ])
        let r = ContentExtractor.extract(from: n, maxBytes: 1000)
        #expect(r.source == .subtree)
        #expect(r.value == "Title\nBody line\na link")
    }

    @Test func harvestSkipsSecureFields() {
        let n = Node(
            role: "AXGroup", value: nil, ranged: nil,
            kids: [
                Node(role: "AXStaticText", value: "Username"),
                Node(role: "AXTextField", subrole: "AXSecureTextField", value: "hunter2"),
                Node(role: "AXStaticText", value: "Sign in"),
            ])
        let r = ContentExtractor.extract(from: n, maxBytes: 1000)
        #expect(r.value == "Username\nSign in")
        #expect(!(r.value ?? "").contains("hunter2"))
    }

    @Test func focusedSecureFieldYieldsNothing() {
        let n = Node(role: "AXTextField", subrole: "AXSecureTextField", value: "hunter2", ranged: "hunter2")
        let r = ContentExtractor.extract(from: n, maxBytes: 1000)
        #expect(r == ExtractedText(value: nil, source: nil))
    }

    @Test func nodeBudgetStopsTheWalk() {
        // 10 text children but a budget of 3 nodes (root + 2 harvested).
        let kids = (0..<10).map { Node(role: "AXStaticText", value: "L\($0)") }
        let n = Node(role: "AXGroup", value: nil, ranged: nil, kids: kids)
        let r = ContentExtractor.extract(from: n, maxBytes: 10000, nodeBudget: 3)
        // Budget-bounded: fewer than all 10 lines captured, no crash.
        #expect((r.value ?? "").split(separator: "\n").count < 10)
    }

    @Test func byteCapStopsAccumulation() {
        let kids = (0..<100).map { _ in Node(role: "AXStaticText", value: String(repeating: "x", count: 100)) }
        let n = Node(role: "AXGroup", value: nil, ranged: nil, kids: kids)
        let r = ContentExtractor.extract(from: n, maxBytes: 250)
        #expect((r.value ?? "").utf8.count <= 250)
        #expect(r.source == .subtree)
    }

    @Test func emptyEverywhereYieldsNothing() {
        let n = Node(role: "AXGroup", value: nil, ranged: nil, kids: [Node(role: "AXImage", value: nil)])
        let r = ContentExtractor.extract(from: n, maxBytes: 1000)
        #expect(r == ExtractedText(value: nil, source: nil))
    }

    @Test func aThrowingNodeDoesNotAbortTheWalk() {
        let n = Node(
            role: "AXGroup", value: nil, ranged: nil,
            kids: [
                Node(role: "AXStaticText", value: "before", throwsOnValue: true),
                Node(role: "AXStaticText", value: "after"),
            ])
        let r = ContentExtractor.extract(from: n, maxBytes: 1000)
        #expect(r.value == "after")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ContentExtractorTests`
Expected: build error — `ContentExtractor.extract` not found.

- [ ] **Step 3: Implement `extract`**

Append to `Sources/Capture/ContentExtractor.swift`:
```swift
public enum ContentExtractor {
    private static let harvestRoles: Set<String> = [
        "AXStaticText", "AXHeading", "AXLink", "AXButton",
    ]

    /// Resolve an element's readable text by the spec §4 ladder: own value → ranged text →
    /// bounded subtree harvest. A secure focused element yields nothing. Never reads a secure
    /// field's value, at any depth. Pure: all reads go through the `TextNode` protocol.
    public static func extract(
        from node: TextNode, maxBytes: Int, nodeBudget: Int = 1500
    ) -> ExtractedText {
        if node.subrole == ElementInfo.secureSubrole {
            return ExtractedText()
        }
        // Rung 1: own value.
        if let own = try? node.ownValue(), !own.isEmpty {
            return ExtractedText(value: own, source: .value)
        }
        // Rung 2: ranged visible text.
        if let ranged = try? node.rangedText(), !ranged.isEmpty {
            return ExtractedText(value: ranged, source: .range)
        }
        // Rung 3: bounded subtree harvest.
        var pieces: [String] = []
        var bytes = 0
        var budget = nodeBudget
        harvest(node, maxBytes: maxBytes, budget: &budget, bytes: &bytes, into: &pieces)
        guard !pieces.isEmpty else { return ExtractedText() }
        return ExtractedText(value: pieces.joined(separator: "\n"), source: .subtree)
    }

    private static func harvest(
        _ node: TextNode, maxBytes: Int, budget: inout Int, bytes: inout Int, into pieces: inout [String]
    ) {
        guard budget > 0, bytes < maxBytes else { return }
        budget -= 1
        if node.subrole == ElementInfo.secureSubrole { return }  // never read a password's text
        if let role = node.role, harvestRoles.contains(role),
            let text = try? node.ownValue(), !text.isEmpty
        {
            pieces.append(text)
            bytes += text.utf8.count + 1  // +1 for the joining newline
        }
        guard bytes < maxBytes, budget > 0 else { return }
        for child in (try? node.children()) ?? [] where budget > 0 && bytes < maxBytes {
            harvest(child, maxBytes: maxBytes, budget: &budget, bytes: &bytes, into: &pieces)
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ContentExtractorTests`
Expected: 9 tests pass.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Capture/ContentExtractor.swift Tests/CaptureTests/ContentExtractorTests.swift
git commit -m "Add ContentExtractor ladder with secure-skip and bounds

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01V87i2D4tcSfTEKf14J5jii"
```

---

### Task 3: AX glue — `AXUIElementTextNode`, ranged-read helpers, `readElement` uses the extractor

**Files:**
- Modify: `Sources/Capture/AXClient.swift`
- Test: `Tests/CaptureTests/LiveContentTests.swift` (gated; the pure ladder is already covered by Task 2)

**Interfaces:**
- Consumes: `ContentExtractor.extract`, `TextNode`, `ExtractedText`, `TextRange`, the existing `AXClient` helpers (`attributes`, `element`, `elements`, `string`, `number`, `range`, `check`).
- Produces: `AXClient.visibleCharacterRange(_ element: AXUIElement) throws -> TextRange?`; `AXClient.stringForRange(_ element: AXUIElement, _ range: TextRange) throws -> String?`; `struct AXUIElementTextNode: TextNode` (holds an `AXUIElement` + unowned `AXClient`); `readElement` now sets `info.value`/`info.textSource` from `ContentExtractor.extract`. Behaviour for a focused native text field is byte-identical to today (rung 1 subsumes the old value read, including the static-text description/title fallback).

- [ ] **Step 1: Write the gated live test**

`Tests/CaptureTests/LiveContentTests.swift`:
```swift
import Foundation
import Testing

@testable import Capture

/// Live AX tests. Require a TCC grant on the terminal; never run in CI.
/// Bring a text-heavy Chrome page (a Wikipedia article) and an open TextEdit doc to the front,
/// then: OPENRHYME_LIVE_AX=1 swift test --filter LiveContentTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENRHYME_LIVE_AX"] == "1"))
@MainActor struct LiveContentTests {
    @Test func extractsTextFromFrontmostApp() throws {
        let client = AXClient()
        #expect(client.isTrusted(prompt: false), "grant Accessibility to the terminal first")
        let app = try #require(client.frontmostApplication())
        let ctx = try client.focusedContext(of: app, reusing: nil)
        let el = try #require(ctx.element)
        print("LIVE \(app.bundleID ?? "?"): role=\(el.role ?? "-") textSource=\(el.textSource ?? "nil") len=\(el.value?.count ?? 0)")
        // On a text-bearing frontmost app we expect *some* content and a recorded source.
        if let value = el.value, !value.isEmpty {
            #expect(el.textSource != nil)
        }
    }

    @Test func unchangedContextDoesNotReExtract() throws {
        let client = AXClient()
        #expect(client.isTrusted(prompt: false))
        let app = try #require(client.frontmostApplication())
        let first = try client.focusedContext(of: app, reusing: nil)
        let count = client.contentReadCount
        // Feed the first result back as the cache; an unchanged context must be a cache hit.
        let cache = client.cache(from: first)
        _ = try client.focusedContext(of: app, reusing: cache)
        #expect(client.contentReadCount == count, "unchanged context re-ran the content read")
    }
}
```

- [ ] **Step 2: Confirm it is skipped without the grant**

Run: `swift test --filter LiveContentTests`
Expected: the suite is disabled (0 tests run) because `OPENRHYME_LIVE_AX` is unset. Also `swift build` must fail here — `focusedContext(of:reusing:)`, `contentReadCount`, `cache(from:)` don't exist yet (Task 4 adds the gate; this step's build failure is expected and resolved after Task 4).
Note: because this test references Task-4 API, it will not compile until Task 4 lands. That is intended — Tasks 3 and 4 are reviewed together as the AX-glue+gate pair. Implement Step 3 (Task 3's own code), then proceed to Task 4; run this suite green (skipped) after Task 4.

- [ ] **Step 3: Implement the AX glue**

In `Sources/Capture/AXClient.swift` add the ranged-read helpers (near the other CF helpers):
```swift
    // MARK: - Ranged text (spec §4.1)

    /// The element's visible character range, if it advertises one.
    func visibleCharacterRange(_ element: AXUIElement) throws -> TextRange? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element, kAXVisibleCharacterRangeAttribute as CFString, &value)
        try check(error)
        return range(value)
    }

    /// The text for a character range, via the parameterized `AXStringForRange` attribute.
    /// Returns nil when the element does not support it (mapped to no-error by `check`).
    func stringForRange(_ element: AXUIElement, _ textRange: TextRange) throws -> String? {
        var cfRange = CFRange(location: textRange.location, length: textRange.length)
        guard let param = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, param, &value)
        try check(error)
        return string(value)
    }
```

Add the node adapter (same file):
```swift
    /// `TextNode` backed by a real `AXUIElement`, so `ContentExtractor` can read the live tree.
    struct AXUIElementTextNode: TextNode {
        let element: AXUIElement
        unowned let client: AXClient
        let role: String?
        let subrole: String?

        init(_ element: AXUIElement, client: AXClient) {
            self.element = element
            self.client = client
            let ids = (try? client.attributes(element, [kAXRoleAttribute, kAXSubroleAttribute])) ?? [nil, nil]
            self.role = client.string(ids[0])
            self.subrole = client.string(ids[1])
        }

        /// Rung 1, behaviour-identical to the pre-slice value read: value → number-as-string →
        /// (static text) description → title.
        func ownValue() throws -> String? {
            let content = try client.attributes(
                element, [kAXValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute])
            if let s = client.string(content[0]) { return s }
            if let n = client.number(content[0]) { return String(n) }
            if role == kAXStaticTextRole { return client.string(content[1]) ?? client.string(content[2]) }
            return nil
        }

        func rangedText() throws -> String? {
            guard let vr = try client.visibleCharacterRange(element), vr.length > 0 else { return nil }
            return try client.stringForRange(element, vr)
        }

        func children() throws -> [TextNode] {
            try client.elements(element, kAXChildrenAttribute).map { AXUIElementTextNode($0, client: self.client) }
        }
    }
```

Rewrite the content portion of `readElement` (keep the identity bundle and secure guard exactly as they are; replace the value/selected/range block):
```swift
    func readElement(_ element: AXUIElement) throws -> ElementInfo {
        let identity = try attributes(
            element,
            [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute])
        var info = ElementInfo(
            role: string(identity[0]), subrole: string(identity[1]),
            identifier: string(identity[2]), title: string(identity[3]))
        guard !info.isSecure else { return info }

        // value + textSource via the content ladder (spec §4). 512 KB harvest guard; Redaction
        // applies the authoritative per-config cap downstream.
        let extracted = ContentExtractor.extract(
            from: AXUIElementTextNode(element, client: self), maxBytes: 524_288)
        info.value = extracted.value
        info.textSource = extracted.source?.rawValue

        let content = try attributes(
            element,
            [kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute, kAXNumberOfCharactersAttribute])
        info.selectedText = string(content[0])
        info.selectedRange = range(content[1])
        info.numberOfCharacters = number(content[2]).map(Int.init)
        return info
    }
```

(`readWindow` is unchanged. `AXClient+Inspect`'s `node` still calls `readElement`, so `inspect` now also shows extracted content — a free bonus, no change needed there.)

- [ ] **Step 4: Build**

Run: `swift build`
Expected: still fails on the Task-4 API referenced by `LiveContentTests` (`focusedContext(of:reusing:)`, `contentReadCount`, `cache(from:)`). Task 3's own additions (`AXUIElementTextNode`, helpers, `readElement`) compile. Do NOT commit yet — Tasks 3 and 4 land together. Proceed to Task 4.

---

### Task 4: The gate — `focusedContext(of:reusing:)`, protocol change, fake update, Capturer threading

**Files:**
- Modify: `Sources/Capture/AXTypes.swift` (protocol), `Sources/Capture/AXClient.swift`, `Sources/Capture/Capturer.swift`, `Tests/CaptureTests/FakeAXClient.swift`
- Test: existing `CapturerTests` (recompile under the new signature) + one new gate-threading test; `LiveContentTests` (from Task 3) now compiles and is skipped.

**Interfaces:**
- Consumes: `ContentCache`, `FocusedContext`, `ExtractedText`.
- Produces: `AXReading.focusedContext(of: AppInfo, reusing: ContentCache?) throws -> FocusedContext`; `AXClient.contentReadCount: Int` (fresh-extraction counter); `AXClient.cache(from: FocusedContext) -> ContentCache` (builds a cache key from a context); `FakeAXClient` records `lastReusing: ContentCache?`; `Capturer` holds `lastContentCache: [Int32: ContentCache]`.

- [ ] **Step 1: Update the protocol + fake, and add the gate-threading test**

In `Sources/Capture/AXTypes.swift`, change the protocol method:
```swift
    /// Focused window and element of `app`. `reusing` is the previous heartbeat's cached
    /// cheap-identity + content; when the cheap identity is unchanged the expensive content read
    /// is skipped and the cached value reused (spec §6). Throws `AXReadError` when the app cannot be read.
    func focusedContext(of app: AppInfo, reusing cache: ContentCache?) throws -> FocusedContext
```

Update `Tests/CaptureTests/FakeAXClient.swift`:
```swift
    private(set) var lastReusing: ContentCache?

    func focusedContext(of app: AppInfo, reusing cache: ContentCache?) throws -> FocusedContext {
        focusedContextCalls += 1
        lastReusing = cache
        if let error = errors[app.pid] { throw error }
        return contexts[app.pid] ?? FocusedContext(app: app, window: nil, element: nil)
    }
```

Add a gate-threading test to `Tests/CaptureTests/CapturerTests.swift`:
```swift
    @Test func heartbeatThreadsTheContentCacheBackToTheReader() async throws {
        let fake = FakeAXClient()
        fake.show(safari, window: WindowInfo(title: "Apple"),
            element: ElementInfo(role: "AXWebArea", value: "page text"))
        let (capturer, _) = try makeCapturer(fake: fake)
        capturer.tick()  // first read: reusing is nil
        #expect(fake.lastReusing == nil)
        capturer.tick()  // second read: the capturer should pass back the cache it built
        #expect(fake.lastReusing != nil)
        #expect(fake.lastReusing?.value == "page text")
        _ = await drain(capturer)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter CapturerTests`
Expected: build error — `focusedContext(of:reusing:)` / `lastReusing` mismatch until the implementation lands.

- [ ] **Step 3: Implement the gate in `AXClient` and threading in `Capturer`**

In `AXClient`, add the counter and the gated `focusedContext`:
```swift
    public private(set) var contentReadCount = 0

    public func focusedContext(of app: AppInfo, reusing cache: ContentCache?) throws -> FocusedContext {
        let application = AXUIElementCreateApplication(app.pid)
        var window: WindowInfo?
        if let focusedWindow = try element(application, kAXFocusedWindowAttribute) {
            window = try readWindow(focusedWindow)
        }
        var element: ElementInfo?
        if let focused = try self.element(application, kAXFocusedUIElementAttribute) {
            let ids = try attributes(
                focused, [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute])
            let role = string(ids[0]); let subrole = string(ids[1])
            let identifier = string(ids[2]); let title = string(ids[3])
            if let cache, cache.matches(
                role: role, subrole: subrole, identifier: identifier, title: title,
                windowTitle: window?.title, document: window?.document, url: window?.url)
            {
                // Cache hit: reuse content, skip the expensive rungs.
                var info = try readElementIdentityOnly(focused)
                info.value = cache.value
                info.textSource = cache.textSource
                element = info
            } else {
                contentReadCount += 1
                element = try readElement(focused)
            }
        }
        return FocusedContext(app: app, window: window, element: element)
    }

    /// Identity + selection only (no content ladder), for the cache-hit path.
    func readElementIdentityOnly(_ element: AXUIElement) throws -> ElementInfo {
        let identity = try attributes(
            element,
            [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute])
        var info = ElementInfo(
            role: string(identity[0]), subrole: string(identity[1]),
            identifier: string(identity[2]), title: string(identity[3]))
        guard !info.isSecure else { return info }
        let content = try attributes(
            element, [kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute, kAXNumberOfCharactersAttribute])
        info.selectedText = string(content[0])
        info.selectedRange = range(content[1])
        info.numberOfCharacters = number(content[2]).map(Int.init)
        return info
    }

    /// Build a cache key from a just-read context.
    public func cache(from context: FocusedContext) -> ContentCache {
        ContentCache(
            role: context.element?.role, subrole: context.element?.subrole,
            identifier: context.element?.identifier, title: context.element?.title,
            windowTitle: context.window?.title, document: context.window?.document,
            url: context.window?.url, value: context.element?.value,
            textSource: context.element?.textSource)
    }
```

In `Capturer`, hold and thread the cache. Add the property:
```swift
    private var lastContentCache: [Int32: ContentCache] = [:]
```
and in `heartbeat()` change the read call and update the cache:
```swift
                context = try ax.focusedContext(of: frontmost, reusing: lastContentCache[frontmost.pid])
                readFailures[frontmost.pid] = nil
                staleBackoff = 5
                if let context { lastContentCache[frontmost.pid] = ax.cache(from: context) }
```
Note: `ax` is typed `any AXReading`, so add `cache(from:)` to the `AXReading` protocol as a default-free requirement — add to the protocol:
```swift
    func cache(from context: FocusedContext) -> ContentCache
```
and implement it on `FakeAXClient` too:
```swift
    func cache(from context: FocusedContext) -> ContentCache {
        ContentCache(
            role: context.element?.role, subrole: context.element?.subrole,
            identifier: context.element?.identifier, title: context.element?.title,
            windowTitle: context.window?.title, document: context.window?.document,
            url: context.window?.url, value: context.element?.value,
            textSource: context.element?.textSource)
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter "CapturerTests|ContentExtractorTests|ContentCacheTests"` then the full `swift test` (foreground).
Expected: all pass, including the new `heartbeatThreadsTheContentCacheBackToTheReader`. `LiveContentTests` compiles and is skipped (no `OPENRHYME_LIVE_AX`). All pre-existing Capturer/HeartbeatDiff tests pass unchanged (the `reusing:` parameter is threaded, behaviour on the fake is the same since the fake returns canned contexts).

- [ ] **Step 5: Format and commit Tasks 3 + 4 together**

```bash
make format && make lint
git add Sources/Capture Tests/CaptureTests
git commit -m "Extract element content via the AX ladder, gated by a content cache

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01V87i2D4tcSfTEKf14J5jii"
```

---

### Task 5: `HeartbeatDiff` — record `extra.textSource`

**Files:**
- Modify: `Sources/Capture/HeartbeatDiff.swift`
- Test: `Tests/CaptureTests/HeartbeatDiffTests.swift`

**Interfaces:**
- Consumes: `FocusedContext.element.textSource`.
- Produces: the emitted `context.snapshot` event's `extra` carries `textSource` when the focused element has one.

- [ ] **Step 1: Write the failing test**

Add to `Tests/CaptureTests/HeartbeatDiffTests.swift`:
```swift
    @Test func snapshotCarriesTextSource() {
        let element = ElementInfo(role: "AXWebArea", value: "page body")
        var el = element
        el.textSource = "subtree"
        let out = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(safari, window: WindowInfo(title: "Apple"), element: el))
        let snapshot = out.events.first { $0.kind == .contextSnapshot }
        #expect(snapshot?.extra?["textSource"] == "subtree")
        #expect(snapshot?.value == "page body")
    }

    @Test func snapshotOmitsTextSourceWhenAbsent() {
        let out = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(safari, window: WindowInfo(title: "Apple"),
                element: ElementInfo(role: "AXGroup")))
        let snapshot = out.events.first { $0.kind == .contextSnapshot }
        #expect(snapshot?.extra?["textSource"] == nil)
    }
```
(These reuse the suite's existing `input(...)` helper and `safari` fixture.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter HeartbeatDiffTests`
Expected: FAIL — `extra["textSource"]` is nil because `compute` doesn't set it yet.

- [ ] **Step 3: Implement**

In `HeartbeatDiff.compute`, where the `context.snapshot` `extra` dictionary is built (the block that already sets `reason`, `valueHash`, `truncated`, `length`), add after the existing keys, before the event is constructed:
```swift
            if let textSource = context.element?.textSource {
                extra["textSource"] = .string(textSource)
            }
```
(Place it alongside the existing `extra["reason"] = "heartbeat"` etc. `context` is the `input.context` already in scope in that branch.)

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter HeartbeatDiffTests` then full `swift test`.
Expected: the two new tests pass; all existing HeartbeatDiff tests still pass.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Capture/HeartbeatDiff.swift Tests/CaptureTests/HeartbeatDiffTests.swift
git commit -m "Record textSource in the context snapshot extra

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01V87i2D4tcSfTEKf14J5jii"
```

---

### Task 6: Live verification + docs

**Files:**
- Modify: `docs/accessibility-api.md` (a short §4 note on the ranged/subtree ladder), `CLAUDE.md` (State line), `README.md` (one line under "Running the MVP")
- Verify: `Tests/CaptureTests/LiveContentTests.swift` against a real capture

- [ ] **Step 1: Run the live suite against real apps** (from a terminal with the Accessibility grant)

Bring a text-heavy Chrome page (a Wikipedia article) frontmost, then:
```bash
OPENRHYME_LIVE_AX=1 swift test --filter LiveContentTests 2>&1 | grep LIVE
```
Then repeat with TextEdit (a document with text) frontmost. Record the printed `textSource` per app in the commit message / a note. Expected: TextEdit → `textSource=value`; Chrome → `range` or `subtree` with non-empty length. If Chrome prints `textSource=nil`, that is itself the finding (AX exposes nothing for that page) — note it; it is the evidence for the future browser-extension slice.

- [ ] **Step 2: End-to-end smoke via the daemon**

```bash
swift build
.build/debug/openrhyme daemon --verbose   # in one terminal, with Chrome/TextEdit allowlisted
# in another, after browsing/typing:
.build/debug/openrhyme events --since 5m
```
Confirm `context.snapshot` rows now carry non-empty `value` for Chrome/TextEdit and an `extra.textSource`.

- [ ] **Step 3: Update docs**

- `docs/accessibility-api.md` §4/§6.2: add a short paragraph that `value` is resolved by the ladder (own value → `AXStringForRange` over `AXVisibleCharacterRange` → bounded `AXStaticText` subtree harvest), secure-skipped, and that `extra.textSource` records which rung fired.
- `CLAUDE.md` State line: append "Content extraction (deep AX text into `value`, `extra.textSource`) landed on top of Part 1."
- `README.md` under "Running the MVP": one line — "`events` now carries the visible on-screen text in `value` for every captured app; `extra.textSource` says which extraction path produced it."

- [ ] **Step 4: Full verification + commit**

```bash
make build && make test && make lint
git add docs/accessibility-api.md CLAUDE.md README.md
git commit -m "Document content extraction and verify live

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01V87i2D4tcSfTEKf14J5jii"
```

---

## Self-review (against the spec)

| Spec section | Task |
|---|---|
| §4 ladder (value → range → subtree), `textSource` | 2 (pure), 3 (AX glue) |
| §4.1 new AX primitives (`visibleCharacterRange`, `stringForRange`) | 3 |
| §4.2 bounds (node budget 1500, byte cap, messaging timeout) | 2 (budget/byte), 3 (timeout is the existing global) |
| §5 redaction / secure-skip per node | 2 (harvest skip), 3 (focused secure guard unchanged), Redaction unchanged |
| §6 gate (cheap identity → skip expensive rungs) | 4 |
| §7 modules touched | 1–5 |
| §8 tests (ladder, bounds, dedup/gate, secure-skip, live) | 2, 4, 6 |
| §3 success criteria (real text, textSource telemetry, no password leak, CPU, green build) | 2, 4, 6 |

**Placeholder scan:** none. **Type consistency:** `TextSource`, `TextNode` (`ownValue`/`rangedText`/`children`), `ExtractedText {value, source}`, `ContentExtractor.extract(from:maxBytes:nodeBudget:)`, `ContentCache {…}.matches(...)`, `ElementInfo.textSource`, `AXReading.focusedContext(of:reusing:)`, `AXReading.cache(from:)`, `AXClient.contentReadCount`, `AXUIElementTextNode` are used with identical names/signatures across tasks. **Note:** Tasks 3 and 4 compile and commit together (Task 3's live test references Task 4's gate API) — the plan states this explicitly at Task 3 Step 2/4 and they share the Task 4 commit.
