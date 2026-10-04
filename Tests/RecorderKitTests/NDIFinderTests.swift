import XCTest
import RecorderKit
import NDITestSupport

// Other NDI sources may be on this Mac or its network (Adrien's applications): the tests look at their own sender only,
// never at the whole list, and connect to nothing.
final class NDIFinderTests: XCTestCase {
    private let library = NDILibrary.shared()

    /// A sender of this test, sending, stopped at the end of the test. Skips the test without the library.
    private func startSender() throws -> (sender: NDITestSender, suffix: String) {
        try XCTSkipUnless(library.isAvailable, library.reason)
        let name = "Test \(UUID().uuidString)"
        let sender = try XCTUnwrap(NDITestSender(library: library, name: name))
        addTeardownBlock { sender.stop() }
        var blue: [UInt8] = [255, 0, 0, 255]
        sender.send(width: 32, height: 16, colour: &blue, marked: false, hasAlpha: true, padding: 0, framesPerSecond: 30)
        // NDI names a source "HOST (name)"
        return (sender, "(\(name))")
    }

    /// Runs the main run loop, where the handlers are called, until the condition holds or 15 s have passed
    private func wait(_ what: String, until condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 15)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        XCTAssertTrue(condition(), "\(what) within 15 s")
    }

    func testASenderIsFound() throws {
        let (_, suffix) = try startSender()
        let finder = try XCTUnwrap(NDIFinder(library: library))
        defer { finder.stop() }

        wait("found") { finder.sourceNames.contains { $0.hasSuffix(suffix) } }
        let title = try XCTUnwrap(finder.sourceNames.first { $0.hasSuffix(suffix) })
        var name: NSString?
        var url: NSString?
        XCTAssertTrue(finder.getName(&name, url: &url, forSourceNamed: title))
        XCTAssertEqual(name as String?, title)
        XCTAssertFalse(finder.getName(&name, url: &url, forSourceNamed: "NOBODY (Test \(UUID().uuidString))"))
    }

    func testASenderWhichStopsIsNoLongerFound() throws {
        let (sender, suffix) = try startSender()
        let finder = try XCTUnwrap(NDIFinder(library: library))
        defer { finder.stop() }
        wait("found") { finder.sourceNames.contains { $0.hasSuffix(suffix) } }
        let title = try XCTUnwrap(finder.sourceNames.first { $0.hasSuffix(suffix) })

        sender.stop()
        wait("gone") { !finder.sourceNames.contains { $0.hasSuffix(suffix) } }
        var name: NSString?
        var url: NSString?
        XCTAssertFalse(finder.getName(&name, url: &url, forSourceNamed: title))
    }

    func testTheChangeHandlerIsCalledOnTheMainQueue() throws {
        let (_, suffix) = try startSender()
        let finder = try XCTUnwrap(NDIFinder(library: library))
        defer { finder.stop() }
        var calls = 0
        var offMain = 0
        var sawOurs = false
        finder.changeHandler = {
            calls += 1
            if !Thread.isMainThread { offMain += 1 }
            if finder.sourceNames.contains(where: { $0.hasSuffix(suffix) }) { sawOurs = true }
        }
        wait("called with the sender") { sawOurs }
        XCTAssertGreaterThan(calls, 0)
        XCTAssertEqual(offMain, 0)
    }

    func testTheDirectoryListsNDISourcesAsNDI() throws {
        let (_, suffix) = try startSender()
        let directory = NDIDirectory(library: library)
        var changed = false
        directory.changeHandler = { changed = true }

        wait("listed") { directory.availableSources().contains { $0.title.hasSuffix(suffix) } }
        let source = try XCTUnwrap(directory.availableSources().first { $0.title.hasSuffix(suffix) })
        XCTAssertTrue(source.title.hasSuffix(suffix))
        XCTAssertEqual(source.detail, "NDI")
        XCTAssertEqual(source.kind, .NDI)
        XCTAssertTrue(changed)
    }

    func testWithoutTheLibraryTheDirectoryIsEmpty() throws {
        let missing = NDILibrary(path: "/nonexistent/\(UUID().uuidString)/libndi.dylib")
        XCTAssertNil(NDIFinder(library: missing))
        let directory = NDIDirectory(library: missing)
        directory.changeHandler = { XCTFail("no change without the library") }
        XCTAssertEqual(directory.availableSources().count, 0)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        XCTAssertNil(directory.connectToSource(withTitle: "HOST (anything)", device: device))
        // Nothing to wait for: the main queue runs a while, so that a call would be seen
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
    }

    /// What the finder makes of the SDK's strings, given as bytes (a terminating zero is added); nil for NULL
    private func copied(name: [UInt8]?, url: [UInt8]?) -> (found: Bool, name: String?, url: String?) {
        func withCString<R>(_ bytes: [UInt8]?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
            guard let bytes else { return body(nil) }
            return (bytes + [0]).withUnsafeBufferPointer { buffer in
                buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { body($0) }
            }
        }
        var copiedName: NSString?
        var copiedURL: NSString?
        let found = withCString(name) { name in
            withCString(url) { url in
                NDIFinder.copyName(&copiedName, url: &copiedURL, fromSourceName: name, url: url)
            }
        }
        return (found, copiedName as String?, copiedURL as String?)
    }

    // A name from another machine may be any bytes: one which is not UTF-8 is left out, rather than end the finder
    func testTheSDKsStringsAreCopiedOrSkipped() {
        let good = copied(name: Array("HOST (Good)".utf8), url: Array("192.168.1.2:5961".utf8))
        XCTAssertTrue(good.found)
        XCTAssertEqual(good.name, "HOST (Good)")
        XCTAssertEqual(good.url, "192.168.1.2:5961")

        let noURL = copied(name: Array("HOST (Good)".utf8), url: nil)
        XCTAssertTrue(noURL.found)
        XCTAssertEqual(noURL.name, "HOST (Good)")
        XCTAssertNil(noURL.url)

        let badName = copied(name: [0xff, 0xfe] + Array(" (Bad)".utf8), url: Array("192.168.1.2:5961".utf8))
        XCTAssertFalse(badName.found)
        XCTAssertNil(badName.name)
        XCTAssertNil(badName.url)

        let badURL = copied(name: Array("HOST (Good)".utf8), url: [0xff, 0xfe, 0x3a])
        XCTAssertTrue(badURL.found)
        XCTAssertEqual(badURL.name, "HOST (Good)")
        XCTAssertNil(badURL.url)

        let noName = copied(name: nil, url: Array("192.168.1.2:5961".utf8))
        XCTAssertFalse(noName.found)
        XCTAssertNil(noName.name)
    }

    func testStopEndsTheThread() throws {
        try XCTSkipUnless(library.isAvailable, library.reason)
        let stopped = try XCTUnwrap(NDIFinder(library: library))
        var calls = 0
        stopped.changeHandler = { calls += 1 }
        stopped.stop()
        stopped.stop()  // twice is harmless
        XCTAssertEqual(stopped.sourceNames, [])

        // A finder which still looks sees the sender; the stopped one never tells of it
        let (_, suffix) = try startSender()
        let looking = try XCTUnwrap(NDIFinder(library: library))
        defer { looking.stop() }
        wait("found by the other finder") { looking.sourceNames.contains { $0.hasSuffix(suffix) } }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(stopped.sourceNames, [])
    }

    // The finder's thread does not keep it alive: released, it stops, so a directory which is released ends its finder
    func testAReleasedFinderIsFreed() throws {
        try XCTSkipUnless(library.isAvailable, library.reason)
        weak var released: NDIFinder?
        autoreleasepool {
            let finder = NDIFinder(library: library)
            finder?.changeHandler = {}
            released = finder
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        }
        XCTAssertNil(released)
    }
}
