// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TokenSpend",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CCrypto", path: "Sources/CCrypto"),
        .executableTarget(
            name: "TokenSpend",
            dependencies: ["CCrypto"],
            path: "Sources/TokenSpend",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
