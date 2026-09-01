import Foundation

public struct PIDFileError: Error, Equatable, Sendable {
    public let runningPID: Int32
}

/// `daemon.pid`: refuses a second daemon while one is alive, tolerates stale files.
public struct PIDFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func read() -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `kill(pid, 0)` succeeds (or fails with EPERM) only for a live process.
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public var livePID: Int32? {
        guard let pid = read(), Self.isAlive(pid) else { return nil }
        return pid
    }

    public func acquire(pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        if let running = livePID, running != pid {
            throw PIDFileError(runningPID: running)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "\(pid)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    public func release() {
        try? FileManager.default.removeItem(at: url)
    }
}
