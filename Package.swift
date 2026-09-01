// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenRhyme",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "openrhyme", targets: ["openrhyme"])
    ],
    targets: [
        // macOS accessibility + input-activity capture. Emits raw events; knows nothing
        // about storage or sessions. See docs/accessibility-api.md.
        .target(name: "Capture"),

        // Hot / warm / cold tiers on SQLite (+ FTS5). The on-disk schema is the public
        // contract the Python MCP server reads. See docs/engine-interface.md.
        .target(name: "Store"),

        // Deterministic, inference-free compaction: sessionization, dedup, idle
        // dropping, repeat collapsing. No LLM calls live here, ever.
        .target(name: "Compact"),

        // Single executable: daemon + control/query subcommands with --json output.
        .executableTarget(
            name: "openrhyme",
            dependencies: ["Capture", "Store", "Compact"]
        ),

        .testTarget(name: "CaptureTests", dependencies: ["Capture"]),
        .testTarget(name: "StoreTests", dependencies: ["Store"]),
        .testTarget(name: "CompactTests", dependencies: ["Compact"]),
    ],
    swiftLanguageModes: [.v6]
)
