import Foundation

/// The state behind the first-enable review notice (spec privacy §2/§7.3 pattern: "Silently
/// deleting a user's timeline because they typed a rule is a worse failure than the leak it
/// fixes").
///
/// Privacy fix round 2, S2. Before this, the notice was produced only on the startup path and
/// only suppressed that one call: the periodic loop spawned moments later swept the very rows
/// the notice had just promised to keep, and a user who enabled retention on an already-running
/// daemon — the likeliest path, since `config.json` is just a file and `openrhyme status`
/// reflects the change immediately — got no notice at all. One gate instance is now shared by
/// both paths for the life of the daemon process, so "skip the first sweep" means the whole run,
/// not one tick.
///
/// The gate deliberately does *not* persist. Across restarts the off→on transition is detected
/// from the previous `daemon.started` row instead (its `extra.privacy.retentionDays`), which is
/// written unconditionally on every start and is exempt from sweeping — so the notice fires
/// exactly once per off→on transition: not once per store, and not on every restart forever.
/// Restarting the daemon is itself the acknowledgement; a user who saw the notice and left
/// retention on gets the sweep on the next start.
actor RetentionReviewGate {
    /// What the caller should do with this sweep attempt.
    enum Step: Equatable {
        /// `retention_days` is off (0 or negative): nothing to do, and the gate has reset, so a
        /// later off→on flip in this same run is a fresh transition and notices again.
        case retentionOff
        /// A notice already fired in this run and nothing has been reviewed since: hold.
        case awaitingReview
        /// Retention just went from off to on: count what it would remove and decide.
        case firstEnable
        /// Retention was already on: sweep normally.
        case proceed
    }

    /// The last `retention_days` this gate saw in force. Seeded from the previous
    /// `daemon.started` row so the startup path and the periodic path apply one predicate.
    private var lastRetentionDays: Int
    private var awaitingReview = false

    init(previousRetentionDays: Int) {
        self.lastRetentionDays = max(previousRetentionDays, 0)
    }

    func step(retentionDays: Int) -> Step {
        guard retentionDays > 0 else {
            lastRetentionDays = 0
            awaitingReview = false
            return .retentionOff
        }
        if awaitingReview { return .awaitingReview }
        if lastRetentionDays <= 0 { return .firstEnable }
        lastRetentionDays = retentionDays
        return .proceed
    }

    /// Records that this window is cleared to sweep — used after a `.firstEnable` that turned
    /// out to have nothing outside the window, where there is no history to review and so
    /// nothing to warn about.
    func allowSweeping(retentionDays: Int) {
        lastRetentionDays = max(retentionDays, 0)
        awaitingReview = false
    }

    /// Records that the notice fired: nothing is swept for the rest of this process.
    func holdForReview() {
        awaitingReview = true
    }
}
