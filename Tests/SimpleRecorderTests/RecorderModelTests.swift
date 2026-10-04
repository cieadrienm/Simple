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

    // MARK: The assembled picture

    func testOutputLayoutGapAndSizeFollowTheControllerBothWays() {
        XCTAssertEqual(model.output, "separate")
        XCTAssertEqual(model.layout, "row")
        send("/output", "both")
        send("/layout", "grid")
        send("/gap", NSNumber(value: 12))
        send("/width", NSNumber(value: 1920))
        send("/height", NSNumber(value: 1080))
        XCTAssertEqual(model.output, "both")
        XCTAssertEqual(model.layout, "grid")
        XCTAssertEqual(model.gap, 12)
        XCTAssertEqual(model.width, 1920)
        XCTAssertEqual(model.height, 1080)

        model.setOutput("assembled")
        model.setLayout("focus")
        model.setGap(4)
        model.setSize(width: 0, height: 0)
        XCTAssertEqual(recorder.controller.output, "assembled")
        XCTAssertEqual(recorder.controller.layout, "focus")
        XCTAssertEqual(recorder.controller.gap, 4)
        XCTAssertEqual(recorder.controller.width, 0)
        XCTAssertEqual(recorder.controller.height, 0)
        XCTAssertEqual(model.output, "assembled")
        XCTAssertEqual(model.layout, "focus")
    }

    func testMovieCountFollowsTheOutput() {
        XCTAssertEqual(model.movieCount, 0)
        for title in TestRecorder.titles.prefix(3) { model.tick(title) }
        XCTAssertEqual(model.movieCount, 3)
        model.setOutput("assembled")
        XCTAssertEqual(model.movieCount, 1)
        model.setOutput("both")
        XCTAssertEqual(model.movieCount, 4)
        for _ in 0..<3 { model.untick(place: 1) }
        XCTAssertEqual(model.movieCount, 0, "no source, no movie")
    }

    func testTheTitlesRectanglesFollowTheLayout() {
        XCTAssertEqual(model.pictureSize, .zero)
        XCTAssertEqual(model.titleRects, [])
        // Sources never seen count as 1920 × 1080
        model.tick("A - Simple Server")
        model.tick("B - Simple Server")
        XCTAssertEqual(model.pictureSize, CGSize(width: 3840, height: 1080))
        XCTAssertEqual(model.titleRects, [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)])
        model.setLayout("column")
        XCTAssertEqual(model.pictureSize, CGSize(width: 1920, height: 2160))
        XCTAssertEqual(model.titleRects, [CGRect(x: 0, y: 0, width: 1, height: 0.5), CGRect(x: 0, y: 0.5, width: 1, height: 0.5)])
        // They follow the sources as their sizes become known
        recorder.directory.source("A - Simple Server")?.deliver(recorder.texture(960, 1080))
        spin(0.4)
        model.setLayout("row")
        XCTAssertEqual(model.pictureSize, CGSize(width: 2880, height: 1080))
    }

    func testAPictureTooLargeIsOnlyAProblemWhenItIsRecorded() {
        model.tick("A - Simple Server")
        model.tick("B - Simple Server")
        for title in ["A - Simple Server", "B - Simple Server"] { recorder.directory.source(title)?.deliver(recorder.texture(16384, 16)) }
        spin(0.4)
        XCTAssertEqual(model.pictureSize.width, 32768)
        XCTAssertFalse(model.pictureIsTooLarge, "separate movies do not care")
        model.setOutput("both")
        XCTAssertTrue(model.pictureIsTooLarge)
        model.setSize(width: 3840, height: 2160)
        XCTAssertFalse(model.pictureIsTooLarge)
    }

    func testTheAssembledMoviesFramesAreTheTakes() {
        model.tick("A - Simple Server")
        model.tick("B - Simple Server")
        model.setOutput("both")
        model.toggleRecording()
        let texture = recorder.texture()
        let end = Date().addingTimeInterval(0.6)
        while Date() < end {
            for title in ["A - Simple Server", "B - Simple Server"] { recorder.directory.source(title)?.deliver(texture) }
            spin(0.02)
        }
        XCTAssertGreaterThan(model.assembledFrames, 5)
        XCTAssertEqual(model.frames, model.assembledFrames, "the take bar counts the assembled movie's frames")
        model.toggleRecording()
        let deadline = Date().addingTimeInterval(10)
        while model.isRecording && Date() < deadline { spin(0.02) }
    }

    // MARK: NDI

    func testASourcesKindFollowsItsDirectory() throws {
        recorder.cleanUp()
        recorder = try TestRecorder(ndi: ["HOST (cam 1)", "HOST (cam 2)"])
        model = RecorderModel(controller: recorder.controller)
        XCTAssertEqual(model.available.filter { $0.kind == "ndi" }.map(\.title), ["HOST (cam 1)", "HOST (cam 2)"])
        XCTAssertEqual(model.available.filter { $0.kind == "syphon" }.count, TestRecorder.titles.count)
        model.tick("A - Simple Server")
        model.tick("HOST (cam 2)")
        XCTAssertEqual(model.places.map(\.kind), ["syphon", "ndi"])
        XCTAssertEqual(model.available.filter { $0.kind == "ndi" }.map(\.title), ["HOST (cam 1)"])
    }

    func testNDIAvailabilityFollowsTheController() {
        XCTAssertFalse(model.ndiAvailable)
        recorder.controller.ndiAvailable = true
        // The controller says nothing when this changes: the model reads it with the next change
        send("/fps", NSNumber(value: 25))
        XCTAssertTrue(model.ndiAvailable)
    }

    func testTheReasonNDIIsOffIsPassedToTheModel() {
        let other = RecorderModel(controller: recorder.controller, ndiOffReason: "libndi.dylib was not found")
        XCTAssertEqual(other.ndiOffReason, "libndi.dylib was not found")
        XCTAssertEqual(model.ndiOffReason, "")
    }

    // MARK: Sound

    func testAPlaceSaysItHasSound() throws {
        recorder.cleanUp()
        recorder = try TestRecorder(ndi: ["HOST (cam 1)", "HOST (cam 2)"])
        model = RecorderModel(controller: recorder.controller)
        model.tick("HOST (cam 1)")
        model.tick("HOST (cam 2)")
        XCTAssertEqual(model.places.map(\.hasSound), [false, false])
        let source = try XCTUnwrap(recorder.directory.source("HOST (cam 2)"))
        source.deliverSound(SourceSound.silence(ofFrameCount: 960, sampleRate: 48000))
        // The controller says nothing when a source starts to have sound: the model reads it with the next change
        send("/fps", NSNumber(value: 25))
        XCTAssertEqual(model.places.map(\.hasSound), [false, true])
    }

    func testSoundFollowsTheControllerBothWays() throws {
        recorder.cleanUp()
        recorder = try TestRecorder(ndi: ["HOST (cam 1)", "HOST (cam 2)"])
        model = RecorderModel(controller: recorder.controller)
        model.tick("HOST (cam 1)")
        model.tick("HOST (cam 2)")
        XCTAssertEqual(model.sound, "")
        model.setSound("HOST (cam 2)")
        XCTAssertEqual(recorder.controller.sound, "HOST (cam 2)")
        XCTAssertEqual(model.sound, "HOST (cam 2)")
        // The other way: OSC
        send("/sound", "HOST (cam 1)")
        XCTAssertEqual(model.sound, "HOST (cam 1)")
        model.setSound("")
        XCTAssertEqual(recorder.controller.sound, "")
        XCTAssertEqual(model.sound, "")
        XCTAssertEqual(model.soundLeftOut, 0)
    }

    func testASoundChosenAmongThePlacesIsNeverMissing() throws {
        recorder.cleanUp()
        recorder = try TestRecorder(ndi: ["HOST (cam 1)"])
        model = RecorderModel(controller: recorder.controller)
        // Ticked, but never connected: its kind is still empty
        recorder.controller.ndiAvailable = false
        model.tick("HOST (cam 1)")
        model.tick("A - Simple Server")
        XCTAssertFalse(model.soundIsMissing)
        send("/sound", "HOST (cam 1)")
        XCTAssertEqual(model.sound, "HOST (cam 1)")
        XCTAssertFalse(model.soundIsMissing)
        XCTAssertEqual(model.soundChoices.filter { $0 == "HOST (cam 1)" }.count, 1)
        // A Syphon place named by /sound is offered plainly, once
        send("/sound", "A - Simple Server")
        XCTAssertFalse(model.soundIsMissing)
        XCTAssertEqual(model.soundChoices.filter { $0 == "A - Simple Server" }.count, 1)
    }

    func testASoundWhichIsNotAPlaceIsMissing() throws {
        recorder.cleanUp()
        recorder = try TestRecorder(ndi: ["HOST (cam 1)", "HOST (cam 2)"])
        model = RecorderModel(controller: recorder.controller)
        model.tick("HOST (cam 1)")
        model.tick("HOST (cam 2)")
        model.setSound("HOST (cam 2)")
        model.untick(place: 2)
        XCTAssertEqual(model.sound, "HOST (cam 2)")
        XCTAssertTrue(model.soundIsMissing)
        XCTAssertFalse(model.soundChoices.contains("HOST (cam 2)"))
        model.setSound("")
        XCTAssertFalse(model.soundIsMissing)
    }
}
