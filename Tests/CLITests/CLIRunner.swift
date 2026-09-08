import Foundation

/// Thread-safe box used to hand stderr bytes back from the background drain queue.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }
    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Runs the built `openrhyme` binary. `swift test` builds it next to the test bundle.
enum CLIRunner {
    static var binaryURL: URL {
        if let override = ProcessInfo.processInfo.environment["OPENRHYME_BIN"] {
            return URL(fileURLWithPath: override)
        }
        let testBundle = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }
        let products =
            testBundle?.bundleURL.deletingLastPathComponent()
            ?? URL(fileURLWithPath: ".build/debug", isDirectory: true)
        return products.appendingPathComponent("openrhyme")
    }

    /// `env` is required, and every caller must put `OPENRHYME_DATA_DIR` in it (use
    /// `tempEnv()` when the test does not care about the store). Privacy fix round 2, S6: it
    /// used to default to `[:]`, which meant a test that forgot it inherited the developer's
    /// real `~/Library/Application Support/OpenRhyme` and ran a command against their live
    /// history on every `swift test`. Making the parameter mandatory is what stops that coming
    /// back — the compiler now asks the question the reviewer had to ask by hand.
    ///
    /// Awaits the subprocess *without* parking a Swift-concurrency thread. Swift Testing runs
    /// every test in parallel on the cooperative pool, whose width is the core count and whose
    /// worker threads are shared with `DispatchQueue.global()`. This used to be a synchronous
    /// function, so each concurrent CLI test parked one of those threads for the whole life of
    /// its subprocess — 7.5 s apiece for the two purge tests that deliberately hold a SQLite
    /// lock until the CLI's retry backoff is exhausted. Once every pool thread is parked, the
    /// process schedules nothing at all: Swift delivers `Task.sleep` wakeups by enqueueing the
    /// resumption onto that same pool, so *timers stop firing process-wide*, on every executor
    /// including an idle main actor. That is what made unrelated `@MainActor` tests in
    /// `ObserverTests` miss 5 ms observer retries inside a 10 s deadline on CI (run
    /// 33940108336): a ~11 s window in which the whole test process emitted nothing while their
    /// wall-clock deadlines kept running. Verified by reproducing the exact failure set locally
    /// with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, which narrows the pool to one thread.
    ///
    /// The blocking calls therefore run on a private serial queue. Private queues target
    /// libdispatch's *overcommit* root queue, so they always get a thread of their own no matter
    /// how busy the cooperative pool is — the same reason the stdout/stderr drains below use
    /// one. `run()` and `waitUntilExit()` must also stay on a single thread (`waitUntilExit`
    /// spins the calling thread's run loop waiting for a source registered by `run`), and this
    /// queue is what now guarantees that; before, an `await` between them would have been a
    /// deadlock.
    static func run(
        _ args: [String], env: [String: String], stdin: String? = nil
    ) async throws -> (stdout: String, stderr: String, status: Int32) {
        let queue = DispatchQueue(label: "openrhyme.cli-runner")
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = try runBlocking(args, env: env, stdin: stdin)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The blocking half of `run`, which must only ever be called off the cooperative pool.
    private static func runBlocking(
        _ args: [String], env: [String: String], stdin: String?
    ) throws -> (stdout: String, stderr: String, status: Int32) {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment.merge(env) { _, new in new }
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        if let stdin {
            let input = Pipe()
            process.standardInput = input
            input.fileHandleForWriting.write(Data(stdin.utf8))
            input.fileHandleForWriting.closeFile()
        }
        try process.run()

        // Drain stdout and stderr on private serial queues so neither pipe filling up can
        // deadlock the child and the parent against each other. Private queues target the
        // overcommit root queue, so they always get a thread even when Swift Testing's
        // cooperative pool (which shares DispatchQueue.global()'s worker pool) is saturated.
        let outBox = DataBox()
        let errBox = DataBox()
        let outHandle = out.fileHandleForReading
        let errHandle = err.fileHandleForReading
        let group = DispatchGroup()
        let outQueue = DispatchQueue(label: "openrhyme.cli-runner.stdout")
        let errQueue = DispatchQueue(label: "openrhyme.cli-runner.stderr")
        outQueue.async(group: group) { outBox.set(outHandle.readDataToEndOfFile()) }
        errQueue.async(group: group) { errBox.set(errHandle.readDataToEndOfFile()) }
        group.wait()
        process.waitUntilExit()
        let stdout = String(decoding: outBox.get(), as: UTF8.self)
        let stderr = String(decoding: errBox.get(), as: UTF8.self)

        return (stdout, stderr, process.terminationStatus)
    }

    static func tempDataDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A throwaway data dir as a ready-made environment, for tests whose command has nothing to
    /// do with stored events (`version`, `--help`, an argument-validation failure). They still
    /// must not be pointed at the real store.
    static func tempEnv() throws -> [String: String] {
        ["OPENRHYME_DATA_DIR": try tempDataDir().path]
    }

    static func json(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return object as? [String: Any] ?? [:]
    }
}
