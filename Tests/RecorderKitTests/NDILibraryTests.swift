import XCTest
import RecorderKit
import NDITestSupport

final class NDILibraryTests: XCTestCase {
    private let sdkLibrary = "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib"

    func testTheSDKsLibraryLoads() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sdkLibrary), "the NDI SDK is not installed")
        let library = NDILibrary(path: sdkLibrary)
        XCTAssertTrue(library.isAvailable, library.reason)
        XCTAssertTrue(library.version.hasPrefix("NDI"), library.version)
        XCTAssertEqual(library.path, sdkLibrary)
    }

    func testALibraryWhichIsNotThereIsNotAvailable() {
        let missing = "/nonexistent/\(UUID().uuidString)/libndi.dylib"
        let library = NDILibrary(path: missing)
        XCTAssertFalse(library.isAvailable)
        XCTAssertEqual(library.version, "")
        XCTAssertNil(library.path)
        XCTAssertTrue(library.reason.contains(missing), library.reason)
    }

    func testAFileWhichIsNotTheLibraryIsNotAvailable() {
        let library = NDILibrary(path: "/usr/lib/libz.dylib")
        XCTAssertFalse(library.isAvailable)
        XCTAssertEqual(library.version, "")
        XCTAssertNil(library.path)
        XCTAssertTrue(library.reason.contains("is not an NDI library"), library.reason)
    }

    func testNoPathIsNotAvailable() {
        let library = NDILibrary(path: nil)
        XCTAssertFalse(library.isAvailable)
        XCTAssertTrue(library.reason.contains("libndi.dylib was not found"), library.reason)
    }

    func testTheEnvironmentChoosesTheLibrary() {
        let bundle = "/Applications/SimpleRecorder.app"
        XCTAssertEqual(NDILibrary.candidatePaths(withEnvironment: ["SIMPLE_NDI_LIBRARY": "/somewhere/libndi.dylib",
                                                                   "NDI_RUNTIME_DIR_V6": "/runtime"],
                                                 bundlePath: bundle),
                       ["/somewhere/libndi.dylib"])
        XCTAssertEqual(NDILibrary.candidatePaths(withEnvironment: ["NDI_RUNTIME_DIR_V6": "/runtime"], bundlePath: bundle),
                       ["/Applications/SimpleRecorder.app/Contents/Frameworks/libndi.dylib",
                        "/runtime/libndi.dylib",
                        "/usr/local/lib/libndi.dylib",
                        "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib"])
        // Without NDI's runtime variable, its place is left out rather than made "/libndi.dylib"
        XCTAssertEqual(NDILibrary.candidatePaths(withEnvironment: [:], bundlePath: bundle),
                       ["/Applications/SimpleRecorder.app/Contents/Frameworks/libndi.dylib",
                        "/usr/local/lib/libndi.dylib",
                        "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib"])
    }

    func testTheSharedLibraryIsLoadedOnce() {
        XCTAssertTrue(NDILibrary.shared() === NDILibrary.shared())
    }

    // The proof: a frame sent by this process is received by it, through the library's own functions
    func testAFrameSentIsReceived() throws {
        let library = NDILibrary.shared()
        try XCTSkipUnless(library.isAvailable, library.reason)
        let name = "Test \(UUID().uuidString)"
        let sender = try XCTUnwrap(NDITestSender(library: library, name: name))
        defer { sender.stop() }
        var blue: [UInt8] = [255, 0, 0, 255]
        sender.send(width: 64, height: 48, colour: &blue, marked: true, hasAlpha: true, padding: 0, framesPerSecond: 30)

        // Discovery first; mDNS may be refused to an unsigned test runner, so then connect to the sender's address
        let start = Date()
        var size = NDITestSender.receiveOneFrame(named: name, library: library, timeout: 15)
        print("NDI proof: through discovery \(size) after \(Date().timeIntervalSince(start)) s")
        if size == .zero {
            let direct = Date()
            size = NDITestSender.receiveOneFrame(fromSource: sender.sourceName, url: sender.sourceURL, library: library, timeout: 15)
            print("NDI proof: directly from \(sender.sourceName) \(size) after \(Date().timeIntervalSince(direct)) s")
        }
        XCTAssertEqual(size, CGSize(width: 64, height: 48))
    }

    // What a receiver does without a finder: connect to the sender's name and address (NDI gives the sender none)
    func testAFrameIsReceivedWithoutAFinder() throws {
        let library = NDILibrary.shared()
        try XCTSkipUnless(library.isAvailable, library.reason)
        let sender = try XCTUnwrap(NDITestSender(library: library, name: "Test \(UUID().uuidString)"))
        defer { sender.stop() }
        var green: [UInt8] = [0, 255, 0, 255]
        sender.send(width: 32, height: 16, colour: &green, marked: false, hasAlpha: false, padding: 8, framesPerSecond: 30)

        let start = Date()
        let size = NDITestSender.receiveOneFrame(fromSource: sender.sourceName, url: sender.sourceURL, library: library, timeout: 15)
        print("NDI direct: \(sender.sourceName) at \(sender.sourceURL ?? "no address") \(size) after \(Date().timeIntervalSince(start)) s")
        XCTAssertEqual(size, CGSize(width: 32, height: 16))
    }
}
