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
        // The NDI SDK's headers: libndi.dylib itself is loaded at run time (NDILibrary), never linked
        .target(name: "NDIHeaders", path: "ThirdParty/NDI", exclude: ["README.md"], publicHeadersPath: "include"),
        .target(name: "RecorderKit", dependencies: ["NDIHeaders"], path: "Recorder", publicHeadersPath: "."),
        .executableTarget(name: "SimpleRecorder", dependencies: ["RecorderKit", "Syphon"], path: "App"),
        .executableTarget(name: "simple-recorder-mcp", path: "MCP"),
        // An NDI sender for the tests, made through NDILibrary
        .target(name: "NDITestSupport", dependencies: ["RecorderKit", "NDIHeaders"], path: "Tests/NDITestSupport", publicHeadersPath: "."),
        .testTarget(name: "RecorderKitTests", dependencies: ["RecorderKit", "NDITestSupport"], path: "Tests/RecorderKitTests"),
        .testTarget(name: "SimpleRecorderTests", dependencies: ["SimpleRecorder", "RecorderKit", "Syphon", "NDITestSupport"], path: "Tests/SimpleRecorderTests"),
    ]
)
