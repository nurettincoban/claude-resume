// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeResume",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "ClaudeResume",
            path: "Sources/ClaudeResume",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClaudeResumeTests",
            dependencies: ["ClaudeResume"],
            path: "Tests/ClaudeResumeTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
