import XCTest
import Metal
import RecorderKit
import Syphon
@testable import SimpleRecorder

final class SyphonSourcesTests: XCTestCase {
    func testTitlesAreNameThenApplication() {
        func title(_ name: String?, _ application: String?) -> String {
            var description: [String: Any] = [:]
            description[SyphonServerDescriptionNameKey] = name
            description[SyphonServerDescriptionAppNameKey] = application
            return SyphonDirectory.title(for: description)
        }
        XCTAssertEqual(title("main view", "eMotion"), "main view - eMotion")
        XCTAssertEqual(title("", "Simple Server"), "Simple Server")
        XCTAssertEqual(title(nil, "Simple Server"), "Simple Server")
        XCTAssertEqual(title("Output", ""), "Output")
        XCTAssertEqual(title(nil, nil), "Untitled Server")
    }

    func testListsAndReceivesFramesFromASyphonServer() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let name = "test-\(UUID().uuidString.prefix(8))"
        let server = try XCTUnwrap(SyphonMetalServer(name: name, device: device, options: nil))
        defer { server.stop() }

        let directory = SyphonDirectory()
        var changes = 0
        directory.changeHandler = { changes += 1 }
        // The server announces itself between processes: give the announcement time to come round
        let deadline = Date().addingTimeInterval(5)
        var description: SourceDescription?
        while description == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            description = directory.availableSources().first { $0.title.hasPrefix(name + " - ") }
        }
        let found = try XCTUnwrap(description, "the server is not listed")
        XCTAssertEqual(found.kind, .syphon)
        XCTAssertFalse(found.detail.isEmpty)
        XCTAssertGreaterThan(changes, 0, "the directory did not say its sources changed")
        XCTAssertNil(directory.connectToSource(withTitle: "no such server", device: device))

        let source = try XCTUnwrap(directory.connectToSource(withTitle: found.title, device: device))
        defer { source.stop() }
        XCTAssertTrue(source.flipped)
        XCTAssertEqual(source.title, found.title)
        let received = expectation(description: "a frame")
        received.assertForOverFulfill = false
        var size = (0, 0)
        source.frameHandler = { frame in
            size = (frame.width, frame.height)
            received.fulfill()
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 320, height: 180, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for _ in 0..<20 {
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            server.publishFrameTexture(texture, on: buffer, imageRegion: NSRect(x: 0, y: 0, width: 320, height: 180), flipped: true)
            buffer.commit()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        wait(for: [received], timeout: 5)
        XCTAssertEqual(size.0, 320)
        XCTAssertEqual(size.1, 180)
    }
}
