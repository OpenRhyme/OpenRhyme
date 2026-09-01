import Dispatch
import Foundation

/// Suspends until one of the given signals arrives. Signal sources are delivered on the main
/// queue, which the async main loop services while we await.
@MainActor
final class SignalWaiter {
    private var sources: [DispatchSourceSignal] = []
    private var continuation: CheckedContinuation<Int32, Never>?

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
        continuation?.resume(returning: sig)
        continuation = nil
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}
