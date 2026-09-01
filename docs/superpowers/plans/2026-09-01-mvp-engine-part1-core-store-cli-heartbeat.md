# OpenRhyme MVP Engine — Part 1: Core, Store, CLI, Heartbeat Capture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the engine up to the spec's milestone 2 — a working `openrhyme` CLI that stores, queries and exports raw events, and a `daemon` that captures the focused context of allowlisted apps via the 5 s heartbeat path (no observers yet).

**Architecture:** Five SwiftPM targets: `Core` (event model, config, paths — no platform code), `Store` (thin wrapper over the system SQLite3, one `events` table, an `EventStore` actor as single writer), `Capture` (all Accessibility code, behind an `AXReading` protocol so capture logic is unit-tested with a fake), `openrhyme` (swift-argument-parser commands), `Compact` (empty stub). All AX work happens on the main thread (`@MainActor`); events flow through an `AsyncStream<RawEvent>` into the store actor.

**Tech Stack:** Swift 6 language mode (tools 6.0), macOS 14+, Swift Testing (`import Testing`), swift-argument-parser 1.8.2, system `SQLite3` module, CryptoKit (SHA-256), `os.Logger`. No other dependencies.

**Spec:** `docs/superpowers/specs/2026-09-01-mvp-capture-engine-design.md` (this plan implements §§3–11 up to milestone 2 of §12). Also read `docs/accessibility-api.md` before Tasks 16–19.

## Global Constraints

- `Package.swift`: `swift-tools-version: 6.0`, `platforms: [.macOS(.v14)]`, `swiftLanguageModes: [.v6]`. Strict concurrency is on; code must compile without warnings-as-errors being needed.
- Dependencies: **only** `apple/swift-argument-parser` pinned `exact: "1.8.2"`. Nothing else may be added.
- No network code anywhere. No screenshots, no audio, no event tap. Never read the value of an element whose subrole is `AXSecureTextField`.
- `AXUIElement`, `AXObserver`, `kAX…` constants, `NSWorkspace` appear **only** inside `Sources/Capture` and `Sources/openrhyme/InspectCommand.swift`/`AppsCommand.swift` (which use `AXClient`). Everything leaving `Capture` is a `Sendable` struct.
- JSON field names are the spec's column names: `bundle_id`, `app_name`, `window_title`, `element_title`, `selected_text`, `extra`.
- Config defaults (spec §8): `heartbeat_seconds: 5`, `idle_seconds: 120`, `value_debounce_ms: 500`, `max_value_bytes: 524288`, `record_other_apps: false`. Schema version `1`. Engine version string `"0.1.0"`.
- Data dir: `$OPENRHYME_DATA_DIR` else `~/Library/Application Support/OpenRhyme/`; files `events.sqlite`, `config.json`, `daemon.pid`.
- CLI envelope: `{"ok":true,"data":…}` / `{"ok":false,"error":{"code","message","hint"}}` on stdout; exit codes `0` ok, `1` failure, `2` usage, `3` not trusted, `4` daemon not running, `5` schema too new.
- Formatting: `make format` before every commit; CI runs `swift format lint --strict`. Line length 100, 4-space indent.
- Commit messages: short, single line, no trailers.
- Tests: Swift Testing only (`@Test`, `#expect`, `#require`). Tests never require a TCC grant; anything touching live AX is gated behind `OPENRHYME_LIVE_AX=1`.

---

## File structure

| Path | Responsibility |
|---|---|
| `Package.swift` | targets, dependency pin, test targets |
| `Sources/Core/JSONValue.swift` | `JSONValue` enum — the only representation of free-form JSON |
| `Sources/Core/EventKind.swift` | `EventKind` string enum (spec §5 table) |
| `Sources/Core/RawEvent.swift` | `RawEvent` struct with snake_case coding keys; `EngineVersion` |
| `Sources/Core/TimeSpec.swift` | parse `2h` / ISO-8601 / unix / local time into unix seconds |
| `Sources/Core/Paths.swift` | data dir resolution, file URLs |
| `Sources/Core/PIDFile.swift` | pidfile acquire/release/liveness |
| `Sources/Core/Config.swift` | `config.json` load/save with unknown-key preservation |
| `Sources/Core/Hashing.swift` | `sha256Hex` |
| `Sources/Store/Database.swift` | `Database` + `Statement` over `sqlite3_*`, `SQLValue` |
| `Sources/Store/Schema.swift` | DDL v1, `migrate`, `check` |
| `Sources/Store/EventStore.swift` | actor: `append`, `query`, `stream`, `count`, `lastEventTS` |
| `Sources/Store/JSONLExport.swift` | one JSON line per event in column order |
| `Sources/Capture/AXTypes.swift` | `AppInfo`, `WindowInfo`, `ElementInfo`, `FocusedContext`, `TrustState`, `AXReadError`, `AXReading` |
| `Sources/Capture/Redaction.swift` | secure-field skip, UTF-8-safe truncation |
| `Sources/Capture/HeartbeatDiff.swift` | `LastKnownState` + pure diff → events |
| `Sources/Capture/Capturer.swift` | heartbeat loop, trust states, config reload, idle |
| `Sources/Capture/AXClient.swift` | real `AXReading` over the C API |
| `Sources/Capture/ElectronSupport.swift` | `isElectronBundle(url)` (enabling comes in Part 2) |
| `Sources/openrhyme/OpenRhyme.swift` | `@main` root command |
| `Sources/openrhyme/Output.swift` | envelope, `CLIError`, `runJSON` |
| `Sources/openrhyme/VersionCommand.swift`, `EventsCommand.swift`, `ExportCommand.swift`, `AppsCommand.swift`, `StatusCommand.swift`, `InspectCommand.swift`, `DaemonCommand.swift` | one file per command |
| `Tests/CoreTests/*`, `Tests/StoreTests/*`, `Tests/CaptureTests/*` (incl. `FakeAXClient.swift`), `Tests/CLITests/*` (runs the built binary) | tests |

---

### Task 1: Package targets and `JSONValue`

**Files:**
- Modify: `Package.swift`
- Create: `Sources/Core/JSONValue.swift`
- Create: `Tests/CoreTests/JSONValueTests.swift`
- Delete: `Tests/CaptureTests/CaptureTests.swift`, `Tests/StoreTests/StoreTests.swift` (comment-only stubs; real tests replace them in later tasks — keep `Tests/CompactTests/CompactTests.swift`)

**Interfaces:**
- Produces: `public enum JSONValue: Codable, Equatable, Hashable, Sendable` with cases `.string(String)`, `.number(Double)`, `.bool(Bool)`, `.null`, `.array([JSONValue])`, `.object([String: JSONValue])`; literal conformances; accessors `stringValue`, `doubleValue`, `boolValue`, `arrayValue`, `objectValue`.

- [ ] **Step 1: Replace `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenRhyme",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "openrhyme", targets: ["openrhyme"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2")
    ],
    targets: [
        // Platform-free model: events, config, paths, time parsing.
        .target(name: "Core"),

        // All Accessibility code. Emits Sendable structs only.
        .target(name: "Capture", dependencies: ["Core"]),

        // SQLite events table; the schema is a public contract.
        .target(
            name: "Store",
            dependencies: ["Core"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // Deterministic compaction. Empty until after the MVP.
        .target(name: "Compact", dependencies: ["Core"]),

        .executableTarget(
            name: "openrhyme",
            dependencies: [
                "Core", "Capture", "Store", "Compact",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        .testTarget(name: "CoreTests", dependencies: ["Core"]),
        .testTarget(name: "StoreTests", dependencies: ["Store", "Core"]),
        .testTarget(name: "CaptureTests", dependencies: ["Capture", "Core"]),
        .testTarget(name: "CompactTests", dependencies: ["Compact"]),
        .testTarget(name: "CLITests", dependencies: ["openrhyme", "Store", "Core"]),
    ],
    swiftLanguageModes: [.v6]
)
```

- [ ] **Step 2: Create the Core target directory with a placeholder so the package resolves, delete the stub tests, and write the failing test**

```bash
mkdir -p Sources/Core Tests/CoreTests Tests/CLITests
git rm -q Tests/CaptureTests/CaptureTests.swift Tests/StoreTests/StoreTests.swift
```

`Tests/CoreTests/JSONValueTests.swift`:
```swift
import Foundation
import Testing

@testable import Core

@Suite struct JSONValueTests {
    @Test func roundTripsNestedStructure() throws {
        let value: JSONValue = [
            "s": "text", "n": 1.5, "i": 2, "b": true, "z": .null,
            "a": [1, "two", false], "o": ["k": "v"],
        ]
        let data = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(back == value)
    }

    @Test func decodesFromRawJSON() throws {
        let data = Data(#"{"a":[1,2,{"b":null}],"c":"d","e":true}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value["a"]?.arrayValue?.count == 3)
        #expect(value["a"]?[2]?["b"] == .null)
        #expect(value["c"]?.stringValue == "d")
        #expect(value["e"]?.boolValue == true)
    }

    @Test func encodesIntegralNumbersWithoutFraction() throws {
        let data = try JSONEncoder().encode(JSONValue.number(5))
        #expect(String(decoding: data, as: UTF8.self) == "5")
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --filter JSONValueTests`
Expected: build error — `JSONValue` not found.

- [ ] **Step 4: Implement `JSONValue`**

`Sources/Core/JSONValue.swift`:
```swift
import Foundation

/// A JSON document value. The only free-form JSON type used in the engine; `RawEvent.extra`
/// and `Config.raw` are built from it.
public enum JSONValue: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let string): try container.encode(string)
        case .number(let number):
            if number == number.rounded(), abs(number) < 1e15 {
                try container.encode(Int64(number))
            } else {
                try container.encode(number)
            }
        case .bool(let bool): try container.encode(bool)
        case .null: try container.encodeNil()
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter JSONValueTests`
Expected: 3 tests pass. Also run `swift build` — every target (including the new empty `CLITests`, which needs at least one file) must compile. If `CLITests` fails for having no sources, create `Tests/CLITests/CLITests.swift` containing only `// CLI end-to-end tests are added in Task 10.` — Task 10 replaces it.

- [ ] **Step 6: Format and commit**

```bash
make format && make lint
git add Package.swift Package.resolved Sources/Core Tests
git commit -m "Add Core target and JSONValue"
```

---

### Task 2: `EventKind` and `RawEvent`

**Files:**
- Create: `Sources/Core/EventKind.swift`, `Sources/Core/RawEvent.swift`
- Test: `Tests/CoreTests/RawEventTests.swift`

**Interfaces:**
- Produces: `public enum EventKind: String, Codable, Sendable, CaseIterable` (22 cases, raw values exactly as spec §5); `public struct RawEvent: Codable, Sendable, Equatable` with fields `id: Int64?`, `ts: Double`, `kind: EventKind`, `pid: Int32?`, `bundleID`, `appName`, `windowTitle`, `document`, `url`, `role`, `subrole`, `identifier`, `elementTitle`, `value`, `selectedText: String?`, `extra: [String: JSONValue]?`; a memberwise `public init(ts:kind:…)` with all optionals defaulting to `nil`; `public enum EngineVersion { public static let string = "0.1.0" }`.

- [ ] **Step 1: Write the failing test**

`Tests/CoreTests/RawEventTests.swift`:
```swift
import Foundation
import Testing

@testable import Core

@Suite struct RawEventTests {
    @Test func usesSnakeCaseKeysAndOmitsNils() throws {
        let event = RawEvent(
            ts: 1_756_700_000.25, kind: .windowFocused, pid: 42,
            bundleID: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "notes.md",
            extra: ["reason": "heartbeat"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(event), as: UTF8.self)
        #expect(json.contains(#""bundle_id":"com.apple.TextEdit""#))
        #expect(json.contains(#""app_name":"TextEdit""#))
        #expect(json.contains(#""window_title":"notes.md""#))
        #expect(json.contains(#""kind":"window.focused""#))
        #expect(!json.contains("selected_text"))
        #expect(!json.contains(#""id""#))
    }

    @Test func roundTrips() throws {
        let event = RawEvent(
            ts: 1.5, kind: .elementValueChanged, pid: 7, bundleID: "b", appName: "a",
            windowTitle: "w", document: "file:///x", url: "https://e", role: "AXTextArea",
            subrole: "AXStandard", identifier: "id", elementTitle: "t", value: "v",
            selectedText: "s", extra: ["valueHash": "abc", "truncated": false, "length": 1])
        let data = try JSONEncoder().encode(event)
        let back = try JSONDecoder().decode(RawEvent.self, from: data)
        #expect(back == event)
    }

    @Test func everyKindHasDottedRawValue() {
        for kind in EventKind.allCases {
            #expect(kind.rawValue.contains("."), "\(kind) must be namespaced")
        }
        #expect(EventKind.allCases.count == 22)
        #expect(EventKind(rawValue: "context.snapshot") == .contextSnapshot)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter RawEventTests`
Expected: build error — `RawEvent`/`EventKind` not found.

- [ ] **Step 3: Implement**

`Sources/Core/EventKind.swift`:
```swift
/// Every event kind the engine emits. Raw values are the strings stored in `events.kind`
/// and are a public contract (spec §5).
public enum EventKind: String, Codable, Sendable, CaseIterable {
    case daemonStarted = "daemon.started"
    case daemonStopped = "daemon.stopped"
    case permissionChanged = "permission.changed"
    case appLaunched = "app.launched"
    case appTerminated = "app.terminated"
    case appActivated = "app.activated"
    case appDeactivated = "app.deactivated"
    case appAXEnabled = "app.ax_enabled"
    case appOpaque = "app.opaque"
    case windowFocused = "window.focused"
    case windowTitleChanged = "window.title_changed"
    case windowCreated = "window.created"
    case windowDestroyed = "window.destroyed"
    case elementFocused = "element.focused"
    case elementValueChanged = "element.value_changed"
    case elementSelectionChanged = "element.selection_changed"
    case menuItemSelected = "menu.item_selected"
    case contextSnapshot = "context.snapshot"
    case idleStarted = "idle.started"
    case idleEnded = "idle.ended"
    case systemSleep = "system.sleep"
    case systemWake = "system.wake"
}
```

`Sources/Core/RawEvent.swift`:
```swift
import Foundation

public enum EngineVersion {
    public static let string = "0.1.0"
}

/// One row of the `events` table. Field names in JSON are the column names.
public struct RawEvent: Codable, Sendable, Equatable {
    public var id: Int64?
    public var ts: Double
    public var kind: EventKind
    public var pid: Int32?
    public var bundleID: String?
    public var appName: String?
    public var windowTitle: String?
    public var document: String?
    public var url: String?
    public var role: String?
    public var subrole: String?
    public var identifier: String?
    public var elementTitle: String?
    public var value: String?
    public var selectedText: String?
    public var extra: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case id, ts, kind, pid
        case bundleID = "bundle_id"
        case appName = "app_name"
        case windowTitle = "window_title"
        case document, url, role, subrole, identifier
        case elementTitle = "element_title"
        case value
        case selectedText = "selected_text"
        case extra
    }

    public init(
        id: Int64? = nil, ts: Double, kind: EventKind, pid: Int32? = nil,
        bundleID: String? = nil, appName: String? = nil, windowTitle: String? = nil,
        document: String? = nil, url: String? = nil, role: String? = nil,
        subrole: String? = nil, identifier: String? = nil, elementTitle: String? = nil,
        value: String? = nil, selectedText: String? = nil, extra: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.ts = ts
        self.kind = kind
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.document = document
        self.url = url
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.elementTitle = elementTitle
        self.value = value
        self.selectedText = selectedText
        self.extra = extra
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter RawEventTests`
Expected: 3 tests pass.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Core Tests/CoreTests
git commit -m "Add EventKind and RawEvent"
```

---

### Task 3: `TimeSpec` parsing

**Files:**
- Create: `Sources/Core/TimeSpec.swift`
- Test: `Tests/CoreTests/TimeSpecTests.swift`

**Interfaces:**
- Produces: `public enum TimeSpec { public static func parse(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) throws -> Double }` returning unix seconds; `public struct TimeSpecError: Error, Equatable { public let input: String }`.

- [ ] **Step 1: Write the failing test**

`Tests/CoreTests/TimeSpecTests.swift`:
```swift
import Foundation
import Testing

@testable import Core

@Suite struct TimeSpecTests {
    let now = Date(timeIntervalSince1970: 1_756_710_000)  // 2025-09-01T07:00:00Z
    let utc = TimeZone(identifier: "UTC")!

    @Test(arguments: [
        ("30s", 1_756_710_000.0 - 30),
        ("30m", 1_756_710_000.0 - 1800),
        ("2h", 1_756_710_000.0 - 7200),
        ("1d", 1_756_710_000.0 - 86400),
        ("1.5h", 1_756_710_000.0 - 5400),
        ("1756700000", 1_756_700_000.0),
        ("1756700000.5", 1_756_700_000.5),
        ("2025-09-01T07:00:00Z", 1_756_710_000.0),
        ("2025-09-01T07:00:00.250Z", 1_756_710_000.25),
        ("2025-09-01T09:00:00+02:00", 1_756_710_000.0),
        ("2025-09-01T07:00:00", 1_756_710_000.0),  // local, and local == UTC here
        ("2025-09-01 07:00", 1_756_710_000.0),
        ("2025-09-01", 1_756_684_800.0),
    ])
    func parses(input: String, expected: Double) throws {
        let parsed = try TimeSpec.parse(input, now: now, timeZone: utc)
        #expect(abs(parsed - expected) < 0.001, "\(input)")
    }

    @Test(arguments: ["", "yesterday", "2h30m", "1e5", "2025-13-01", "5w"])
    func rejects(input: String) {
        #expect(throws: TimeSpecError.self) {
            try TimeSpec.parse(input, now: now, timeZone: utc)
        }
    }

    @Test func localTimeUsesGivenZone() throws {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let parsed = try TimeSpec.parse("2025-09-01T16:00:00", now: now, timeZone: tokyo)
        #expect(parsed == 1_756_710_000.0)  // 16:00 JST == 07:00 UTC
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TimeSpecTests`
Expected: build error — `TimeSpec` not found.

- [ ] **Step 3: Implement**

`Sources/Core/TimeSpec.swift`:
```swift
import Foundation

public struct TimeSpecError: Error, Equatable, Sendable {
    public let input: String
}

/// Parses the `<time>` grammar shared by the CLI and the MCP server (spec §9):
/// relative durations (`30s`, `30m`, `2h`, `1d`, decimals allowed) meaning "that long ago",
/// unix seconds, ISO-8601 with a zone, or local date/time without a zone.
public enum TimeSpec {
    public static func parse(
        _ text: String, now: Date = Date(), timeZone: TimeZone = .current
    ) throws -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw TimeSpecError(input: text) }

        if let relative = parseRelative(trimmed) {
            return now.timeIntervalSince1970 - relative
        }
        if trimmed.allSatisfy({ $0.isNumber || $0 == "." }), let seconds = Double(trimmed) {
            return seconds
        }
        if let date = parseISO8601(trimmed) {
            return date.timeIntervalSince1970
        }
        if let date = parseLocal(trimmed, timeZone: timeZone) {
            return date.timeIntervalSince1970
        }
        throw TimeSpecError(input: text)
    }

    private static func parseRelative(_ text: String) -> Double? {
        guard let unit = text.last else { return nil }
        let multiplier: Double
        switch unit {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 3600
        case "d": multiplier = 86400
        default: return nil
        }
        let digits = text.dropLast()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber || $0 == "." }),
            let amount = Double(digits)
        else { return nil }
        return amount * multiplier
    }

    private static func parseISO8601(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func parseLocal(_ text: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TimeSpecTests`
Expected: all parametrised cases pass. If `"2026-13-01"` unexpectedly parses, `isLenient = false` is not being honoured — add an explicit month range check by round-tripping: `formatter.string(from: date) == text`.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Core/TimeSpec.swift Tests/CoreTests/TimeSpecTests.swift
git commit -m "Add TimeSpec parsing"
```

---

### Task 4: `Paths` and `PIDFile`

**Files:**
- Create: `Sources/Core/Paths.swift`, `Sources/Core/PIDFile.swift`
- Test: `Tests/CoreTests/PathsTests.swift`, `Tests/CoreTests/PIDFileTests.swift`

**Interfaces:**
- Produces: `public struct Paths: Sendable, Equatable { public let dataDir: URL; public var databaseURL, configURL, pidFileURL: URL; public init(dataDir:); public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Paths; public func ensureDataDir() throws }`
- Produces: `public struct PIDFile: Sendable { public let url: URL; public init(url:); public func read() -> Int32?; public static func isAlive(_ pid: Int32) -> Bool; public func acquire(pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws; public func release(); public var livePID: Int32? }`; `public struct PIDFileError: Error, Equatable { public let runningPID: Int32 }`.

- [ ] **Step 1: Write the failing tests**

`Tests/CoreTests/PathsTests.swift`:
```swift
import Foundation
import Testing

@testable import Core

@Suite struct PathsTests {
    @Test func environmentOverrideWins() {
        let paths = Paths.resolve(environment: ["OPENRHYME_DATA_DIR": "/tmp/orh-test"])
        #expect(paths.dataDir.path == "/tmp/orh-test")
        #expect(paths.databaseURL.lastPathComponent == "events.sqlite")
        #expect(paths.configURL.lastPathComponent == "config.json")
        #expect(paths.pidFileURL.lastPathComponent == "daemon.pid")
    }

    @Test func expandsTilde() {
        let paths = Paths.resolve(environment: ["OPENRHYME_DATA_DIR": "~/orh"])
        #expect(!paths.dataDir.path.hasPrefix("~"))
        #expect(paths.dataDir.path.hasSuffix("/orh"))
    }

    @Test func defaultIsApplicationSupport() {
        let paths = Paths.resolve(environment: [:])
        #expect(paths.dataDir.path.hasSuffix("/Library/Application Support/OpenRhyme"))
    }

    @Test func ensureDataDirCreatesDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-\(UUID().uuidString)", isDirectory: true)
        let paths = Paths(dataDir: dir)
        try paths.ensureDataDir()
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        try? FileManager.default.removeItem(at: dir)
    }
}
```

`Tests/CoreTests/PIDFileTests.swift`:
```swift
import Foundation
import Testing

@testable import Core

@Suite struct PIDFileTests {
    private func temp() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-\(UUID().uuidString).pid")
    }

    @Test func acquireWritesOwnPIDAndReleaseRemovesIt() throws {
        let file = PIDFile(url: temp())
        try file.acquire()
        #expect(file.read() == ProcessInfo.processInfo.processIdentifier)
        #expect(file.livePID == ProcessInfo.processInfo.processIdentifier)
        file.release()
        #expect(file.read() == nil)
    }

    @Test func staleFileIsOverwritten() throws {
        let file = PIDFile(url: temp())
        try "999999".write(to: file.url, atomically: true, encoding: .utf8)  // no such process
        #expect(file.livePID == nil)
        try file.acquire()
        #expect(file.read() == ProcessInfo.processInfo.processIdentifier)
        file.release()
    }

    @Test func liveFileRefusesAcquire() throws {
        let file = PIDFile(url: temp())
        try file.acquire()  // our own pid is alive
        #expect(throws: PIDFileError(runningPID: ProcessInfo.processInfo.processIdentifier)) {
            try file.acquire(pid: 12345)
        }
        file.release()
    }

    @Test func isAliveKnowsSelf() {
        #expect(PIDFile.isAlive(ProcessInfo.processInfo.processIdentifier))
        #expect(!PIDFile.isAlive(999_999))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "PathsTests|PIDFileTests"`
Expected: build error — `Paths`/`PIDFile` not found.

- [ ] **Step 3: Implement**

`Sources/Core/Paths.swift`:
```swift
import Foundation

/// Where the engine keeps its files (spec §8). `OPENRHYME_DATA_DIR` overrides the default.
public struct Paths: Sendable, Equatable {
    public let dataDir: URL

    public init(dataDir: URL) {
        self.dataDir = dataDir
    }

    public var databaseURL: URL { dataDir.appendingPathComponent("events.sqlite") }
    public var configURL: URL { dataDir.appendingPathComponent("config.json") }
    public var pidFileURL: URL { dataDir.appendingPathComponent("daemon.pid") }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Paths {
        if let override = environment["OPENRHYME_DATA_DIR"], !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return Paths(dataDir: URL(fileURLWithPath: expanded, isDirectory: true))
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Paths(dataDir: support.appendingPathComponent("OpenRhyme", isDirectory: true))
    }

    public func ensureDataDir() throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }
}
```

`Sources/Core/PIDFile.swift`:
```swift
import Foundation

public struct PIDFileError: Error, Equatable, Sendable {
    public let runningPID: Int32
}

/// `daemon.pid`: refuses a second daemon while one is alive, tolerates stale files.
public struct PIDFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func read() -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `kill(pid, 0)` succeeds (or fails with EPERM) only for a live process.
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public var livePID: Int32? {
        guard let pid = read(), Self.isAlive(pid) else { return nil }
        return pid
    }

    public func acquire(pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        if let running = livePID, running != pid {
            throw PIDFileError(runningPID: running)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "\(pid)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    public func release() {
        try? FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "PathsTests|PIDFileTests"`
Expected: 8 tests pass.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Core Tests/CoreTests
git commit -m "Add Paths and PIDFile"
```

---

### Task 5: `Config`

**Files:**
- Create: `Sources/Core/Config.swift`
- Test: `Tests/CoreTests/ConfigTests.swift`

**Interfaces:**
- Produces: `public struct CaptureSettings: Sendable, Equatable { heartbeatSeconds: Double = 5; idleSeconds: Double = 120; valueDebounceMs: Int = 500; maxValueBytes: Int = 524_288; recordOtherApps: Bool = false }`; `public struct Config: Sendable, Equatable { public static let schema = 1; public var allowlist: [String]; public var capture: CaptureSettings; public var raw: [String: JSONValue]; public init(allowlist:capture:raw:); public static func load(from url: URL) throws -> Config; public func save(to url: URL) throws; public func allowing(_:) -> Config; public func denying(_:) -> Config; public func isAllowed(_ bundleID: String?) -> Bool; public var allowlistSet: Set<String> }`; `public static func modificationDate(of url: URL) -> Date?`.

- [ ] **Step 1: Write the failing test**

`Tests/CoreTests/ConfigTests.swift`:
```swift
import Foundation
import Testing

@testable import Core

@Suite struct ConfigTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-\(UUID().uuidString).json")
    }

    @Test func missingFileYieldsDefaults() throws {
        let config = try Config.load(from: tempURL())
        #expect(config.allowlist.isEmpty)
        #expect(config.capture == CaptureSettings())
        #expect(config.capture.heartbeatSeconds == 5)
        #expect(config.capture.idleSeconds == 120)
        #expect(config.capture.valueDebounceMs == 500)
        #expect(config.capture.maxValueBytes == 524_288)
        #expect(config.capture.recordOtherApps == false)
    }

    @Test func loadsKnownKeysAndKeepsUnknownOnes() throws {
        let url = tempURL()
        try """
            {"schema":1,"note":"keep me","allowlist":["com.apple.Safari"],
             "capture":{"heartbeat_seconds":2,"custom":true}}
            """.write(to: url, atomically: true, encoding: .utf8)
        var config = try Config.load(from: url)
        #expect(config.allowlist == ["com.apple.Safari"])
        #expect(config.capture.heartbeatSeconds == 2)
        #expect(config.capture.idleSeconds == 120)

        config = config.allowing("com.apple.TextEdit").allowing("com.apple.Safari")
        try config.save(to: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(#""note" : "keep me""#))
        #expect(text.contains(#""custom" : true"#))
        let reloaded = try Config.load(from: url)
        #expect(reloaded.allowlist == ["com.apple.Safari", "com.apple.TextEdit"])
        #expect(reloaded.capture.heartbeatSeconds == 2)
    }

    @Test func allowAndDenyAreIdempotent() {
        let config = Config().allowing("a").allowing("a").allowing("b").denying("zzz")
        #expect(config.allowlist == ["a", "b"])
        #expect(config.denying("a").allowlist == ["b"])
        #expect(config.isAllowed("a"))
        #expect(!config.isAllowed("c"))
        #expect(!config.isAllowed(nil))
    }

    @Test func savedFileIsPrettyAndSorted() throws {
        let url = tempURL()
        try Config(allowlist: ["b", "a"]).save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("{\n"))
        #expect(text.range(of: "\"allowlist\"")!.lowerBound < text.range(of: "\"capture\"")!.lowerBound)
        #expect(text.contains(#""schema" : 1"#))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ConfigTests`
Expected: build error — `Config` not found.

- [ ] **Step 3: Implement**

`Sources/Core/Config.swift`:
```swift
import Foundation

public struct CaptureSettings: Sendable, Equatable {
    public var heartbeatSeconds: Double = 5
    public var idleSeconds: Double = 120
    public var valueDebounceMs: Int = 500
    public var maxValueBytes: Int = 524_288
    public var recordOtherApps: Bool = false

    public init() {}

    static let keys = (
        heartbeat: "heartbeat_seconds", idle: "idle_seconds", debounce: "value_debounce_ms",
        maxValue: "max_value_bytes", others: "record_other_apps"
    )

    init(json: [String: JSONValue]) {
        self.init()
        if let v = json[Self.keys.heartbeat]?.doubleValue { heartbeatSeconds = v }
        if let v = json[Self.keys.idle]?.doubleValue { idleSeconds = v }
        if let v = json[Self.keys.debounce]?.doubleValue { valueDebounceMs = Int(v) }
        if let v = json[Self.keys.maxValue]?.doubleValue { maxValueBytes = Int(v) }
        if let v = json[Self.keys.others]?.boolValue { recordOtherApps = v }
    }

    func merged(into json: [String: JSONValue]) -> [String: JSONValue] {
        var out = json
        out[Self.keys.heartbeat] = .number(heartbeatSeconds)
        out[Self.keys.idle] = .number(idleSeconds)
        out[Self.keys.debounce] = .number(Double(valueDebounceMs))
        out[Self.keys.maxValue] = .number(Double(maxValueBytes))
        out[Self.keys.others] = .bool(recordOtherApps)
        return out
    }
}

/// `config.json` (spec §8). Unknown keys survive a load/save round trip via `raw`.
public struct Config: Sendable, Equatable {
    public static let schema = 1

    public var allowlist: [String]
    public var capture: CaptureSettings
    public var raw: [String: JSONValue]

    public init(
        allowlist: [String] = [], capture: CaptureSettings = CaptureSettings(),
        raw: [String: JSONValue] = [:]
    ) {
        self.allowlist = allowlist
        self.capture = capture
        self.raw = raw
    }

    public var allowlistSet: Set<String> { Set(allowlist) }

    public func isAllowed(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return allowlist.contains(bundleID)
    }

    public func allowing(_ bundleID: String) -> Config {
        var copy = self
        if !copy.allowlist.contains(bundleID) { copy.allowlist.append(bundleID) }
        return copy
    }

    public func denying(_ bundleID: String) -> Config {
        var copy = self
        copy.allowlist.removeAll { $0 == bundleID }
        return copy
    }

    public static func load(from url: URL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        let data = try Data(contentsOf: url)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let raw = value.objectValue ?? [:]
        let allowlist = raw["allowlist"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let capture = CaptureSettings(json: raw["capture"]?.objectValue ?? [:])
        return Config(allowlist: allowlist, capture: capture, raw: raw)
    }

    public func save(to url: URL) throws {
        var out = raw
        out["schema"] = .number(Double(Self.schema))
        out["allowlist"] = .array(allowlist.map(JSONValue.string))
        out["capture"] = .object(capture.merged(into: raw["capture"]?.objectValue ?? [:]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(JSONValue.object(out))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
            as? Date
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ConfigTests`
Expected: 4 tests pass. (`JSONEncoder` pretty-prints as `"key" : value` with spaces around the colon — the assertions rely on that.)

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Core/Config.swift Tests/CoreTests/ConfigTests.swift
git commit -m "Add Config with unknown-key preservation"
```

---

### Task 6: `Database` and `Statement` (SQLite wrapper)

**Files:**
- Create: `Sources/Store/Database.swift`
- Delete: `Sources/Store/Store.swift` (stub) — replace its module comment at the top of `Database.swift`
- Test: `Tests/StoreTests/DatabaseTests.swift`

**Interfaces:**
- Produces: `public struct DatabaseError: Error, Sendable, CustomStringConvertible { code: Int32; message: String }`; `public enum SQLValue: Sendable, Equatable { case text(String), int(Int64), real(Double), null }`; `public final class Database { public enum Mode: Sendable { case readWrite, readOnly }; public init(url: URL, mode: Mode) throws; public func exec(_ sql: String) throws; public func prepare(_ sql: String) throws -> Statement; public var lastInsertRowID: Int64; public func scalarString(_ sql: String) throws -> String?; public func close() }`; `public final class Statement { @discardableResult func bind(_ values: [SQLValue]) -> Statement; func step() throws -> Bool; func string(_ column: Int32) -> String?; func int64(_:) -> Int64?; func double(_:) -> Double?; func reset() }`.
- Note: `Database`/`Statement` are deliberately **not** `Sendable`; the `EventStore` actor (Task 8) owns them.

- [ ] **Step 1: Write the failing test**

`Tests/StoreTests/DatabaseTests.swift`:
```swift
import Foundation
import Testing

@testable import Store

@Suite struct DatabaseTests {
    private func tempDB() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("t.sqlite")
    }

    @Test func opensInWALModeAndRoundTripsRows() throws {
        let url = tempDB()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try Database(url: url, mode: .readWrite)
        #expect(try db.scalarString("PRAGMA journal_mode") == "wal")

        try db.exec("CREATE TABLE t (a TEXT, b INTEGER, c REAL, d TEXT)")
        let insert = try db.prepare("INSERT INTO t VALUES (?, ?, ?, ?)")
        insert.bind([.text("x"), .int(7), .real(1.5), .null])
        #expect(try insert.step() == false)
        #expect(db.lastInsertRowID == 1)

        let select = try db.prepare("SELECT a, b, c, d FROM t")
        #expect(try select.step() == true)
        #expect(select.string(0) == "x")
        #expect(select.int64(1) == 7)
        #expect(select.double(2) == 1.5)
        #expect(select.string(3) == nil)
        #expect(try select.step() == false)
    }

    @Test func readOnlyRefusesWrites() throws {
        let url = tempDB()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let db = try Database(url: url, mode: .readWrite)
            try db.exec("CREATE TABLE t (a)")
            db.close()
        }
        let ro = try Database(url: url, mode: .readOnly)
        #expect(throws: DatabaseError.self) { try ro.exec("INSERT INTO t VALUES (1)") }
    }

    @Test func reportsSQLErrorsWithMessage() throws {
        let url = tempDB()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try Database(url: url, mode: .readWrite)
        do {
            try db.exec("SELEKT 1")
            Issue.record("expected a syntax error")
        } catch let error as DatabaseError {
            #expect(error.message.contains("syntax error"))
        }
    }

    @Test func missingFileInReadOnlyModeFails() {
        let url = tempDB()
        #expect(throws: DatabaseError.self) { try Database(url: url, mode: .readOnly) }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter DatabaseTests`
Expected: build error — `Database` not found.

- [ ] **Step 3: Implement**

```bash
git rm -q Sources/Store/Store.swift
```

`Sources/Store/Database.swift`:
```swift
// Store — the events table. The SQLite schema is a public contract read by the CLI and by
// the Python MCP server (read-only). Schema changes are versioned; see Schema.swift.

import Foundation
import SQLite3

public struct DatabaseError: Error, Sendable, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public var description: String { "sqlite error \(code): \(message)" }
}

public enum SQLValue: Sendable, Equatable {
    case text(String)
    case int(Int64)
    case real(Double)
    case null
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A single SQLite connection. Not thread-safe by design: owned by the `EventStore` actor
/// or by one CLI command.
public final class Database {
    public enum Mode: Sendable {
        case readWrite
        case readOnly
    }

    private var handle: OpaquePointer?
    public let url: URL

    public init(url: URL, mode: Mode) throws {
        self.url = url
        let flags =
            mode == .readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var opened: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &opened, flags, nil)
        guard rc == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let opened { sqlite3_close_v2(opened) }
            throw DatabaseError(code: rc, message: message)
        }
        handle = opened
        try exec("PRAGMA busy_timeout=2000")
        if mode == .readWrite {
            try exec("PRAGMA journal_mode=WAL")
            try exec("PRAGMA synchronous=NORMAL")
        }
    }

    deinit { close() }

    public func close() {
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
    }

    public func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &error)
        guard rc == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw DatabaseError(code: rc, message: message)
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else {
            throw DatabaseError(code: rc, message: errorMessage)
        }
        return Statement(statement)
    }

    /// First column of the first row, as text. `nil` when there is no row or it is NULL.
    public func scalarString(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        guard try statement.step() else { return nil }
        return statement.string(0)
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
}

public final class Statement {
    private let statement: OpaquePointer

    init(_ statement: OpaquePointer) {
        self.statement = statement
    }

    deinit { sqlite3_finalize(statement) }

    @discardableResult
    public func bind(_ values: [SQLValue]) -> Statement {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            case .int(let int): sqlite3_bind_int64(statement, index, int)
            case .real(let real): sqlite3_bind_double(statement, index, real)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return self
    }

    /// `true` when a row is available, `false` when the statement is done.
    public func step() throws -> Bool {
        let rc = sqlite3_step(statement)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            let db = sqlite3_db_handle(statement)
            throw DatabaseError(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    public func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    public func string(_ column: Int32) -> String? {
        guard !isNull(column), let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    public func int64(_ column: Int32) -> Int64? {
        isNull(column) ? nil : sqlite3_column_int64(statement, column)
    }

    public func double(_ column: Int32) -> Double? {
        isNull(column) ? nil : sqlite3_column_double(statement, column)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter DatabaseTests`
Expected: 4 tests pass.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Store Tests/StoreTests
git commit -m "Add SQLite Database wrapper"
```

---

### Task 7: `Schema` v1

**Files:**
- Create: `Sources/Store/Schema.swift`
- Test: `Tests/StoreTests/SchemaTests.swift`

**Interfaces:**
- Produces: `public enum Schema { public static let version = 1; public static let ddl: String; public static func migrate(_ db: Database) throws; @discardableResult public static func check(_ db: Database) throws -> Int; public static func currentVersion(_ db: Database) throws -> Int }`; `public struct SchemaTooNewError: Error, Equatable, Sendable { public let found: Int; public let supported: Int }`.

- [ ] **Step 1: Write the failing test**

`Tests/StoreTests/SchemaTests.swift`:
```swift
import Foundation
import Testing

@testable import Store

@Suite struct SchemaTests {
    private func freshDB() throws -> Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("events.sqlite")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try Database(url: url, mode: .readWrite)
    }

    @Test func migrateCreatesTablesAndRecordsVersion() throws {
        let db = try freshDB()
        #expect(try Schema.currentVersion(db) == 0)
        try Schema.migrate(db)
        #expect(try Schema.currentVersion(db) == 1)
        let tables = try db.prepare(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        var names: [String] = []
        while try tables.step() { names.append(tables.string(0)!) }
        #expect(names == ["events", "meta"])
        let indexes = try db.prepare(
            "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'events_%' ORDER BY name")
        var indexNames: [String] = []
        while try indexes.step() { indexNames.append(indexes.string(0)!) }
        #expect(indexNames == ["events_app_ts", "events_kind_ts", "events_ts"])
    }

    @Test func migrateIsIdempotent() throws {
        let db = try freshDB()
        try Schema.migrate(db)
        try Schema.migrate(db)
        #expect(try Schema.currentVersion(db) == 1)
    }

    @Test func refusesNewerSchema() throws {
        let db = try freshDB()
        try Schema.migrate(db)
        try db.exec("UPDATE meta SET value='2' WHERE key='schema_version'")
        #expect(throws: SchemaTooNewError(found: 2, supported: 1)) { try Schema.migrate(db) }
        #expect(throws: SchemaTooNewError(found: 2, supported: 1)) { try Schema.check(db) }
    }

    @Test func eventsColumnsMatchSpec() throws {
        let db = try freshDB()
        try Schema.migrate(db)
        let info = try db.prepare("PRAGMA table_info(events)")
        var columns: [String] = []
        while try info.step() { columns.append(info.string(1)!) }
        #expect(columns == [
            "id", "ts", "kind", "pid", "bundle_id", "app_name", "window_title", "document",
            "url", "role", "subrole", "identifier", "element_title", "value", "selected_text",
            "extra",
        ])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SchemaTests`
Expected: build error — `Schema` not found.

- [ ] **Step 3: Implement**

`Sources/Store/Schema.swift`:
```swift
import Foundation

public struct SchemaTooNewError: Error, Equatable, Sendable {
    public let found: Int
    public let supported: Int
}

/// Schema v1 (spec §7.1). Column order here is the JSON key order used by exports.
public enum Schema {
    public static let version = 1

    public static let ddl = """
        CREATE TABLE IF NOT EXISTS events (
          id            INTEGER PRIMARY KEY,
          ts            REAL    NOT NULL,
          kind          TEXT    NOT NULL,
          pid           INTEGER,
          bundle_id     TEXT,
          app_name      TEXT,
          window_title  TEXT,
          document      TEXT,
          url           TEXT,
          role          TEXT,
          subrole       TEXT,
          identifier    TEXT,
          element_title TEXT,
          value         TEXT,
          selected_text TEXT,
          extra         TEXT
        );
        CREATE INDEX IF NOT EXISTS events_ts      ON events (ts);
        CREATE INDEX IF NOT EXISTS events_kind_ts ON events (kind, ts);
        CREATE INDEX IF NOT EXISTS events_app_ts  ON events (bundle_id, ts);
        """

    private static let metaDDL =
        "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)"

    public static func currentVersion(_ db: Database) throws -> Int {
        let hasMeta = try db.scalarString(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='meta'")
        guard hasMeta != nil else { return 0 }
        let text = try db.scalarString("SELECT value FROM meta WHERE key='schema_version'")
        return text.flatMap(Int.init) ?? 0
    }

    /// For read-only connections: verifies the file is understood, returns its version.
    @discardableResult
    public static func check(_ db: Database) throws -> Int {
        let found = try currentVersion(db)
        if found > version { throw SchemaTooNewError(found: found, supported: version) }
        return found
    }

    /// For the writer: creates or upgrades to the current version.
    public static func migrate(_ db: Database) throws {
        let found = try check(db)
        guard found < version else { return }
        try db.exec("BEGIN")
        do {
            try db.exec(metaDDL)
            try db.exec(ddl)
            try db.exec(
                "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '\(version)')")
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SchemaTests`
Expected: 4 tests pass.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Store/Schema.swift Tests/StoreTests/SchemaTests.swift
git commit -m "Add schema v1 migration"
```

---

### Task 8: `EventStore` actor

**Files:**
- Create: `Sources/Store/EventStore.swift`
- Test: `Tests/StoreTests/EventStoreTests.swift`

**Interfaces:**
- Consumes: `Database`, `Statement`, `SQLValue`, `Schema`, `RawEvent`, `EventKind`, `JSONValue`.
- Produces: `public struct EventQuery: Sendable, Equatable { since: Double; until: Double?; kinds: [EventKind]?; bundleID: String?; limit: Int; afterID: Int64?; static let maxLimit = 10_000; init(since:until:kinds:bundleID:limit:afterID:) }`; `public actor EventStore { public let url: URL; public init(url: URL, readOnly: Bool = false) throws; @discardableResult public func append(_ event: RawEvent) throws -> Int64; public func query(_ q: EventQuery) throws -> [RawEvent]; public func count() throws -> Int64; public func lastEventTS() throws -> Double?; public func close() }`; `public struct StoreNotFoundError: Error, Sendable { public let url: URL }`.

- [ ] **Step 1: Write the failing test**

`Tests/StoreTests/EventStoreTests.swift`:
```swift
import Foundation
import Testing

@testable import Core
@testable import Store

@Suite struct EventStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("events.sqlite")
    }

    private func event(_ ts: Double, _ kind: EventKind, app: String = "com.a") -> RawEvent {
        RawEvent(ts: ts, kind: kind, pid: 1, bundleID: app, appName: "A", extra: ["n": 1])
    }

    @Test func appendAssignsIDsAndQueryReturnsOrderedRows() async throws {
        let store = try EventStore(url: tempURL())
        let first = try await store.append(event(10, .appActivated))
        let second = try await store.append(event(20, .windowFocused, app: "com.b"))
        #expect(first == 1 && second == 2)
        #expect(try await store.count() == 2)
        #expect(try await store.lastEventTS() == 20)

        let rows = try await store.query(EventQuery(since: 0))
        #expect(rows.map(\.id) == [1, 2])
        #expect(rows[0].kind == .appActivated)
        #expect(rows[0].extra == ["n": 1])
        #expect(rows[1].bundleID == "com.b")
    }

    @Test func filtersBySinceUntilKindsAppAndLimit() async throws {
        let store = try EventStore(url: tempURL())
        for i in 1...10 {
            try await store.append(
                event(Double(i), i.isMultiple(of: 2) ? .windowFocused : .appActivated,
                    app: i <= 5 ? "com.a" : "com.b"))
        }
        #expect(try await store.query(EventQuery(since: 8)).map(\.ts) == [8, 9, 10])
        #expect(try await store.query(EventQuery(since: 3, until: 4)).map(\.ts) == [3, 4])
        #expect(
            try await store.query(EventQuery(since: 0, kinds: [.windowFocused])).count == 5)
        #expect(try await store.query(EventQuery(since: 0, bundleID: "com.b")).count == 5)
        #expect(try await store.query(EventQuery(since: 0, limit: 3)).map(\.ts) == [1, 2, 3])
        #expect(try await store.query(EventQuery(since: 0, afterID: 8)).map(\.ts) == [9, 10])
    }

    @Test func limitIsCapped() {
        #expect(EventQuery(since: 0, limit: 999_999).limit == EventQuery.maxLimit)
        #expect(EventQuery(since: 0, limit: 0).limit == 1)
    }

    @Test func readOnlyStoreCannotAppendButCanQuery() async throws {
        let url = tempURL()
        do {
            let writer = try EventStore(url: url)
            try await writer.append(event(1, .daemonStarted))
            await writer.close()
        }
        let reader = try EventStore(url: url, readOnly: true)
        #expect(try await reader.count() == 1)
        await #expect(throws: DatabaseError.self) {
            try await reader.append(event(2, .daemonStopped))
        }
    }

    @Test func readOnlyOnMissingFileThrowsStoreNotFound() {
        #expect(throws: StoreNotFoundError.self) {
            try EventStore(url: tempURL(), readOnly: true)
        }
    }

    @Test func lastEventTSIsNilWhenEmpty() async throws {
        let store = try EventStore(url: tempURL())
        #expect(try await store.lastEventTS() == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter EventStoreTests`
Expected: build error — `EventStore` not found.

- [ ] **Step 3: Implement**

`Sources/Store/EventStore.swift`:
```swift
import Core
import Foundation

public struct StoreNotFoundError: Error, Sendable {
    public let url: URL
}

public struct EventQuery: Sendable, Equatable {
    public static let maxLimit = 10_000

    public var since: Double
    public var until: Double?
    public var kinds: [EventKind]?
    public var bundleID: String?
    public var limit: Int
    public var afterID: Int64?

    public init(
        since: Double, until: Double? = nil, kinds: [EventKind]? = nil,
        bundleID: String? = nil, limit: Int = 1000, afterID: Int64? = nil
    ) {
        self.since = since
        self.until = until
        self.kinds = kinds
        self.bundleID = bundleID
        self.limit = min(max(limit, 1), Self.maxLimit)
        self.afterID = afterID
    }
}

/// The single writer of `events.sqlite`. Readers open it with `readOnly: true`.
public actor EventStore {
    public let url: URL
    private let db: Database
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private let decoder = JSONDecoder()

    public init(url: URL, readOnly: Bool = false) throws {
        self.url = url
        if readOnly {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw StoreNotFoundError(url: url)
            }
            db = try Database(url: url, mode: .readOnly)
            try Schema.check(db)
        } else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            db = try Database(url: url, mode: .readWrite)
            try Schema.migrate(db)
        }
    }

    public func close() {
        db.close()
    }

    private static let columns = [
        "id", "ts", "kind", "pid", "bundle_id", "app_name", "window_title", "document", "url",
        "role", "subrole", "identifier", "element_title", "value", "selected_text", "extra",
    ]

    @discardableResult
    public func append(_ event: RawEvent) throws -> Int64 {
        let insert = try db.prepare(
            """
            INSERT INTO events (ts, kind, pid, bundle_id, app_name, window_title, document, url,
              role, subrole, identifier, element_title, value, selected_text, extra)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        let extra: SQLValue
        if let object = event.extra {
            extra = .text(String(decoding: try encoder.encode(object), as: UTF8.self))
        } else {
            extra = .null
        }
        insert.bind([
            .real(event.ts), .text(event.kind.rawValue), event.pid.map { .int(Int64($0)) } ?? .null,
            text(event.bundleID), text(event.appName), text(event.windowTitle),
            text(event.document), text(event.url), text(event.role), text(event.subrole),
            text(event.identifier), text(event.elementTitle), text(event.value),
            text(event.selectedText), extra,
        ])
        _ = try insert.step()
        return db.lastInsertRowID
    }

    private func text(_ value: String?) -> SQLValue {
        value.map(SQLValue.text) ?? .null
    }

    public func query(_ query: EventQuery) throws -> [RawEvent] {
        var sql = "SELECT \(Self.columns.joined(separator: ", ")) FROM events WHERE ts >= ?"
        var binds: [SQLValue] = [.real(query.since)]
        if let until = query.until {
            sql += " AND ts <= ?"
            binds.append(.real(until))
        }
        if let kinds = query.kinds, !kinds.isEmpty {
            sql += " AND kind IN (\(Array(repeating: "?", count: kinds.count).joined(separator: ", ")))"
            binds += kinds.map { .text($0.rawValue) }
        }
        if let bundleID = query.bundleID {
            sql += " AND bundle_id = ?"
            binds.append(.text(bundleID))
        }
        if let afterID = query.afterID {
            sql += " AND id > ?"
            binds.append(.int(afterID))
        }
        sql += " ORDER BY ts, id LIMIT ?"
        binds.append(.int(Int64(query.limit)))

        let statement = try db.prepare(sql).bind(binds)
        var rows: [RawEvent] = []
        while try statement.step() {
            rows.append(try row(statement))
        }
        return rows
    }

    private func row(_ s: Statement) throws -> RawEvent {
        guard let kindRaw = s.string(2), let kind = EventKind(rawValue: kindRaw) else {
            throw DatabaseError(code: -1, message: "unknown kind in row \(s.int64(0) ?? -1)")
        }
        var extra: [String: JSONValue]?
        if let json = s.string(15) {
            extra = try decoder.decode([String: JSONValue].self, from: Data(json.utf8))
        }
        return RawEvent(
            id: s.int64(0), ts: s.double(1) ?? 0, kind: kind, pid: s.int64(3).map(Int32.init),
            bundleID: s.string(4), appName: s.string(5), windowTitle: s.string(6),
            document: s.string(7), url: s.string(8), role: s.string(9), subrole: s.string(10),
            identifier: s.string(11), elementTitle: s.string(12), value: s.string(13),
            selectedText: s.string(14), extra: extra)
    }

    public func count() throws -> Int64 {
        Int64(try db.scalarString("SELECT COUNT(*) FROM events") ?? "0") ?? 0
    }

    public func lastEventTS() throws -> Double? {
        try db.scalarString("SELECT MAX(ts) FROM events").flatMap(Double.init)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter EventStoreTests`
Expected: 6 tests pass.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Store/EventStore.swift Tests/StoreTests/EventStoreTests.swift
git commit -m "Add EventStore actor"
```

---

### Task 9: `JSONLExport`

**Files:**
- Create: `Sources/Store/JSONLExport.swift`
- Test: `Tests/StoreTests/JSONLExportTests.swift`

**Interfaces:**
- Produces: `public enum JSONLExport { public static func line(for event: RawEvent) throws -> String }` — one JSON object, keys in column order, `null` fields omitted, `extra` inlined, no trailing newline.

- [ ] **Step 1: Write the failing test**

`Tests/StoreTests/JSONLExportTests.swift`:
```swift
import Foundation
import Testing

@testable import Core
@testable import Store

@Suite struct JSONLExportTests {
    @Test func keysFollowColumnOrderAndNilsAreOmitted() throws {
        let event = RawEvent(
            id: 3, ts: 1_756_700_000.5, kind: .contextSnapshot, pid: 9, bundleID: "com.x",
            windowTitle: "a \"quoted\" title\nline2", value: "v/slash",
            extra: ["reason": "heartbeat", "truncated": false, "length": 7])
        let line = try JSONLExport.line(for: event)
        #expect(!line.contains("\n"))
        #expect(
            line == #"{"id":3,"ts":1756700000.5,"kind":"context.snapshot","pid":9,"bundle_id":"com.x","window_title":"a \"quoted\" title\nline2","value":"v/slash","extra":{"length":7,"reason":"heartbeat","truncated":false}}"#
        )
    }

    @Test func integralTimestampKeepsNoFraction() throws {
        let line = try JSONLExport.line(for: RawEvent(ts: 10, kind: .idleStarted))
        #expect(line == #"{"ts":10,"kind":"idle.started"}"#)
    }

    @Test func lineIsValidJSONThatDecodesBack() throws {
        let event = RawEvent(
            ts: 1, kind: .elementFocused, role: "AXTextArea", selectedText: "tab\there",
            extra: ["nested": ["a": [1, 2]]])
        let line = try JSONLExport.line(for: event)
        let back = try JSONDecoder().decode(RawEvent.self, from: Data(line.utf8))
        #expect(back == event)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter JSONLExportTests`
Expected: build error — `JSONLExport` not found.

- [ ] **Step 3: Implement**

`Sources/Store/JSONLExport.swift`:
```swift
import Core
import Foundation

/// One event per line, keys in `events` column order (spec §7.3). Hand-written so the order
/// is the column order rather than `JSONEncoder`'s alphabetical order.
public enum JSONLExport {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static func line(for event: RawEvent) throws -> String {
        var fields: [(String, String)] = []
        if let id = event.id { fields.append(("id", String(id))) }
        fields.append(("ts", number(event.ts)))
        fields.append(("kind", quoted(event.kind.rawValue)))
        if let pid = event.pid { fields.append(("pid", String(pid))) }
        let strings: [(String, String?)] = [
            ("bundle_id", event.bundleID), ("app_name", event.appName),
            ("window_title", event.windowTitle), ("document", event.document),
            ("url", event.url), ("role", event.role), ("subrole", event.subrole),
            ("identifier", event.identifier), ("element_title", event.elementTitle),
            ("value", event.value), ("selected_text", event.selectedText),
        ]
        for (key, value) in strings {
            if let value { fields.append((key, quoted(value))) }
        }
        if let extra = event.extra {
            fields.append(("extra", String(decoding: try encoder.encode(extra), as: UTF8.self)))
        }
        return "{" + fields.map { "\"\($0)\":\($1)" }.joined(separator: ",") + "}"
    }

    private static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    /// JSON string literal with the escapes RFC 8259 requires. Slashes are left alone.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case ..<" ": out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter JSONLExportTests`
Expected: 3 tests pass.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Store/JSONLExport.swift Tests/StoreTests/JSONLExportTests.swift
git commit -m "Add JSONL export line format"
```

---

### Task 10: CLI skeleton, envelope, `version`, end-to-end test runner

**Files:**
- Create: `Sources/openrhyme/OpenRhyme.swift`, `Sources/openrhyme/Output.swift`, `Sources/openrhyme/VersionCommand.swift`
- Delete: `Sources/openrhyme/main.swift` (an `@main` type replaces it)
- Create: `Tests/CLITests/CLIRunner.swift`, `Tests/CLITests/VersionCommandTests.swift` (replace the Task 1 placeholder `Tests/CLITests/CLITests.swift` if it exists)

**Interfaces:**
- Produces (CLI, internal to the executable): `struct CLIError: Error { code: String; message: String; hint: String?; exitCode: Int32 }` with static constructors `notTrusted`, `dbNotFound(URL)`, `daemonNotRunning`, `schemaTooNew(found:supported:)`, `usage(String)`; `enum Output { static func printSuccess<T: Encodable>(_ data: T, json: Bool, human: () -> String) ; static func fail(_ error: Error) -> Never }`; `func runJSON<T: Encodable>(json: Bool, human: (T) -> String, _ body: () async throws -> T) async` — runs the body, prints the envelope (or the human text), exits non-zero on error.
- Produces (tests): `enum CLIRunner { static func run(_ args: [String], env: [String: String] = [:], stdin: String? = nil) throws -> (stdout: String, stderr: String, status: Int32); static var binaryURL: URL }`.

- [ ] **Step 1: Write the failing test**

`Tests/CLITests/CLIRunner.swift`:
```swift
import Foundation

/// Runs the built `openrhyme` binary. `swift test` builds it next to the test bundle.
enum CLIRunner {
    static var binaryURL: URL {
        if let override = ProcessInfo.processInfo.environment["OPENRHYME_BIN"] {
            return URL(fileURLWithPath: override)
        }
        let testBundle = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }
        let products =
            testBundle?.bundleURL.deletingLastPathComponent()
            ?? URL(fileURLWithPath: ".build/debug", isDirectory: true)
        return products.appendingPathComponent("openrhyme")
    }

    static func run(
        _ args: [String], env: [String: String] = [:], stdin: String? = nil
    ) throws -> (stdout: String, stderr: String, status: Int32) {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment.merge(env) { _, new in new }
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        if let stdin {
            let input = Pipe()
            process.standardInput = input
            input.fileHandleForWriting.write(Data(stdin.utf8))
            input.fileHandleForWriting.closeFile()
        }
        try process.run()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (stdout, stderr, process.terminationStatus)
    }

    static func tempDataDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func json(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return object as? [String: Any] ?? [:]
    }
}
```

`Tests/CLITests/VersionCommandTests.swift`:
```swift
import Foundation
import Testing

@Suite struct VersionCommandTests {
    @Test func versionJSONEnvelope() throws {
        let result = try CLIRunner.run(["version", "--json"])
        #expect(result.status == 0, result.stderr)
        let envelope = try CLIRunner.json(result.stdout)
        #expect(envelope["ok"] as? Bool == true)
        let data = envelope["data"] as? [String: Any]
        #expect(data?["engine"] as? String == "0.1.0")
        #expect(data?["schema"] as? Int == 1)
        #expect(result.stdout.filter { $0 == "\n" }.count == 1, "exactly one line")
    }

    @Test func versionHumanOutput() throws {
        let result = try CLIRunner.run(["version"])
        #expect(result.status == 0)
        #expect(result.stdout == "openrhyme 0.1.0 (schema 1)\n")
    }

    @Test func unknownCommandExitsWithUsageCode() throws {
        let result = try CLIRunner.run(["bogus"])
        #expect(result.status == 64 || result.status == 2)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter VersionCommandTests`
Expected: FAIL — the binary prints nothing (the `main.swift` stub) or the test cannot parse the envelope.

- [ ] **Step 3: Implement the skeleton**

```bash
git rm -q Sources/openrhyme/main.swift
rm -f Tests/CLITests/CLITests.swift
```

`Sources/openrhyme/Output.swift`:
```swift
import ArgumentParser
import Core
import Foundation
import Store

/// A failure the CLI reports as an envelope on stdout plus a stable exit code (spec §9).
struct CLIError: Error {
    let code: String
    let message: String
    let hint: String?
    let exitCode: Int32

    init(code: String, message: String, hint: String? = nil, exitCode: Int32 = 1) {
        self.code = code
        self.message = message
        self.hint = hint
        self.exitCode = exitCode
    }

    static let notTrusted = CLIError(
        code: "not_trusted", message: "Accessibility permission is missing",
        hint: "System Settings → Privacy & Security → Accessibility → enable the app that runs openrhyme",
        exitCode: 3)

    static func dbNotFound(_ url: URL) -> CLIError {
        CLIError(
            code: "db_not_found", message: "No event database at \(url.path)",
            hint: "Start `openrhyme daemon` and allow an app with `openrhyme apps allow <bundle-id>`")
    }

    static func daemonNotRunning(_ paths: Paths) -> CLIError {
        CLIError(
            code: "daemon_not_running", message: "No daemon is running",
            hint: "Start it with `openrhyme daemon` (pidfile: \(paths.pidFileURL.path))",
            exitCode: 4)
    }

    static func schemaTooNew(found: Int, supported: Int) -> CLIError {
        CLIError(
            code: "schema_too_new",
            message: "Database schema \(found) is newer than this build supports (\(supported))",
            hint: "Upgrade openrhyme", exitCode: 5)
    }

    static func usage(_ message: String) -> CLIError {
        CLIError(code: "usage", message: message, exitCode: 2)
    }
}

private struct ErrorBody: Encodable {
    let code: String
    let message: String
    let hint: String?
}

private struct Envelope<T: Encodable>: Encodable {
    let ok: Bool
    let data: T?
    let error: ErrorBody?
}

private let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

enum Output {
    static func stderr(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    static func envelope<T: Encodable>(_ data: T) throws -> String {
        String(decoding: try jsonEncoder.encode(Envelope(ok: true, data: data, error: nil)), as: UTF8.self)
    }

    static func envelope(_ error: CLIError) -> String {
        let body = Envelope<String>(
            ok: false, data: nil,
            error: ErrorBody(code: error.code, message: error.message, hint: error.hint))
        return String(decoding: (try? jsonEncoder.encode(body)) ?? Data("{\"ok\":false}".utf8), as: UTF8.self)
    }

    /// Maps any thrown error to a `CLIError` with a stable code.
    static func cliError(_ error: Error) -> CLIError {
        switch error {
        case let error as CLIError: return error
        case let error as StoreNotFoundError: return .dbNotFound(error.url)
        case let error as SchemaTooNewError:
            return .schemaTooNew(found: error.found, supported: error.supported)
        case let error as DatabaseError:
            return CLIError(code: "database_error", message: error.description)
        case let error as TimeSpecError:
            return .usage("Cannot parse time '\(error.input)' (use 2h, 30m, unix seconds, or ISO-8601)")
        default:
            return CLIError(code: "internal_error", message: String(describing: error))
        }
    }
}

/// Runs a command body and prints its result as the JSON envelope or as human text.
/// On error prints the failure envelope (JSON) or the message (human) and exits with the code.
func runJSON<T: Encodable>(
    json: Bool, human: (T) -> String, _ body: () async throws -> T
) async throws {
    do {
        let data = try await body()
        if json {
            print(try Output.envelope(data))
        } else {
            let text = human(data)
            if !text.isEmpty { print(text) }
        }
    } catch {
        let cli = Output.cliError(error)
        if json {
            print(Output.envelope(cli))
        } else {
            Output.stderr("error: \(cli.message)" + (cli.hint.map { "\nhint: \($0)" } ?? ""))
        }
        throw ExitCode(cli.exitCode)
    }
}
```

`Sources/openrhyme/VersionCommand.swift`:
```swift
import ArgumentParser
import Core
import Store

struct VersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version", abstract: "Engine and schema versions.")

    @Flag(name: .long, help: "Emit a JSON envelope.") var json = false

    struct Info: Encodable {
        let engine: String
        let schema: Int
    }

    func run() async throws {
        try await runJSON(json: json, human: { "openrhyme \($0.engine) (schema \($0.schema))" }) {
            Info(engine: EngineVersion.string, schema: Schema.version)
        }
    }
}
```

`Sources/openrhyme/OpenRhyme.swift`:
```swift
import ArgumentParser

@main
struct OpenRhyme: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "openrhyme",
        abstract: "Local-first computer history for macOS: capture, store and query your activity.",
        version: "0.1.0",
        subcommands: [VersionCommand.self],
        defaultSubcommand: nil)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter VersionCommandTests`
Expected: 3 tests pass. If the runner cannot find the binary, run `swift build` first and re-run; if it still fails, print `CLIRunner.binaryURL` in the test and fix the products-directory lookup for this toolchain — do not skip the test.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/openrhyme Tests/CLITests
git commit -m "Add CLI skeleton with JSON envelope and version command"
```

---

### Task 11: `events` and `export` commands

**Files:**
- Create: `Sources/openrhyme/EventsCommand.swift`, `Sources/openrhyme/ExportCommand.swift`
- Modify: `Sources/openrhyme/OpenRhyme.swift` (register subcommands)
- Test: `Tests/CLITests/EventsAndExportTests.swift`

**Interfaces:**
- Consumes: `EventStore(url:readOnly:)`, `EventQuery`, `JSONLExport.line(for:)`, `TimeSpec.parse`, `Paths.resolve()`, `runJSON`.
- Produces: `openrhyme events --since <time> [--until <time>] [--kind k]... [--app id] [--limit n] [--json]` → `{"events":[…],"count":n}`; `openrhyme export --since <time> [--until <time>] [--out path]` → JSONL.

- [ ] **Step 1: Write the failing test**

`Tests/CLITests/EventsAndExportTests.swift`:
```swift
import Foundation
import Testing

@testable import Core
@testable import Store

@Suite struct EventsAndExportTests {
    /// Seeds a store in a temp data dir and returns the env the CLI needs to find it.
    private func seeded() async throws -> [String: String] {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        let now = Date().timeIntervalSince1970
        try await store.append(RawEvent(ts: now - 7200, kind: .appActivated, bundleID: "com.a"))
        try await store.append(RawEvent(ts: now - 60, kind: .windowFocused, bundleID: "com.a",
            windowTitle: "T", extra: ["reason": "heartbeat"]))
        try await store.append(RawEvent(ts: now - 30, kind: .elementFocused, bundleID: "com.b"))
        await store.close()
        return ["OPENRHYME_DATA_DIR": dir.path]
    }

    @Test func eventsFiltersAndWrapsInEnvelope() async throws {
        let env = try await seeded()
        let result = try CLIRunner.run(["events", "--since", "1h", "--json"], env: env)
        #expect(result.status == 0, result.stderr)
        let envelope = try CLIRunner.json(result.stdout)
        let data = envelope["data"] as? [String: Any]
        #expect(data?["count"] as? Int == 2)
        let events = data?["events"] as? [[String: Any]]
        #expect(events?.first?["kind"] as? String == "window.focused")
        #expect(events?.first?["window_title"] as? String == "T")
        #expect((events?.first?["extra"] as? [String: Any])?["reason"] as? String == "heartbeat")

        let byApp = try CLIRunner.run(
            ["events", "--since", "1d", "--app", "com.b", "--json"], env: env)
        #expect((try CLIRunner.json(byApp.stdout)["data"] as? [String: Any])?["count"] as? Int == 1)

        let byKind = try CLIRunner.run(
            ["events", "--since", "1d", "--kind", "app.activated", "--kind", "element.focused",
             "--limit", "1", "--json"], env: env)
        #expect((try CLIRunner.json(byKind.stdout)["data"] as? [String: Any])?["count"] as? Int == 1)
    }

    @Test func eventsHumanOutputIsOneLinePerEvent() async throws {
        let env = try await seeded()
        let result = try CLIRunner.run(["events", "--since", "1d"], env: env)
        #expect(result.status == 0)
        #expect(result.stdout.split(separator: "\n").count == 3)
        #expect(result.stdout.contains("window.focused"))
    }

    @Test func exportWritesJSONLToStdoutAndFile() async throws {
        let env = try await seeded()
        let result = try CLIRunner.run(["export", "--since", "1d"], env: env)
        #expect(result.status == 0, result.stderr)
        let lines = result.stdout.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix(#"{"id":1,"ts":"#))
        #expect(lines[1].contains(#""extra":{"reason":"heartbeat"}"#))

        let out = try CLIRunner.tempDataDir().appendingPathComponent("day.jsonl")
        let toFile = try CLIRunner.run(
            ["export", "--since", "1d", "--out", out.path], env: env)
        #expect(toFile.status == 0)
        #expect(toFile.stdout.isEmpty)
        #expect(try String(contentsOf: out, encoding: .utf8).split(separator: "\n").count == 3)
    }

    @Test func missingDatabaseIsAStableError() throws {
        let env = ["OPENRHYME_DATA_DIR": try CLIRunner.tempDataDir().path]
        let result = try CLIRunner.run(["events", "--since", "1h", "--json"], env: env)
        #expect(result.status == 1)
        let envelope = try CLIRunner.json(result.stdout)
        #expect(envelope["ok"] as? Bool == false)
        #expect((envelope["error"] as? [String: Any])?["code"] as? String == "db_not_found")
    }

    @Test func badTimeIsAUsageError() throws {
        let result = try CLIRunner.run(["events", "--since", "yesterday", "--json"])
        #expect(result.status == 2)
        #expect((try CLIRunner.json(result.stdout)["error"] as? [String: Any])?["code"] as? String == "usage")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter EventsAndExportTests`
Expected: FAIL — `events` is not a known subcommand.

- [ ] **Step 3: Implement**

`Sources/openrhyme/EventsCommand.swift`:
```swift
import ArgumentParser
import Core
import Foundation
import Store

struct EventsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events", abstract: "Query raw events.")

    @Option(name: .long, help: "Start time: 2h, 30m, unix seconds, or ISO-8601.") var since: String
    @Option(name: .long, help: "End time (same grammar).") var until: String?
    @Option(name: .long, help: "Event kind filter, repeatable (e.g. window.focused).")
    var kind: [String] = []
    @Option(name: .long, help: "Bundle identifier filter.") var app: String?
    @Option(name: .long, help: "Maximum rows (default 1000, max 10000).") var limit: Int = 1000
    @Flag(name: .long, help: "Emit a JSON envelope.") var json = false

    struct Result: Encodable {
        let events: [RawEvent]
        let count: Int
    }

    static func parseKinds(_ names: [String]) throws -> [EventKind]? {
        guard !names.isEmpty else { return nil }
        return try names.map { name in
            guard let kind = EventKind(rawValue: name) else {
                throw CLIError.usage("Unknown kind '\(name)'")
            }
            return kind
        }
    }

    func run() async throws {
        try await runJSON(json: json, human: Self.humanLines) {
            let query = EventQuery(
                since: try TimeSpec.parse(since),
                until: try until.map { try TimeSpec.parse($0) },
                kinds: try Self.parseKinds(kind), bundleID: app, limit: limit)
            let store = try EventStore(url: Paths.resolve().databaseURL, readOnly: true)
            let events = try await store.query(query)
            await store.close()
            return Result(events: events, count: events.count)
        }
    }

    static func humanLines(_ result: Result) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return result.events.map { event in
            let time = formatter.string(from: Date(timeIntervalSince1970: event.ts))
            let app = event.bundleID ?? "-"
            let detail = event.windowTitle ?? event.elementTitle ?? event.value?.prefix(60).description ?? ""
            return "\(time)  \(event.kind.rawValue)  \(app)  \(detail)"
        }.joined(separator: "\n")
    }
}
```

`Sources/openrhyme/ExportCommand.swift`:
```swift
import ArgumentParser
import Core
import Foundation
import Store

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export", abstract: "Export raw events as JSON Lines.")

    @Option(name: .long, help: "Start time: 2h, 30m, unix seconds, or ISO-8601.") var since: String
    @Option(name: .long, help: "End time (same grammar).") var until: String?
    @Option(name: .long, help: "Write to this file instead of stdout.") var out: String?

    func run() async throws {
        do {
            let sinceTS = try TimeSpec.parse(since)
            let untilTS = try until.map { try TimeSpec.parse($0) }
            let store = try EventStore(url: Paths.resolve().databaseURL, readOnly: true)
            let handle: FileHandle
            if let out {
                FileManager.default.createFile(atPath: out, contents: nil)
                handle = try FileHandle(forWritingTo: URL(fileURLWithPath: out))
            } else {
                handle = FileHandle.standardOutput
            }
            var afterID: Int64?
            while true {
                let page = try await store.query(
                    EventQuery(since: sinceTS, until: untilTS, limit: EventQuery.maxLimit, afterID: afterID))
                for event in page {
                    handle.write(Data((try JSONLExport.line(for: event) + "\n").utf8))
                }
                guard page.count == EventQuery.maxLimit, let last = page.last?.id else { break }
                afterID = last
            }
            if out != nil { try handle.close() }
            await store.close()
        } catch {
            let cli = Output.cliError(error)
            Output.stderr("error: \(cli.message)" + (cli.hint.map { "\nhint: \($0)" } ?? ""))
            throw ExitCode(cli.exitCode)
        }
    }
}
```

Register in `OpenRhyme.swift`: `subcommands: [EventsCommand.self, ExportCommand.self, VersionCommand.self]`.

Note on paging: `export` pages by `id` with `afterID`, so its order is insertion order; `events` orders by `ts, id`. Both are documented in the spec's §7.2/§7.3 wording for the MVP.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter EventsAndExportTests`
Expected: 5 tests pass.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/openrhyme Tests/CLITests
git commit -m "Add events and export commands"
```

---

### Task 12: `apps list|allow|deny`

**Files:**
- Create: `Sources/openrhyme/AppsCommand.swift`
- Modify: `Sources/openrhyme/OpenRhyme.swift`
- Test: `Tests/CLITests/AppsCommandTests.swift`

**Interfaces:**
- Consumes: `Config.load/save/allowing/denying`, `Paths`.
- Produces: `openrhyme apps list [--json]` → `{"allowlist":[…]}`; `openrhyme apps allow <bundle-id> [--json]` / `deny` → `{"allowlist":[…],"changed":Bool}`. `apps running` is added in Task 16 (it needs `AXClient`).

- [ ] **Step 1: Write the failing test**

`Tests/CLITests/AppsCommandTests.swift`:
```swift
import Foundation
import Testing

@Suite struct AppsCommandTests {
    @Test func allowListDenyRoundTrip() throws {
        let dir = try CLIRunner.tempDataDir()
        let env = ["OPENRHYME_DATA_DIR": dir.path]

        var result = try CLIRunner.run(["apps", "list", "--json"], env: env)
        #expect(result.status == 0)
        #expect((try CLIRunner.json(result.stdout)["data"] as? [String: Any])?["allowlist"] as? [String] == [])

        result = try CLIRunner.run(["apps", "allow", "com.apple.TextEdit", "--json"], env: env)
        #expect(result.status == 0, result.stderr)
        var data = try CLIRunner.json(result.stdout)["data"] as? [String: Any]
        #expect(data?["changed"] as? Bool == true)
        #expect(data?["allowlist"] as? [String] == ["com.apple.TextEdit"])

        result = try CLIRunner.run(["apps", "allow", "com.apple.TextEdit", "--json"], env: env)
        data = try CLIRunner.json(result.stdout)["data"] as? [String: Any]
        #expect(data?["changed"] as? Bool == false)

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path))

        result = try CLIRunner.run(["apps", "deny", "com.apple.TextEdit"], env: env)
        #expect(result.status == 0)
        #expect(result.stdout.contains("(empty)"))
    }

    @Test func allowRejectsObviouslyInvalidIdentifier() throws {
        let env = ["OPENRHYME_DATA_DIR": try CLIRunner.tempDataDir().path]
        let result = try CLIRunner.run(["apps", "allow", "TextEdit", "--json"], env: env)
        #expect(result.status == 2)
        #expect((try CLIRunner.json(result.stdout)["error"] as? [String: Any])?["code"] as? String == "usage")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter AppsCommandTests`
Expected: FAIL — `apps` is not a known subcommand.

- [ ] **Step 3: Implement**

`Sources/openrhyme/AppsCommand.swift`:
```swift
import ArgumentParser
import Core
import Foundation

struct AppsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps", abstract: "Manage the capture allowlist.",
        subcommands: [List.self, Allow.self, Deny.self], defaultSubcommand: List.self)

    struct Allowlist: Encodable {
        let allowlist: [String]
        let changed: Bool?
    }

    static func humanAllowlist(_ result: Allowlist) -> String {
        result.allowlist.isEmpty ? "(empty)" : result.allowlist.joined(separator: "\n")
    }

    static func validated(_ bundleID: String) throws -> String {
        let trimmed = bundleID.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("."), !trimmed.contains(" ") else {
            throw CLIError.usage(
                "'\(bundleID)' is not a bundle identifier (expected e.g. com.apple.TextEdit; try `openrhyme apps running`)")
        }
        return trimmed
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the allowlist.")
        @Flag(name: .long) var json = false

        func run() async throws {
            try await runJSON(json: json, human: AppsCommand.humanAllowlist) {
                Allowlist(allowlist: try Config.load(from: Paths.resolve().configURL).allowlist, changed: nil)
            }
        }
    }

    struct Allow: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add an app to the allowlist.")
        @Argument(help: "Bundle identifier, e.g. com.apple.Safari.") var bundleID: String
        @Flag(name: .long) var json = false

        func run() async throws {
            try await runJSON(json: json, human: AppsCommand.humanAllowlist) {
                let paths = Paths.resolve()
                let id = try AppsCommand.validated(bundleID)
                let before = try Config.load(from: paths.configURL)
                let after = before.allowing(id)
                if after != before { try after.save(to: paths.configURL) }
                return Allowlist(allowlist: after.allowlist, changed: after != before)
            }
        }
    }

    struct Deny: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove an app from the allowlist.")
        @Argument(help: "Bundle identifier.") var bundleID: String
        @Flag(name: .long) var json = false

        func run() async throws {
            try await runJSON(json: json, human: AppsCommand.humanAllowlist) {
                let paths = Paths.resolve()
                let id = try AppsCommand.validated(bundleID)
                let before = try Config.load(from: paths.configURL)
                let after = before.denying(id)
                if after != before { try after.save(to: paths.configURL) }
                return Allowlist(allowlist: after.allowlist, changed: after != before)
            }
        }
    }
}
```

Register in `OpenRhyme.swift`: `subcommands: [AppsCommand.self, EventsCommand.self, ExportCommand.self, VersionCommand.self]`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter AppsCommandTests`
Expected: 2 tests pass.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/openrhyme Tests/CLITests
git commit -m "Add apps list/allow/deny commands"
```

---

### Task 13: Capture types, `AXReading` protocol, `FakeAXClient`, `Redaction`, `Hashing`

**Files:**
- Create: `Sources/Core/Hashing.swift`, `Sources/Capture/AXTypes.swift`, `Sources/Capture/Redaction.swift`
- Delete: `Sources/Capture/Capture.swift` (stub) — its module comment moves to the top of `AXTypes.swift`
- Test: `Tests/CaptureTests/FakeAXClient.swift` (test support, no `@Test`), `Tests/CaptureTests/RedactionTests.swift`, `Tests/CoreTests/HashingTests.swift`

**Interfaces:**
- Produces (Core): `public enum Hashing { public static func sha256Hex(_ text: String) -> String }`.
- Produces (Capture): 
  - `public struct AppInfo: Sendable, Equatable, Hashable { pid: Int32; bundleID: String?; name: String?; bundleURL: URL? }`
  - `public struct WindowInfo: Sendable, Equatable { title, document, url: String? }`
  - `public struct TextRange: Sendable, Equatable { location: Int; length: Int }`
  - `public struct ElementInfo: Sendable, Equatable { role, subrole, identifier, title, value, selectedText: String?; selectedRange: TextRange?; numberOfCharacters: Int?; var isSecure: Bool }`
  - `public struct FocusedContext: Sendable, Equatable { app: AppInfo; window: WindowInfo?; element: ElementInfo? }`
  - `public enum TrustState: String, Sendable { needsPermission, active, stale }`
  - `public enum AXReadError: Error, Equatable, Sendable { apiDisabled, cannotComplete, notImplemented, invalidElement, other(Int32) }`
  - `@MainActor public protocol AXReading: AnyObject { func isTrusted(prompt: Bool) -> Bool; func setGlobalMessagingTimeout(_ seconds: Float); func runningApplications() -> [AppInfo]; func frontmostApplication() -> AppInfo?; func focusedContext(of app: AppInfo) throws -> FocusedContext; func secondsSinceLastInput() -> Double }`
  - `public struct RedactedText: Sendable, Equatable { value: String?; selectedText: String?; truncated: Bool; length: Int }`; `public enum Redaction { public static func apply(_ element: ElementInfo?, maxValueBytes: Int) -> RedactedText }`
- Produces (tests): `@MainActor final class FakeAXClient: AXReading` with settable `trusted`, `running`, `frontmost`, `contexts: [Int32: FocusedContext]`, `errors: [Int32: AXReadError]`, `idleSeconds`, and counters `promptCount`, `focusedContextCalls`.

- [ ] **Step 1: Write the failing tests**

`Tests/CoreTests/HashingTests.swift`:
```swift
import Testing

@testable import Core

@Suite struct HashingTests {
    @Test func sha256OfKnownString() {
        #expect(
            Hashing.sha256Hex("abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Hashing.sha256Hex("").count == 64)
    }
}
```

`Tests/CaptureTests/RedactionTests.swift`:
```swift
import Testing

@testable import Capture

@Suite struct RedactionTests {
    @Test func secureFieldsNeverExposeText() {
        let element = ElementInfo(
            role: "AXTextField", subrole: "AXSecureTextField", value: "hunter2",
            selectedText: "hunter")
        #expect(element.isSecure)
        let redacted = Redaction.apply(element, maxValueBytes: 1000)
        #expect(redacted == RedactedText(value: nil, selectedText: nil, truncated: false, length: 0))
    }

    @Test func passesShortValuesThrough() {
        let element = ElementInfo(role: "AXTextArea", value: "héllo", selectedText: "é")
        let redacted = Redaction.apply(element, maxValueBytes: 1000)
        #expect(redacted.value == "héllo")
        #expect(redacted.selectedText == "é")
        #expect(redacted.truncated == false)
        #expect(redacted.length == 6)  // bytes, not characters
    }

    @Test func truncatesOnAUTF8Boundary() {
        let element = ElementInfo(role: "AXTextArea", value: "aé✓")  // 1 + 2 + 3 bytes
        let cut = Redaction.apply(element, maxValueBytes: 4)
        #expect(cut.value == "aé")
        #expect(cut.truncated == true)
        #expect(cut.length == 6)
        let exact = Redaction.apply(element, maxValueBytes: 6)
        #expect(exact.value == "aé✓")
        #expect(exact.truncated == false)
    }

    @Test func nilElementYieldsNothing() {
        #expect(Redaction.apply(nil, maxValueBytes: 10) == RedactedText(value: nil, selectedText: nil, truncated: false, length: 0))
    }
}
```

`Tests/CaptureTests/FakeAXClient.swift`:
```swift
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

    func isTrusted(prompt: Bool) -> Bool {
        if prompt { promptCount += 1 }
        return trusted
    }

    func setGlobalMessagingTimeout(_ seconds: Float) {
        timeout = seconds
    }

    func runningApplications() -> [AppInfo] { running }

    func frontmostApplication() -> AppInfo? { frontmost }

    func focusedContext(of app: AppInfo) throws -> FocusedContext {
        focusedContextCalls += 1
        if let error = errors[app.pid] { throw error }
        return contexts[app.pid] ?? FocusedContext(app: app, window: nil, element: nil)
    }

    func secondsSinceLastInput() -> Double { idleSeconds }

    // Convenience builders used by several test files.
    static func app(_ pid: Int32, _ bundleID: String, name: String? = nil) -> AppInfo {
        AppInfo(pid: pid, bundleID: bundleID, name: name ?? bundleID.split(separator: ".").last.map(String.init), bundleURL: nil)
    }

    func show(_ app: AppInfo, window: WindowInfo? = nil, element: ElementInfo? = nil) {
        frontmost = app
        contexts[app.pid] = FocusedContext(app: app, window: window, element: element)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "HashingTests|RedactionTests"`
Expected: build errors — types not found.

- [ ] **Step 3: Implement**

```bash
git rm -q Sources/Capture/Capture.swift
```

`Sources/Core/Hashing.swift`:
```swift
import CryptoKit
import Foundation

public enum Hashing {
    public static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
```

`Sources/Capture/AXTypes.swift`:
```swift
// Capture — macOS Accessibility capture. Owns TCC trust checks and recovery, the focused
// context reads (and, from Part 2, observers). Emits Sendable structs only; AXUIElement
// never leaves this module. Reference: docs/accessibility-api.md.

import Foundation

public struct AppInfo: Sendable, Equatable, Hashable {
    public var pid: Int32
    public var bundleID: String?
    public var name: String?
    public var bundleURL: URL?

    public init(pid: Int32, bundleID: String?, name: String?, bundleURL: URL?) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.bundleURL = bundleURL
    }
}

public struct WindowInfo: Sendable, Equatable {
    public var title: String?
    public var document: String?
    public var url: String?

    public init(title: String? = nil, document: String? = nil, url: String? = nil) {
        self.title = title
        self.document = document
        self.url = url
    }
}

public struct TextRange: Sendable, Equatable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct ElementInfo: Sendable, Equatable {
    public static let secureSubrole = "AXSecureTextField"

    public var role: String?
    public var subrole: String?
    public var identifier: String?
    public var title: String?
    public var value: String?
    public var selectedText: String?
    public var selectedRange: TextRange?
    public var numberOfCharacters: Int?

    public init(
        role: String? = nil, subrole: String? = nil, identifier: String? = nil,
        title: String? = nil, value: String? = nil, selectedText: String? = nil,
        selectedRange: TextRange? = nil, numberOfCharacters: Int? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.value = value
        self.selectedText = selectedText
        self.selectedRange = selectedRange
        self.numberOfCharacters = numberOfCharacters
    }

    public var isSecure: Bool { subrole == Self.secureSubrole }
}

public struct FocusedContext: Sendable, Equatable {
    public var app: AppInfo
    public var window: WindowInfo?
    public var element: ElementInfo?

    public init(app: AppInfo, window: WindowInfo?, element: ElementInfo?) {
        self.app = app
        self.window = window
        self.element = element
    }
}

public enum TrustState: String, Sendable {
    case needsPermission
    case active
    case stale
}

public enum AXReadError: Error, Equatable, Sendable {
    case apiDisabled
    case cannotComplete
    case notImplemented
    case invalidElement
    case other(Int32)
}

/// Everything the capture logic needs from the Accessibility API, so it can be driven by
/// `FakeAXClient` in tests and by `AXClient` in the daemon. Main-actor: AX is not thread-safe.
@MainActor
public protocol AXReading: AnyObject {
    func isTrusted(prompt: Bool) -> Bool
    func setGlobalMessagingTimeout(_ seconds: Float)
    func runningApplications() -> [AppInfo]
    func frontmostApplication() -> AppInfo?
    /// Focused window and element of `app`. Throws `AXReadError` when the app cannot be read.
    func focusedContext(of app: AppInfo) throws -> FocusedContext
    /// Seconds since the last keyboard/mouse event in this session. Needs no TCC grant.
    func secondsSinceLastInput() -> Double
}
```

`Sources/Capture/Redaction.swift`:
```swift
public struct RedactedText: Sendable, Equatable {
    public var value: String?
    public var selectedText: String?
    public var truncated: Bool
    public var length: Int

    public init(value: String?, selectedText: String?, truncated: Bool, length: Int) {
        self.value = value
        self.selectedText = selectedText
        self.truncated = truncated
        self.length = length
    }
}

/// Spec §6.5: secure fields expose nothing; values are capped at a UTF-8 boundary.
public enum Redaction {
    public static func apply(_ element: ElementInfo?, maxValueBytes: Int) -> RedactedText {
        guard let element, !element.isSecure else {
            return RedactedText(value: nil, selectedText: nil, truncated: false, length: 0)
        }
        guard let value = element.value else {
            return RedactedText(
                value: nil, selectedText: element.selectedText, truncated: false, length: 0)
        }
        let length = value.utf8.count
        guard length > maxValueBytes else {
            return RedactedText(
                value: value, selectedText: element.selectedText, truncated: false, length: length)
        }
        return RedactedText(
            value: truncate(value, toBytes: maxValueBytes), selectedText: element.selectedText,
            truncated: true, length: length)
    }

    /// Longest prefix of `text` that is at most `bytes` long and ends on a scalar boundary.
    static func truncate(_ text: String, toBytes bytes: Int) -> String {
        var count = max(bytes, 0)
        while count > 0 {
            if let prefix = String(text.utf8.prefix(count)) { return prefix }
            count -= 1
        }
        return ""
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "HashingTests|RedactionTests"`
Expected: 5 tests pass, and `Tests/CaptureTests/FakeAXClient.swift` compiles (it has no tests of its own).

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Core/Hashing.swift Sources/Capture Tests/CaptureTests Tests/CoreTests/HashingTests.swift
git commit -m "Add capture types, AXReading protocol, redaction and fake client"
```

---

### Task 14: `HeartbeatDiff` and `LastKnownState`

**Files:**
- Create: `Sources/Capture/HeartbeatDiff.swift`
- Test: `Tests/CaptureTests/HeartbeatDiffTests.swift`

**Interfaces:**
- Consumes: `AppInfo`, `FocusedContext`, `Redaction`, `Hashing`, `RawEvent`, `EventKind`.
- Produces: `public struct ContextSignature: Sendable, Equatable { pid: Int32; windowTitle, document, url, role, subrole, identifier, elementTitle, selectedText, valueHash: String? }`; `public struct LastKnownState: Sendable, Equatable { frontmost: AppInfo?; signature: ContextSignature?; idle: Bool; idleSince: Double?; init() }`; `public enum HeartbeatDiff { public struct Input: Sendable { frontmost: AppInfo?; context: FocusedContext?; allowlist: Set<String>; recordOtherApps: Bool; maxValueBytes: Int; now: Double }; public struct Output: Sendable, Equatable { events: [RawEvent]; state: LastKnownState }; public static func compute(previous: LastKnownState, input: Input) -> Output; static func isAllowed(_ app: AppInfo?, _ allowlist: Set<String>) -> Bool }`.

- [ ] **Step 1: Write the failing test**

`Tests/CaptureTests/HeartbeatDiffTests.swift`:
```swift
import Testing

@testable import Capture
@testable import Core

@Suite struct HeartbeatDiffTests {
    let safari = FakeAXClient.app(10, "com.apple.Safari")
    let textEdit = FakeAXClient.app(20, "com.apple.TextEdit")
    let finder = FakeAXClient.app(30, "com.apple.finder")
    let allow: Set<String> = ["com.apple.Safari", "com.apple.TextEdit"]

    private func input(
        _ app: AppInfo?, window: WindowInfo? = nil, element: ElementInfo? = nil,
        others: Bool = false, maxBytes: Int = 1000, now: Double = 100
    ) -> HeartbeatDiff.Input {
        HeartbeatDiff.Input(
            frontmost: app,
            context: app.map { FocusedContext(app: $0, window: window, element: element) },
            allowlist: allow, recordOtherApps: others, maxValueBytes: maxBytes, now: now)
    }

    @Test func firstAllowedAppActivatesAndSnapshots() {
        let out = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(safari, window: WindowInfo(title: "Apple", url: "https://apple.com")))
        #expect(out.events.map(\.kind) == [.appActivated, .contextSnapshot])
        #expect(out.events[0].bundleID == "com.apple.Safari")
        #expect(out.events[0].extra?["allowlisted"] == true)
        #expect(out.events[1].windowTitle == "Apple")
        #expect(out.events[1].url == "https://apple.com")
        #expect(out.events[1].extra?["reason"] == "heartbeat")
        #expect(out.events.allSatisfy { $0.ts == 100 })
        #expect(out.state.frontmost == safari)
        #expect(out.state.signature?.windowTitle == "Apple")
    }

    @Test func unchangedContextEmitsNothing() {
        let first = HeartbeatDiff.compute(
            previous: LastKnownState(), input: input(safari, window: WindowInfo(title: "Apple")))
        let second = HeartbeatDiff.compute(
            previous: first.state, input: input(safari, window: WindowInfo(title: "Apple"), now: 105))
        #expect(second.events.isEmpty)
        #expect(second.state == first.state)
    }

    @Test func titleChangeSnapshotsWithoutRepeatingUnchangedValue() {
        let element = ElementInfo(role: "AXTextArea", value: "same text")
        let first = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(textEdit, window: WindowInfo(title: "a.md"), element: element))
        #expect(first.events[1].value == "same text")
        #expect(first.events[1].extra?["valueHash"] == .string(Hashing.sha256Hex("same text")))

        let second = HeartbeatDiff.compute(
            previous: first.state,
            input: input(textEdit, window: WindowInfo(title: "a.md — Edited"), element: element))
        #expect(second.events.map(\.kind) == [.contextSnapshot])
        #expect(second.events[0].value == nil)
        #expect(second.events[0].extra?["valueUnchanged"] == true)
        #expect(second.events[0].windowTitle == "a.md — Edited")
    }

    @Test func valueChangeSnapshotsWithNewValueAndHash() {
        let first = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(textEdit, element: ElementInfo(role: "AXTextArea", value: "v1")))
        let second = HeartbeatDiff.compute(
            previous: first.state,
            input: input(textEdit, element: ElementInfo(role: "AXTextArea", value: "v2")))
        #expect(second.events.count == 1)
        #expect(second.events[0].value == "v2")
        #expect(second.events[0].extra?["valueHash"] == .string(Hashing.sha256Hex("v2")))
        #expect(second.events[0].extra?["truncated"] == false)
        #expect(second.events[0].extra?["length"] == 2)
    }

    @Test func switchingBetweenAllowedAppsDeactivatesAndActivates() {
        let first = HeartbeatDiff.compute(previous: LastKnownState(), input: input(safari))
        let second = HeartbeatDiff.compute(previous: first.state, input: input(textEdit))
        #expect(second.events.map(\.kind) == [.appDeactivated, .appActivated, .contextSnapshot])
        #expect(second.events[0].bundleID == "com.apple.Safari")
        #expect(second.events[1].bundleID == "com.apple.TextEdit")
    }

    @Test func leavingToOtherAppIsInvisibleByDefault() {
        let first = HeartbeatDiff.compute(previous: LastKnownState(), input: input(safari))
        let second = HeartbeatDiff.compute(previous: first.state, input: input(finder))
        #expect(second.events.map(\.kind) == [.appDeactivated])
        #expect(second.state.frontmost == finder)
        #expect(second.state.signature == nil)
        let third = HeartbeatDiff.compute(previous: second.state, input: input(finder, now: 110))
        #expect(third.events.isEmpty)
    }

    @Test func recordOtherAppsAddsBareActivation() {
        let first = HeartbeatDiff.compute(previous: LastKnownState(), input: input(safari))
        let second = HeartbeatDiff.compute(
            previous: first.state, input: input(finder, window: WindowInfo(title: "Desktop"), others: true))
        #expect(second.events.map(\.kind) == [.appDeactivated, .appActivated])
        #expect(second.events[1].bundleID == "com.apple.finder")
        #expect(second.events[1].windowTitle == nil)
        #expect(second.events[1].extra?["allowlisted"] == false)
    }

    @Test func secureFieldSnapshotHasNoText() {
        let element = ElementInfo(role: "AXTextField", subrole: "AXSecureTextField", value: "pw")
        let out = HeartbeatDiff.compute(previous: LastKnownState(), input: input(safari, element: element))
        let snapshot = out.events[1]
        #expect(snapshot.value == nil)
        #expect(snapshot.selectedText == nil)
        #expect(snapshot.subrole == "AXSecureTextField")
        #expect(snapshot.extra?["valueHash"] == nil)
    }

    @Test func noFrontmostAppClearsState() {
        let first = HeartbeatDiff.compute(previous: LastKnownState(), input: input(safari))
        let second = HeartbeatDiff.compute(previous: first.state, input: input(nil))
        #expect(second.events.map(\.kind) == [.appDeactivated])
        #expect(second.state.frontmost == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter HeartbeatDiffTests`
Expected: build error — `HeartbeatDiff` not found.

- [ ] **Step 3: Implement**

`Sources/Capture/HeartbeatDiff.swift`:
```swift
import Core
import Foundation

/// What the heartbeat compares between ticks. Only the hash of a value is kept.
public struct ContextSignature: Sendable, Equatable {
    public var pid: Int32
    public var windowTitle: String?
    public var document: String?
    public var url: String?
    public var role: String?
    public var subrole: String?
    public var identifier: String?
    public var elementTitle: String?
    public var selectedText: String?
    public var valueHash: String?
}

public struct LastKnownState: Sendable, Equatable {
    public var frontmost: AppInfo?
    public var signature: ContextSignature?
    public var idle = false
    public var idleSince: Double?

    public init() {}
}

/// Spec §6.2: pure diff of the focused context against the last known state.
public enum HeartbeatDiff {
    public struct Input: Sendable {
        public var frontmost: AppInfo?
        public var context: FocusedContext?
        public var allowlist: Set<String>
        public var recordOtherApps: Bool
        public var maxValueBytes: Int
        public var now: Double

        public init(
            frontmost: AppInfo?, context: FocusedContext?, allowlist: Set<String>,
            recordOtherApps: Bool, maxValueBytes: Int, now: Double
        ) {
            self.frontmost = frontmost
            self.context = context
            self.allowlist = allowlist
            self.recordOtherApps = recordOtherApps
            self.maxValueBytes = maxValueBytes
            self.now = now
        }
    }

    public struct Output: Sendable, Equatable {
        public var events: [RawEvent]
        public var state: LastKnownState
    }

    static func isAllowed(_ app: AppInfo?, _ allowlist: Set<String>) -> Bool {
        guard let bundleID = app?.bundleID else { return false }
        return allowlist.contains(bundleID)
    }

    public static func compute(previous: LastKnownState, input: Input) -> Output {
        var events: [RawEvent] = []
        var state = previous
        let app = input.frontmost
        let appChanged = app?.pid != previous.frontmost?.pid
            || app?.bundleID != previous.frontmost?.bundleID
        let allowed = isAllowed(app, input.allowlist)

        if appChanged {
            if let old = previous.frontmost, isAllowed(old, input.allowlist) {
                events.append(appEvent(.appDeactivated, old, allowed: true, now: input.now))
            }
            if let app, allowed {
                events.append(appEvent(.appActivated, app, allowed: true, now: input.now))
            } else if let app, input.recordOtherApps {
                events.append(appEvent(.appActivated, app, allowed: false, now: input.now))
            }
            state.frontmost = app
            state.signature = nil
        }

        guard let app, allowed, let context = input.context else {
            if !allowed { state.signature = nil }
            return Output(events: events, state: state)
        }

        let redacted = Redaction.apply(context.element, maxValueBytes: input.maxValueBytes)
        let hash = redacted.value.map(Hashing.sha256Hex)
        let signature = ContextSignature(
            pid: app.pid, windowTitle: context.window?.title, document: context.window?.document,
            url: context.window?.url, role: context.element?.role,
            subrole: context.element?.subrole, identifier: context.element?.identifier,
            elementTitle: context.element?.title, selectedText: redacted.selectedText,
            valueHash: hash)

        if appChanged || signature != previous.signature {
            let valueUnchanged = hash != nil && hash == previous.signature?.valueHash
            var extra: [String: JSONValue] = ["reason": "heartbeat"]
            if let hash {
                extra["valueHash"] = .string(hash)
                extra["truncated"] = .bool(redacted.truncated)
                extra["length"] = .number(Double(redacted.length))
            }
            if valueUnchanged { extra["valueUnchanged"] = true }
            events.append(
                RawEvent(
                    ts: input.now, kind: .contextSnapshot, pid: app.pid, bundleID: app.bundleID,
                    appName: app.name, windowTitle: context.window?.title,
                    document: context.window?.document, url: context.window?.url,
                    role: context.element?.role, subrole: context.element?.subrole,
                    identifier: context.element?.identifier, elementTitle: context.element?.title,
                    value: valueUnchanged ? nil : redacted.value,
                    selectedText: redacted.selectedText, extra: extra))
        }
        state.signature = signature
        return Output(events: events, state: state)
    }

    private static func appEvent(
        _ kind: EventKind, _ app: AppInfo, allowed: Bool, now: Double
    ) -> RawEvent {
        RawEvent(
            ts: now, kind: kind, pid: app.pid, bundleID: app.bundleID, appName: app.name,
            extra: ["allowlisted": .bool(allowed)])
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter HeartbeatDiffTests`
Expected: 9 tests pass.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Capture/HeartbeatDiff.swift Tests/CaptureTests/HeartbeatDiffTests.swift
git commit -m "Add heartbeat diff against last known state"
```

---

### Task 15: `Capturer` — heartbeat loop, trust states, config reload, idle

**Files:**
- Create: `Sources/Capture/Capturer.swift`
- Test: `Tests/CaptureTests/CapturerTests.swift`

**Interfaces:**
- Consumes: `AXReading`, `HeartbeatDiff`, `LastKnownState`, `Config`, `Paths`, `RawEvent`.
- Produces: `@MainActor public final class Capturer { public let events: AsyncStream<RawEvent>; public private(set) var trust: TrustState; public private(set) var state: LastKnownState; public private(set) var config: Config; public init(ax: any AXReading, paths: Paths, config: Config, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }); public func start(); public func stop(); public func tick() }`. `stop()` finishes the stream. `tick()` is one heartbeat and is what tests drive.

- [ ] **Step 1: Write the failing test**

`Tests/CaptureTests/CapturerTests.swift`:
```swift
import Foundation
import Testing

@testable import Capture
@testable import Core

@Suite @MainActor struct CapturerTests {
    let safari = FakeAXClient.app(10, "com.apple.Safari")
    let finder = FakeAXClient.app(30, "com.apple.finder")

    private func makeCapturer(
        fake: FakeAXClient, allow: [String] = ["com.apple.Safari"], clock: Clock = Clock()
    ) throws -> (Capturer, Paths) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-cap-\(UUID().uuidString)", isDirectory: true)
        let paths = Paths(dataDir: dir)
        try paths.ensureDataDir()
        let config = Config(allowlist: allow)
        try config.save(to: paths.configURL)
        let capturer = Capturer(ax: fake, paths: paths, config: config, now: { clock.now })
        return (capturer, paths)
    }

    final class Clock: @unchecked Sendable {
        var now: Double = 1000
    }

    private func drain(_ capturer: Capturer) async -> [RawEvent] {
        capturer.stop()
        var out: [RawEvent] = []
        for await event in capturer.events { out.append(event) }
        return out
    }

    @Test func untrustedProducesNoReadsUntilGranted() async throws {
        let fake = FakeAXClient()
        fake.trusted = false
        fake.show(safari, window: WindowInfo(title: "Apple"))
        let (capturer, _) = try makeCapturer(fake: fake)

        capturer.tick()
        #expect(capturer.trust == .needsPermission)
        #expect(fake.focusedContextCalls == 0)

        fake.trusted = true
        capturer.tick()
        #expect(capturer.trust == .active)
        #expect(fake.focusedContextCalls == 1)

        let events = await drain(capturer)
        #expect(events.map(\.kind) == [.permissionChanged, .appActivated, .contextSnapshot])
        #expect(events[0].extra?["trusted"] == true)
        #expect(events[0].extra?["state"] == "active")
    }

    @Test func steadyStateEmitsNothing() async throws {
        let fake = FakeAXClient()
        fake.show(safari, window: WindowInfo(title: "Apple"))
        let (capturer, _) = try makeCapturer(fake: fake)
        capturer.tick()
        capturer.tick()
        capturer.tick()
        let events = await drain(capturer)
        #expect(events.map(\.kind) == [.permissionChanged, .appActivated, .contextSnapshot])
    }

    @Test func apiDisabledGoesStaleAndBacksOff() async throws {
        let fake = FakeAXClient()
        let clock = Clock()
        fake.show(safari)
        let (capturer, _) = try makeCapturer(fake: fake, clock: clock)
        capturer.tick()  // active
        fake.errors[safari.pid] = .apiDisabled
        capturer.tick()
        #expect(capturer.trust == .stale)
        let callsAfterStale = fake.focusedContextCalls

        clock.now += 1  // within back-off: no read attempted
        capturer.tick()
        #expect(fake.focusedContextCalls == callsAfterStale)

        fake.errors = [:]
        clock.now += 10  // past the first 5 s back-off
        capturer.tick()
        #expect(capturer.trust == .active)

        let events = await drain(capturer)
        let permission = events.filter { $0.kind == .permissionChanged }
        #expect(permission.map { $0.extra?["state"] } == ["active", "stale", "active"])
    }

    @Test func idleStartsAndEndsWithThreshold() async throws {
        let fake = FakeAXClient()
        let clock = Clock()
        fake.show(safari)
        let (capturer, _) = try makeCapturer(fake: fake, clock: clock)
        capturer.tick()
        fake.idleSeconds = 130
        capturer.tick()
        #expect(capturer.state.idle)
        clock.now += 60
        fake.idleSeconds = 2
        capturer.tick()
        #expect(!capturer.state.idle)

        let events = await drain(capturer)
        let idle = events.filter { $0.kind == .idleStarted || $0.kind == .idleEnded }
        #expect(idle.map(\.kind) == [.idleStarted, .idleEnded])
        #expect(idle[0].extra?["idleSeconds"] == 130)
        #expect(idle[1].extra?["idleSeconds"] == 190)  // 130 + 60 since idle began
    }

    @Test func configReloadPicksUpNewAllowlist() async throws {
        let fake = FakeAXClient()
        fake.show(finder, window: WindowInfo(title: "Desktop"))
        let (capturer, paths) = try makeCapturer(fake: fake, allow: ["com.apple.Safari"])
        capturer.tick()
        #expect(fake.focusedContextCalls == 0)

        try Config(allowlist: ["com.apple.finder"]).save(to: paths.configURL)
        // Ensure the mtime moves even on coarse filesystems.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: paths.configURL.path)
        capturer.tick()
        #expect(capturer.config.allowlist == ["com.apple.finder"])
        #expect(fake.focusedContextCalls == 1)

        let events = await drain(capturer)
        #expect(events.contains { $0.kind == .contextSnapshot && $0.bundleID == "com.apple.finder" })
    }

    @Test func readFailuresAreCountedButDoNotStopCapture() async throws {
        let fake = FakeAXClient()
        fake.show(safari)
        fake.errors[safari.pid] = .cannotComplete
        let (capturer, _) = try makeCapturer(fake: fake)
        capturer.tick()
        capturer.tick()
        #expect(capturer.trust == .active)
        #expect(capturer.readFailures[safari.pid] == 2)
        fake.errors = [:]
        capturer.tick()
        #expect(capturer.readFailures[safari.pid] == nil)
        let events = await drain(capturer)
        #expect(events.map(\.kind) == [.permissionChanged, .appActivated, .contextSnapshot])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter CapturerTests`
Expected: build error — `Capturer` not found.

- [ ] **Step 3: Implement**

`Sources/Capture/Capturer.swift`:
```swift
import Core
import Foundation
import os

/// Drives capture on the main actor: trust state machine, config reload, the heartbeat
/// diff, and idle detection (spec §§6.2, 6.6, 6.8). Observers are added in Part 2.
@MainActor
public final class Capturer {
    public let events: AsyncStream<RawEvent>
    public private(set) var trust: TrustState = .needsPermission
    public private(set) var state = LastKnownState()
    public private(set) var config: Config
    /// Consecutive failed context reads per pid (reset on success). Part 2 turns this into
    /// `app.opaque` events.
    public private(set) var readFailures: [Int32: Int] = [:]

    private let ax: any AXReading
    private let paths: Paths
    private let now: @Sendable () -> Double
    private let continuation: AsyncStream<RawEvent>.Continuation
    private let logger = Logger(subsystem: "org.openrhyme.engine", category: "capture")
    private var configModified: Date?
    private var loop: Task<Void, Never>?
    private var staleBackoff: Double = 5
    private var nextTrustCheck: Double = 0

    public init(
        ax: any AXReading, paths: Paths, config: Config,
        now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.ax = ax
        self.paths = paths
        self.config = config
        self.now = now
        self.configModified = Config.modificationDate(of: paths.configURL)
        let (stream, continuation) = AsyncStream<RawEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
    }

    public func start() {
        guard loop == nil else { return }
        ax.setGlobalMessagingTimeout(0.25)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                let seconds = max(self.config.capture.heartbeatSeconds, 0.5)
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        continuation.finish()
    }

    /// One heartbeat. Public so tests and Part 2's observer path can drive it directly.
    public func tick() {
        reloadConfigIfChanged()
        checkTrust()
        guard trust == .active else { return }
        heartbeat()
        checkIdle()
    }

    private func emit(_ event: RawEvent) {
        continuation.yield(event)
    }

    private func reloadConfigIfChanged() {
        let modified = Config.modificationDate(of: paths.configURL)
        guard modified != configModified else { return }
        configModified = modified
        do {
            config = try Config.load(from: paths.configURL)
            logger.info("config reloaded: \(self.config.allowlist.count) allowlisted apps")
        } catch {
            logger.error("config reload failed: \(String(describing: error))")
        }
    }

    private func setTrust(_ new: TrustState) {
        guard new != trust else { return }
        trust = new
        emit(
            RawEvent(
                ts: now(), kind: .permissionChanged,
                extra: ["trusted": .bool(new == .active), "state": .string(new.rawValue)]))
    }

    private func checkTrust() {
        switch trust {
        case .active:
            return
        case .needsPermission:
            if ax.isTrusted(prompt: false) { setTrust(.active) }
        case .stale:
            guard now() >= nextTrustCheck else { return }
            if ax.isTrusted(prompt: false) {
                setTrust(.active)
                staleBackoff = 5
            } else {
                scheduleStaleRetry()
            }
        }
    }

    private func scheduleStaleRetry() {
        nextTrustCheck = now() + staleBackoff
        staleBackoff = min(staleBackoff * 2, 60)
    }

    private func heartbeat() {
        let frontmost = ax.frontmostApplication()
        var context: FocusedContext?
        if let frontmost, HeartbeatDiff.isAllowed(frontmost, config.allowlistSet) {
            do {
                context = try ax.focusedContext(of: frontmost)
                readFailures[frontmost.pid] = nil
            } catch AXReadError.apiDisabled {
                setTrust(.stale)
                staleBackoff = 5
                scheduleStaleRetry()
                return
            } catch {
                readFailures[frontmost.pid, default: 0] += 1
                logger.warning(
                    "read failed for pid \(frontmost.pid): \(String(describing: error)) (\(self.readFailures[frontmost.pid] ?? 0)x)")
            }
        }
        let output = HeartbeatDiff.compute(
            previous: state,
            input: HeartbeatDiff.Input(
                frontmost: frontmost, context: context, allowlist: config.allowlistSet,
                recordOtherApps: config.capture.recordOtherApps,
                maxValueBytes: config.capture.maxValueBytes, now: now()))
        for event in output.events { emit(event) }
        let idle = state.idle
        let idleSince = state.idleSince
        state = output.state
        state.idle = idle
        state.idleSince = idleSince
    }

    private func checkIdle() {
        let idleSeconds = ax.secondsSinceLastInput()
        let threshold = config.capture.idleSeconds
        if !state.idle, idleSeconds >= threshold {
            state.idle = true
            state.idleSince = now() - idleSeconds
            emit(RawEvent(ts: now(), kind: .idleStarted, extra: ["idleSeconds": .number(idleSeconds)]))
        } else if state.idle, idleSeconds < threshold {
            let span = now() - (state.idleSince ?? now())
            state.idle = false
            state.idleSince = nil
            emit(RawEvent(ts: now(), kind: .idleEnded, extra: ["idleSeconds": .number(span)]))
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CapturerTests`
Expected: 6 tests pass. The `idleEnded` expectation is `190`: idle began at `now − 130`, and `now` advanced by 60 before the end tick, so the span is `130 + 60`.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Capture/Capturer.swift Tests/CaptureTests/CapturerTests.swift
git commit -m "Add Capturer heartbeat loop with trust states and idle"
```

---

### Task 16: `AXClient` (real Accessibility reads), `ElectronSupport`, `apps running`

**Files:**
- Create: `Sources/Capture/AXClient.swift`, `Sources/Capture/AXClient+Inspect.swift`, `Sources/Capture/AXTypes+Codable.swift`, `Sources/Capture/ElectronSupport.swift`
- Modify: `Sources/openrhyme/AppsCommand.swift` (add `Running` subcommand)
- Test: `Tests/CaptureTests/ElectronSupportTests.swift`, `Tests/CaptureTests/LiveAXClientTests.swift` (gated), `Tests/CLITests/AppsRunningTests.swift`

**Interfaces:**
- Consumes: `AXReading`, `AppInfo`, `WindowInfo`, `ElementInfo`, `TextRange`, `FocusedContext`, `AXReadError`.
- Produces: `@MainActor public final class AXClient: AXReading { public init() }` plus `public func focusedElementInspection(of app: AppInfo, depth: Int) throws -> ElementInspection` (in `AXClient+Inspect.swift`); `public struct ElementNode: Sendable, Encodable { role, subrole, title, identifier, value: String?; children: [ElementNode] }`; `public struct ElementInspection: Sendable, Encodable { attributeNames: [String]; tree: ElementNode? }`; `extension AppInfo: Codable`, `WindowInfo: Codable`, `TextRange: Codable`, `ElementInfo: Codable`, `FocusedContext: Codable`; `public enum ElectronSupport { public static func isElectronBundle(_ bundleURL: URL?) -> Bool }`; `extension AppInfo { public init(running: NSRunningApplication) }`.
- Produces (CLI): `openrhyme apps running [--json]` → `{"apps":[{"pid","bundle_id","name","allowlisted","is_electron"}]}`.

- [ ] **Step 1: Write the failing tests**

`Tests/CaptureTests/ElectronSupportTests.swift`:
```swift
import Foundation
import Testing

@testable import Capture

@Suite struct ElectronSupportTests {
    @Test func detectsElectronFrameworkInsideBundle() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fake-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
            withIntermediateDirectories: true)
        #expect(ElectronSupport.isElectronBundle(bundle))
    }

    @Test func nativeBundleIsNotElectron() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("Native-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        #expect(!ElectronSupport.isElectronBundle(bundle))
        #expect(!ElectronSupport.isElectronBundle(nil))
    }
}
```

`Tests/CaptureTests/LiveAXClientTests.swift` — runs only with `OPENRHYME_LIVE_AX=1` and a trusted terminal:
```swift
import Foundation
import Testing

@testable import Capture

@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENRHYME_LIVE_AX"] == "1"))
@MainActor struct LiveAXClientTests {
    @Test func readsFrontmostContextWithoutThrowing() throws {
        let client = AXClient()
        #expect(client.isTrusted(prompt: false), "grant Accessibility to the terminal first")
        let frontmost = try #require(client.frontmostApplication())
        let context = try client.focusedContext(of: frontmost)
        #expect(context.app == frontmost)
        #expect(client.runningApplications().contains { $0.pid == frontmost.pid })
        #expect(client.secondsSinceLastInput() >= 0)
        let inspection = try client.focusedElementInspection(of: frontmost, depth: 1)
        #expect(!inspection.attributeNames.isEmpty || inspection.tree == nil)
    }
}
```

`Tests/CLITests/AppsRunningTests.swift`:
```swift
import Foundation
import Testing

@Suite struct AppsRunningTests {
    @Test func listsRunningAppsWithFlags() throws {
        let dir = try CLIRunner.tempDataDir()
        let env = ["OPENRHYME_DATA_DIR": dir.path]
        _ = try CLIRunner.run(["apps", "allow", "com.apple.finder"], env: env)
        let result = try CLIRunner.run(["apps", "running", "--json"], env: env)
        #expect(result.status == 0, result.stderr)
        let apps = (try CLIRunner.json(result.stdout)["data"] as? [String: Any])?["apps"] as? [[String: Any]]
        let finder = apps?.first { $0["bundle_id"] as? String == "com.apple.finder" }
        #expect(finder != nil, "Finder is always running in a logged-in session")
        #expect(finder?["allowlisted"] as? Bool == true)
        #expect(finder?["is_electron"] as? Bool == false)
        #expect((finder?["pid"] as? Int ?? 0) > 0)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "ElectronSupportTests|AppsRunningTests"`
Expected: build error — `ElectronSupport`/`AXClient` not found.

- [ ] **Step 3: Implement**

`Sources/Capture/ElectronSupport.swift`:
```swift
import Foundation

/// Spec §6.7. Detection only; enabling the AX tree is added in Part 2.
public enum ElectronSupport {
    public static func isElectronBundle(_ bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let framework = bundleURL.appendingPathComponent(
            "Contents/Frameworks/Electron Framework.framework", isDirectory: true)
        return FileManager.default.fileExists(atPath: framework.path)
    }
}
```

`Sources/Capture/AXTypes+Codable.swift`:
```swift
extension AppInfo: Codable {
    enum CodingKeys: String, CodingKey {
        case pid
        case bundleID = "bundle_id"
        case name
        case bundleURL = "bundle_url"
    }
}

extension WindowInfo: Codable {}
extension TextRange: Codable {}

extension ElementInfo: Codable {
    enum CodingKeys: String, CodingKey {
        case role, subrole, identifier, title, value
        case selectedText = "selected_text"
        case selectedRange = "selected_range"
        case numberOfCharacters = "number_of_characters"
    }
}

extension FocusedContext: Codable {}
```

`Sources/Capture/AXClient.swift`:
```swift
import AppKit
import ApplicationServices
import Core
import Foundation

extension AppInfo {
    public init(running app: NSRunningApplication) {
        self.init(
            pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName,
            bundleURL: app.bundleURL)
    }
}

/// The real `AXReading` over the C API (docs/accessibility-api.md §3). Every read is one
/// `AXUIElementCopyMultipleAttributeValues` round-trip per element.
@MainActor
public final class AXClient: AXReading {
    public init() {}

    public func isTrusted(prompt: Bool) -> Bool {
        // The literal key avoids importing the non-Sendable `kAXTrustedCheckOptionPrompt` global.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func setGlobalMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    public func runningApplications() -> [AppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map(AppInfo.init(running:))
    }

    public func frontmostApplication() -> AppInfo? {
        NSWorkspace.shared.frontmostApplication.map(AppInfo.init(running:))
    }

    public func focusedContext(of app: AppInfo) throws -> FocusedContext {
        let application = AXUIElementCreateApplication(app.pid)
        var window: WindowInfo?
        if let focusedWindow = try element(application, kAXFocusedWindowAttribute) {
            window = try readWindow(focusedWindow)
        }
        var element: ElementInfo?
        if let focused = try self.element(application, kAXFocusedUIElementAttribute) {
            element = try readElement(focused)
        }
        return FocusedContext(app: app, window: window, element: element)
    }

    public func secondsSinceLastInput() -> Double {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // MARK: - Reads (internal so AXClient+Inspect can reuse them)

    func readWindow(_ window: AXUIElement) throws -> WindowInfo {
        let values = try attributes(
            window, [kAXTitleAttribute, kAXDocumentAttribute, kAXURLAttribute])
        return WindowInfo(
            title: string(values[0]), document: string(values[1]) ?? url(values[1]),
            url: url(values[2]) ?? string(values[2]))
    }

    func readElement(_ element: AXUIElement) throws -> ElementInfo {
        let identity = try attributes(
            element,
            [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute])
        var info = ElementInfo(
            role: string(identity[0]), subrole: string(identity[1]),
            identifier: string(identity[2]), title: string(identity[3]))
        guard !info.isSecure else { return info }

        let content = try attributes(
            element,
            [
                kAXValueAttribute, kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute,
                kAXNumberOfCharactersAttribute, kAXDescriptionAttribute,
            ])
        // Spec §6.4 order: value → selected text → description for static text.
        info.value = string(content[0]) ?? number(content[0]).map { String($0) }
        if info.value == nil, info.role == kAXStaticTextRole {
            info.value = string(content[4]) ?? info.title
        }
        info.selectedText = string(content[1])
        info.selectedRange = range(content[2])
        info.numberOfCharacters = number(content[3]).map(Int.init)
        return info
    }

    func element(_ parent: AXUIElement, _ name: String) throws -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(parent, name as CFString, &value)
        try check(error)
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func elements(_ parent: AXUIElement, _ name: String) throws -> [AXUIElement] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(parent, name as CFString, &value)
        try check(error)
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return ((value as! CFArray) as NSArray).compactMap { item -> AXUIElement? in
            let object = item as AnyObject
            guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            return (object as! AXUIElement)
        }
    }

    /// One IPC for several attributes. Unsupported attributes come back as `nil`.
    func attributes(_ element: AXUIElement, _ names: [String]) throws -> [CFTypeRef?] {
        var array: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &array)
        try check(error)
        guard let array else { return Array(repeating: nil, count: names.count) }
        return (0..<CFArrayGetCount(array)).map { index -> CFTypeRef? in
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { return nil }
            let value = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
            if CFGetTypeID(value) == AXValueGetTypeID(),
                AXValueGetType(value as! AXValue) == .axError
            {
                return nil  // placeholder for an unsupported attribute
            }
            return value
        }
    }

    func attributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success, let names else {
            return []
        }
        return (names as NSArray).compactMap { $0 as? String }
    }

    func check(_ error: AXError) throws {
        switch error {
        case .success, .noValue, .attributeUnsupported: return
        case .apiDisabled: throw AXReadError.apiDisabled
        case .cannotComplete: throw AXReadError.cannotComplete
        case .notImplemented: throw AXReadError.notImplemented
        case .invalidUIElement: throw AXReadError.invalidElement
        default: throw AXReadError.other(error.rawValue)
        }
    }

    // MARK: - CF conversions

    func string(_ value: CFTypeRef?) -> String? {
        guard let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    func url(_ value: CFTypeRef?) -> String? {
        guard let value, CFGetTypeID(value) == CFURLGetTypeID() else { return nil }
        return ((value as! CFURL) as URL).absoluteString
    }

    func number(_ value: CFTypeRef?) -> Double? {
        guard let value, CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        return ((value as! CFNumber) as NSNumber).doubleValue
    }

    func range(_ value: CFTypeRef?) -> TextRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var cfRange = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &cfRange) else { return nil }
        return TextRange(location: cfRange.location, length: cfRange.length)
    }
}
```

`Sources/Capture/AXClient+Inspect.swift`:
```swift
import ApplicationServices
import Foundation

public struct ElementNode: Sendable, Encodable {
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var identifier: String?
    public var value: String?
    public var children: [ElementNode]
}

public struct ElementInspection: Sendable, Encodable {
    public var attributeNames: [String]
    public var tree: ElementNode?
}

extension AXClient {
    /// Developer tool behind `openrhyme inspect`: attribute names of the focused element and
    /// a bounded subtree (`depth` ≤ 3, at most 200 nodes). The daemon never walks trees.
    public func focusedElementInspection(of app: AppInfo, depth: Int) throws -> ElementInspection {
        let application = AXUIElementCreateApplication(app.pid)
        guard let focused = try element(application, kAXFocusedUIElementAttribute) else {
            return ElementInspection(attributeNames: [], tree: nil)
        }
        var budget = 200
        let tree = try node(focused, depth: min(max(depth, 0), 3), budget: &budget)
        return ElementInspection(attributeNames: attributeNames(focused), tree: tree)
    }

    private func node(_ element: AXUIElement, depth: Int, budget: inout Int) throws -> ElementNode {
        budget -= 1
        let info = try readElement(element)
        var children: [ElementNode] = []
        if depth > 0, budget > 0 {
            for child in try elements(element, kAXChildrenAttribute) where budget > 0 {
                children.append(try node(child, depth: depth - 1, budget: &budget))
            }
        }
        return ElementNode(
            role: info.role, subrole: info.subrole, title: info.title, identifier: info.identifier,
            value: info.value.map { String($0.prefix(200)) }, children: children)
    }
}
```

Add to `Sources/openrhyme/AppsCommand.swift` (inside `AppsCommand`, and register `Running.self` in `subcommands`):
```swift
    struct RunningApp: Encodable {
        let pid: Int32
        let bundleID: String?
        let name: String?
        let allowlisted: Bool
        let isElectron: Bool

        enum CodingKeys: String, CodingKey {
            case pid, name, allowlisted
            case bundleID = "bundle_id"
            case isElectron = "is_electron"
        }
    }

    struct RunningList: Encodable {
        let apps: [RunningApp]
    }

    struct Running: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List running apps with their bundle identifiers.")
        @Flag(name: .long) var json = false

        func run() async throws {
            try await runJSON(json: json, human: Self.human) {
                let config = try Config.load(from: Paths.resolve().configURL)
                let apps = await MainActor.run { AXClient().runningApplications() }
                return RunningList(
                    apps: apps.sorted { ($0.name ?? "") < ($1.name ?? "") }.map { app in
                        RunningApp(
                            pid: app.pid, bundleID: app.bundleID, name: app.name,
                            allowlisted: config.isAllowed(app.bundleID),
                            isElectron: ElectronSupport.isElectronBundle(app.bundleURL))
                    })
            }
        }

        static func human(_ list: RunningList) -> String {
            list.apps.map { app in
                let flags = [app.allowlisted ? "allowed" : nil, app.isElectron ? "electron" : nil]
                    .compactMap { $0 }.joined(separator: ",")
                return "\(app.bundleID ?? "-")\t\(app.name ?? "-")\t\(flags)"
            }.joined(separator: "\n")
        }
    }
```
Add `import Capture` at the top of `AppsCommand.swift`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "ElectronSupportTests|AppsRunningTests"`
Expected: 3 tests pass; `LiveAXClientTests` is skipped (disabled) unless `OPENRHYME_LIVE_AX=1`. Then, once, from a terminal that has the Accessibility grant: `OPENRHYME_LIVE_AX=1 swift test --filter LiveAXClientTests` — expected pass. If the terminal lacks the grant the test fails on its first expectation with the hint; grant it (System Settings → Privacy & Security → Accessibility → your terminal app) and re-run.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Capture Sources/openrhyme/AppsCommand.swift Tests
git commit -m "Add AXClient, Electron detection and apps running"
```

---

### Task 17: `inspect` command

**Files:**
- Create: `Sources/openrhyme/InspectCommand.swift`
- Modify: `Sources/openrhyme/OpenRhyme.swift`
- Test: `Tests/CLITests/InspectCommandTests.swift`

**Interfaces:**
- Consumes: `AXClient.isTrusted`, `frontmostApplication`, `focusedContext(of:)`, `focusedElementInspection(of:depth:)`, `CLIError.notTrusted`.
- Produces: `openrhyme inspect [--depth N] [--json]` → `{"app":…,"window":…,"element":…,"attribute_names":[…],"tree":…}`; exit 3 when not trusted.

- [ ] **Step 1: Write the failing test**

`Tests/CLITests/InspectCommandTests.swift`:
```swift
import Foundation
import Testing

@Suite struct InspectCommandTests {
    @Test func inspectEitherReportsContextOrNotTrusted() throws {
        let result = try CLIRunner.run(["inspect", "--json", "--depth", "1"])
        let envelope = try CLIRunner.json(result.stdout)
        if result.status == 3 {
            #expect(envelope["ok"] as? Bool == false)
            #expect((envelope["error"] as? [String: Any])?["code"] as? String == "not_trusted")
        } else {
            #expect(result.status == 0, result.stderr)
            let data = envelope["data"] as? [String: Any]
            #expect(data?["app"] != nil)
            #expect(data?["attribute_names"] is [String])
        }
    }

    @Test func inspectRejectsNegativeDepth() throws {
        let result = try CLIRunner.run(["inspect", "--depth", "-1", "--json"])
        #expect(result.status == 2 || result.status == 64)  // ArgumentParser uses EX_USAGE
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter InspectCommandTests`
Expected: FAIL — `inspect` is not a known subcommand.

- [ ] **Step 3: Implement**

`Sources/openrhyme/InspectCommand.swift`:
```swift
import ArgumentParser
import Capture
import Core
import Foundation

struct InspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Dump the focused app, window and element as the daemon sees them (dev tool).")

    @Option(name: .long, help: "Child levels to include under the focused element (0–3).")
    var depth: Int = 0
    @Flag(name: .long, help: "Emit a JSON envelope.") var json = false

    struct Inspection: Encodable {
        let app: AppInfo?
        let window: WindowInfo?
        let element: ElementInfo?
        let attributeNames: [String]
        let tree: ElementNode?

        enum CodingKeys: String, CodingKey {
            case app, window, element, tree
            case attributeNames = "attribute_names"
        }
    }

    func validate() throws {
        guard (0...3).contains(depth) else {
            throw ValidationError("--depth must be between 0 and 3")
        }
    }

    func run() async throws {
        let depth = self.depth
        try await runJSON(json: json, human: Self.human) {
            try await MainActor.run {
                let client = AXClient()
                guard client.isTrusted(prompt: false) else { throw CLIError.notTrusted }
                guard let app = client.frontmostApplication() else {
                    return Inspection(app: nil, window: nil, element: nil, attributeNames: [], tree: nil)
                }
                let context = try client.focusedContext(of: app)
                let inspection = try client.focusedElementInspection(of: app, depth: depth)
                return Inspection(
                    app: app, window: context.window, element: context.element,
                    attributeNames: inspection.attributeNames, tree: inspection.tree)
            }
        }
    }

    static func human(_ inspection: Inspection) -> String {
        var lines: [String] = []
        lines.append("app:      \(inspection.app?.bundleID ?? "-") (pid \(inspection.app?.pid ?? 0))")
        lines.append("window:   \(inspection.window?.title ?? "-")")
        if let document = inspection.window?.document { lines.append("document: \(document)") }
        if let url = inspection.window?.url { lines.append("url:      \(url)") }
        if let element = inspection.element {
            lines.append("element:  \(element.role ?? "-") / \(element.subrole ?? "-") \(element.title ?? "")")
            if let value = element.value { lines.append("value:    \(value.prefix(200))") }
            if let selected = element.selectedText { lines.append("selected: \(selected.prefix(200))") }
        }
        lines.append("attributes: \(inspection.attributeNames.joined(separator: " "))")
        return lines.joined(separator: "\n")
    }
}
```

`ValidationError` from ArgumentParser makes the command exit with `EX_USAGE` (64), which the test accepts alongside `2`. Register `InspectCommand.self` in `OpenRhyme.swift`'s `subcommands`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter InspectCommandTests`
Expected: 2 tests pass. Then try it by hand from a trusted terminal: `swift run openrhyme inspect` with TextEdit frontmost — you should see the window title, document URL, `AXTextArea`, and the text.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/openrhyme Tests/CLITests
git commit -m "Add inspect command"
```

---

### Task 18: `status` command

**Files:**
- Create: `Sources/openrhyme/StatusCommand.swift`
- Modify: `Sources/openrhyme/OpenRhyme.swift`
- Test: `Tests/CLITests/StatusCommandTests.swift`

**Interfaces:**
- Consumes: `AXClient.isTrusted`, `PIDFile.livePID`, `EventStore(readOnly:)`, `count()`, `lastEventTS()`, `Config.load`.
- Produces: `openrhyme status [--json]` → `{"trusted","state","daemon_running","pid","data_dir","db_path","event_count","last_event_ts","allowlist","opaque_apps"}`.

- [ ] **Step 1: Write the failing test**

`Tests/CLITests/StatusCommandTests.swift`:
```swift
import Foundation
import Testing

@testable import Core
@testable import Store

@Suite struct StatusCommandTests {
    @Test func reportsEmptyStateWithoutDatabase() throws {
        let dir = try CLIRunner.tempDataDir()
        let result = try CLIRunner.run(["status", "--json"], env: ["OPENRHYME_DATA_DIR": dir.path])
        #expect(result.status == 0, result.stderr)
        let data = try CLIRunner.json(result.stdout)["data"] as? [String: Any]
        #expect(data?["daemon_running"] as? Bool == false)
        #expect(data?["event_count"] as? Int == 0)
        #expect(data?["last_event_ts"] == nil || data?["last_event_ts"] is NSNull)
        #expect(data?["data_dir"] as? String == dir.path)
        #expect(data?["allowlist"] as? [String] == [])
        #expect(data?["opaque_apps"] as? [String] == [])
        #expect(["active", "needsPermission"].contains(data?["state"] as? String ?? ""))
    }

    @Test func reportsCountsAndLiveDaemon() async throws {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        try await store.append(RawEvent(ts: 5, kind: .daemonStarted))
        try await store.append(RawEvent(ts: 9, kind: .appActivated, bundleID: "com.a"))
        await store.close()
        // The test process itself stands in for a live daemon.
        try PIDFile(url: dir.appendingPathComponent("daemon.pid")).acquire()
        try Config(allowlist: ["com.a"]).save(to: dir.appendingPathComponent("config.json"))

        let result = try CLIRunner.run(["status", "--json"], env: ["OPENRHYME_DATA_DIR": dir.path])
        #expect(result.status == 0, result.stderr)
        let data = try CLIRunner.json(result.stdout)["data"] as? [String: Any]
        #expect(data?["daemon_running"] as? Bool == true)
        #expect(data?["pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier))
        #expect(data?["event_count"] as? Int == 2)
        #expect(data?["last_event_ts"] as? Double == 9)
        #expect(data?["allowlist"] as? [String] == ["com.a"])

        let human = try CLIRunner.run(["status"], env: ["OPENRHYME_DATA_DIR": dir.path])
        #expect(human.stdout.contains("daemon:   running"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter StatusCommandTests`
Expected: FAIL — `status` is not a known subcommand.

- [ ] **Step 3: Implement**

`Sources/openrhyme/StatusCommand.swift`:
```swift
import ArgumentParser
import Capture
import Core
import Foundation
import Store

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Trust state, daemon liveness, store size, allowlist.")

    @Flag(name: .long, help: "Emit a JSON envelope.") var json = false

    struct Status: Encodable {
        let trusted: Bool
        let state: String
        let daemonRunning: Bool
        let pid: Int32?
        let dataDir: String
        let dbPath: String
        let eventCount: Int64
        let lastEventTS: Double?
        let allowlist: [String]
        let opaqueApps: [String]

        enum CodingKeys: String, CodingKey {
            case trusted, state, pid, allowlist
            case daemonRunning = "daemon_running"
            case dataDir = "data_dir"
            case dbPath = "db_path"
            case eventCount = "event_count"
            case lastEventTS = "last_event_ts"
            case opaqueApps = "opaque_apps"
        }
    }

    func run() async throws {
        try await runJSON(json: json, human: Self.human) {
            let paths = Paths.resolve()
            let trusted = await MainActor.run { AXClient().isTrusted(prompt: false) }
            let config = try Config.load(from: paths.configURL)
            let livePID = PIDFile(url: paths.pidFileURL).livePID
            var count: Int64 = 0
            var last: Double?
            if FileManager.default.fileExists(atPath: paths.databaseURL.path) {
                let store = try EventStore(url: paths.databaseURL, readOnly: true)
                count = try await store.count()
                last = try await store.lastEventTS()
                await store.close()
            }
            return Status(
                trusted: trusted,
                state: trusted ? TrustState.active.rawValue : TrustState.needsPermission.rawValue,
                daemonRunning: livePID != nil, pid: livePID, dataDir: paths.dataDir.path,
                dbPath: paths.databaseURL.path, eventCount: count, lastEventTS: last,
                allowlist: config.allowlist, opaqueApps: [])
        }
    }

    static func human(_ status: Status) -> String {
        let last = status.lastEventTS.map {
            ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0))
        } ?? "-"
        return """
            trusted:  \(status.trusted) (\(status.state))
            daemon:   \(status.daemonRunning ? "running (pid \(status.pid ?? 0))" : "not running")
            data dir: \(status.dataDir)
            events:   \(status.eventCount) (last \(last))
            allowed:  \(status.allowlist.isEmpty ? "(none)" : status.allowlist.joined(separator: ", "))
            """
    }
}
```

Register `StatusCommand.self` in `OpenRhyme.swift`. `opaque_apps` is always empty in Part 1; Part 2 fills it from the daemon's `app.opaque` events.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter StatusCommandTests`
Expected: 2 tests pass.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/openrhyme Tests/CLITests
git commit -m "Add status command"
```

---

### Task 19: `daemon` command, runtime wiring, docs

**Files:**
- Create: `Sources/openrhyme/DaemonCommand.swift`, `Sources/openrhyme/SignalWaiter.swift`
- Modify: `Sources/openrhyme/OpenRhyme.swift`, `README.md` (Building section), `CLAUDE.md` (State section), `Makefile` (add `run` target)
- Test: `Tests/CLITests/DaemonCommandTests.swift`

**Interfaces:**
- Consumes: `Capturer`, `AXClient`, `EventStore`, `PIDFile`, `Config`, `Paths`, `EngineVersion`, `Schema.version`.
- Produces: `openrhyme daemon [--no-prompt] [--verbose]`; `@MainActor final class SignalWaiter { init(signals: [Int32]); func wait() async }`.

- [ ] **Step 1: Write the failing test**

`Tests/CLITests/DaemonCommandTests.swift`:
```swift
import Foundation
import Testing

@testable import Core
@testable import Store

@Suite struct DaemonCommandTests {
    private func launchDaemon(dataDir: URL) throws -> Process {
        let process = Process()
        process.executableURL = CLIRunner.binaryURL
        process.arguments = ["daemon", "--no-prompt"]
        var env = ProcessInfo.processInfo.environment
        env["OPENRHYME_DATA_DIR"] = dataDir.path
        process.environment = env
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        return process
    }

    private func waitForPIDFile(_ dir: URL, timeout: TimeInterval = 10) async -> Bool {
        let pidfile = PIDFile(url: dir.appendingPathComponent("daemon.pid"))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pidfile.livePID != nil { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test func startsWritesPidfileAndStopsCleanlyOnSIGTERM() async throws {
        let dir = try CLIRunner.tempDataDir()
        let daemon = try launchDaemon(dataDir: dir)
        #expect(await waitForPIDFile(dir), "daemon did not write daemon.pid")

        daemon.terminate()  // SIGTERM
        daemon.waitUntilExit()
        #expect(daemon.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("daemon.pid").path))

        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"), readOnly: true)
        let events = try await store.query(EventQuery(since: 0))
        await store.close()
        #expect(events.first?.kind == .daemonStarted)
        #expect(events.first?.extra?["version"] == "0.1.0")
        #expect(events.first?.extra?["schema"] == 1)
        #expect(events.last?.kind == .daemonStopped)
    }

    @Test func secondDaemonIsRefused() async throws {
        let dir = try CLIRunner.tempDataDir()
        let first = try launchDaemon(dataDir: dir)
        #expect(await waitForPIDFile(dir))

        let second = try CLIRunner.run(["daemon", "--no-prompt", "--json"], env: ["OPENRHYME_DATA_DIR": dir.path])
        #expect(second.status == 1)
        #expect((try CLIRunner.json(second.stdout)["error"] as? [String: Any])?["code"] as? String == "daemon_already_running")

        first.terminate()
        first.waitUntilExit()
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter DaemonCommandTests`
Expected: FAIL — `daemon` is not a known subcommand (the process exits immediately, no pidfile).

- [ ] **Step 3: Implement**

`Sources/openrhyme/SignalWaiter.swift`:
```swift
import Dispatch
import Foundation

/// Suspends until one of the given signals arrives. Signal sources are delivered on the main
/// queue, which the async main loop services while we await.
@MainActor
final class SignalWaiter {
    private var sources: [DispatchSourceSignal] = []
    private var continuation: CheckedContinuation<Int32, Never>?

    init(signals: [Int32]) {
        for sig in signals {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.fire(sig) }
            }
            source.resume()
            sources.append(source)
        }
    }

    private func fire(_ sig: Int32) {
        continuation?.resume(returning: sig)
        continuation = nil
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}
```

`Sources/openrhyme/DaemonCommand.swift`:
```swift
import ArgumentParser
import Capture
import Core
import Foundation
import Store
import os

struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon", abstract: "Run capture in the foreground until SIGINT/SIGTERM.")

    @Flag(name: .long, help: "Do not show the Accessibility permission dialog.") var noPrompt = false
    @Flag(name: .long, help: "Log every stored event to stderr.") var verbose = false
    @Flag(name: .long, help: "Report startup failures as a JSON envelope.") var json = false

    func run() async throws {
        do {
            try await runDaemon()
        } catch {
            let cli = Output.cliError(error)
            if json { print(Output.envelope(cli)) } else { Output.stderr("error: \(cli.message)") }
            throw ExitCode(cli.exitCode)
        }
    }

    /// Everything that touches AX lives on the main actor; the store is an actor of its own.
    @MainActor
    private func runDaemon() async throws {
        let logger = Logger(subsystem: "org.openrhyme.engine", category: "daemon")
        let paths = Paths.resolve()
        try paths.ensureDataDir()
        let config = try Config.load(from: paths.configURL)
        let pidfile = PIDFile(url: paths.pidFileURL)
        do {
            try pidfile.acquire()
        } catch let error as PIDFileError {
            throw CLIError(
                code: "daemon_already_running",
                message: "A daemon is already running (pid \(error.runningPID))",
                hint: "Stop it first, or remove \(paths.pidFileURL.path) if that pid is stale")
        }
        defer { pidfile.release() }

        let store = try EventStore(url: paths.databaseURL)
        let client = AXClient()
        if !client.isTrusted(prompt: !noPrompt) {
            Output.stderr(
                "Accessibility permission missing — enable it for the app that runs openrhyme in System Settings → Privacy & Security → Accessibility. Capture starts automatically once granted.")
        }
        let capturer = Capturer(ax: client, paths: paths, config: config)
        let waiter = SignalWaiter(signals: [SIGINT, SIGTERM])

        try await store.append(
            RawEvent(
                ts: Date().timeIntervalSince1970, kind: .daemonStarted,
                extra: [
                    "version": .string(EngineVersion.string),
                    "schema": .number(Double(Schema.version)),
                    "allowlist": .array(config.allowlist.map(JSONValue.string)),
                ]))
        let allowed = config.allowlist.isEmpty
            ? "(none — run `openrhyme apps allow <bundle-id>`)" : config.allowlist.joined(separator: ", ")
        Output.stderr("openrhyme daemon \(EngineVersion.string) — data dir \(paths.dataDir.path); allowlisted: \(allowed)")

        // The consumer runs off the main thread; `events`, `store` and `logger` are Sendable.
        let events = capturer.events
        let verbose = self.verbose
        let consumer = Task.detached {
            for await event in events {
                do {
                    try await store.append(event)
                    if verbose { Output.stderr("\(event.kind.rawValue) \(event.bundleID ?? "")") }
                } catch {
                    logger.error("store append failed: \(String(describing: error))")
                }
            }
        }
        capturer.start()

        let sig = await waiter.wait()
        logger.info("signal \(sig) received, stopping")
        capturer.stop()
        await consumer.value
        try await store.append(RawEvent(ts: Date().timeIntervalSince1970, kind: .daemonStopped))
        await store.close()
        Output.stderr("stopped")
    }
}
```

Register `DaemonCommand.self` first in `OpenRhyme.swift`'s `subcommands` so it leads the help output:
```swift
subcommands: [
    DaemonCommand.self, StatusCommand.self, AppsCommand.self, InspectCommand.self,
    EventsCommand.self, ExportCommand.self, VersionCommand.self,
]
```

`Makefile` — add:
```make
run:
	swift build && .build/debug/openrhyme daemon --verbose
```
and `run` to `.PHONY`.

`README.md` — replace the **Building** section's last paragraph with:
```markdown
## Running the MVP

```sh
make build
.build/debug/openrhyme apps running          # find bundle identifiers
.build/debug/openrhyme apps allow com.apple.TextEdit
make run                                     # starts the daemon in the foreground
# in another terminal, after a while:
.build/debug/openrhyme status
.build/debug/openrhyme events --since 10m
.build/debug/openrhyme export --since 1d --out today.jsonl
```

The daemon needs the **Accessibility** grant. When launched from a terminal, macOS attributes the request to the terminal app, so grant it to Terminal/iTerm (System Settings → Privacy & Security → Accessibility). `openrhyme inspect` shows exactly what the daemon can see for the frontmost app.
```

`CLAUDE.md` — in **State**, replace "Workspace scaffolded, no implementation yet. Every `Sources/*/*.swift` file is a comment-only stub." with "Part 1 of the MVP plan is implemented: Core, Store, CLI (`daemon`, `status`, `apps`, `inspect`, `events`, `export`, `version`) and heartbeat capture. Observers, Electron enabling and opaque-app detection are Part 2 (`docs/superpowers/plans/`)."

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter DaemonCommandTests`
Expected: 2 tests pass. Then the whole suite and lint: `make build && make test && make lint` — all green.

- [ ] **Step 5: Manual smoke (from a trusted terminal)**

```sh
.build/debug/openrhyme apps allow com.apple.TextEdit
make run
```
Open TextEdit, type a few words, switch to another app and back. In a second terminal: `openrhyme events --since 5m` should show `permission.changed`, `app.activated`, `context.snapshot` rows with the window title and text. Ctrl-C the daemon: it prints `stopped`, and `openrhyme status` shows `daemon: not running`.

- [ ] **Step 6: Format and commit**

```bash
make format && make lint
git add Sources/openrhyme Tests/CLITests Makefile README.md CLAUDE.md
git commit -m "Add daemon command and runtime wiring"
```

---

## Self-review (against the spec)

**Spec coverage for Part 1's scope (§12 milestones 1–2):**

| Spec section | Task |
|---|---|
| §3 architecture, main-thread AX, actor store, `AsyncStream` | 8, 15, 19 |
| §4 modules and dependency rules; `AXReading` protocol + fake | 1, 13 |
| §5 `RawEvent`, `EventKind`, `JSONValue`, per-kind fields (heartbeat kinds) | 1, 2, 14, 15 |
| §6.1 allowlist, no reads of other apps, `record_other_apps` | 14 |
| §6.2 heartbeat: config reload, trust re-check, focused-context pull, diff, idle | 15 (+ 14) |
| §6.4 attribute bundle, one `CopyMultipleAttributeValues`, text order | 16 |
| §6.5 secure fields, identical-value dedup, size cap | 13, 14 |
| §6.6 idle via `secondsSinceLastEventType` | 15, 16 |
| §6.7 Electron **detection** (enabling → Part 2) | 16 |
| §6.8 permission states, back-off, `apiDisabled`, messaging timeout; per-pid failure counter (opaque event → Part 2) | 15, 16 |
| §7 schema v1, pragmas, `EventStore` API, JSONL format | 6, 7, 8, 9 |
| §8 paths, `config.json`, unknown-key preservation, env override | 4, 5 |
| §9 every CLI command except `apps running`'s `is_electron` semantics beyond detection; envelope; exit codes; `<time>` grammar | 3, 10, 11, 12, 16, 17, 18 |
| §10 daemon runtime: pidfile, signals, `daemon.started/stopped`, logging | 19 |
| §11 tests per module; live gate | every task |

**Deferred to Part 2 (by the spec's own milestone order):** §6.3 observers and debounce, `app.launched/terminated` via `NSWorkspace`, `window.*` and `element.*` kinds from notifications, `menu.item_selected`, `system.sleep/wake`, `app.ax_enabled` (Electron enabling), `app.opaque`, `status.opaque_apps`.

**Known deviations, deliberately:** `export` pages by `id` (insertion order) rather than `ts, id`; `context.snapshot` omits an unchanged `value` and marks `extra.valueUnchanged` so a title change on a large document does not re-store the document. Both are noted in the tasks and should be folded into the spec text when Part 2's spec update lands.

**Placeholder scan:** none — every step has its code or command. **Type consistency:** `EventQuery(since:until:kinds:bundleID:limit:afterID:)`, `EventStore.append/query/count/lastEventTS/close`, `Config.load/save/allowing/denying/isAllowed/allowlistSet/modificationDate`, `Paths.resolve/ensureDataDir/databaseURL/configURL/pidFileURL`, `PIDFile.acquire/release/livePID/read/isAlive`, `AXReading` methods, `HeartbeatDiff.compute(previous:input:)`, `Capturer.start/stop/tick/events/trust/state/config/readFailures`, `AXClient.focusedElementInspection(of:depth:)`, `runJSON(json:human:_:)`, `Output.envelope/cliError/stderr`, `CLIError.notTrusted/dbNotFound/daemonNotRunning/schemaTooNew/usage` are used with the same names and signatures in every task that references them.
