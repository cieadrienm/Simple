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

    // MARK: The assembled movie

    private func names(_ name: String, _ titles: [String], _ output: TakeOutput) -> (sources: [String], assembled: String?) {
        var assembled: NSURL?
        let urls = Take.urls(forName: name, sourceTitles: titles, output: output, inFolder: folder, assembledURL: &assembled)
        return (urls.map(\.lastPathComponent), assembled?.lastPathComponent)
    }

    private func start(_ titles: [String], output: TakeOutput, assembled: NSSize, name: String = "take",
                       settings: MovieRecorderSettings = MovieRecorderSettings()) throws {
        try take.start(withSourceTitles: titles, sizes: titles.map { _ in NSNull() }, output: output, assembledSize: assembled,
                       name: name, folder: folder, settings: settings, atTime: 100)
    }

    private func appendAssembled(_ texture: MTLTexture, at time: Double) {
        take.appendAssembledTexture(texture, atTime: time)
        let deadline = Date().addingTimeInterval(5)
        while take.framesPending > 0 && Date() < deadline { usleep(500) }
    }

    func testOutputNames() {
        XCTAssertEqual(Take.outputNames(), ["separate", "assembled", "both"])
        XCTAssertEqual(Take.name(for: .both), "both")
        var output = TakeOutput.separate
        XCTAssertTrue(Take.getOutput(&output, forName: "Assembled"))
        XCTAssertEqual(output, .assembled)
        XCTAssertFalse(Take.getOutput(&output, forName: "mosaic"))
    }

    func testNamesForEachOutput() throws {
        // One source
        XCTAssertEqual(names("Depth", ["depthMap"], .separate).sources, ["Depth.mov"])
        XCTAssertNil(names("Depth", ["depthMap"], .separate).assembled)
        XCTAssertEqual(names("Depth", ["depthMap"], .assembled).sources, [])
        XCTAssertEqual(names("Depth", ["depthMap"], .assembled).assembled, "Depth.mov")
        XCTAssertEqual(names("Depth", ["depthMap"], .both).sources, ["Depth — depthMap.mov"])
        XCTAssertEqual(names("Depth", ["depthMap"], .both).assembled, "Depth.mov")
        // Several
        XCTAssertEqual(names("Show", ["A", "B"], .separate).sources, ["Show — A.mov", "Show — B.mov"])
        XCTAssertEqual(names("Show", ["A", "B"], .assembled).assembled, "Show.mov")
        XCTAssertEqual(names("Show", ["A", "B"], .both).sources, ["Show — A.mov", "Show — B.mov"])
        XCTAssertEqual(names("Show", ["A", "B"], .both).assembled, "Show.mov")
        // The same number for all, the assembled movie included
        try Data().write(to: folder.appendingPathComponent("Show — B.mov"))
        XCTAssertEqual(names("Show", ["A", "B"], .both).sources, ["Show 2 — A.mov", "Show 2 — B.mov"])
        XCTAssertEqual(names("Show", ["A", "B"], .both).assembled, "Show 2.mov")
        XCTAssertEqual(names("Show", ["A", "B"], .assembled).assembled, "Show.mov")
        try Data().write(to: folder.appendingPathComponent("Show.mov"))
        try Data().write(to: folder.appendingPathComponent("Show 2.mov"))
        XCTAssertEqual(names("Show", ["A", "B"], .assembled).assembled, "Show 3.mov")
    }

    func testAssembledAloneWritesOneMovieOfThePicturesSize() throws {
        try start(["A", "B"], output: .assembled, assembled: NSSize(width: 640, height: 180))
        XCTAssertEqual(take.movies.count, 0)
        let movie = try XCTUnwrap(take.assembledMovie)
        XCTAssertEqual(movie.url.lastPathComponent, "take.mov")
        XCTAssertEqual(movie.sourceTitle, "")
        let picture = texture(640, 180)
        for index in 0..<15 { appendAssembled(picture, at: 100 + Double(index) / 30) }
        XCTAssertNil(finish(at: 100.5))

        XCTAssertEqual(movie.framesWritten, 15)
        XCTAssertEqual(try MovieInfo(movie.url).size, CGSize(width: 640, height: 180))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["take.mov"])
    }

    func testFramesFromSourcesAreNotWrittenWhenOnlyAssembled() throws {
        try start(["A", "B"], output: .assembled, assembled: NSSize(width: 640, height: 180))
        append(texture(320, 180), from: 0, at: 100)
        append(texture(320, 180), from: 1, at: 100)
        XCTAssertNotNil(finish(at: 100.2), "no picture was assembled: there is no movie")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testBothWritesTheSourcesMoviesAndTheAssembledOne() throws {
        try start(["A", "B"], output: .both, assembled: NSSize(width: 640, height: 180))
        let a = texture(320, 180), picture = texture(640, 180)
        for index in 0..<30 {
            append(a, from: 0, at: 100 + Double(index) / 30)
            append(a, from: 1, at: 100 + Double(index) / 30)
            // The first picture is assembled half a second into the take
            if index >= 15 { appendAssembled(picture, at: 100 + Double(index) / 30) }
        }
        XCTAssertNil(finish(at: 101))

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["take — A.mov", "take — B.mov", "take.mov"])
        let assembled = try MovieInfo(try XCTUnwrap(take.assembledMovie).url)
        XCTAssertEqual(assembled.size, CGSize(width: 640, height: 180))
        XCTAssertEqual(assembled.start, 0.5, accuracy: 0.02, "on the take's clock")
        XCTAssertEqual(assembled.duration, 1.0, accuracy: 0.05)
        XCTAssertEqual(take.movies.map(\.framesWritten), [30, 30])
    }

    func testSeparateHasNoAssembledMovie() throws {
        try start(["A"], output: .separate, assembled: NSSize(width: 640, height: 180))
        XCTAssertNil(take.assembledMovie)
        XCTAssertFalse(take.wantsAssembledFrame(atTime: 100))
        appendAssembled(texture(640, 180), at: 100)
        append(texture(320, 180), from: 0, at: 100)
        XCTAssertNil(finish(at: 100.1))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["take.mov"])
        XCTAssertEqual(try MovieInfo(folder.appendingPathComponent("take.mov")).size, CGSize(width: 320, height: 180))
    }

    func testWantsAssembledFrameFollowsTheFrameRate() throws {
        let settings = MovieRecorderSettings()
        settings.framesPerSecond = 30
        try start(["A"], output: .assembled, assembled: NSSize(width: 320, height: 180), settings: settings)
        XCTAssertTrue(take.wantsAssembledFrame(atTime: 100))
        appendAssembled(texture(320, 180), at: 100)
        XCTAssertFalse(take.wantsAssembledFrame(atTime: 100 + 1.0 / 120))
        XCTAssertTrue(take.wantsAssembledFrame(atTime: 100 + 1.0 / 30))
        finish(at: 100.1)
        XCTAssertFalse(take.wantsAssembledFrame(atTime: 101))
    }

    func testAnAssembledPictureTooLargeToBeWrittenStartsNothing() {
        // Every codec writes eight 1080p sources side by side (15360 wide) on this Mac. What none can is a picture
        // larger than a Metal texture, 16384 on a side: its frames would all be dropped, silently.
        XCTAssertThrowsError(try start(["A", "B"], output: .both, assembled: NSSize(width: 20000, height: 1080))) {
            let message = ($0 as NSError).localizedDescription
            XCTAssertTrue(message.contains("20000"), message)
            XCTAssertTrue(message.contains("smaller"), "it must say what to do: \(message)")
        }
        XCTAssertFalse(take.isRecording)
        XCTAssertNil(take.assembledMovie)
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        // The largest which can be is written
        XCTAssertNoThrow(try start(["A", "B"], output: .assembled, assembled: NSSize(width: 16384, height: 1080)))
        appendAssembled(texture(16384, 1080), at: 100)
        XCTAssertNil(finish(at: 100.1))
        XCTAssertEqual(take.assembledMovie?.framesWritten, 1)
    }

    func testAnAssembledProRes4444MovieIsTransparentBetweenSources() throws {
        let settings = MovieRecorderSettings()
        settings.codec = .proRes4444
        let compositor = Compositor(commandQueue: device.makeCommandQueue()!)
        let layout = Layout(kind: .row, sourceSizes: [NSValue(size: NSSize(width: 320, height: 180)), NSValue(size: NSSize(width: 320, height: 180))],
                            gap: 40, fitting: .zero)
        try start(["A", "B"], output: .assembled, assembled: layout.size, settings: settings)
        let opaque = texture(320, 180)
        let white = [UInt8](repeating: 255, count: 320 * 180 * 4)
        opaque.replace(region: MTLRegionMake2D(0, 0, 320, 180), mipmapLevel: 0, withBytes: white, bytesPerRow: 320 * 4)
        for index in 0..<5 {
            let picture = try XCTUnwrap(compositor.compose(layout, textures: [opaque, opaque], flipped: [false, false], transparent: true))
            appendAssembled(picture, at: 100 + Double(index) / 30)
        }
        XCTAssertNil(finish(at: 100.2))

        let asset = AVURLAsset(url: try XCTUnwrap(take.assembledMovie).url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try MovieInfo.videoTrack(asset), outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(try XCTUnwrap(output.copyNextSampleBuffer())))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[y * rowBytes + x * 4 + 3] }
        XCTAssertGreaterThan(alpha(160, 90), 250, "in the first source")
        XCTAssertLessThan(alpha(340, 90), 5, "between the sources")
        XCTAssertGreaterThan(alpha(520, 90), 250, "in the second source")
    }

    func testTheAssembledMoviesFailureIsReportedWithNoIndex() throws {
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
        try hdiutil(["create", "-size", "12m", "-fs", "HFS+", "-volname", "TakeTest", image.path])
        try hdiutil(["attach", "-nobrowse", "-mountpoint", volume.path, image.path])
        defer { try? hdiutil(["detach", "-force", volume.path]) }

        let failed = expectation(description: "failed")
        var failedIndex: UInt?
        take.movieFailureHandler = { index, _ in
            failedIndex = index
            failed.fulfill()
        }
        let settings = MovieRecorderSettings()
        settings.codec = .proRes4444
        try take.start(withSourceTitles: ["A", "B"], sizes: [NSNull(), NSNull()], output: .assembled, assembledSize: NSSize(width: 1280, height: 720),
                       name: "take", folder: volume, settings: settings, atTime: 100)
        let picture = texture(1280, 720)
        var noise = [UInt8](repeating: 0, count: 1280 * 720 * 4)
        for index in 0..<600 where take.assembledMovie?.error == nil {
            arc4random_buf(&noise, noise.count)
            for alpha in stride(from: 3, to: noise.count, by: 4) { noise[alpha] = 255 }
            picture.replace(region: MTLRegionMake2D(0, 0, 1280, 720), mipmapLevel: 0, withBytes: noise, bytesPerRow: 1280 * 4)
            appendAssembled(picture, at: 100 + Double(index) / 30)
        }
        wait(for: [failed], timeout: 20)

        XCTAssertEqual(failedIndex, UInt(NSNotFound))
        XCTAssertNotNil(take.assembledMovie?.error)
        XCTAssertTrue(take.isRecording, "the take goes on")
        XCTAssertNil(finish(at: 130), "the movie has frames: it is kept")
    }
}
