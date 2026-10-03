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
    /// Which of the directory's entries it is connected to
    var entry = 0
    weak var directory: FakeDirectory?

    init(title: String) { self.title = title }
    /// How many times it was asked whether it is alive
    private(set) var aliveChecks = 0
    var isAlive: Bool {
        aliveChecks += 1
        return !(directory?.dead.contains(entry) ?? false)
    }
    func stop() { stopped = true }
    func deliver(_ texture: MTLTexture) { frameHandler?(texture) }
}

/// The sources which exist, as the test says. As in Syphon's directory, a source whose application was killed
/// stays listed: only connecting to it tells that it has gone.
final class FakeDirectory: NSObject, SourceDirectory {
    var changeHandler: (() -> Void)?
    private(set) var titles: [String]
    /// The entries (indexes into `titles`) which are listed but dead
    private(set) var dead = Set<Int>()
    /// Every source ever connected to, the latest last
    private(set) var connections: [FakeSource] = []
    /// The titles of the sources whose frames have their first row at the bottom, as Syphon's
    var flippedTitles = Set<String>()

    init(_ titles: [String]) { self.titles = titles }

    func availableSources() -> [SourceDescription] {
        titles.map { SourceDescription(title: $0, detail: "Test", kind: .syphon) }
    }

    func connectToSource(withTitle title: String, device: MTLDevice) -> FrameSource? {
        // The first with the title which is alive
        guard let entry = titles.indices.first(where: { titles[$0] == title && !dead.contains($0) }) else { return nil }
        let source = FakeSource(title: title)
        source.entry = entry
        source.directory = self
        source.flipped = flippedTitles.contains(title)
        connections.append(source)
        return source
    }

    /// The live connection to a source, if there is one.
    func source(_ title: String) -> FakeSource? {
        connections.last { $0.title == title && !$0.stopped }
    }

    func setTitles(_ titles: [String]) {
        self.titles = titles
        dead = []
        changeHandler?()
    }

    /// The application of an entry is killed: nothing is announced, and the entry stays.
    func kill(entry: Int) { dead.insert(entry) }

    /// An application is launched: its source is announced.
    func launch(_ title: String) {
        titles.append(title)
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

    func testAvailableSourcesListEachTitleOnce() {
        // Syphon lists a server which was killed for ever, and again when it is relaunched
        directory.setTitles(["main view - eMotion", "A - Simple Server", "main view - eMotion"])
        XCTAssertEqual(controller.availableSources.map(\.title), ["main view - eMotion", "A - Simple Server"])
    }

    func testASourceWhoseApplicationWasKilledIsFoundAgain() throws {
        directory.setTitles(["C - Simple Server"])
        XCTAssertTrue(controller.addSource(matching: "C - Simple Server"))
        let first = try XCTUnwrap(directory.source("C - Simple Server"))
        let texture = makeTexture()
        first.deliver(texture)

        // Killed: Syphon says nothing, and goes on listing it
        directory.kill(entry: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(2.8))
        XCTAssertTrue(first.stopped, "a source which has gone is let go of")
        XCTAssertNil(directory.source("C - Simple Server"), "there is nothing alive to connect to")
        XCTAssertEqual(titles, ["C - Simple Server"], "the place stays its own")
        XCTAssertFalse(controller.places[0].isOnline)

        // Relaunched: listed a second time, beside the dead entry
        directory.launch("C - Simple Server")
        let second = try XCTUnwrap(directory.source("C - Simple Server"))
        XCTAssertEqual(second.entry, 1, "the live one, not the dead one which comes first")
        let end = Date().addingTimeInterval(0.6)
        while Date() < end {
            second.deliver(texture)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(controller.places[0].isOnline)
    }

    func testASilentSourceWhichIsAliveIsKept() throws {
        // Two live servers with the same title, as eMotion can have: the first is taken, and stays taken when it
        // has nothing to say (a scene which does not move publishes no frame)
        directory.setTitles(["main view - eMotion", "main view - eMotion"])
        XCTAssertTrue(controller.addSource(matching: "main view - eMotion"))
        let source = try XCTUnwrap(directory.source("main view - eMotion"))
        XCTAssertEqual(source.entry, 0)

        RunLoop.main.run(until: Date().addingTimeInterval(4.6))
        XCTAssertFalse(source.stopped, "it is alive: silence is not a reason to leave it")
        XCTAssertEqual(directory.connections.count, 1, "nor to connect to it again")
        // Asking makes a client in the source's application: after 2 s, then 4 s later, then 8… not every 2 s
        XCTAssertEqual(source.aliveChecks, 1, "a still scene must not be asked again and again")

        let texture = makeTexture()
        source.deliver(texture)
        RunLoop.main.run(until: Date().addingTimeInterval(2.6))
        XCTAssertEqual(source.aliveChecks, 2, "it spoke: the next silence is counted from the start")
    }

    func testAPlaceWaitingForItsSourceCanBeGivenItAgain() {
        // What a show's OSC preset does: it names the sources each time, whether they are there yet or not
        XCTAssertTrue(controller.addSource(matching: "A - Simple Server"))
        XCTAssertTrue(controller.addSource(matching: "B - Simple Server"))
        directory.setTitles(["A - Simple Server"])
        send("/source/2", "B - Simple Server")
        XCTAssertEqual(controller.error, "", "B is away, but the second place is already its own")
        XCTAssertEqual(titles, ["A - Simple Server", "B - Simple Server"])
        XCTAssertTrue(controller.setSourceMatching("B - Simple Server", atPlace: 1), "and it can be moved")
        XCTAssertEqual(titles, ["B - Simple Server", "A - Simple Server"])
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

    func testAMovieWhichCannotBeFinishedIsReported() throws {
        // A disk of its own, which goes away while the take is being recorded
        let image = folder.appendingPathComponent("small.dmg")
        let volume = folder.appendingPathComponent("volume")
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        func hdiutil(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try XCTSkipIf(process.terminationStatus != 0, "hdiutil \(arguments.first ?? "") failed")
        }
        try hdiutil(["create", "-size", "20m", "-fs", "HFS+", "-volname", "RecorderTest", image.path])
        try hdiutil(["attach", "-nobrowse", "-mountpoint", volume.path, image.path])
        var attached = true
        defer { if attached { try? hdiutil(["detach", "-force", volume.path]) } }

        controller.folder = volume.path
        XCTAssertTrue(controller.addSource(matching: "A - Simple Server"))
        XCTAssertTrue(controller.addSource(matching: "B - Simple Server"))
        XCTAssertTrue(controller.start())
        deliverFrames(for: 0.5)
        try hdiutil(["detach", "-force", volume.path])
        attached = false
        stopAndWait()

        XCTAssertFalse(controller.recordingError.isEmpty, "movies which could not be finished must be said to have failed")
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

    // MARK: The assembled picture

    private let a = "A - Simple Server", b = "B - Simple Server", depth = "depthMap - eMotion"
    private let red: [UInt8] = [0, 0, 255, 255], green: [UInt8] = [0, 255, 0, 255], blue: [UInt8] = [255, 0, 0, 255]

    private func tick(_ titles: [String]) {
        for title in titles { XCTAssertTrue(controller.addSource(matching: title)) }
    }

    /// A texture of one colour (blue, green, red, alpha); with `bottom`, its last rows are of that colour.
    private func solid(_ width: Int, _ height: Int, _ colour: [UInt8], bottom: [UInt8]? = nil) -> MTLTexture {
        let texture = makeTexture(width, height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let pixel = (y >= height / 2 ? bottom : nil) ?? colour
            for x in 0..<width {
                for channel in 0..<4 { pixels[(y * width + x) * 4 + channel] = pixel[channel] }
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
        return texture
    }

    /// Reads a movie's pictures: the first, or the last. The answer gives a pixel as blue, green, red, alpha.
    private func picture(_ url: URL, last: Bool = false) throws -> (Int, Int) -> [UInt8] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try MovieInfo.videoTrack(asset), outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        var buffer: CVPixelBuffer?
        // The movie starts with the take, its pictures with its first frame: until then the reader gives a black one
        let start = try MovieInfo(url).start
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetPresentationTimeStamp(sample).seconds >= start - 0.001 else { continue }
            if let image = CMSampleBufferGetImageBuffer(sample) { buffer = image }
            if !last && buffer != nil { break }
        }
        let image = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let rowBytes = CVPixelBufferGetBytesPerRow(image)
        let data = Data(bytes: CVPixelBufferGetBaseAddress(image)!, count: rowBytes * CVPixelBufferGetHeight(image))
        return { x, y in (0..<4).map { data[y * rowBytes + x * 4 + $0] } }
    }

    /// Movies are compressed: a colour comes back nearly as it was.
    private func assertColour(_ pixel: [UInt8], _ expected: [UInt8], _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let close = zip(pixel, expected).prefix(3).allSatisfy { abs(Int($0) - Int($1)) <= 40 }
        XCTAssertTrue(close, "\(message) got \(pixel), expected \(expected)", file: file, line: line)
    }

    private func size(_ width: Int, _ height: Int) -> CGSize { CGSize(width: width, height: height) }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }

    func testDefaultsAreSeparateAndRow() {
        XCTAssertEqual(controller.output, "separate")
        XCTAssertEqual(controller.layout, "row")
        XCTAssertEqual(controller.gap, 0)
        XCTAssertNil(controller.assembledFrame)
        XCTAssertEqual(controller.assembledFile, "")
    }

    func testOSCSetsOutputLayoutAndGap() {
        send("/output", "Both")
        send("/layout", "grid")
        send("/gap", NSNumber(value: 12))
        XCTAssertEqual(controller.output, "both")
        XCTAssertEqual(controller.layout, "grid")
        XCTAssertEqual(controller.gap, 12)
        XCTAssertEqual(controller.error, "")

        send("/output", "mosaic")
        XCTAssertEqual(controller.output, "both")
        XCTAssertTrue(controller.error.contains("/output") && controller.error.contains("separate, assembled, both"), controller.error)
        send("/layout", "diagonal")
        XCTAssertEqual(controller.layout, "grid")
        XCTAssertTrue(controller.error.contains("/layout") && controller.error.contains("row, column, grid, focus"), controller.error)
        send("/gap", "wide")
        XCTAssertTrue(controller.error.contains("/gap"), controller.error)

        send("/gap", NSNumber(value: -5))
        XCTAssertEqual(controller.gap, 0)
        send("/gap", NSNumber(value: 100_000))
        XCTAssertEqual(controller.gap, 1000)
        // Set from the window, a name which does not exist changes nothing
        controller.output = "mosaic"
        controller.layout = "diagonal"
        XCTAssertEqual(controller.output, "both")
        XCTAssertEqual(controller.layout, "grid")
    }

    func testTheySurviveARelaunch() {
        send("/output", "assembled")
        send("/layout", "focus")
        send("/gap", NSNumber(value: 8))
        let next = RecorderController(device: device, directory: directory, defaults: defaults)
        XCTAssertEqual(next.output, "assembled")
        XCTAssertEqual(next.layout, "focus")
        XCTAssertEqual(next.gap, 8)
    }

    func testAssembledLayoutFollowsThePlacesAndTheSettings() {
        XCTAssertEqual(controller.assembledLayout.frames, [])
        tick([a, b])
        deliverFrames(for: 0.1, from: [(a, makeTexture(640, 360)), (b, makeTexture(320, 360))])
        XCTAssertEqual(controller.assembledLayout.size, size(960, 360))
        XCTAssertEqual(controller.assembledLayout.frames.map(\.rectValue), [NSRect(x: 0, y: 0, width: 640, height: 360), NSRect(x: 640, y: 0, width: 320, height: 360)])
        send("/layout", "column")
        XCTAssertEqual(controller.assembledLayout.size, size(640, 1080))
        send("/layout", "row")
        send("/gap", NSNumber(value: 20))
        XCTAssertEqual(controller.assembledLayout.size, size(980, 360))
        send("/gap", NSNumber(value: 0))
        send("/width", NSNumber(value: 480))
        send("/height", NSNumber(value: 270))
        XCTAssertEqual(controller.assembledLayout.size, size(480, 270))
        XCTAssertEqual(controller.assembledLayout.frames.map(\.rectValue.size.width), [320, 160])
        // A source never seen counts as 1920 × 1080
        send("/width", NSNumber(value: 0))
        tick([depth])
        XCTAssertEqual(controller.assembledLayout.size, size(1920 + 960 + 1920, 1080))
    }

    func testAPictureIsComposedForTheMonitorWhenIdle() throws {
        tick([a, b])
        deliverFrames(for: 0.2, from: [(a, makeTexture(640, 360)), (b, makeTexture(320, 360))])
        let frame = try XCTUnwrap(controller.assembledFrame)
        XCTAssertEqual(frame.width, 960)
        XCTAssertEqual(frame.height, 360)
        // It follows the layout without waiting for a frame: a picture which does not move sends none
        send("/layout", "column")
        XCTAssertEqual(controller.assembledFrame?.height, 1080)
        // No source, no picture
        send("/source/1", "")
        send("/source/1", "")
        XCTAssertNil(controller.assembledFrame)
    }

    func testALargePictureIsShownSmallerThanItIsRecorded() throws {
        tick([a, b])
        send("/output", "assembled")
        send("/name", "show")
        deliverFrames(for: 0.2, from: [(a, makeTexture(4000, 500)), (b, makeTexture(4000, 500))])
        XCTAssertEqual(controller.assembledLayout.size, size(8000, 500), "the picture's size is the one recorded")
        XCTAssertEqual(controller.assembledFrame?.width, 4096)
        XCTAssertEqual(controller.assembledFrame?.height, 256)
        XCTAssertTrue(controller.start())
        deliverFrames(for: 0.3, from: [(a, makeTexture(4000, 500)), (b, makeTexture(4000, 500))])
        stopAndWait()
        XCTAssertEqual(try MovieInfo(folder.appendingPathComponent("show.mov")).size, size(8000, 500))
    }

    func testAssembledWritesOneMovie() throws {
        tick([a, b, depth])
        send("/name", "show")
        send("/output", "assembled")
        deliverFrames(for: 0.1, from: [(a, makeTexture(640, 360)), (b, makeTexture(320, 360)), (depth, makeTexture(160, 360))])
        XCTAssertTrue(controller.start())
        deliverFrames(for: 0.5, from: [(a, makeTexture(640, 360)), (b, makeTexture(320, 360)), (depth, makeTexture(160, 360))])
        settle()
        XCTAssertGreaterThan(controller.assembledFrames, 10)
        XCTAssertEqual(controller.frames, controller.assembledFrames)
        stopAndWait()
        XCTAssertEqual(controller.error, "")

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["show.mov"])
        let movie = folder.appendingPathComponent("show.mov")
        XCTAssertEqual(try MovieInfo(movie).size, size(1120, 360))
        XCTAssertEqual(controller.places.map(\.file), ["", "", ""])
        XCTAssertEqual(controller.places.map(\.frames), [0, 0, 0])
        XCTAssertEqual(controller.file, movie.path)
        XCTAssertEqual(controller.assembledFile, movie.path)
        XCTAssertGreaterThan(controller.assembledFrames, 10)
    }

    func testBothWritesEverything() throws {
        tick([a, b])
        send("/name", "show")
        send("/output", "both")
        deliverFrames(for: 0.1, from: [(a, makeTexture(640, 360)), (b, makeTexture(320, 360))])
        XCTAssertTrue(controller.start())
        deliverFrames(for: 0.5, from: [(a, makeTexture(640, 360)), (b, makeTexture(320, 360))])
        stopAndWait()
        XCTAssertEqual(controller.error, "")

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["show — A - Simple Server.mov", "show — B - Simple Server.mov", "show.mov"])
        XCTAssertEqual(controller.file, folder.appendingPathComponent("show.mov").path)
        XCTAssertEqual(controller.assembledFile, controller.file)
        XCTAssertEqual(controller.places.map { URL(fileURLWithPath: $0.file).lastPathComponent }, ["show — A - Simple Server.mov", "show — B - Simple Server.mov"])
        XCTAssertEqual(try MovieInfo(URL(fileURLWithPath: controller.file)).size, size(960, 360))
        XCTAssertEqual(try MovieInfo(URL(fileURLWithPath: controller.places[1].file)).size, size(320, 360))
        XCTAssertGreaterThan(controller.places[1].frames, 10)
        XCTAssertGreaterThan(controller.assembledFrames, 10)
    }

    func testOneSourceInBothIsNamedAfterItsTitleBesideTheAssembledMovie() throws {
        tick([a])
        send("/name", "show")
        send("/output", "both")
        XCTAssertTrue(controller.start())
        deliverFrames(for: 0.3)
        stopAndWait()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["show — A - Simple Server.mov", "show.mov"])
    }

    func testThePictureHasEachSourceInItsPlace() throws {
        // The first as Syphon delivers: its first row is the bottom of the picture, which is red above and blue below
        directory.flippedTitles = [a]
        tick([a, b, depth])
        send("/output", "assembled")
        send("/name", "show")
        let pictures = [(a, solid(64, 48, blue, bottom: red)), (b, solid(64, 48, green)), (depth, solid(64, 48, blue))]
        deliverFrames(for: 0.1, from: pictures)
        XCTAssertTrue(controller.start())
        deliverFrames(for: 0.4, from: pictures)
        stopAndWait()

        let pixel = try picture(folder.appendingPathComponent("show.mov"))
        assertColour(pixel(32, 10), red, "the top of the first source")
        assertColour(pixel(32, 38), blue, "the bottom of the first source")
        assertColour(pixel(96, 24), green, "the second source")
        assertColour(pixel(160, 24), blue, "the third source")
    }

    func testASourceWhichIsAwayLeavesItsPlaceBlack() throws {
        tick([a, b])
        // B's application quits before it was ever seen: it keeps its place, as large as a source never seen
        directory.setTitles([a])
        XCTAssertEqual(titles, [a, b])
        send("/output", "assembled")
        send("/name", "show")
        XCTAssertTrue(controller.start())
        deliverFrames(for: 0.4, from: [(a, solid(192, 108, red))])
        stopAndWait()
        XCTAssertEqual(controller.error, "")

        let movie = folder.appendingPathComponent("show.mov")
        XCTAssertEqual(try MovieInfo(movie).size, size(3840, 1080))
        let pixel = try picture(movie)
        assertColour(pixel(960, 540), red, "the source which is there")
        assertColour(pixel(2880, 540), [0, 0, 0, 255], "the place of the source which is away")
    }

    func testASourceWhichChangesSizeStaysInItsPlace() throws {
        tick([a, b])
        send("/output", "assembled")
        send("/name", "show")
        deliverFrames(for: 0.1, from: [(a, solid(64, 48, red)), (b, solid(64, 48, green))])
        XCTAssertTrue(controller.start())
        deliverFrames(for: 0.3, from: [(a, solid(64, 48, red)), (b, solid(64, 48, green))])
        // A's window is resized: it is square now
        deliverFrames(for: 0.3, from: [(a, solid(48, 48, red)), (b, solid(64, 48, green))])
        XCTAssertEqual(controller.places[0].width, 48)
        XCTAssertEqual(controller.assembledLayout.size, size(128, 48), "the take's picture does not change")
        stopAndWait()
        XCTAssertEqual(controller.error, "")
        XCTAssertEqual(controller.assembledLayout.size, size(112, 48), "the next take's will be as the sources are now")

        let movie = folder.appendingPathComponent("show.mov")
        XCTAssertEqual(try MovieInfo(movie).size, size(128, 48))
        let pixel = try picture(movie, last: true)
        assertColour(pixel(32, 24), red, "the source, in its place")
        assertColour(pixel(2, 24), [0, 0, 0, 255], "fitted, not stretched")
        assertColour(pixel(96, 24), green, "its neighbour has not moved")
    }

    func testTheNextSourceDrivesThePictureWhenTheFirstGoesAway() throws {
        tick([a, b])
        send("/output", "assembled")
        send("/name", "show")
        deliverFrames(for: 0.1, from: [(a, solid(64, 48, red)), (b, solid(64, 48, green))])
        XCTAssertTrue(controller.start())
        deliverFrames(for: 0.3, from: [(a, solid(64, 48, red)), (b, solid(64, 48, green))])
        settle()
        let before = controller.assembledFrames
        XCTAssertGreaterThan(before, 5)
        // A's application is killed: only B delivers
        directory.kill(entry: 2)
        deliverFrames(for: 3.0, from: [(b, solid(64, 48, green))])
        settle()
        XCTAssertGreaterThan(controller.assembledFrames, before + 40, "the picture is driven by the source which is left")
        stopAndWait()
        XCTAssertEqual(controller.error, "")

        let movie = folder.appendingPathComponent("show.mov")
        XCTAssertGreaterThan(try MovieInfo(movie).duration, 3.2)
        let pixel = try picture(movie, last: true)
        assertColour(pixel(96, 24), green)
        assertColour(pixel(32, 24), [0, 0, 0, 255], "the place of the source which has gone is black once it is known to be gone")
    }

    func testChangingTheLayoutWhileRecordingAppliesToTheNextTake() throws {
        tick([a, b])
        send("/output", "assembled")
        send("/name", "show")
        deliverFrames(for: 0.1, from: [(a, makeTexture(64, 48)), (b, makeTexture(64, 48))])
        XCTAssertTrue(controller.start())
        deliverFrames(for: 0.2, from: [(a, makeTexture(64, 48)), (b, makeTexture(64, 48))])
        send("/layout", "column")
        send("/gap", NSNumber(value: 10))
        send("/output", "both")
        XCTAssertEqual(controller.error, "", "they can be set while recording")
        XCTAssertEqual(controller.assembledLayout.size, size(128, 48), "the take keeps the picture it started with")
        deliverFrames(for: 0.2, from: [(a, makeTexture(64, 48)), (b, makeTexture(64, 48))])
        XCTAssertEqual(controller.assembledFrame?.width, 128)
        stopAndWait()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["show.mov"])
        XCTAssertEqual(try MovieInfo(folder.appendingPathComponent("show.mov")).size, size(128, 48))

        XCTAssertEqual(controller.assembledLayout.size, size(64, 106))
        XCTAssertTrue(controller.start())
        deliverFrames(for: 0.3, from: [(a, makeTexture(64, 48)), (b, makeTexture(64, 48))])
        stopAndWait()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
                       ["show 2 — A - Simple Server.mov", "show 2 — B - Simple Server.mov", "show 2.mov", "show.mov"])
        XCTAssertEqual(try MovieInfo(folder.appendingPathComponent("show 2.mov")).size, size(64, 106))
    }

    func testAPictureTooLargeIsRefusedAtTheStart() throws {
        tick([a, b])
        // Two sources as wide as a texture can be: side by side they are more than any can hold
        deliverFrames(for: 0.1, from: [(a, makeTexture(16384, 16)), (b, makeTexture(16384, 16))])
        XCTAssertEqual(controller.assembledLayout.size, size(32768, 16))
        // It is still shown, smaller: the sources must be seen, and separate movies can be recorded
        let shown = try XCTUnwrap(controller.assembledFrame)
        XCTAssertEqual(shown.width, 4096)
        XCTAssertEqual(shown.height, 2)
        send("/output", "both")
        XCTAssertFalse(controller.start())
        XCTAssertTrue(controller.error.contains("32768") && controller.error.contains("smaller size"), controller.error)
        XCTAssertEqual(controller.state, "idle")
        XCTAssertEqual(controller.places.map(\.file), ["", ""])
        XCTAssertEqual(controller.assembledFile, "")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        // Fitted into a size, it is written
        send("/width", NSNumber(value: 4096))
        send("/height", NSNumber(value: 64))
        XCTAssertTrue(controller.start())
        deliverFrames(for: 0.2, from: [(a, makeTexture(16384, 16)), (b, makeTexture(16384, 16))])
        stopAndWait()
        XCTAssertEqual(controller.error, "")
        XCTAssertEqual(try MovieInfo(URL(fileURLWithPath: controller.assembledFile)).size, size(4096, 64))
    }

    func testTheAssembledMovieFailingIsReported() throws {
        // A small disk of its own, which the assembled movie fills
        let image = folder.appendingPathComponent("small.dmg")
        let volume = folder.appendingPathComponent("volume")
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        func hdiutil(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try XCTSkipIf(process.terminationStatus != 0, "hdiutil \(arguments.first ?? "") failed")
        }
        try hdiutil(["create", "-size", "12m", "-fs", "HFS+", "-volname", "RecorderTest", image.path])
        try hdiutil(["attach", "-nobrowse", "-mountpoint", volume.path, image.path])
        defer { try? hdiutil(["detach", "-force", volume.path]) }

        controller.folder = volume.path
        tick([a])
        send("/codec", "prores4444")
        send("/output", "assembled")
        XCTAssertTrue(controller.start())
        // Noise does not compress: the disk is full within a few frames
        let source = try XCTUnwrap(directory.source(a))
        let texture = makeTexture(1280, 720)
        var noise = [UInt8](repeating: 0, count: 1280 * 720 * 4)
        let deadline = Date().addingTimeInterval(20)
        while controller.state == "recording" && Date() < deadline {
            arc4random_buf(&noise, noise.count)
            for alpha in stride(from: 3, to: noise.count, by: 4) { noise[alpha] = 255 }
            texture.replace(region: MTLRegionMake2D(0, 0, 1280, 720), mipmapLevel: 0, withBytes: noise, bytesPerRow: 1280 * 4)
            source.deliver(texture)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        // The only movie of the take has failed: the take stops by itself
        waitForState("idle")
        XCTAssertFalse(controller.recordingError.isEmpty)
        XCTAssertEqual(controller.error, controller.recordingError)
    }

    func testOSCQueryDescribesTheAssembledPicture() throws {
        tick([a, b])
        XCTAssertTrue(controller.startNetwork(withOSCPort: 19460, queryPort: 19461, name: "Recorder Test"))
        deliverFrames(for: 0.1, from: [(a, makeTexture(640, 360)), (b, makeTexture(320, 360))])
        send("/output", "both")
        send("/layout", "column")
        send("/gap", NSNumber(value: 4))

        let root = contents(get("/"))
        let output = try XCTUnwrap(root["output"] as? [String: Any])
        XCTAssertEqual(output["VALUE"] as? [String], ["both"])
        XCTAssertEqual((output["RANGE"] as? [[String: [String]]])?.first?["VALS"], ["separate", "assembled", "both"])
        let layout = try XCTUnwrap(root["layout"] as? [String: Any])
        XCTAssertEqual(layout["VALUE"] as? [String], ["column"])
        XCTAssertEqual((layout["RANGE"] as? [[String: [String]]])?.first?["VALS"], ["row", "column", "grid", "focus"])
        let gap = try XCTUnwrap(root["gap"] as? [String: Any])
        XCTAssertEqual(gap["VALUE"] as? [Int], [4])
        XCTAssertEqual(gap["TYPE"] as? String, "i")
        for name in ["output", "layout", "gap"] {
            XCTAssertFalse(((root[name] as? [String: Any])?["DESCRIPTION"] as? String ?? "").isEmpty, "\(name) has no description")
        }

        let assembled = contents(contents(root["status"])["assembled"])
        XCTAssertEqual(Set(assembled.keys), ["width", "height", "file", "frames", "dropped"])
        XCTAssertEqual((assembled["width"] as? [String: Any])?["VALUE"] as? [Int], [640])
        XCTAssertEqual((assembled["height"] as? [String: Any])?["VALUE"] as? [Int], [360 + 4 + 720])
        XCTAssertEqual((assembled["file"] as? [String: Any])?["VALUE"] as? [String], [""])
        XCTAssertEqual((assembled["frames"] as? [String: Any])?["VALUE"] as? [Int], [0])
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
        XCTAssertEqual(Set(root.keys), ["source", "record", "codec", "width", "height", "fps", "bitrate", "folder", "name", "output", "layout", "gap", "status"])

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
        XCTAssertEqual(Set(status.keys), ["state", "elapsed", "frames", "dropped", "file", "error", "failure", "source", "assembled"])
        XCTAssertEqual((status["state"] as? [String: Any])?["VALUE"] as? [String], ["idle"])
        let placeStatus = contents(contents(status["source"])["1"])
        XCTAssertEqual(Set(placeStatus.keys), ["online", "width", "height", "fps", "file", "frames", "dropped"])
        XCTAssertEqual(Set(contents(status["source"]).keys), Set((1...8).map(String.init)))
        // An OSC int, not a JSON true or false
        let online = try XCTUnwrap(((placeStatus["online"] as? [String: Any])?["VALUE"] as? [Any])?.first as? NSNumber)
        XCTAssertFalse(CFGetTypeID(online) == CFBooleanGetTypeID(), "online is served as a boolean")
        XCTAssertEqual(online.intValue, 0)
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
