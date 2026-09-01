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
        if let v = json[Self.keys.debounce]?.doubleValue, let exact = Int(exactly: v) {
            valueDebounceMs = exact
        }
        if let v = json[Self.keys.maxValue]?.doubleValue, let exact = Int(exactly: v) {
            maxValueBytes = exact
        }
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
