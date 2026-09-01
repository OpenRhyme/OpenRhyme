import Foundation

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

    static func run(
        _ args: [String], env: [String: String] = [:], stdin: String? = nil
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
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (stdout, stderr, process.terminationStatus)
    }

    static func tempDataDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func json(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return object as? [String: Any] ?? [:]
    }
}
