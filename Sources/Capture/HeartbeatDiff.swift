import Core
import Foundation

/// What the heartbeat compares between ticks. Only the hash of a value is kept.
/// `windowTitle` / `elementTitle` hold **normalized** titles (`TitleNormalizer`), so badge
/// flicker and counter changes never register as a change.
public struct ContextSignature: Sendable, Equatable {
    public var pid: Int32
    public var protectedBy: String?
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

/// Spec 2026-09-03 §6.1: whether the user's input caused an observer notification.
public enum InputClass: String, Sendable {
    case user
    case ambient
}

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

public struct LastKnownState: Sendable, Equatable {
    public var frontmost: AppInfo?
    public var signature: ContextSignature?
    /// The raw title of the last seen state, for `previousTitle`.
    public var lastWindowTitle: String?
    public var idle = false
    public var idleSince: Double?
    public var recentHashes: [Int32: RecentValueHashes] = [:]

    public init() {}

    /// Forget pids whose newest stored hash is older than the memory window.
    mutating func pruneRecentHashes(now: Double, ttl: Double) {
        recentHashes = recentHashes.filter { _, recent in
            recent.newest.map { now - $0 <= ttl } ?? false
        }
    }
}

/// Spec §6.2: pure diff of the focused context against the last known state.
public enum HeartbeatDiff {
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

    public struct Input: Sendable {
        public var frontmost: AppInfo?
        public var context: FocusedContext?
        public var allowlist: Set<String>
        public var recordOtherApps: Bool
        public var maxValueBytes: Int
        public var now: Double
        public var trigger: Trigger
        public var input: InputClass?
        public var contentMemorySeconds: Double
        public var policy: PrivacyPolicy

        public init(
            frontmost: AppInfo?, context: FocusedContext?, allowlist: Set<String>,
            recordOtherApps: Bool, maxValueBytes: Int, now: Double, trigger: Trigger = .heartbeat,
            input: InputClass? = nil, contentMemorySeconds: Double = 1800,
            policy: PrivacyPolicy
        ) {
            self.frontmost = frontmost
            self.context = context
            self.allowlist = allowlist
            self.recordOtherApps = recordOtherApps
            self.maxValueBytes = maxValueBytes
            self.now = now
            self.trigger = trigger
            self.input = input
            self.contentMemorySeconds = contentMemorySeconds
            self.policy = policy
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
        let appChanged =
            app?.pid != previous.frontmost?.pid
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

        // Privacy §5.5: a protected context yields an app-level marker and nothing else. The
        // signature is (pid, protectedBy), so consecutive protected reads dedup to one row.
        if case .protected(let rule) = context.protection {
            let signature = ContextSignature(pid: app.pid, protectedBy: rule)
            if appChanged || signature != state.signature {
                events.append(
                    RawEvent(
                        ts: input.now, kind: .contextSnapshot, pid: app.pid,
                        bundleID: app.bundleID, appName: app.name,
                        extra: [
                            "reason": .string(input.trigger.reason),
                            "protected": .bool(true),
                            "protectedBy": .string(rule),
                            "fingerprint": .string(
                                Fingerprint.compute(
                                    bundleID: app.bundleID, windowTitle: nil, document: nil,
                                    url: nil)),
                        ]))
            }
            state.signature = signature
            state.lastWindowTitle = nil
            return Output(events: events, state: state)
        }

        let element = context.element
        let redacted = Redaction.apply(
            element, maxValueBytes: input.maxValueBytes, policy: input.policy)
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
            let recentlyStored =
                hash.map {
                    state.recentHashes[app.pid]?.contains(
                        $0, now: input.now, ttl: input.contentMemorySeconds) ?? false
                } ?? false
            let valueUnchanged =
                hash != nil && (hash == state.signature?.valueHash || recentlyStored)
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
            if !redacted.redactedRules.isEmpty {
                extra["redacted"] = .array(redacted.redactedRules.map(JSONValue.string))
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
            if !valueUnchanged, let hash {
                state.recentHashes[app.pid, default: RecentValueHashes()].insert(
                    hash, now: input.now, ttl: input.contentMemorySeconds)
            }
        }
        state.signature = signature
        state.lastWindowTitle = context.window?.title
        state.pruneRecentHashes(now: input.now, ttl: input.contentMemorySeconds)
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
