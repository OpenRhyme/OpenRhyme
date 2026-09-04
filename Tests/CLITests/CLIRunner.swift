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
    static func run(
        _ args: [String], env: [String: String], stdin: String? = nil
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
        // cooperative pool (which shares DispatchQueue.global()'s worker pool) is saturated
        // by other parallel CLI tests blocked here.
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
