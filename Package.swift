// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PenBridge",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .executableTarget(
            name: "PenBridge",
            dependencies: ["CZlib"],
            path: "Sources/PenBridge",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
