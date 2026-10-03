// swift-tools-version: 5.9
import PackageDescription

// Simple Recorder: the recording core (Objective-C, no Syphon), the app (SwiftUI) and the MCP tool.
// Syphon comes as an xcframework built from the submodule: run Scripts/syphon.sh once before `swift build`.
// Simple Server is built from Simple.xcworkspace.
let package = Package(
    name: "Simple",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RecorderKit", targets: ["RecorderKit"]),
        .executable(name: "SimpleRecorder", targets: ["SimpleRecorder"]),
        .executable(name: "simple-recorder-mcp", targets: ["simple-recorder-mcp"]),
    ],
    targets: [
        .binaryTarget(name: "Syphon", path: "build/Syphon.xcframework"),
        .target(name: "RecorderKit", path: "Recorder", publicHeadersPath: "."),
        .executableTarget(name: "SimpleRecorder", dependencies: ["RecorderKit", "Syphon"], path: "App"),
        .executableTarget(name: "simple-recorder-mcp", path: "MCP"),
        .testTarget(name: "RecorderKitTests", dependencies: ["RecorderKit"], path: "Tests/RecorderKitTests"),
        .testTarget(name: "SimpleRecorderTests", dependencies: ["SimpleRecorder", "RecorderKit", "Syphon"], path: "Tests/SimpleRecorderTests"),
    ]
)
