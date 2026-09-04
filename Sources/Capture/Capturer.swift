import Core
import Foundation
import os

/// Drives capture on the main actor: trust state machine, config reload, the heartbeat
/// diff, and idle detection (spec §§6.2, 6.6, 6.8). Observer and lifecycle paths
/// (spec 2026-09-02-observers-design.md §6) share the same refresh.
@MainActor
public final class Capturer {
    public let events: AsyncStream<RawEvent>
    public private(set) var trust: TrustState = .needsPermission
    public private(set) var state = LastKnownState()
    public private(set) var config: Config
    /// Consecutive failed context reads per pid (reset on success). A later slice turns this into
    /// `app.opaque` events.
    public private(set) var readFailures: [Int32: Int] = [:]

    private let ax: any AXReading
    public let paths: Paths
    private let now: @Sendable () -> Double
    private let continuation: AsyncStream<RawEvent>.Continuation
    private let logger = Logger(subsystem: "org.openrhyme.engine", category: "capture")
    private var configModified: Date?
    private var loop: Task<Void, Never>?
    private var staleBackoff: Double = 5
    private var nextTrustCheck: Double = 0
    private var lastContentCache: [Int32: ContentCache] = [:]
    /// Pids with a live observer (spec §5.5).
    public private(set) var observed: Set<Int32> = []
    /// The kinds each observed pid is currently registered for (spec §6.7).
    private var observedKinds: [Int32: Set<ObservedKind>] = [:]
    private var electronEnabled: Set<Int32> = []
    private var observeFailedAt: [Int32: Double] = [:]
    private var observeRetries: [Int32: Task<Void, Never>] = [:]
    private var pendingRefresh: [Int32: Task<Void, Never>] = [:]
    private var pendingFreshRead: [Int32: Bool] = [:]
    private var pendingActivation: Task<Void, Never>?
    private let retryDelays: [Duration]
    /// Spec §6.2: a pid that exhausted its retries is re-attempted by reconcile at most this often.
    static let reconcileRetrySeconds: Double = 60

    public init(
        ax: any AXReading, paths: Paths, config: Config,
        now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
        retryDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(10)]
    ) {
        self.ax = ax
        self.paths = paths
        self.config = config
        self.now = now
        self.retryDelays = retryDelays
        self.configModified = Config.modificationDate(of: paths.configURL)
        let (stream, continuation) = AsyncStream<RawEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
        warnAboutConfig()
    }

    public func start() {
        guard loop == nil else { return }
        ax.setGlobalMessagingTimeout(0.25)
        ax.startLifecycle { [weak self] event in self?.handle(lifecycle: event) }
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
        dropAllPendingRefreshes()
        pendingActivation?.cancel()
        pendingActivation = nil
        loop?.cancel()
        loop = nil
        for task in observeRetries.values { task.cancel() }
        observeRetries = [:]
        ax.stopObservingAll()
        observed = []
        ax.stopLifecycle()
        continuation.finish()
    }

    /// One heartbeat. Public so tests can drive it directly.
    public func tick() {
        reloadConfigIfChanged()
        checkTrust()
        guard trust == .active else { return }
        refresh(trigger: .heartbeat, freshRead: false)
        checkIdle()
        reconcileObservers()
    }

    /// Spec 2026-09-03 §6.7: the notification families in force for an app.
    func enabledKinds(for app: AppInfo) -> Set<ObservedKind> {
        ObservedKind.kinds(fromConfig: config.capture.effectiveNotifications(for: app.bundleID))
    }

    /// Spec 2026-09-03 §6.1. Every notification for the frontmost app is classified by input
    /// recency: user-driven changes are recorded now (titles/values after one debounce); ambient
    /// title and value changes are dropped — the heartbeat samples them. Focus and window changes
    /// always refresh. Public so the hub's handler and tests drive it.
    public func handle(change: ObservedChange) {
        guard trust == .active, let frontmost = ax.frontmostApplication(),
            change.pid == frontmost.pid,
            enabledKinds(for: frontmost).contains(change.kind)
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

    /// Spec 2026-09-03 §6.1 / observers-spec §6.4. One pending refresh per pid; every user-driven title or value change
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

    /// Spec observers-spec §6.4: a pending refresh is dropped, not run, once the focused context has moved.
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

    /// Spec §6.1. Public so tests can drive it; the real source is `AppLifecycle`.
    public func handle(lifecycle event: LifecycleEvent) {
        switch event {
        case .launched(let app):
            guard HeartbeatDiff.isAllowed(app, config.allowlistSet) else { return }
            emit(appEvent(.appLaunched, app))
            observe(app)
        case .terminated(let app):
            if observed.contains(app.pid) { emit(appEvent(.appTerminated, app)) }
            unobserve(app.pid)
        case .activated:
            dropAllPendingRefreshes()
            scheduleActivationRefresh()
        case .sleep:
            dropAllPendingRefreshes()
            pendingActivation?.cancel()
            pendingActivation = nil
            emit(RawEvent(ts: now(), kind: .systemSleep))
        case .wake:
            emit(RawEvent(ts: now(), kind: .systemWake))
        }
    }

    private func appEvent(_ kind: EventKind, _ app: AppInfo) -> RawEvent {
        RawEvent(ts: now(), kind: kind, pid: app.pid, bundleID: app.bundleID, appName: app.name)
    }

    /// Spec §5.5 / §6.2. Idempotent. An Electron app is enabled once per pid lifetime first.
    func observe(_ app: AppInfo) {
        guard trust == .active, HeartbeatDiff.isAllowed(app, config.allowlistSet),
            !observed.contains(app.pid), observeRetries[app.pid] == nil
        else { return }
        if ElectronSupport.isElectronBundle(app.bundleURL), !electronEnabled.contains(app.pid) {
            let result = ax.enableElectronAccessibility(app)
            electronEnabled.insert(app.pid)
            emit(
                RawEvent(
                    ts: now(), kind: .appAXEnabled, pid: app.pid, bundleID: app.bundleID,
                    appName: app.name,
                    extra: ["method": .string(result.method), "result": .string(result.result)]))
        }
        attemptObserve(app, attempt: 0)
    }

    private func attemptObserve(_ app: AppInfo, attempt: Int) {
        let kinds = enabledKinds(for: app)
        do {
            try ax.startObserving(app, kinds: kinds) { [weak self] change in
                self?.handle(change: change)
            }
            observed.insert(app.pid)
            observedKinds[app.pid] = kinds
            observeFailedAt[app.pid] = nil
            observeRetries[app.pid] = nil
        } catch AXReadError.apiDisabled {
            setTrust(.stale)
            scheduleStaleRetry()
        } catch {
            guard attempt < retryDelays.count else {
                logger.warning("observer for pid \(app.pid) gave up after \(attempt) retries")
                observeFailedAt[app.pid] = now()
                observeRetries[app.pid] = nil
                return
            }
            logger.debug(
                "observer for pid \(app.pid) not ready (\(String(describing: error))); retry \(attempt + 1)"
            )
            let delay = retryDelays[attempt]
            observeRetries[app.pid] = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                self.observeRetries[app.pid] = nil
                guard self.trust == .active,
                    HeartbeatDiff.isAllowed(app, self.config.allowlistSet)
                else { return }
                self.attemptObserve(app, attempt: attempt + 1)
            }
        }
    }

    func unobserve(_ pid: Int32) {
        dropPendingRefresh(for: pid)
        observeRetries[pid]?.cancel()
        observeRetries[pid] = nil
        if observed.contains(pid) { ax.stopObserving(pid: pid) }
        observed.remove(pid)
        observedKinds[pid] = nil
        electronEnabled.remove(pid)
        observeFailedAt[pid] = nil
        lastContentCache[pid] = nil
        readFailures[pid] = nil
    }

    /// Spec §6.5. Every active heartbeat and after a config reload: observe running allowlisted
    /// apps (initial grant, trust recovery, allowlist edits, given-up retries), drop gone ones.
    private func reconcileObservers() {
        guard trust == .active else { return }
        let running = ax.runningApplications().filter {
            HeartbeatDiff.isAllowed($0, config.allowlistSet)
        }
        let runningPids = Set(running.map(\.pid))
        // Spec §6.7: a config edit changed an observed app's set → re-register with the new one.
        for app in running
        where observed.contains(app.pid) && observedKinds[app.pid] != enabledKinds(for: app) {
            let electron = electronEnabled.contains(app.pid)
            unobserve(app.pid)
            if electron { electronEnabled.insert(app.pid) }  // same pid lifetime: no second write
            observe(app)
        }
        for app in running where !observed.contains(app.pid) {
            if let failedAt = observeFailedAt[app.pid],
                now() - failedAt < Self.reconcileRetrySeconds
            {
                continue
            }
            observe(app)
        }
        for pid in Array(observed) where !runningPids.contains(pid) { unobserve(pid) }
    }

    private func emit(_ event: RawEvent) {
        continuation.yield(event)
    }

    /// Spec 2026-09-03 §6.6 / §6.7: two misconfigurations degrade capture silently, so say so.
    private func warnAboutConfig() {
        if config.capture.activationSettleMs > config.capture.valueDebounceMs {
            logger.warning(
                "activation_settle_ms (\(self.config.capture.activationSettleMs)) exceeds value_debounce_ms (\(self.config.capture.valueDebounceMs)): a debounced refresh can land before the activated app's AX tree has settled"
            )
        }
        if !config.capture.unknownNotificationNames.isEmpty {
            logger.warning(
                "ignoring unknown capture.notifications names: \(self.config.capture.unknownNotificationNames.joined(separator: ", "))"
            )
        }
    }

    private func reloadConfigIfChanged() {
        let modified = Config.modificationDate(of: paths.configURL)
        guard modified != configModified else { return }
        configModified = modified
        do {
            config = try Config.load(from: paths.configURL)
            logger.info("config reloaded: \(self.config.allowlist.count) allowlisted apps")
            warnAboutConfig()
            reconcileObservers()
        } catch {
            logger.error("config reload failed: \(String(describing: error))")
        }
    }

    private func setTrust(_ new: TrustState) {
        guard new != trust else { return }
        trust = new
        if new != .active {
            dropAllPendingRefreshes()
            pendingActivation?.cancel()
            pendingActivation = nil
            for task in observeRetries.values { task.cancel() }
            observeRetries = [:]
            ax.stopObservingAll()
            observed = []
        }
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
            } else {
                scheduleStaleRetry()
            }
        }
    }

    private func scheduleStaleRetry() {
        nextTrustCheck = now() + staleBackoff
        staleBackoff = min(staleBackoff * 2, 60)
    }

    /// The read-and-diff every path shares (spec §6.3): heartbeat, activation, observer.
    /// `freshRead` bypasses the content cache so the ladder runs again (spec §6.4).
    private func refresh(
        trigger: HeartbeatDiff.Trigger, freshRead: Bool, input: InputClass? = nil
    ) {
        let frontmost = ax.frontmostApplication()
        var context: FocusedContext?
        if let frontmost, HeartbeatDiff.isAllowed(frontmost, config.allowlistSet) {
            do {
                context = try ax.focusedContext(
                    of: frontmost,
                    reusing: freshRead ? nil : lastContentCache[frontmost.pid],
                    policy: PrivacyPolicy(settings: config.privacy))
                readFailures[frontmost.pid] = nil
                staleBackoff = 5
                if let context { lastContentCache[frontmost.pid] = ax.cache(from: context) }
            } catch AXReadError.apiDisabled {
                setTrust(.stale)
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
                maxValueBytes: config.capture.maxValueBytes, now: now(), trigger: trigger,
                input: input, contentMemorySeconds: config.capture.contentMemorySeconds))
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
