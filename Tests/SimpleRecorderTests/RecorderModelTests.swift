import XCTest
import RecorderKit
@testable import SimpleRecorder

@MainActor
final class RecorderModelTests: XCTestCase {
    private var recorder: TestRecorder!
    private var model: RecorderModel!

    override func setUp() async throws {
        recorder = try TestRecorder()
        model = RecorderModel(controller: recorder.controller, errorDisplayTime: 0.3)
    }

    override func tearDown() async throws {
        recorder.cleanUp()
    }

    private func send(_ address: String, _ arguments: Any...) {
        recorder.controller.handle(OSCMessage(address: address, arguments: arguments))
    }

    private func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testTheModelStartsWithTheControllersState() {
        XCTAssertEqual(model.state, "idle")
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(model.places, [])
        XCTAssertEqual(model.available.map(\.title), TestRecorder.titles)
        XCTAssertEqual(model.available.first?.detail, "eMotion")
        XCTAssertEqual(model.codec, "h264")
        XCTAssertEqual(model.folder, recorder.folder.path)
    }

    func testTheModelFollowsTheController() {
        send("/codec", "hevc")
        send("/fps", NSNumber(value: 25))
        send("/name", "show")
        send("/source/1", "A - Simple Server")
        XCTAssertEqual(model.codec, "hevc")
        XCTAssertEqual(model.fps, 25)
        XCTAssertEqual(model.name, "show")
        XCTAssertEqual(model.places.map(\.title), ["A - Simple Server"])
    }

    func testTickingFromTheModelReachesTheController() {
        model.tick("B - Simple Server")
        model.tick("main view - eMotion")
        XCTAssertEqual(recorder.controller.places.map(\.title), ["B - Simple Server", "main view - eMotion"])
        XCTAssertEqual(model.places.map(\.title), ["B - Simple Server", "main view - eMotion"])
        XCTAssertEqual(model.available.map(\.title), ["depthMap - eMotion", "A - Simple Server"], "ticked sources leave the available ones")

        model.move(from: 2, to: 1)
        XCTAssertEqual(model.places.map(\.title), ["main view - eMotion", "B - Simple Server"])
        model.untick(place: 1)
        XCTAssertEqual(model.places.map(\.title), ["B - Simple Server"])
        XCTAssertTrue(model.available.contains { $0.title == "main view - eMotion" })
    }

    func testSettingsSetFromTheModelReachTheController() {
        model.setCodec("prores4444")
        model.setFPS(30)
        model.setBitrate(12)
        model.setName("take")
        model.setFolder("/tmp")
        let controller = recorder.controller
        XCTAssertEqual(controller.codec, "prores4444")
        XCTAssertEqual(controller.fps, 30)
        XCTAssertEqual(controller.bitrate, 12)
        XCTAssertEqual(controller.name, "take")
        XCTAssertEqual(controller.folder, "/tmp")
        XCTAssertEqual(model.codec, "prores4444")
    }

    func testAPlaceShowsWhatItsSourceDelivers() {
        model.tick("A - Simple Server")
        XCTAssertFalse(model.places[0].isOnline)
        let texture = recorder.texture(640, 360)
        let end = Date().addingTimeInterval(0.8)
        while Date() < end {
            recorder.directory.source("A - Simple Server")?.deliver(texture)
            spin(0.02)
        }
        XCTAssertTrue(model.places[0].isOnline)
        XCTAssertEqual(model.places[0].width, 640)
        XCTAssertEqual(model.places[0].height, 360)
        XCTAssertGreaterThan(model.places[0].fps, 10)
    }

    func testStartedByOSCTheModelSaysRecording() {
        model.tick("A - Simple Server")
        send("/record", NSNumber(value: 1))
        XCTAssertTrue(model.isRecording)
        XCTAssertEqual(model.state, "recording")
        let texture = recorder.texture()
        let end = Date().addingTimeInterval(0.6)
        while Date() < end {
            recorder.directory.source("A - Simple Server")?.deliver(texture)
            spin(0.02)
        }
        XCTAssertGreaterThan(model.elapsed, 0.3)
        XCTAssertGreaterThan(model.frames, 5)
        XCTAssertEqual(model.movieCount, 1)

        send("/record", NSNumber(value: 0))
        let deadline = Date().addingTimeInterval(10)
        while model.isRecording && Date() < deadline { spin(0.02) }
        XCTAssertEqual(model.state, "idle")
        XCTAssertEqual(model.failure, "")
    }

    func testTheRecordButtonTogglesTheRecording() {
        model.tick("A - Simple Server")
        model.toggleRecording()
        XCTAssertTrue(recorder.controller.isRecording)
        model.toggleRecording()
        XCTAssertNotEqual(recorder.controller.state, "recording")
        let deadline = Date().addingTimeInterval(10)
        while model.isRecording && Date() < deadline { spin(0.02) }
    }

    func testAnErrorIsPublishedThenClearedAfterAWhile() {
        send("/codec", "hap")
        XCTAssertTrue(model.notice.contains("hap"), model.notice)
        spin(0.6)
        XCTAssertEqual(model.notice, "", "the error has been shown long enough")
        XCTAssertFalse(recorder.controller.error.isEmpty, "the controller keeps it for OSCQuery")
    }

    func testANewErrorReplacesTheOneShown() {
        send("/codec", "hap")
        spin(0.2)
        send("/nothing")
        XCTAssertTrue(model.notice.contains("/nothing"), model.notice)
        spin(0.2)
        XCTAssertTrue(model.notice.contains("/nothing"), "the first error's time must not clear the second")
        spin(0.4)
        XCTAssertEqual(model.notice, "")
    }

    func testTheSameErrorAgainIsShownAgain() {
        send("/codec", "hap")
        spin(0.6)
        XCTAssertEqual(model.notice, "")
        send("/codec", "hap")
        XCTAssertTrue(model.notice.contains("hap"), "the mistake was made again: it must be said again")
    }

    func testAFailureStaysUntilTheNextTake() {
        model.tick("A - Simple Server")
        model.toggleRecording()
        model.toggleRecording()
        let deadline = Date().addingTimeInterval(10)
        while model.isRecording && Date() < deadline { spin(0.02) }
        XCTAssertFalse(model.failure.isEmpty, "no frame was received")
        spin(0.6)
        XCTAssertFalse(model.failure.isEmpty, "a failure is not cleared with time")

        model.toggleRecording()
        XCTAssertEqual(model.failure, "")
        model.toggleRecording()
        while model.isRecording && Date() < Date().addingTimeInterval(0) { spin(0.02) }
    }

    func testThePortsAreShown() {
        XCTAssertTrue(recorder.controller.startNetwork(withOSCPort: 19530, queryPort: 19531, name: "Model Test"))
        XCTAssertEqual(model.oscPort, 19530)
        XCTAssertEqual(model.oscQueryPort, 19531)
    }
}
