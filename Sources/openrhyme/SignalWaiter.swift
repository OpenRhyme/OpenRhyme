import Dispatch
import Foundation

/// Suspends until one of the given signals arrives. Signal sources are delivered on the main
/// queue, which the async main loop services while we await.
@MainActor
final class SignalWaiter {
    private var sources: [DispatchSourceSignal] = []
    private var continuation: CheckedContinuation<Int32, Never>?
    /// A signal that arrived before `wait()` was reached. `signal(sig, SIG_IGN)` in `init` has
    /// already disabled the default terminate action, so without this latch the signal would be
    /// dropped and the daemon would wait forever for a second one.
    private var pending: Int32?

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
        guard let continuation else {
            pending = sig
            return
        }
        self.continuation = nil
        continuation.resume(returning: sig)
    }

    func wait() async -> Int32 {
        if let pending {
            self.pending = nil
            return pending
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}
