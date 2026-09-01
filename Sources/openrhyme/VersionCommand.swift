import ArgumentParser
import Core
import Store

struct VersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version", abstract: "Engine and schema versions.")

    @Flag(name: .long, help: "Emit a JSON envelope.") var json = false

    struct Info: Encodable {
        let engine: String
        let schema: Int
    }

    func run() async throws {
        try await runJSON(json: json, human: { "openrhyme \($0.engine) (schema \($0.schema))" }) {
            Info(engine: EngineVersion.string, schema: Schema.version)
        }
    }
}
