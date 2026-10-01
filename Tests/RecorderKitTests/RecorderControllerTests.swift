import XCTest
import AVFoundation
import Metal
import RecorderKit

private final class FakeSources: NSObject, RecorderSourceProvider {
    var titles: [String] = ["main view - eMotion", "main view - eMotion", "Simple Server"]
    var applications: [String] = ["eMotion", "eMotion", "Simple Server"]
    var selected: Int = 2
    var selections: [Int] = []

    func sourceTitles() -> [String] { titles }
    func selectedSourceTitle() -> String? { selected >= 0 ? titles[selected] : nil }
    func selectedSourceApplicationName() -> String? { selected >= 0 ? applications[selected] : nil }
    func selectSource(at index: Int) {
        selections.append(index)
        selected = index
    }
}

final class RecorderControllerTests: XCTestCase {
    private var device: MTLDevice!
    private var folder: URL!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var sources: FakeSources!
    private var controller: RecorderController!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("RecorderControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaultsName = "RecorderControllerTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        sources = FakeSources()
        controller = RecorderController(device: device, sourceProvider: sources, defaults: defaults)
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

    private func makeTexture() -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 320, height: 180, mipmapped: false)
        return device.makeTexture(descriptor: descriptor)!
    }

    /// Delivers frames as a source would, from another thread, for `seconds`.
    private func deliverFrames(for seconds: Double) {
        let texture = makeTexture()
        let delivered = expectation(description: "frames delivered")
        DispatchQueue.global().async { [controller] in
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                controller!.frameReceived(texture)
                usleep(16_000)
            }
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: seconds + 5)
    }

    private func waitForState(_ state: String, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(20)
        while controller.state != state && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(controller.state, state, file: file, line: line)
    }

    // MARK: Settings

    func testDefaults() {
        let fresh = RecorderController(device: device, sourceProvider: sources, defaults: defaults)
        XCTAssertEqual(fresh.codec, "h264")
        XCTAssertEqual(fresh.width, 0)
        XCTAssertEqual(fresh.height, 0)
        XCTAssertEqual(fresh.fps, 0)
        XCTAssertEqual(fresh.bitrate, 0)
        XCTAssertEqual(fresh.name, "")
        XCTAssertEqual(fresh.state, "idle")
        XCTAssertEqual(fresh.error, "")
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

    func testReadOnlyAndUnknownAddressesAreIgnored() {
        send("/status/frames", NSNumber(value: 99))
        send("/nothing/here", NSNumber(value: 1))
        XCTAssertEqual(controller.frames, 0)
        XCTAssertEqual(controller.error, "")
    }

    func testSettingsPersist() {
        send("/codec", "prores4444")
        send("/width", NSNumber(value: 1280))
        send("/fps", NSNumber(value: Float(25)))
        send("/name", "take")

        let next = RecorderController(device: device, sourceProvider: sources, defaults: defaults)
        XCTAssertEqual(next.codec, "prores4444")
        XCTAssertEqual(next.width, 1280)
        XCTAssertEqual(next.fps, 25)
        XCTAssertEqual(next.name, "take")
        XCTAssertEqual(next.folder, folder.path)
    }

    // MARK: Sources

    func testSourceIsSelectedByExactTitleThenBySubstring() {
        XCTAssertTrue(controller.selectSource(matching: "main view - eMotion"))
        XCTAssertEqual(sources.selections, [0], "the first of two servers with the same title")
        send("/source", "simple")
        XCTAssertEqual(sources.selections, [0, 2])
        XCTAssertEqual(controller.error, "")
    }

    func testAnEmptySourceTitleIsRefusedWithAnError() {
        send("/source", "")
        XCTAssertEqual(sources.selections, [])
        XCTAssertFalse(controller.error.isEmpty)
    }

    func testUnknownSourceIsRefusedWithAnError() {
        XCTAssertFalse(controller.selectSource(matching: "Millumin"))
        XCTAssertEqual(sources.selections, [])
        XCTAssertTrue(controller.error.contains("Millumin"), controller.error)
    }

    // MARK: Recording

    func testRecordsFromOSC() throws {
        send("/name", "take")
        send("/record", NSNumber(value: 1))
        XCTAssertEqual(controller.state, "recording")
        XCTAssertTrue(controller.isRecording)
        XCTAssertEqual(controller.file, folder.appendingPathComponent("take.mov").path)

        deliverFrames(for: 0.5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertGreaterThan(controller.frames, 10)
        XCTAssertGreaterThan(controller.elapsed, 0.4)
        XCTAssertEqual(controller.sourceWidth, 320)
        XCTAssertEqual(controller.sourceHeight, 180)

        send("/record", NSNumber(value: 0))
        XCTAssertEqual(controller.state, "finishing")
        waitForState("idle")
        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(controller.error, "")

        let movie = try MovieInfo(URL(fileURLWithPath: controller.file))
        XCTAssertEqual(movie.size, CGSize(width: 320, height: 180))
        XCTAssertGreaterThan(movie.duration, 0.4)
    }

    func testSettingsReachTheMovie() throws {
        send("/codec", "prores422")
        send("/width", NSNumber(value: 640))
        send("/height", NSNumber(value: 480))
        XCTAssertTrue(controller.start())
        deliverFrames(for: 0.3)
        controller.stop(completionHandler: nil)
        waitForState("idle")

        let movie = try MovieInfo(URL(fileURLWithPath: controller.file))
        XCTAssertEqual(movie.size, CGSize(width: 640, height: 480))
        XCTAssertEqual(movie.codec, "apcn")
    }

    func testToggleStartsThenStops() {
        send("/record/toggle")
        XCTAssertEqual(controller.state, "recording")
        deliverFrames(for: 0.2)
        send("/record/toggle")
        waitForState("idle")
        XCTAssertTrue(FileManager.default.fileExists(atPath: controller.file))
    }

    func testAutomaticNameUsesTheSourceApplicationAndTheDate() {
        XCTAssertTrue(controller.start())
        let file = URL(fileURLWithPath: controller.file).lastPathComponent
        XCTAssertTrue(file.hasPrefix("Simple Server \(Calendar.current.component(.year, from: Date()))-"), file)
        XCTAssertTrue(file.hasSuffix(".mov"), file)
        controller.stop(completionHandler: nil)
        waitForState("idle")
    }

    func testAnExistingFileIsNeverOverwritten() throws {
        try Data("precious".utf8).write(to: folder.appendingPathComponent("take.mov"))
        send("/name", "take")
        XCTAssertTrue(controller.start())
        XCTAssertEqual(controller.file, folder.appendingPathComponent("take 2.mov").path)
        deliverFrames(for: 0.2)
        controller.stop(completionHandler: nil)
        waitForState("idle")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("take.mov")), Data("precious".utf8))
    }

    func testANameCannotLeaveTheFolder() {
        send("/name", "../../escape")
        XCTAssertTrue(controller.start())
        XCTAssertEqual(URL(fileURLWithPath: controller.file).deletingLastPathComponent().path, folder.path)
        controller.stop(completionHandler: nil)
        waitForState("idle")
    }

    func testStartWithoutASourceFails() {
        sources.selected = -1
        XCTAssertFalse(controller.start())
        XCTAssertEqual(controller.state, "idle")
        XCTAssertFalse(controller.error.isEmpty)
    }

    func testStartInAMissingFolderFails() {
        controller.folder = folder.appendingPathComponent("missing").path
        send("/record", NSNumber(value: 1))
        XCTAssertEqual(controller.state, "idle")
        XCTAssertTrue(controller.error.contains("missing"), controller.error)
    }

    func testStoppingWithoutFramesReportsIt() {
        XCTAssertTrue(controller.start())
        controller.stop(completionHandler: nil)
        waitForState("idle")
        XCTAssertFalse(controller.error.isEmpty)
        XCTAssertEqual(controller.file, "")
    }

    func testStartingClearsThePreviousError() {
        send("/codec", "hap")
        XCTAssertFalse(controller.error.isEmpty)
        XCTAssertTrue(controller.start())
        XCTAssertEqual(controller.error, "")
        controller.stop(completionHandler: nil)
        waitForState("idle")
    }

    func testRecordOneWhileRecordingChangesNothing() {
        XCTAssertTrue(controller.start())
        let file = controller.file
        send("/record", NSNumber(value: 1))
        XCTAssertEqual(controller.state, "recording")
        XCTAssertEqual(controller.file, file)
        XCTAssertEqual(controller.error, "")
        controller.stop(completionHandler: nil)
        waitForState("idle")
    }

    func testStopHandlerIsCalledWhenTheFileIsFinished() {
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
        XCTAssertTrue(controller.start())
        deliverFrames(for: 0.2)
        send("/codec", "hap")
        XCTAssertFalse(controller.error.isEmpty)
        controller.stop(completionHandler: nil)
        waitForState("idle")

        XCTAssertEqual(controller.recordingError, "", "the movie was written as asked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: controller.file))
    }

    func testWhyARecordingEndedIsKeptUntilTheNextOne() {
        XCTAssertTrue(controller.start())
        controller.stop(completionHandler: nil)
        waitForState("idle")
        XCTAssertFalse(controller.recordingError.isEmpty, "no frame was received")

        send("/fps", NSNumber(value: 25))
        XCTAssertFalse(controller.recordingError.isEmpty)

        XCTAssertTrue(controller.start())
        XCTAssertEqual(controller.recordingError, "")
        deliverFrames(for: 0.2)
        controller.stop(completionHandler: nil)
        waitForState("idle")
        XCTAssertEqual(controller.recordingError, "")
    }

    // MARK: A source which goes away

    func testTheSourceChosenIsSelectedAgainWhenItComesBack() {
        sources.selected = 2
        controller.sourceSelectionDidChange(true)

        // Simple Server quits: the menu falls back on another server
        sources.titles = ["main view - eMotion"]
        sources.applications = ["eMotion"]
        sources.selected = 0
        controller.sourceSelectionDidChange(false)
        controller.sourcesDidChange()
        XCTAssertEqual(sources.selections, [])

        // It is launched again
        sources.titles = ["main view - eMotion", "Simple Server"]
        sources.applications = ["eMotion", "Simple Server"]
        controller.sourcesDidChange()
        XCTAssertEqual(sources.selections, [1])
    }

    func testASourceChosenWhileTheFirstIsAwayIsKept() {
        sources.selected = 2
        controller.sourceSelectionDidChange(true)
        sources.titles = ["main view - eMotion", "Map - AMKinectTrack"]
        sources.applications = ["eMotion", "AMKinectTrack"]
        sources.selected = 0
        controller.sourceSelectionDidChange(false)

        // The user picks another source rather than wait
        sources.selected = 1
        controller.sourceSelectionDidChange(true)

        sources.titles = ["main view - eMotion", "Map - AMKinectTrack", "Simple Server"]
        sources.applications = ["eMotion", "AMKinectTrack", "Simple Server"]
        controller.sourcesDidChange()
        XCTAssertEqual(sources.selections, [], "the user's choice stands")
    }

    func testASourceSelectedByOSCIsTheOneToComeBackTo() {
        send("/source", "main view")
        XCTAssertEqual(sources.selections, [0])
        controller.sourceSelectionDidChange(true)

        sources.titles = ["Simple Server"]
        sources.applications = ["Simple Server"]
        sources.selected = 0
        controller.sourceSelectionDidChange(false)
        sources.titles = ["Simple Server", "main view - eMotion"]
        sources.applications = ["Simple Server", "eMotion"]
        controller.sourcesDidChange()
        XCTAssertEqual(sources.selections, [0, 1])
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

    func testOSCQueryDescribesEveryParameter() throws {
        XCTAssertTrue(controller.startNetwork(withOSCPort: 19430, queryPort: 19431, name: "Recorder Test"))
        XCTAssertEqual(controller.oscPort, 19430)
        send("/codec", "hevc")

        let info = get("/?HOST_INFO")
        XCTAssertEqual(info["NAME"] as? String, "Recorder Test")
        XCTAssertEqual(info["OSC_PORT"] as? Int, 19430)

        let root = try XCTUnwrap(get("/")["CONTENTS"] as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["source", "record", "codec", "width", "height", "fps", "bitrate", "folder", "name", "status"])

        let codec = try XCTUnwrap(root["codec"] as? [String: Any])
        XCTAssertEqual(codec["VALUE"] as? [String], ["hevc"])
        XCTAssertEqual(codec["ACCESS"] as? Int, 3)
        XCTAssertEqual((codec["RANGE"] as? [[String: [String]]])?.first?["VALS"], ["h264", "hevc", "prores422", "prores4444"])

        let source = try XCTUnwrap(root["source"] as? [String: Any])
        XCTAssertEqual(source["VALUE"] as? [String], ["Simple Server"])
        XCTAssertEqual((source["RANGE"] as? [[String: [String]]])?.first?["VALS"], ["main view - eMotion", "Simple Server"])

        let record = try XCTUnwrap(root["record"] as? [String: Any])
        XCTAssertEqual(record["VALUE"] as? [Int], [0])
        XCTAssertEqual(record["TYPE"] as? String, "i")
        XCTAssertNotNil((record["CONTENTS"] as? [String: Any])?["toggle"])

        let status = try XCTUnwrap((root["status"] as? [String: Any])?["CONTENTS"] as? [String: Any])
        XCTAssertEqual(Set(status.keys), ["state", "elapsed", "frames", "dropped", "file", "error", "failure", "source"])
        XCTAssertEqual((status["failure"] as? [String: Any])?["VALUE"] as? [String], [""])
        XCTAssertEqual((status["state"] as? [String: Any])?["VALUE"] as? [String], ["idle"])
        XCTAssertEqual((status["state"] as? [String: Any])?["ACCESS"] as? Int, 1)
        for (name, node) in root where name != "status" {
            XCTAssertFalse(((node as? [String: Any])?["DESCRIPTION"] as? String ?? "").isEmpty, "\(name) has no description")
        }
    }

    func testOSCQueryFollowsTheSourcesAvailable() throws {
        XCTAssertTrue(controller.startNetwork(withOSCPort: 19440, queryPort: 19441, name: "Recorder Test"))
        sources.titles = ["Millumin"]
        sources.applications = ["Millumin"]
        sources.selected = 0
        controller.sourcesDidChange()

        let source = get("/source")
        XCTAssertEqual(source["VALUE"] as? [String], ["Millumin"])
        XCTAssertEqual((source["RANGE"] as? [[String: [String]]])?.first?["VALS"], ["Millumin"])
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
