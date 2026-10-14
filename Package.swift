// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Reader",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Reader", targets: ["Reader"]),
    ],
    targets: [
        // Everything that isn't UI: positions, persistence, sync, the restore state machine and
        // the flowing-text pipeline. No third-party dependencies.
        .target(
            name: "ReaderCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "Reader", dependencies: ["ReaderCore"]),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"]),
    ]
)
