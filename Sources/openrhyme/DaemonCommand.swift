import ArgumentParser
import Capture
import Core
import Foundation
import Store
import os

struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon", abstract: "Run capture in the foreground until SIGINT/SIGTERM.")

    @Flag(name: .long, help: "Do not show the Accessibility permission dialog.") var noPrompt =
        false
    @Flag(name: .long, help: "Log every stored event to stderr.") var verbose = false
    @Flag(name: .long, help: "Report startup failures as a JSON envelope.") var json = false

    func run() async throws {
        do {
            try await runDaemon()
        } catch {
            let cli = Output.cliError(error)
            if json { print(Output.envelope(cli)) } else { Output.stderr("error: \(cli.message)") }
            throw ExitCode(cli.exitCode)
        }
    }

    /// Everything that touches AX lives on the main actor; the store is an actor of its own.
    @MainActor
    private func runDaemon() async throws {
        // Installed first so a signal arriving during startup is latched, not lost to the
        // default terminate action.
        let waiter = SignalWaiter(signals: [SIGINT, SIGTERM])
        let logger = Logger(subsystem: "org.openrhyme.engine", category: "daemon")
        let paths = Paths.resolve()
        try paths.ensureDataDir()
        let config = try Config.load(from: paths.configURL)
        let pidfile = PIDFile(url: paths.pidFileURL)
        do {
            try pidfile.acquire()
        } catch let error as PIDFileError {
            throw CLIError(
                code: "daemon_already_running",
                message: "A daemon is already running (pid \(error.runningPID))",
                hint: "Stop it first, or remove \(paths.pidFileURL.path) if that pid is stale")
        }
        defer { pidfile.release() }

        let store = try EventStore(url: paths.databaseURL)
        let client = AXClient()
        if !client.isTrusted(prompt: !noPrompt) {
            Output.stderr(
                "Accessibility permission missing — enable it for the app that runs openrhyme in System Settings → Privacy & Security → Accessibility. Capture starts automatically once granted."
            )
        }
        let capturer = Capturer(ax: client, paths: paths, config: config)

        try await store.append(
            RawEvent(
                ts: Date().timeIntervalSince1970, kind: .daemonStarted,
                extra: [
                    "version": .string(EngineVersion.string),
                    "schema": .number(Double(Schema.version)),
                    "allowlist": .array(config.allowlist.map(JSONValue.string)),
                ]))
        let allowed =
            config.allowlist.isEmpty
            ? "(none — run `openrhyme apps allow <bundle-id>`)"
            : config.allowlist.joined(separator: ", ")
        Output.stderr(
            "openrhyme daemon \(EngineVersion.string) — data dir \(paths.dataDir.path); allowlisted: \(allowed)"
        )

        // The consumer runs off the main thread; `events`, `store` and `logger` are Sendable.
        let events = capturer.events
        let verbose = self.verbose
        let consumer = Task.detached {
            for await event in events {
                do {
                    try await store.append(event)
                    if verbose { Output.stderr("\(event.kind.rawValue) \(event.bundleID ?? "")") }
                } catch {
                    logger.error("store append failed: \(String(describing: error))")
                }
            }
        }
        capturer.start()

        let sig = await waiter.wait()
        logger.info("signal \(sig) received, stopping")
        capturer.stop()
        await consumer.value
        try await store.append(RawEvent(ts: Date().timeIntervalSince1970, kind: .daemonStopped))
        await store.close()
        Output.stderr("stopped")
    }
}
