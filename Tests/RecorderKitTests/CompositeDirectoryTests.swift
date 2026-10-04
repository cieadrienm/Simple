import XCTest
import Metal
import RecorderKit

final class CompositeDirectoryTests: XCTestCase {
    private var device: MTLDevice!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    }

    func testSourcesOfAllDirectoriesAreListedInOrder() {
        let syphon = FakeDirectory(["A - Simple Server", "B - Simple Server"])
        let ndi = FakeDirectory(["STUDIO (Camera)"], kind: .NDI)
        let composite = CompositeDirectory(directories: [syphon, ndi])
        XCTAssertEqual(composite.availableSources().map(\.title), ["A - Simple Server", "B - Simple Server", "STUDIO (Camera)"])
        XCTAssertEqual(composite.availableSources().map(\.kind), [.syphon, .syphon, .NDI])
        XCTAssertEqual(CompositeDirectory(directories: []).availableSources().count, 0)
    }

    func testASyphonServerComesBeforeAnNDISourceOfTheSameTitle() throws {
        let syphon = FakeDirectory(["Same"])
        let ndi = FakeDirectory(["Same", "Other"], kind: .NDI)
        let composite = CompositeDirectory(directories: [syphon, ndi])
        let source = try XCTUnwrap(composite.connectToSource(withTitle: "Same", device: device))
        XCTAssertTrue(source === syphon.connections.last)
        XCTAssertEqual(ndi.connections.count, 0)

        // The controller lists the title once, and its place is Syphon's
        let defaultsName = "CompositeDirectoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let controller = RecorderController(device: device, directory: composite, defaults: defaults)
        XCTAssertEqual(controller.availableSources.map(\.title), ["Same", "Other"])
        XCTAssertEqual(controller.availableSources.map(\.kind), [.syphon, .NDI])
        XCTAssertTrue(controller.addSource(matching: "Same"))
        XCTAssertEqual(controller.places[0].kindName, "syphon")
        XCTAssertEqual(syphon.connections.count, 2)
        XCTAssertEqual(ndi.connections.count, 0)
    }

    func testTheSecondDirectoryConnectsWhenTheFirstDoesNotListTheTitle() throws {
        let syphon = FakeDirectory(["A - Simple Server"])
        let ndi = FakeDirectory(["STUDIO (Camera)"], kind: .NDI)
        let composite = CompositeDirectory(directories: [syphon, ndi])
        let source = try XCTUnwrap(composite.connectToSource(withTitle: "STUDIO (Camera)", device: device))
        XCTAssertTrue(source === ndi.connections.last)
        XCTAssertEqual(syphon.connections.count, 0)
        XCTAssertNil(composite.connectToSource(withTitle: "Millumin", device: device))

        // Listed by the first but dead there: the next which lists it is asked
        let both = FakeDirectory(["Same"])
        let other = FakeDirectory(["Same"], kind: .NDI)
        both.kill(entry: 0)
        let fallback = try XCTUnwrap(CompositeDirectory(directories: [both, other]).connectToSource(withTitle: "Same", device: device))
        XCTAssertTrue(fallback === other.connections.last)
    }

    func testAChangeInAnyDirectoryIsTold() {
        let syphon = FakeDirectory(["A - Simple Server"])
        let ndi = FakeDirectory([], kind: .NDI)
        let composite = CompositeDirectory(directories: [syphon, ndi])
        var told = 0
        composite.changeHandler = { told += 1 }
        XCTAssertNotNil(composite.changeHandler)
        syphon.launch("B - Simple Server")
        XCTAssertEqual(told, 1)
        ndi.launch("STUDIO (Camera)")
        XCTAssertEqual(told, 2)
        XCTAssertEqual(composite.availableSources().map(\.title), ["A - Simple Server", "B - Simple Server", "STUDIO (Camera)"])
    }
}
