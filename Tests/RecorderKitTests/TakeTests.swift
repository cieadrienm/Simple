import XCTest
import AVFoundation
import Metal
import RecorderKit

final class TakeTests: XCTestCase {
    private var device: MTLDevice!
    private var folder: URL!
    private var take: Take!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TakeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        take = Take(device: device)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Helpers

    private func texture(_ width: Int, _ height: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        return device.makeTexture(descriptor: descriptor)!
    }

    private func names(_ name: String, _ titles: [String]) -> [String] {
        Take.urls(forName: name, sourceTitles: titles, inFolder: folder).map(\.lastPathComponent)
    }

    private func start(_ titles: [String], sizes: [Any]? = nil, name: String = "take", at time: Double = 100,
                       settings: MovieRecorderSettings = MovieRecorderSettings()) throws {
        try take.start(withSourceTitles: titles, sizes: sizes ?? titles.map { _ in NSNull() }, name: name, folder: folder, settings: settings, atTime: time)
    }

    private func append(_ texture: MTLTexture, from index: Int, at time: Double) {
        take.append(texture, flipped: false, fromSourceAt: UInt(index), atTime: time)
        let deadline = Date().addingTimeInterval(5)
        while take.framesPending > 0 && Date() < deadline { usleep(500) }
    }

    @discardableResult
    private func finish(at time: Double) -> Error? {
        let finished = expectation(description: "finished")
        var result: Error?
        take.finish(atTime: time) {
            XCTAssertTrue(Thread.isMainThread)
            result = $0
            finished.fulfill()
        }
        wait(for: [finished], timeout: 20)
        return result
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    // MARK: Names

    func testOneSourceTakesTheNameAlone() {
        XCTAssertEqual(names("Depth", ["depthMap - eMotion"]), ["Depth.mov"])
    }

    func testSeveralSourcesAreNamedAfterTheirTitles() {
        XCTAssertEqual(names("Show", ["main view - eMotion", "Camera"]), ["Show — main view - eMotion.mov", "Show — Camera.mov"])
    }

    func testTheSameNumberIsAddedToEveryNameWhenOneExists() throws {
        try Data().write(to: folder.appendingPathComponent("Show — Camera.mov"))
        XCTAssertEqual(names("Show", ["main view", "Camera"]), ["Show 2 — main view.mov", "Show 2 — Camera.mov"])
        try Data().write(to: folder.appendingPathComponent("Show 2 — main view.mov"))
        XCTAssertEqual(names("Show", ["main view", "Camera"]), ["Show 3 — main view.mov", "Show 3 — Camera.mov"])
        try Data().write(to: folder.appendingPathComponent("Depth.mov"))
        XCTAssertEqual(names("Depth", ["depthMap"]), ["Depth 2.mov"])
    }

    func testTitlesAndNamesCannotLeaveTheFolder() {
        for url in Take.urls(forName: "../../up", sourceTitles: ["a/b", "../c:d", ".hidden"], inFolder: folder) {
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, folder.standardizedFileURL.path, url.path)
            XCTAssertFalse(url.lastPathComponent.hasPrefix("."), url.lastPathComponent)
        }
    }

    // MARK: Movies

    func testEverySourceGetsItsMovieAtItsOwnSize() throws {
        try start(["A", "B"])
        XCTAssertTrue(take.isRecording)
        let a = texture(640, 360), b = texture(320, 320)
        for index in 0..<15 {
            append(a, from: 0, at: 100 + Double(index) / 30)
            append(b, from: 1, at: 100 + Double(index) / 30)
        }
        XCTAssertNil(finish(at: 100.5))

        XCTAssertFalse(take.isRecording)
        XCTAssertEqual(take.movies.map(\.sourceTitle), ["A", "B"])
        XCTAssertEqual(take.movies.map(\.url.lastPathComponent), ["take — A.mov", "take — B.mov"])
        XCTAssertEqual(try MovieInfo(take.movies[0].url).size, CGSize(width: 640, height: 360))
        XCTAssertEqual(try MovieInfo(take.movies[1].url).size, CGSize(width: 320, height: 320))
    }

    func testTheSizeSettingDoesNotApplyToSeparateMovies() throws {
        let settings = MovieRecorderSettings()
        settings.width = 1920
        settings.height = 1080
        try start(["A"], settings: settings)
        let a = texture(640, 360)
        for index in 0..<5 { append(a, from: 0, at: 100 + Double(index) / 30) }
        XCTAssertNil(finish(at: 100.2))
        XCTAssertEqual(try MovieInfo(take.movies[0].url).size, CGSize(width: 640, height: 360))
    }

    func testTwoMoviesShareTheTakesClock() throws {
        try start(["A", "B"])
        let a = texture(320, 180), b = texture(320, 180)
        // A delivers from the start, B half a second later
        for index in 0..<30 {
            append(a, from: 0, at: 100 + Double(index) / 30)
            if index >= 15 { append(b, from: 1, at: 100 + Double(index) / 30) }
        }
        XCTAssertNil(finish(at: 101))

        let movieA = try MovieInfo(take.movies[0].url), movieB = try MovieInfo(take.movies[1].url)
        XCTAssertEqual(movieA.start, 0, accuracy: 0.02)
        XCTAssertEqual(movieB.start, 0.5, accuracy: 0.02)
        XCTAssertEqual(movieA.duration, 1.0, accuracy: 0.05)
        XCTAssertEqual(movieB.duration, 1.0, accuracy: 0.05)
    }

    func testAMovieWhichStartsLateIsPlacedOnTheTakesClock() throws {
        // The size of B is not known when the take starts: its source is away
        try start(["A", "B"], sizes: [NSValue(size: NSSize(width: 320, height: 180)), NSNull()])
        let a = texture(320, 180), b = texture(640, 480)
        for index in 0..<60 {
            append(a, from: 0, at: 100 + Double(index) / 30)
            if index >= 45 { append(b, from: 1, at: 100 + Double(index) / 30) }
        }
        XCTAssertNil(finish(at: 102))

        let movieB = try MovieInfo(take.movies[1].url)
        XCTAssertEqual(movieB.size, CGSize(width: 640, height: 480))
        XCTAssertEqual(movieB.start, 1.5, accuracy: 0.02)
        XCTAssertEqual(movieB.duration, 2.0, accuracy: 0.05)
    }

    func testASourceWhichNeverArrivesLeavesNoFileAndIsNotAFailure() throws {
        try start(["A", "B", "C"], sizes: [NSNull(), NSValue(size: NSSize(width: 640, height: 360)), NSNull()])
        let a = texture(320, 180)
        for index in 0..<10 { append(a, from: 0, at: 100 + Double(index) / 30) }
        XCTAssertNil(finish(at: 100.4))

        XCTAssertTrue(exists("take — A.mov"))
        XCTAssertFalse(exists("take — B.mov"), "B's size was known, so its file was begun: it must not stay")
        XCTAssertFalse(exists("take — C.mov"))
        XCTAssertEqual(take.movies.map(\.framesWritten), [10, 0, 0])
        XCTAssertNil(take.movies[1].error)
    }

    func testATakeWithNoFrameAtAllFails() throws {
        try start(["A", "B"])
        let error = finish(at: 101)
        XCTAssertNotNil(error)
        XCTAssertFalse((error as NSError?)?.localizedDescription.isEmpty ?? true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testFramesAndDropsAreCountedPerMovie() throws {
        try start(["A", "B"])
        let a = texture(320, 180)
        for index in 0..<12 { append(a, from: 0, at: 100 + Double(index) / 30) }
        for index in 0..<7 { append(a, from: 1, at: 100 + Double(index) / 30) }
        XCTAssertEqual(take.movies.map(\.framesWritten), [12, 7])
        XCTAssertEqual(take.movies.map(\.framesDropped), [0, 0])
        finish(at: 100.5)
        XCTAssertEqual(take.movies.map(\.framesWritten), [12, 7])
    }

    func testAFrameFromASourceWhichIsNotInTheTakeIsIgnored() throws {
        try start(["A"])
        append(texture(320, 180), from: 3, at: 100)
        append(texture(320, 180), from: 0, at: 100)
        XCTAssertNil(finish(at: 100.1))
        XCTAssertEqual(take.movies.map(\.framesWritten), [1])
    }

    // MARK: Starting

    func testStartFailsInAMissingFolderAndWritesNothing() {
        let missing = folder.appendingPathComponent("missing")
        XCTAssertThrowsError(try take.start(withSourceTitles: ["A"], sizes: [NSNull()], name: "take", folder: missing,
                                            settings: MovieRecorderSettings(), atTime: 100)) {
            XCTAssertTrue(($0 as NSError).localizedDescription.contains("missing"), ($0 as NSError).localizedDescription)
        }
        XCTAssertFalse(take.isRecording)
    }

    func testStartWithoutSourcesFails() {
        XCTAssertThrowsError(try start([]))
        XCTAssertFalse(take.isRecording)
    }

    func testStartWhileRecordingOrFinishingFails() throws {
        try start(["A"])
        XCTAssertThrowsError(try start(["A"], name: "other"))
        let a = texture(320, 180)
        for index in 0..<5 { append(a, from: 0, at: 100 + Double(index) / 30) }

        let finished = expectation(description: "finished")
        take.finish(atTime: 100.2) { _ in finished.fulfill() }
        XCTAssertThrowsError(try start(["A"], name: "other"), "the first take's movies are not finished")
        wait(for: [finished], timeout: 20)

        try start(["A"], name: "other")
        append(a, from: 0, at: 200)
        XCTAssertNil(finish(at: 200.1))
        XCTAssertTrue(exists("take.mov") && exists("other.mov"))
    }

    func testATakeCanFollowAnother() throws {
        let a = texture(320, 180)
        for name in ["one", "two", "three"] {
            try start(["A", "B"], name: name)
            for index in 0..<4 {
                append(a, from: 0, at: 100 + Double(index) / 30)
                append(a, from: 1, at: 100 + Double(index) / 30)
            }
            XCTAssertNil(finish(at: 100.2))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 6)
    }
}
