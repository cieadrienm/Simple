import XCTest
import AVFoundation
import Metal
import RecorderKit

/// A source which delivers the frames the test gives it.
final class FakeSource: NSObject, FrameSource {
    let title: String
    var flipped = false
    var frameHandler: ((MTLTexture) -> Void)?
    private(set) var stopped = false

    init(title: String) { self.title = title }
    func stop() { stopped = true }
    func deliver(_ texture: MTLTexture) { frameHandler?(texture) }
}

/// The sources which exist, as the test says.
final class FakeDirectory: NSObject, SourceDirectory {
    var changeHandler: (() -> Void)?
    private(set) var titles: [String]
    /// Every source ever connected to, the latest last
    private(set) var connections: [FakeSource] = []

    init(_ titles: [String]) { self.titles = titles }

    func availableSources() -> [SourceDescription] {
        titles.map { SourceDescription(title: $0, detail: "Test", kind: .syphon) }
    }

    func connectToSource(withTitle title: String, device: MTLDevice) -> FrameSource? {
        guard titles.contains(title) else { return nil }
        let source = FakeSource(title: title)
        connections.append(source)
        return source
    }

    /// The live connection to a source, if there is one.
    func source(_ title: String) -> FakeSource? {
        connections.last { $0.title == title && !$0.stopped }
    }

    func setTitles(_ titles: [String]) {
        self.titles = titles
        changeHandler?()
    }
}

final class RecorderControllerTests: XCTestCase {
    private var device: MTLDevice!
    private var folder: URL!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var directory: FakeDirectory!
    private var controller: RecorderController!

    private let all = ["main view - eMotion", "depthMap - eMotion", "A - Simple Server", "B - Simple Server"]

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("RecorderControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaultsName = "RecorderControllerTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        directory = FakeDirectory(all)
        controller = RecorderController(device: device, directory: directory, defaults: defaults)
        controller.folder = folder.path
    }

    override func tearDownWithError() throws {
        controller.stopNetwork()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Helpers

    private func send(_ address: String, _ arguments: Any...) {
        controller.handle(OSCMessage(address: address, arguments: arguments))
    }

    private var titles: [String] { controller.places.map(\.title) }

    private func makeTexture(_ width: Int = 320, _ height: Int = 180) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        return device.makeTexture(descriptor: descriptor)!
    }

    /// Delivers frames from sources as they would, from another thread, for `seconds`.
    private func deliverFrames(for seconds: Double, from sources: [(String, MTLTexture)]) {
        let live = sources.compactMap { title, texture in directory.source(title).map { ($0, texture) } }
        let delivered = expectation(description: "frames delivered")
        DispatchQueue.global().async {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                for (source, texture) in live { source.deliver(texture) }
                usleep(16_000)
            }
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: seconds + 5)
    }

    private func deliverFrames(for seconds: Double) {
        deliverFrames(for: seconds, from: titles.map { ($0, makeTexture()) })
    }

    private func waitForState(_ state: String, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(20)
        while controller.state != state && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(controller.state, state, file: file, line: line)
    }

    private func stopAndWait() {
        controller.stop(completionHandler: nil)
        waitForState("idle")
    }

    /// One source ticked, as Simple Client had.
    private func tickOne() {
        XCTAssertTrue(controller.addSource(matching: "A - Simple Server"))
    }

    // MARK: Settings

    func testDefaults() {
        XCTAssertEqual(controller.codec, "h264")
        XCTAssertEqual(controller.width, 0)
        XCTAssertEqual(controller.height, 0)
        XCTAssertEqual(controller.fps, 0)
        XCTAssertEqual(controller.bitrate, 0)
        XCTAssertEqual(controller.name, "")
        XCTAssertEqual(controller.state, "idle")
        XCTAssertEqual(controller.error, "")
        XCTAssertEqual(controller.places.count, 0)
    }

    func testOSCSetsSettings() {
        send("/codec", "hevc")
        send("/width", NSNumber(value: 1280))
        send("/height", NSNumber(value: 720))
        send("/fps", NSNumber(value: Float(25)))
        send("/bitrate", NSNumber(value: Float(8.5)))
        send("/folder", "/tmp")
        send("/name", "take")

        XCTAssertEqual(controller.codec, "hevc")
        XCTAssertEqual(controller.width, 1280)
        XCTAssertEqual(controller.height, 720)
        XCTAssertEqual(controller.fps, 25)
        XCTAssertEqual(controller.bitrate, 8.5)
        XCTAssertEqual(controller.folder, "/tmp")
        XCTAssertEqual(controller.name, "take")
        XCTAssertEqual(controller.error, "")
    }

    func testNumbersAreAcceptedInAnyForm() {
        send("/width", NSNumber(value: Float(1920)))
        send("/height", "1080")
        send("/fps", NSNumber(value: 30))
        XCTAssertEqual(controller.width, 1920)
        XCTAssertEqual(controller.height, 1080)
        XCTAssertEqual(controller.fps, 30)
    }

    func testValuesOutOfRangeAreClamped() {
        send("/width", NSNumber(value: -5))
        send("/fps", NSNumber(value: 10_000))
        send("/bitrate", NSNumber(value: -1))
        XCTAssertEqual(controller.width, 0)
        XCTAssertEqual(controller.fps, 240)
        XCTAssertEqual(controller.bitrate, 0)
    }

    func testUnknownCodecIsRefusedWithAnError() {
        send("/codec", "hap")
        XCTAssertEqual(controller.codec, "h264")
        XCTAssertTrue(controller.error.contains("hap"), controller.error)
    }

    func testMissingOrWrongArgumentsAreRefusedWithAnError() {
        send("/width")
        XCTAssertFalse(controller.error.isEmpty)
        send("/width", "wide")
        XCTAssertTrue(controller.error.contains("/width"), controller.error)
        XCTAssertEqual(controller.width, 0)
    }

    func testAMessageToAnUnknownAddressIsReported() {
        send("/record <0>")
        XCTAssertTrue(controller.error.contains("/record <0>"), controller.error)
        send("/source/9", "A")
        XCTAssertTrue(controller.error.contains("/source/9"), controller.error)
    }

    func testAMessageToAnAddressWhichCanOnlyBeReadIsReported() {
        send("/status/frames", NSNumber(value: 99))
        XCTAssertEqual(controller.frames, 0)
        XCTAssertTrue(controller.error.contains("/status/frames"), controller.error)
    }

    func testSettingsPersist() {
        send("/codec", "prores4444")
        send("/width", NSNumber(value: 1280))
        send("/fps", NSNumber(value: Float(25)))
        send("/name", "take")

        let next = RecorderController(device: device, directory: directory, defaults: defaults)
        XCTAssertEqual(next.codec, "prores4444")
        XCTAssertEqual(next.width, 1280)
        XCTAssertEqual(next.fps, 25)
        XCTAssertEqual(next.name, "take")
        XCTAssertEqual(next.folder, folder.path)
    }

    // MARK: Places

    func testAvailableSourcesAreThoseOfTheDirectory() {
        XCTAssertEqual(controller.availableSources.map(\.title), all)
        directory.setTitles(["Millumin"])
        XCTAssertEqual(controller.availableSources.map(\.title), ["Millumin"])
    }

    func testTickingConnectsAndUntickingDisconnects() {
        XCTAssertTrue(controller.addSource(matching: "A - Simple Server"))
        XCTAssertEqual(titles, ["A - Simple Server"])
        let source = try! XCTUnwrap(directory.source("A - Simple Server"))
        XCTAssertNotNil(source.frameHandler)

        controller.removeSource(atPlace: 1)
        XCTAssertEqual(titles, [])
        XCTAssertTrue(source.stopped)
    }

    func testOnlyTickedSourcesAreConnected() {
        XCTAssertEqual(directory.connections.count, 0, "nothing is ticked")
        XCTAssertTrue(controller.addSource(matching: "depthMap - eMotion"))
        XCTAssertEqual(directory.connections.map(\.title), ["depthMap - eMotion"])
    }

    func testASourceIsFoundByItsTitleThenByAPartOfIt() {
        XCTAssertTrue(controller.addSource(matching: "depthmap"))
        XCTAssertTrue(controller.addSource(matching: "main view - eMotion"))
        XCTAssertEqual(titles, ["depthMap - eMotion", "main view - eMotion"])
        XCTAssertEqual(controller.error, "")
    }

    func testAnUnknownOrEmptySourceIsRefusedWithAnError() {
        XCTAssertFalse(controller.addSource(matching: "Millumin"))
        XCTAssertTrue(controller.error.contains("Millumin"), controller.error)
        XCTAssertFalse(controller.addSource(matching: ""))
        XCTAssertEqual(titles, [])
    }

    func testASourceIsInOnePlaceOnly() {
        XCTAssertTrue(controller.addSource(matching: "A - Simple Server"))
        XCTAssertTrue(controller.addSource(matching: "B - Simple Server"))
        XCTAssertTrue(controller.addSource(matching: "A - Simple Server"), "already ticked: nothing to do")
        XCTAssertEqual(titles, ["A - Simple Server", "B - Simple Server"])

        // Asked for in the second place, the first source moves there
        XCTAssertTrue(controller.setSourceMatching("A - Simple Server", atPlace: 2))
        XCTAssertEqual(titles, ["B - Simple Server", "A - Simple Server"])
        XCTAssertEqual(directory.connections.filter { !$0.stopped }.count, 2)
    }

    func testSettingAPlaceReplacesItsSourceOrAddsOne() {
        XCTAssertTrue(controller.setSourceMatching("A - Simple Server", atPlace: 1))
        XCTAssertTrue(controller.setSourceMatching("B - Simple Server", atPlace: 1))
        XCTAssertEqual(titles, ["B - Simple Server"])
        XCTAssertNil(directory.source("A - Simple Server"), "A is no longer connected to")

        XCTAssertTrue(controller.setSourceMatching("A - Simple Server", atPlace: 5))
        XCTAssertEqual(titles, ["B - Simple Server", "A - Simple Server"], "places close up: the fifth is the second")
    }

    func testPlacesCloseUp() {
        for title in ["A - Simple Server", "B - Simple Server", "depthMap - eMotion"] { XCTAssertTrue(controller.addSource(matching: title)) }
        XCTAssertTrue(controller.setSourceMatching("", atPlace: 1))
        XCTAssertEqual(titles, ["B - Simple Server", "depthMap - eMotion"])
        controller.removeSource(atPlace: 7)
        XCTAssertEqual(titles.count, 2)
    }

    func testMovingASourceChangesTheOrder() {
        for title in ["A - Simple Server", "B - Simple Server", "depthMap - eMotion"] { XCTAssertTrue(controller.addSource(matching: title)) }
        XCTAssertTrue(controller.moveSource(fromPlace: 3, toPlace: 1))
        XCTAssertEqual(titles, ["depthMap - eMotion", "A - Simple Server", "B - Simple Server"])
        XCTAssertFalse(controller.moveSource(fromPlace: 5, toPlace: 1))
        XCTAssertEqual(directory.connections.count, 3, "moving does not reconnect")
    }

    func testNoMoreThanEightPlaces() {
        let many = (1...9).map { "Source \($0)" }
        directory.setTitles(many)
        for title in many.prefix(8) { XCTAssertTrue(controller.addSource(matching: title)) }
        XCTAssertFalse(controller.addSource(matching: many[8]))
        XCTAssertEqual(titles.count, 8)
        XCTAssertFalse(controller.error.isEmpty)
    }

    func testPlacesCannotChangeWhileRecording() {
        XCTAssertTrue(controller.addSource(matching: "A - Simple Server"))
        XCTAssertTrue(controller.addSource(matching: "B - Simple Server"))
        XCTAssertTrue(controller.start())

        XCTAssertFalse(controller.addSource(matching: "depthMap - eMotion"))
        XCTAssertFalse(controller.error.isEmpty)
        XCTAssertFalse(controller.setSourceMatching("", atPlace: 1))
        XCTAssertFalse(controller.moveSource(fromPlace: 2, toPlace: 1))
        controller.removeSource(atPlace: 1)
        send("/source/1", "depthMap - eMotion")
        XCTAssertEqual(titles, ["A - Simple Server", "B - Simple Server"])

        deliverFrames(for: 0.2)
        stopAndWait()
        XCTAssertTrue(controller.addSource(matching: "depthMap - eMotion"))
    }

    func testPlacesPersistAndReconnect() {
        XCTAssertTrue(controller.addSource(matching: "B - Simple Server"))
        XCTAssertTrue(controller.addSource(matching: "A - Simple Server"))

        let later = FakeDirectory(["A - Simple Server"])
        let next = RecorderController(device: device, directory: later, defaults: defaults)
        XCTAssertEqual(next.places.map(\.title), ["B - Simple Server", "A - Simple Server"], "B is away, and keeps its place")
        XCTAssertEqual(later.connections.map(\.title), ["A - Simple Server"])
        later.setTitles(["A - Simple Server", "B - Simple Server"])
        XCTAssertNotNil(later.source("B - Simple Server"), "B is back, and connected to")
    }

    func testAPlaceSaysWhatItsSourceDelivers() {
        XCTAssertTrue(controller.addSource(matching: "A - Simple Server"))
        XCTAssertFalse(controller.places[0].isOnline, "no frame yet")
        deliverFrames(for: 0.6, from: [("A - Simple Server", makeTexture(640, 360))])
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let place = controller.places[0]
        XCTAssertTrue(place.isOnline)
        XCTAssertEqual(place.width, 640)
        XCTAssertEqual(place.height, 360)
        XCTAssertGreaterThan(place.fps, 20)
        XCTAssertNotNil(place.latestFrame)
    }

    func testASourceWhichComesBackGoesOnInItsPlace() throws {
        XCTAssertTrue(controller.addSource(matching: "A - Simple Server"))
        XCTAssertTrue(controller.addSource(matching: "B - Simple Server"))
        XCTAssertTrue(controller.start())
        deliverFrames(for: 0.3)

        // B's application quits
        let first = try XCTUnwrap(directory.source("B - Simple Server"))
        directory.setTitles(all.filter { $0 != "B - Simple Server" })
        XCTAssertEqual(titles, ["A - Simple Server", "B - Simple Server"], "the place stays B's")
        XCTAssertTrue(first.stopped)
        deliverFrames(for: 0.3)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(controller.places[1].isOnline)
        let framesWhileAway = controller.places[1].frames

        // It is launched again
        directory.setTitles(all)
        let second = try XCTUnwrap(directory.source("B - Simple Server"))
        XCTAssertFalse(second === first)
        deliverFrames(for: 0.3)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(controller.places[1].isOnline)
        XCTAssertGreaterThan(controller.places[1].frames, framesWhileAway, "frames reach B's movie again")
        stopAndWait()
        XCTAssertEqual(controller.recordingError, "")
    }

    func testTheMonitorGetsEachPlacesLatestFrame() {
        XCTAssertTrue(controller.addSource(matching: "A - Simple Server"))
        XCTAssertTrue(controller.addSource(matching: "B - Simple Server"))
        let a = makeTexture(640, 360), b = makeTexture(320, 320)
        directory.source("A - Simple Server")?.deliver(a)
        directory.source("B - Simple Server")?.deliver(b)
        XCTAssertTrue(controller.places[0].latestFrame === a)
        XCTAssertTrue(controller.places[1].latestFrame === b)
    }

    // MARK: Places by OSC

    func testOSCSetsAndClearsAPlace() {
        send("/source/1", "A - Simple Server")
        send("/source/2", "depthmap")
        XCTAssertEqual(titles, ["A - Simple Server", "depthMap - eMotion"])
        send("/source/1", "")
        XCTAssertEqual(titles, ["depthMap - eMotion"])
        XCTAssertEqual(controller.error, "")
        send("/source/2", "Millumin")
        XCTAssertTrue(controller.error.contains("Millumin"), controller.error)
    }

    func testSourceIsAnAliasOfTheFirstPlace() {
        send("/source", "B - Simple Server")
        XCTAssertEqual(titles, ["B - Simple Server"])
        send("/source", "simple")
        XCTAssertEqual(titles, ["A - Simple Server"], "the first place's source is replaced")
    }

    // MARK: Recording

    func testRecordingWritesOneMoviePerPlace() throws {
        for title in ["A - Simple Server", "B - Simple Server", "depthMap - eMotion"] { XCTAssertTrue(controller.addSource(matching: title)) }
        send("/name", "show")
        send("/record", NSNumber(value: 1))
        XCTAssertEqual(controller.state, "recording")
        deliverFrames(for: 0.5, from: [("A - Simple Server", makeTexture(640, 360)), ("B - Simple Server", makeTexture(320, 320)),
                                       ("depthMap - eMotion", makeTexture(512, 520))])
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertGreaterThan(controller.places[2].frames, 10)
        send("/record", NSNumber(value: 0))
        XCTAssertEqual(controller.state, "finishing")
        waitForState("idle")
        XCTAssertEqual(controller.error, "")

        let files = controller.places.map { URL(fileURLWithPath: $0.file) }
        XCTAssertEqual(files.map(\.lastPathComponent), ["show — A - Simple Server.mov", "show — B - Simple Server.mov", "show — depthMap - eMotion.mov"])
        XCTAssertEqual(try files.map { try MovieInfo($0).size }, [CGSize(width: 640, height: 360), CGSize(width: 320, height: 320), CGSize(width: 512, height: 520)])
        XCTAssertEqual(controller.file, files[0].path)
    }

    func testOneSourceTakesTheNameAlone() throws {
        tickOne()
        send("/name", "Depth")
        XCTAssertTrue(controller.start())
        XCTAssertEqual(controller.file, folder.appendingPathComponent("Depth.mov").path)
        deliverFrames(for: 0.3)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertGreaterThan(controller.frames, 5)
        XCTAssertGreaterThan(controller.elapsed, 0.2)
        stopAndWait()
        XCTAssertGreaterThan(try MovieInfo(URL(fileURLWithPath: controller.file)).duration, 0.2)
    }

    func testRecordZeroStopsWhateverTheTypeOfTheArgument() {
        tickOne()
        let zeros: [(String, Any)] = [("int", NSNumber(value: Int32(0))), ("float", NSNumber(value: Float(0))), ("false", NSNumber(value: false)), ("string", "0")]
        for (name, zero) in zeros {
            XCTAssertTrue(controller.start(), name)
            deliverFrames(for: 0.1)
            send("/record", zero)
            XCTAssertNotEqual(controller.state, "recording", "/record with \(name) zero did not stop the recording")
            waitForState("idle")
        }
    }

    func testSettingsReachTheMovies() throws {
        tickOne()
        send("/codec", "prores422")
        send("/fps", NSNumber(value: 30))
        XCTAssertTrue(controller.start())
        deliverFrames(for: 0.4)
        stopAndWait()
        let movie = try MovieInfo(URL(fileURLWithPath: controller.file))
        XCTAssertEqual(movie.codec, "apcn")
        XCTAssertEqual(movie.size, CGSize(width: 320, height: 180))
    }

    func testToggleStartsThenStops() {
        tickOne()
        send("/record/toggle")
        XCTAssertEqual(controller.state, "recording")
        deliverFrames(for: 0.2)
        send("/record/toggle")
        waitForState("idle")
        XCTAssertTrue(FileManager.default.fileExists(atPath: controller.file))
    }

    func testAutomaticNameIsTheAppAndTheDate() {
        tickOne()
        XCTAssertTrue(controller.start())
        let file = URL(fileURLWithPath: controller.file).lastPathComponent
        XCTAssertTrue(file.hasPrefix("Simple Recorder \(Calendar.current.component(.year, from: Date()))-"), file)
        XCTAssertTrue(file.hasSuffix(".mov"), file)
        stopAndWait()
    }

    func testAnExistingFileIsNeverOverwritten() throws {
        tickOne()
        try Data("precious".utf8).write(to: folder.appendingPathComponent("take.mov"))
        send("/name", "take")
        XCTAssertTrue(controller.start())
        XCTAssertEqual(controller.file, folder.appendingPathComponent("take 2.mov").path)
        deliverFrames(for: 0.2)
        stopAndWait()
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("take.mov")), Data("precious".utf8))
    }

    func testStartWithoutAPlaceFails() {
        XCTAssertFalse(controller.start())
        XCTAssertEqual(controller.state, "idle")
        XCTAssertFalse(controller.error.isEmpty)
    }

    func testStartInAMissingFolderFails() {
        tickOne()
        controller.folder = folder.appendingPathComponent("missing").path
        send("/record", NSNumber(value: 1))
        XCTAssertEqual(controller.state, "idle")
        XCTAssertTrue(controller.error.contains("missing"), controller.error)
    }

    func testStoppingWithoutFramesReportsIt() {
        tickOne()
        XCTAssertTrue(controller.start())
        stopAndWait()
        XCTAssertFalse(controller.error.isEmpty)
        XCTAssertFalse(controller.recordingError.isEmpty)
        XCTAssertEqual(controller.file, "")
    }

    func testASourceWhichDeliversNothingIsNotAFailure() {
        XCTAssertTrue(controller.addSource(matching: "A - Simple Server"))
        XCTAssertTrue(controller.addSource(matching: "B - Simple Server"))
        XCTAssertTrue(controller.start())
        deliverFrames(for: 0.3, from: [("A - Simple Server", makeTexture())])
        stopAndWait()
        XCTAssertEqual(controller.recordingError, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: controller.places[0].file))
        XCTAssertEqual(controller.places[1].file, "", "B has no movie")
    }

    func testStartingClearsThePreviousError() {
        tickOne()
        send("/codec", "hap")
        XCTAssertFalse(controller.error.isEmpty)
        XCTAssertTrue(controller.start())
        XCTAssertEqual(controller.error, "")
        stopAndWait()
    }

    func testRecordOneWhileRecordingChangesNothing() {
        tickOne()
        XCTAssertTrue(controller.start())
        let file = controller.file
        send("/record", NSNumber(value: 1))
        XCTAssertEqual(controller.state, "recording")
        XCTAssertEqual(controller.file, file)
        XCTAssertEqual(controller.error, "")
        stopAndWait()
    }

    func testStopHandlerIsCalledWhenTheFilesAreFinished() {
        tickOne()
        XCTAssertTrue(controller.start())
        deliverFrames(for: 0.2)
        let stopped = expectation(description: "stopped")
        controller.stop {
            XCTAssertEqual(self.controller.state, "idle")
            XCTAssertTrue(FileManager.default.fileExists(atPath: self.controller.file))
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 20)
    }

    func testAMessageRefusedWhileRecordingIsNotWhyTheRecordingEnded() {
        tickOne()
        XCTAssertTrue(controller.start())
        deliverFrames(for: 0.2)
        send("/codec", "hap")
        XCTAssertFalse(controller.error.isEmpty)
        stopAndWait()
        XCTAssertEqual(controller.recordingError, "", "the movie was written as asked")
    }

    func testWhyARecordingEndedIsKeptUntilTheNextOne() {
        tickOne()
        XCTAssertTrue(controller.start())
        stopAndWait()
        XCTAssertFalse(controller.recordingError.isEmpty, "no frame was received")
        send("/fps", NSNumber(value: 25))
        XCTAssertFalse(controller.recordingError.isEmpty)
        XCTAssertTrue(controller.start())
        XCTAssertEqual(controller.recordingError, "")
        deliverFrames(for: 0.2)
        stopAndWait()
        XCTAssertEqual(controller.recordingError, "")
    }

    func testAChangeIsAnnounced() {
        let announced = expectation(forNotification: .RecorderControllerDidChange, object: controller)
        announced.assertForOverFulfill = false
        send("/codec", "hevc")
        wait(for: [announced], timeout: 2)
    }

    // MARK: OSCQuery

    private func get(_ path: String) -> [String: Any] {
        let answered = expectation(description: path)
        var object: [String: Any] = [:]
        let url = URL(string: "http://127.0.0.1:\(controller.oscQueryPort)\(path)")!
        URLSession.shared.dataTask(with: url) { data, _, _ in
            object = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            answered.fulfill()
        }.resume()
        wait(for: [answered], timeout: 5)
        return object
    }

    private func contents(_ node: Any?) -> [String: Any] {
        ((node as? [String: Any])?["CONTENTS"] as? [String: Any]) ?? [:]
    }

    func testOSCQueryDescribesEveryParameter() throws {
        XCTAssertTrue(controller.addSource(matching: "B - Simple Server"))
        XCTAssertTrue(controller.startNetwork(withOSCPort: 19430, queryPort: 19431, name: "Recorder Test"))
        XCTAssertEqual(controller.oscPort, 19430)
        send("/codec", "hevc")

        let info = get("/?HOST_INFO")
        XCTAssertEqual(info["NAME"] as? String, "Recorder Test")
        XCTAssertEqual(info["OSC_PORT"] as? Int, 19430)

        let root = contents(get("/"))
        XCTAssertEqual(Set(root.keys), ["source", "record", "codec", "width", "height", "fps", "bitrate", "folder", "name", "status"])

        let codec = try XCTUnwrap(root["codec"] as? [String: Any])
        XCTAssertEqual(codec["VALUE"] as? [String], ["hevc"])
        XCTAssertEqual((codec["RANGE"] as? [[String: [String]]])?.first?["VALS"], ["h264", "hevc", "prores422", "prores4444"])

        // /source is the first place, and /source/1 … /source/8 the places
        let source = try XCTUnwrap(root["source"] as? [String: Any])
        XCTAssertEqual(source["VALUE"] as? [String], ["B - Simple Server"])
        XCTAssertEqual((source["RANGE"] as? [[String: [String]]])?.first?["VALS"], all)
        let places = contents(source)
        XCTAssertEqual(Set(places.keys), Set((1...8).map(String.init)))
        XCTAssertEqual((places["1"] as? [String: Any])?["VALUE"] as? [String], ["B - Simple Server"])
        XCTAssertEqual((places["2"] as? [String: Any])?["VALUE"] as? [String], [""])
        XCTAssertEqual(((places["2"] as? [String: Any])?["RANGE"] as? [[String: [String]]])?.first?["VALS"], all)

        let status = contents(root["status"])
        XCTAssertEqual(Set(status.keys), ["state", "elapsed", "frames", "dropped", "file", "error", "failure", "source"])
        XCTAssertEqual((status["state"] as? [String: Any])?["VALUE"] as? [String], ["idle"])
        let placeStatus = contents(contents(status["source"])["1"])
        XCTAssertEqual(Set(placeStatus.keys), ["online", "width", "height", "fps", "file", "frames", "dropped"])
        XCTAssertEqual(Set(contents(status["source"]).keys), Set((1...8).map(String.init)))
        for (name, node) in root where name != "status" {
            XCTAssertFalse(((node as? [String: Any])?["DESCRIPTION"] as? String ?? "").isEmpty, "\(name) has no description")
        }
    }

    func testOSCQueryFollowsTheSourcesAvailable() throws {
        XCTAssertTrue(controller.startNetwork(withOSCPort: 19440, queryPort: 19441, name: "Recorder Test"))
        directory.setTitles(["Millumin"])
        XCTAssertEqual((get("/source/3")["RANGE"] as? [[String: [String]]])?.first?["VALS"], ["Millumin"])
    }

    func testMessagesArriveFromTheNetwork() {
        XCTAssertTrue(controller.startNetwork(withOSCPort: 19450, queryPort: 19451, name: "Recorder Test"))
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(controller.oscPort).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let packet = OSCMessage(address: "/fps", arguments: [NSNumber(value: Float(50))]).packet()
        _ = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        let deadline = Date().addingTimeInterval(2)
        while controller.fps != 50 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(controller.fps, 50)
    }
}
