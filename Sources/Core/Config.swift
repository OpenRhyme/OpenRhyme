import Foundation

/// Spec 2026-09-03 privacy §5.1/§6. Lists are `defaults ∪ add \ remove`, so a user extends or
/// disables individual defaults without restating the whole list.
public struct PrivacySettings: Sendable, Equatable {
    public var enabled: Bool = true
    public var entropyRedaction: Bool = true
    public var protectedBundleIDs: Set<String> = Self.defaultBundleIDs
    public var protectedURLPatterns: [String] = Self.defaultURLPatterns
    public var protectedDocumentPatterns: [String] = Self.defaultDocumentPatterns
    public var protectedWindowTitlePatterns: [String] = Self.defaultWindowTitlePatterns
    public var credentialFieldPatterns: [String] = Self.defaultCredentialFieldPatterns

    public static let defaultBundleIDs: Set<String> = [
        "com.1password.1password", "com.1password.7", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "in.sinew.Enpass-Desktop",
        "com.dashlane.Dashlane", "com.apple.keychainaccess",
    ]
    public static let defaultURLPatterns: [String] = [
        "1password.com", "bitwarden.com", "lastpass.com", "dashlane.com", "/ui/vault/",
        "://vault.", "/settings/credentials", "/trust-credentials", "/admin/credentials",
        "/iam-admin/serviceaccounts", "/apikeys",
    ]
    public static let defaultDocumentPatterns: [String] = [
        ".env", ".env.*", "*.pem", "*.key", "*.p12", "*.keystore", "id_rsa*", "id_ed25519*",
        "id_ecdsa*", "*credentials*", "*secrets*", ".npmrc", ".netrc", ".pgpass",
        "*/.aws/*", "*/.ssh/*", "*/.gnupg/*",
    ]
    public static let defaultWindowTitlePatterns: [String] = ["private browsing"]
    public static let defaultCredentialFieldPatterns: [String] = [
        "password", "passwd", "secret", "token", "api key", "api_key", "apikey", "private key",
        "passphrase", "otp", "2fa", "mfa code",
    ]

    public init() {}

    static let keys = (
        enabled: "enabled", entropy: "entropy_redaction", bundles: "protected_bundle_ids",
        urls: "protected_url_patterns", documents: "protected_document_patterns",
        titles: "protected_window_title_patterns", fields: "credential_field_patterns",
        add: "add", remove: "remove"
    )

    init(json: [String: JSONValue]) {
        self.init()
        if let v = json[Self.keys.enabled]?.boolValue { enabled = v }
        if let v = json[Self.keys.entropy]?.boolValue { entropyRedaction = v }
        protectedBundleIDs = Set(
            Self.resolve(Array(Self.defaultBundleIDs), json[Self.keys.bundles]))
        protectedURLPatterns = Self.resolve(Self.defaultURLPatterns, json[Self.keys.urls])
        protectedDocumentPatterns = Self.resolve(
            Self.defaultDocumentPatterns, json[Self.keys.documents])
        protectedWindowTitlePatterns = Self.resolve(
            Self.defaultWindowTitlePatterns, json[Self.keys.titles])
        credentialFieldPatterns = Self.resolve(
            Self.defaultCredentialFieldPatterns, json[Self.keys.fields])
    }

    /// `defaults ∪ add \ remove`, order-stable: defaults first, then additions.
    private static func resolve(_ defaults: [String], _ value: JSONValue?) -> [String] {
        guard let object = value?.objectValue else { return defaults }
        let add = object[keys.add]?.arrayValue?.compactMap(\.stringValue) ?? []
        let remove = Set(object[keys.remove]?.arrayValue?.compactMap(\.stringValue) ?? [])
        var out = defaults.filter { !remove.contains($0) }
        for item in add where !out.contains(item) && !remove.contains(item) { out.append(item) }
        return out
    }

    /// Only the user's deltas are written back, so a future change to a default list reaches
    /// existing installs instead of being frozen into their config.
    func merged(into json: [String: JSONValue]) -> [String: JSONValue] {
        var out = json
        out[Self.keys.enabled] = .bool(enabled)
        out[Self.keys.entropy] = .bool(entropyRedaction)
        out[Self.keys.bundles] = Self.delta(
            Array(Self.defaultBundleIDs), Array(protectedBundleIDs))
        out[Self.keys.urls] = Self.delta(Self.defaultURLPatterns, protectedURLPatterns)
        out[Self.keys.documents] = Self.delta(
            Self.defaultDocumentPatterns, protectedDocumentPatterns)
        out[Self.keys.titles] = Self.delta(
            Self.defaultWindowTitlePatterns, protectedWindowTitlePatterns)
        out[Self.keys.fields] = Self.delta(
            Self.defaultCredentialFieldPatterns, credentialFieldPatterns)
        return out
    }

    private static func delta(_ defaults: [String], _ current: [String]) -> JSONValue {
        let defaultSet = Set(defaults)
        let currentSet = Set(current)
        return .object([
            keys.add: .array(
                current.filter { !defaultSet.contains($0) }.sorted().map(JSONValue.string)),
            keys.remove: .array(
                defaults.filter { !currentSet.contains($0) }.sorted().map(JSONValue.string)),
        ])
    }
}

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
    /// Spec 2026-09-03 privacy §7: days of history to retain before purge; 0 means unset/keep all.
    public var retentionDays: Int = 0
    /// Privacy fix round 1, safeguard: set when `capture.retention_days` is present in the raw
    /// config but not parseable as a whole number (e.g. a quoted string like `"30"`) — a
    /// silent-corruption trap otherwise: the setting falls back to its default (`0`, off)
    /// without any signal that it did. Parse diagnostic only (like `unknownNotificationNames`):
    /// not saved, not compared for equality.
    public private(set) var retentionDaysInvalid: Bool = false
    /// Spec §6.7: the global notification set. Names: window, focus, title, value, menu.
    public var notifications: Set<String> = CaptureSettings.allNotifications
    /// Spec §6.7: per-app overrides by bundle id.
    public var appNotifications: [String: Set<String>] = [:]
    /// Spec 2026-09-03 §6.7: configured names (global or per-app) that are not one of the five
    /// known kinds — parse diagnostics only, so the daemon can warn about a likely typo. Not
    /// saved, not compared for equality.
    public private(set) var unknownNotificationNames: [String] = []

    public static let allNotifications: Set<String> = ["window", "focus", "title", "value", "menu"]

    public init() {}

    public static func == (lhs: CaptureSettings, rhs: CaptureSettings) -> Bool {
        lhs.heartbeatSeconds == rhs.heartbeatSeconds && lhs.idleSeconds == rhs.idleSeconds
            && lhs.valueDebounceMs == rhs.valueDebounceMs && lhs.maxValueBytes == rhs.maxValueBytes
            && lhs.recordOtherApps == rhs.recordOtherApps
            && lhs.userInputWindowSeconds == rhs.userInputWindowSeconds
            && lhs.contentMemorySeconds == rhs.contentMemorySeconds
            && lhs.activationSettleMs == rhs.activationSettleMs
            && lhs.retentionDays == rhs.retentionDays
            && lhs.notifications == rhs.notifications
            && lhs.appNotifications == rhs.appNotifications
    }

    static let keys = (
        heartbeat: "heartbeat_seconds", idle: "idle_seconds", debounce: "value_debounce_ms",
        maxValue: "max_value_bytes", others: "record_other_apps",
        inputWindow: "user_input_window_seconds", contentMemory: "content_memory_seconds",
        settle: "activation_settle_ms", retention: "retention_days",
        notifications: "notifications", apps: "apps"
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
        if let raw = json[Self.keys.retention] {
            if let v = raw.doubleValue, let exact = Int(exactly: v) {
                retentionDays = exact
            } else {
                retentionDaysInvalid = true
            }
        }
        var unknownNames: Set<String> = []
        if let names = json[Self.keys.notifications]?.arrayValue {
            let (known, unknown) = Self.classify(names)
            unknownNames.formUnion(unknown)
            // A non-empty, all-unknown list is a typo ("windows"), not "observe nothing"; an
            // explicit `[]` still means "observe nothing".
            notifications = known.isEmpty && !unknown.isEmpty ? Self.allNotifications : known
        }
        if let apps = json[Self.keys.apps]?.objectValue {
            for (bundleID, value) in apps {
                if let names = value.objectValue?[Self.keys.notifications]?.arrayValue {
                    let (known, unknown) = Self.classify(names)
                    unknownNames.formUnion(unknown)
                    if known.isEmpty && !unknown.isEmpty {
                        // Non-empty, all-unknown: fall back to the global default by not
                        // recording an override for this bundle id at all.
                    } else {
                        appNotifications[bundleID] = known
                    }
                }
            }
        }
        unknownNotificationNames = unknownNames.sorted()
    }

    /// Splits configured notification names into the known subset and the unknown ones (spec
    /// 2026-09-03 §6.7).
    private static func classify(
        _ values: [JSONValue]
    ) -> (known: Set<String>, unknown: Set<String>) {
        let configured = Set(values.compactMap(\.stringValue))
        return (configured.intersection(allNotifications), configured.subtracting(allNotifications))
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
        out[Self.keys.retention] = .number(Double(retentionDays))
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

/// Thrown by `Config.load` when `config.json` exists but is not valid JSON. Distinct from
/// "missing" (not an error — `Config()` defaults apply): a config the engine cannot parse must
/// fail closed with a clear, mapped CLI error (privacy fix round 1, J9) rather than being
/// silently treated as "no privacy settings configured", which is what falling through to the
/// defaults here would otherwise mean.
public struct ConfigParseError: Error, Sendable {
    public let url: URL
    public let reason: String
}

/// `config.json` (spec §8). Unknown keys survive a load/save round trip via `raw`.
public struct Config: Sendable, Equatable {
    public static let schema = 1

    public var allowlist: [String]
    public var capture: CaptureSettings
    public var privacy: PrivacySettings
    public var raw: [String: JSONValue]

    public init(
        allowlist: [String] = [], capture: CaptureSettings = CaptureSettings(),
        privacy: PrivacySettings = PrivacySettings(), raw: [String: JSONValue] = [:]
    ) {
        self.allowlist = allowlist
        self.capture = capture
        self.privacy = privacy
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
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            // Privacy fix round 1, J9: a config that exists but fails to parse must fail
            // closed, loudly — not be silently treated as "no privacy settings configured"
            // (which is what letting `Config()`'s defaults apply here would mean) and not leak
            // a raw `DecodingError` through as an unmapped `internal_error`.
            throw ConfigParseError(url: url, reason: String(describing: error))
        }
        let raw = value.objectValue ?? [:]
        let allowlist = raw["allowlist"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let capture = CaptureSettings(json: raw["capture"]?.objectValue ?? [:])
        let privacy = PrivacySettings(json: raw["privacy"]?.objectValue ?? [:])
        return Config(allowlist: allowlist, capture: capture, privacy: privacy, raw: raw)
    }

    public func save(to url: URL) throws {
        var out = raw
        out["schema"] = .number(Double(Self.schema))
        out["allowlist"] = .array(allowlist.map(JSONValue.string))
        out["capture"] = .object(capture.merged(into: raw["capture"]?.objectValue ?? [:]))
        out["privacy"] = .object(privacy.merged(into: raw["privacy"]?.objectValue ?? [:]))
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
