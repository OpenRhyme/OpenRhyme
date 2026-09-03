import AppKit
import Foundation

/// Spec §5.2. `NSWorkspace` notifications (delivered on the main queue) → `LifecycleEvent`.
/// `didActivateApplication` fires for every app, which is what `capture.record_other_apps` needs.
/// The owner must call `stop()` before dropping the object — `NotificationCenter` retains the
/// registered block (and, through it, the handler) for as long as the token is registered, so an
/// `AppLifecycle` nobody stops keeps receiving events for the process's lifetime.
@MainActor
final class AppLifecycle {
    typealias Handler = @MainActor (LifecycleEvent) -> Void

    private var tokens: [NSObjectProtocol] = []

    func start(handler: @escaping Handler) {
        guard tokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let mappings: [(Notification.Name, @Sendable (Notification) -> LifecycleEvent?)] = [
            (
                NSWorkspace.didLaunchApplicationNotification,
                { Self.app(in: $0).map(LifecycleEvent.launched) }
            ),
            (
                NSWorkspace.didTerminateApplicationNotification,
                { Self.app(in: $0).map(LifecycleEvent.terminated) }
            ),
            (
                NSWorkspace.didActivateApplicationNotification,
                { Self.app(in: $0).map(LifecycleEvent.activated) }
            ),
            (NSWorkspace.willSleepNotification, { _ in .sleep }),
            (NSWorkspace.didWakeNotification, { _ in .wake }),
        ]
        for (name, map) in mappings {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                // `map` is `@Sendable` and returns a `Sendable` `LifecycleEvent?`, so this crosses
                // into the main-actor closure with no unsafe opt-out.
                let event = map(note)
                MainActor.assumeIsolated {
                    if let event { handler(event) }
                }
            }
            tokens.append(token)
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens { center.removeObserver(token) }
        tokens = []
    }

    private static nonisolated func app(in note: Notification) -> AppInfo? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            .map(AppInfo.init(running:))
    }

    isolated deinit {
        stop()
    }
}
