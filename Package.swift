// swift-tools-version: 5.9
import PackageDescription

// The recorder's core (Objective-C, no Syphon) and the MCP tool, so that `swift test` covers them without Xcode.
// The applications themselves are built from Simple.xcworkspace.
let package = Package(
    name: "Simple",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RecorderKit", targets: ["RecorderKit"]),
        .executable(name: "simple-recorder-mcp", targets: ["simple-recorder-mcp"]),
    ],
    targets: [
        .target(name: "RecorderKit", path: "Recorder", publicHeadersPath: "."),
        .executableTarget(name: "simple-recorder-mcp", path: "MCP"),
        .testTarget(name: "RecorderKitTests", dependencies: ["RecorderKit"], path: "Tests/RecorderKitTests"),
    ]
)
