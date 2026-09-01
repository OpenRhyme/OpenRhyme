import ArgumentParser
import Core
import Foundation
import Store

/// A failure the CLI reports as an envelope on stdout plus a stable exit code (spec §9).
struct CLIError: Error {
    let code: String
    let message: String
    let hint: String?
    let exitCode: Int32

    init(code: String, message: String, hint: String? = nil, exitCode: Int32 = 1) {
        self.code = code
        self.message = message
        self.hint = hint
        self.exitCode = exitCode
    }

    static let notTrusted = CLIError(
        code: "not_trusted", message: "Accessibility permission is missing",
        hint:
            "System Settings → Privacy & Security → Accessibility → enable the app that runs openrhyme",
        exitCode: 3)

    static func dbNotFound(_ url: URL) -> CLIError {
        CLIError(
            code: "db_not_found", message: "No event database at \(url.path)",
            hint:
                "Start `openrhyme daemon` and allow an app with `openrhyme apps allow <bundle-id>`")
    }

    static func daemonNotRunning(_ paths: Paths) -> CLIError {
        CLIError(
            code: "daemon_not_running", message: "No daemon is running",
            hint: "Start it with `openrhyme daemon` (pidfile: \(paths.pidFileURL.path))",
            exitCode: 4)
    }

    static func schemaTooNew(found: Int, supported: Int) -> CLIError {
        CLIError(
            code: "schema_too_new",
            message: "Database schema \(found) is newer than this build supports (\(supported))",
            hint: "Upgrade openrhyme", exitCode: 5)
    }

    static func usage(_ message: String) -> CLIError {
        CLIError(code: "usage", message: message, exitCode: 2)
    }
}

private struct ErrorBody: Encodable {
    let code: String
    let message: String
    let hint: String?
}

private struct Envelope<T: Encodable>: Encodable {
    let ok: Bool
    let data: T?
    let error: ErrorBody?
}

private let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

enum Output {
    static func stderr(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    static func envelope<T: Encodable>(_ data: T) throws -> String {
        String(
            decoding: try jsonEncoder.encode(Envelope(ok: true, data: data, error: nil)),
            as: UTF8.self)
    }

    static func envelope(_ error: CLIError) -> String {
        let body = Envelope<String>(
            ok: false, data: nil,
            error: ErrorBody(code: error.code, message: error.message, hint: error.hint))
        return String(
            decoding: (try? jsonEncoder.encode(body)) ?? Data("{\"ok\":false}".utf8), as: UTF8.self)
    }

    /// Maps any thrown error to a `CLIError` with a stable code.
    static func cliError(_ error: Error) -> CLIError {
        switch error {
        case let error as CLIError: return error
        case let error as StoreNotFoundError: return .dbNotFound(error.url)
        case let error as SchemaTooNewError:
            return .schemaTooNew(found: error.found, supported: error.supported)
        case let error as DatabaseError:
            return CLIError(code: "database_error", message: error.description)
        case let error as TimeSpecError:
            return .usage(
                "Cannot parse time '\(error.input)' (use 2h, 30m, unix seconds, or ISO-8601)")
        default:
            return CLIError(code: "internal_error", message: String(describing: error))
        }
    }
}

/// Runs a command body and prints its result as the JSON envelope or as human text.
/// On error prints the failure envelope (JSON) or the message (human) and exits with the code.
func runJSON<T: Encodable>(
    json: Bool, human: (T) -> String, _ body: () async throws -> T
) async throws {
    do {
        let data = try await body()
        if json {
            print(try Output.envelope(data))
        } else {
            let text = human(data)
            if !text.isEmpty { print(text) }
        }
    } catch {
        let cli = Output.cliError(error)
        if json {
            print(Output.envelope(cli))
        } else {
            Output.stderr("error: \(cli.message)" + (cli.hint.map { "\nhint: \($0)" } ?? ""))
        }
        throw ExitCode(cli.exitCode)
    }
}
