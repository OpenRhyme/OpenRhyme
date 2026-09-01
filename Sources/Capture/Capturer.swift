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
                    "read failed for pid \(frontmost.pid): \(String(describing: error)) (\(self.readFailures[frontmost.pid] ?? 0)x)"
                )
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
            emit(
                RawEvent(
                    ts: now(), kind: .idleStarted, extra: ["idleSeconds": .number(idleSeconds)]))
        } else if state.idle, idleSeconds < threshold {
            let span = now() - (state.idleSince ?? now())
            state.idle = false
            state.idleSince = nil
            emit(RawEvent(ts: now(), kind: .idleEnded, extra: ["idleSeconds": .number(span)]))
        }
    }
}
