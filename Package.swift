// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenRhyme",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "openrhyme", targets: ["openrhyme"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2")
    ],
    targets: [
        // Platform-free model: events, config, paths, time parsing.
        .target(name: "Core"),

        // All Accessibility code. Emits Sendable structs only.
        .target(name: "Capture", dependencies: ["Core"]),

        // SQLite events table; the schema is a public contract.
        .target(
            name: "Store",
            dependencies: ["Core"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // Deterministic compaction. Empty until after the MVP.
        .target(name: "Compact", dependencies: ["Core"]),

        .executableTarget(
            name: "openrhyme",
            dependencies: [
                "Core", "Capture", "Store", "Compact",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        .testTarget(name: "CoreTests", dependencies: ["Core"]),
        .testTarget(name: "StoreTests", dependencies: ["Store", "Core"]),
        .testTarget(name: "CaptureTests", dependencies: ["Capture", "Core"]),
        .testTarget(name: "CompactTests", dependencies: ["Compact"]),
        .testTarget(name: "CLITests", dependencies: ["openrhyme", "Store", "Core"]),
    ],
    swiftLanguageModes: [.v6]
)
