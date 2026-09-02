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

        let redacted = Redaction.apply(context.element, maxValueBytes: input.maxValueBytes)
        let hash = redacted.value.map(Hashing.sha256Hex)
        let signature = ContextSignature(
            pid: app.pid, windowTitle: context.window?.title, document: context.window?.document,
            url: context.window?.url, role: context.element?.role,
            subrole: context.element?.subrole, identifier: context.element?.identifier,
            elementTitle: context.element?.title, selectedText: redacted.selectedText,
            valueHash: hash)

        if appChanged || signature != state.signature {
            let valueUnchanged = hash != nil && hash == state.signature?.valueHash
            var extra: [String: JSONValue] = ["reason": "heartbeat"]
            if let hash {
                extra["valueHash"] = .string(hash)
                extra["truncated"] = .bool(redacted.truncated)
                extra["length"] = .number(Double(redacted.length))
            }
            if valueUnchanged { extra["valueUnchanged"] = true }
            if let textSource = context.element?.textSource {
                extra["textSource"] = .string(textSource)
            }
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
