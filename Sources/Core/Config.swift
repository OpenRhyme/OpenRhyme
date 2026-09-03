import Foundation

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
