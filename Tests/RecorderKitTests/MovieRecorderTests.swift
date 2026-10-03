import XCTest
import AVFoundation
import Metal
import RecorderKit

final class MovieRecorderTests: XCTestCase {
    private var device: MTLDevice!
    private var folder: URL!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MovieRecorderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Helpers

    /// A picture with an orange top left quarter, grey elsewhere. `flipped` stores its bottom row first, as Syphon
    /// frames are. `transparentRight` makes its right half fully transparent.
    private func makeTexture(width: Int, height: Int, flipped: Bool = false, transparentRight: Bool = false) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let texture = device.makeTexture(descriptor: descriptor)!
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let row = flipped ? height - 1 - y : y
            for x in 0..<width {
                let offset = (row * width + x) * 4
                if transparentRight && x >= width / 2 { continue }
                let orange = x < width / 2 && y < height / 2
                pixels[offset] = orange ? 0 : 128        // blue
                pixels[offset + 1] = 128                 // green
                pixels[offset + 2] = orange ? 255 : 128  // red
                pixels[offset + 3] = 255
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
        return texture
    }

    private func settings(_ codec: MovieCodec = .H264, width: Int = 0, height: Int = 0, fps: Double = 0) -> MovieRecorderSettings {
        let settings = MovieRecorderSettings()
        settings.codec = codec
        settings.width = width
        settings.height = height
        settings.framesPerSecond = fps
        return settings
    }

    /// Appends a texture and waits until the recorder has dealt with it, so that tests do not depend on how fast
    /// the encoder is.
    private func append(_ texture: MTLTexture, to recorder: MovieRecorder, flipped: Bool = false, at time: Double) {
        recorder.append(texture, flipped: flipped, atTime: time)
        let deadline = Date().addingTimeInterval(5)
        while recorder.framesPending > 0 && Date() < deadline {
            usleep(500)
        }
    }

    @discardableResult
    private func finish(_ recorder: MovieRecorder, at time: Double) -> Error? {
        let finished = expectation(description: "finished")
        var result: Error?
        recorder.finish(atTime: time) {
            XCTAssertTrue(Thread.isMainThread)
            result = $0
            finished.fulfill()
        }
        wait(for: [finished], timeout: 20)
        return result
    }

    /// Records `count` frames of `texture` arriving `rate` times a second, and finishes at `count / rate`.
    private func record(_ texture: MTLTexture, count: Int, rate: Double, settings: MovieRecorderSettings,
                        flipped: Bool = false, name: String = "movie") throws -> (url: URL, recorder: MovieRecorder) {
        let url = folder.appendingPathComponent("\(name).mov")
        let recorder = MovieRecorder(device: device)
        try recorder.startWriting(to: url, settings: settings)
        for index in 0..<count {
            append(texture, to: recorder, flipped: flipped, at: 100 + Double(index) / rate)
        }
        XCTAssertNil(finish(recorder, at: 100 + Double(count) / rate))
        return (url, recorder)
    }

    private func sampleCount(_ url: URL) throws -> Int {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try MovieInfo.videoTrack(asset), outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { count += 1 }
        }
        return count
    }

    /// The first frame of the movie, decoded: (blue, green, red, alpha) of the pixel at x, y from the top left.
    private func firstFrame(_ url: URL) throws -> (width: Int, height: Int, pixel: (Int, Int) -> (b: Int, g: Int, r: Int, a: Int)) {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try MovieInfo.videoTrack(asset),
                                              outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let data = Data(bytes: CVPixelBufferGetBaseAddress(buffer)!, count: rowBytes * height)
        return (width, height, { x, y in
            let offset = y * rowBytes + x * 4
            return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]), Int(data[offset + 3]))
        })
    }

    private func assertOrange(_ pixel: (b: Int, g: Int, r: Int, a: Int), file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(pixel.r > 200 && pixel.b < 70, "expected orange, got \(pixel)", file: file, line: line)
    }

    private func assertGrey(_ pixel: (b: Int, g: Int, r: Int, a: Int), file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(abs(pixel.r - 128) < 30 && abs(pixel.b - 128) < 30, "expected grey, got \(pixel)", file: file, line: line)
    }

    private func assertBlack(_ pixel: (b: Int, g: Int, r: Int, a: Int), file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(pixel.r < 30 && pixel.g < 30 && pixel.b < 30, "expected black, got \(pixel)", file: file, line: line)
    }

    // MARK: Tests

    func testWritesH264MovieOfSourceSize() throws {
        let (url, recorder) = try record(makeTexture(width: 640, height: 360), count: 30, rate: 30, settings: settings())

        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.framesWritten, 30)
        XCTAssertEqual(recorder.framesDropped, 0)
        XCTAssertEqual(recorder.outputSize, CGSize(width: 640, height: 360))
        XCTAssertEqual(try MovieInfo(url).size, CGSize(width: 640, height: 360))
        XCTAssertEqual(try MovieInfo(url).duration, 1.0, accuracy: 0.02)
        XCTAssertEqual(try MovieInfo(url).codec, "avc1")
        XCTAssertEqual(try sampleCount(url), 30)
    }

    func testFrameRateCapHalvesFrames() throws {
        let url = folder.appendingPathComponent("capped.mov")
        let recorder = MovieRecorder(device: device)
        try recorder.startWriting(to: url, settings: settings(fps: 30))
        let texture = makeTexture(width: 320, height: 180)
        // One second of a source at 60 frames a second. Slots are centred on their time, so the last frame, at
        // 59/60 s, is the first of the slot at 1 s: 31 slots receive a frame.
        for index in 0..<60 { append(texture, to: recorder, at: Double(index) / 60) }
        XCTAssertNil(finish(recorder, at: 31.0 / 30))

        XCTAssertEqual(recorder.framesWritten, 31)
        XCTAssertEqual(recorder.framesDropped, 0)
        XCTAssertEqual(try sampleCount(url), 31)
        XCTAssertEqual(try MovieInfo(url).frameRate, 30, accuracy: 0.5)
    }

    func testPictureIsTheRightWayUp() throws {
        let texture = makeTexture(width: 640, height: 360, flipped: true)
        let (url, _) = try record(texture, count: 5, rate: 30, settings: settings(), flipped: true)

        let frame = try firstFrame(url)
        assertOrange(frame.pixel(20, 20))
        assertGrey(frame.pixel(20, 340))
        assertGrey(frame.pixel(620, 20))
    }

    func testPictureWhichIsNotFlippedStaysAsItIs() throws {
        let (url, _) = try record(makeTexture(width: 640, height: 360), count: 5, rate: 30, settings: settings())

        let frame = try firstFrame(url)
        assertOrange(frame.pixel(20, 20))
        assertGrey(frame.pixel(20, 340))
    }

    func testRequestedSizeLetterboxes() throws {
        let (url, recorder) = try record(makeTexture(width: 640, height: 360), count: 5, rate: 30,
                                         settings: settings(width: 400, height: 400))

        XCTAssertEqual(recorder.outputSize, CGSize(width: 400, height: 400))
        let frame = try firstFrame(url)
        XCTAssertEqual(frame.width, 400)
        XCTAssertEqual(frame.height, 400)
        // The picture is 400 × 225, between rows 87 and 312
        assertBlack(frame.pixel(200, 10))
        assertBlack(frame.pixel(200, 390))
        assertOrange(frame.pixel(20, 110))
        assertGrey(frame.pixel(300, 200))
    }

    func testOddSourceSizeIsRoundedDown() throws {
        let (url, _) = try record(makeTexture(width: 641, height: 361), count: 5, rate: 30, settings: settings())

        XCTAssertEqual(try MovieInfo(url).size, CGSize(width: 640, height: 360))
    }

    func testOneDimensionZeroUsesSourceSize() throws {
        let (url, _) = try record(makeTexture(width: 640, height: 360), count: 5, rate: 30, settings: settings(width: 800, height: 0))

        XCTAssertEqual(try MovieInfo(url).size, CGSize(width: 640, height: 360))
    }

    func testSourceSizeChangeKeepsOutputSize() throws {
        let url = folder.appendingPathComponent("resize.mov")
        let recorder = MovieRecorder(device: device)
        try recorder.startWriting(to: url, settings: settings())
        let wide = makeTexture(width: 640, height: 360), square = makeTexture(width: 320, height: 320)
        for index in 0..<10 { append(wide, to: recorder, at: Double(index) / 30) }
        for index in 10..<20 { append(square, to: recorder, at: Double(index) / 30) }
        XCTAssertNil(finish(recorder, at: 20.0 / 30))

        XCTAssertEqual(recorder.framesWritten, 20)
        XCTAssertEqual(try MovieInfo(url).size, CGSize(width: 640, height: 360))
        XCTAssertEqual(try sampleCount(url), 20)
    }

    func testHEVCWrites() throws {
        let (url, _) = try record(makeTexture(width: 640, height: 360), count: 10, rate: 30, settings: settings(.HEVC))
        XCTAssertEqual(try MovieInfo(url).codec, "hvc1")
        assertOrange(try firstFrame(url).pixel(20, 20))
    }

    func testProRes422Writes() throws {
        let (url, _) = try record(makeTexture(width: 640, height: 360), count: 10, rate: 30, settings: settings(.proRes422))
        XCTAssertEqual(try MovieInfo(url).codec, "apcn")
        assertOrange(try firstFrame(url).pixel(20, 20))
    }

    func testProRes4444KeepsAlpha() throws {
        let texture = makeTexture(width: 640, height: 360, transparentRight: true)
        let (url, _) = try record(texture, count: 10, rate: 30, settings: settings(.proRes4444))

        XCTAssertEqual(try MovieInfo(url).codec, "ap4h")
        let frame = try firstFrame(url)
        XCTAssertGreaterThan(frame.pixel(100, 300).a, 250)
        XCTAssertLessThan(frame.pixel(540, 300).a, 5)
    }

    func testBitrateIsApplied() throws {
        // Small blocks of random greys which change with every frame, so that the encoder has something to spend bits on
        let width = 640, height = 360, block = 4
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        let texture = device.makeTexture(descriptor: descriptor)!
        var generator = SystemRandomNumberGenerator()
        let pictures: [[UInt8]] = (0..<6).map { _ in
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            for blockY in 0..<(height / block) {
                for blockX in 0..<(width / block) {
                    let grey = UInt8.random(in: 0...255, using: &generator)
                    for y in (blockY * block)..<((blockY + 1) * block) {
                        let start = (y * width + blockX * block) * 4
                        for offset in start..<(start + block * 4) { pixels[offset] = grey }
                    }
                }
            }
            return pixels
        }
        func size(megabits: Double, name: String) throws -> Int {
            let url = folder.appendingPathComponent("\(name).mov")
            let recorder = MovieRecorder(device: device)
            let settings = settings()
            settings.megabitsPerSecond = megabits
            try recorder.startWriting(to: url, settings: settings)
            for index in 0..<60 {
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pictures[index % pictures.count], bytesPerRow: width * 4)
                append(texture, to: recorder, at: Double(index) / 30)
            }
            XCTAssertNil(finish(recorder, at: 2))
            return try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        }
        let low = try size(megabits: 1, name: "low")
        let high = try size(megabits: 8, name: "high")
        // Two seconds at 1 Mbit/s are 250 kB, at 8 Mbit/s 2 MB. Encoders only approach the bitrate they are given:
        // this picture costs about 540 kB at 1 Mbit/s.
        XCTAssertLessThan(low, 1_000_000)
        XCTAssertGreaterThan(high, 1_500_000)
        XCTAssertGreaterThan(high, low * 2)
    }

    func testAStartTimePlacesTheFirstFrameOnTheClock() throws {
        // A take which started at 100: this source's first frame arrives a second later
        let url = folder.appendingPathComponent("late.mov")
        let recorder = MovieRecorder(device: device)
        try recorder.startWriting(to: url, settings: settings(), startTime: 100)
        let texture = makeTexture(width: 320, height: 180)
        for index in 0..<30 { append(texture, to: recorder, at: 101 + Double(index) / 30) }
        XCTAssertNil(finish(recorder, at: 102))

        XCTAssertEqual(try sampleCount(url), 30)
        XCTAssertEqual(try MovieInfo(url).start, 1.0, accuracy: 0.02)
        XCTAssertEqual(try MovieInfo(url).duration, 2.0, accuracy: 0.05)
    }

    func testWriterIsReadyBeforeTheFirstFrameWhenTheSizeIsGiven() throws {
        // Creating the writer takes a moment: when it waits for the first frame, the frames which follow are lost
        let recorder = MovieRecorder(device: device)
        try recorder.startWriting(to: folder.appendingPathComponent("ready.mov"), settings: settings(width: 640, height: 360))
        XCTAssertEqual(recorder.outputSize, CGSize(width: 640, height: 360))
        finish(recorder, at: 0)
    }

    func testStartFailsForASizeNoEncoderAccepts() {
        let recorder = MovieRecorder(device: device)
        let url = folder.appendingPathComponent("huge.mov")
        XCTAssertThrowsError(try recorder.startWriting(to: url, settings: settings(width: 100_000, height: 100_000))) {
            XCTAssertFalse(($0 as NSError).localizedDescription.isEmpty)
        }
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testStartFailsForMissingFolder() {
        let recorder = MovieRecorder(device: device)
        let url = folder.appendingPathComponent("missing/movie.mov")
        XCTAssertThrowsError(try recorder.startWriting(to: url, settings: settings())) {
            XCTAssertFalse(($0 as NSError).localizedDescription.isEmpty)
        }
        XCTAssertFalse(recorder.isRecording)
    }

    func testStartFailsRatherThanOverwrite() throws {
        let url = folder.appendingPathComponent("existing.mov")
        try Data("precious".utf8).write(to: url)
        XCTAssertThrowsError(try MovieRecorder(device: device).startWriting(to: url, settings: settings()))
        XCTAssertEqual(try Data(contentsOf: url), Data("precious".utf8))
    }

    func testStartWhileRecordingFails() throws {
        let recorder = MovieRecorder(device: device)
        try recorder.startWriting(to: folder.appendingPathComponent("a.mov"), settings: settings())
        XCTAssertTrue(recorder.isRecording)
        XCTAssertThrowsError(try recorder.startWriting(to: folder.appendingPathComponent("b.mov"), settings: settings()))
        finish(recorder, at: 0)
    }

    func testStartWhileThePreviousMovieIsBeingFinishedFails() throws {
        let texture = makeTexture(width: 640, height: 360)
        let recorder = MovieRecorder(device: device)
        try recorder.startWriting(to: folder.appendingPathComponent("first.mov"), settings: settings())
        for index in 0..<10 { append(texture, to: recorder, at: Double(index) / 30) }

        let finished = expectation(description: "finished")
        recorder.finish(atTime: 10.0 / 30) { error in
            XCTAssertNil(error)
            finished.fulfill()
        }
        // The first movie is not finished yet: a second cannot take its place
        XCTAssertThrowsError(try recorder.startWriting(to: folder.appendingPathComponent("second.mov"), settings: settings()))
        wait(for: [finished], timeout: 20)

        XCTAssertEqual(try sampleCount(folder.appendingPathComponent("first.mov")), 10)
        // Once it is, the recorder can be used again
        try recorder.startWriting(to: folder.appendingPathComponent("second.mov"), settings: settings())
        for index in 0..<5 { append(texture, to: recorder, at: 50 + Double(index) / 30) }
        XCTAssertNil(finish(recorder, at: 50 + 5.0 / 30))
        XCTAssertEqual(try sampleCount(folder.appendingPathComponent("second.mov")), 5)
    }

    func testADiskWhichFillsUpIsReportedAsSuchAndTheMovieIsKept() throws {
        // A small disk of its own, which the movie fills
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

        let url = volume.appendingPathComponent("full.mov")
        let recorder = MovieRecorder(device: device)
        let failed = expectation(description: "failed")
        var failure: Error?
        recorder.failureHandler = {
            failure = $0
            failed.fulfill()
        }
        try recorder.startWriting(to: url, settings: settings(.proRes4444))
        // Noise does not compress: twenty frames of ProRes 4444 are more than 12 MB. Opaque noise: the encoder
        // itself fails on noise whose transparency is random too, which no real picture is.
        let texture = makeTexture(width: 1280, height: 720)
        var noise = [UInt8](repeating: 0, count: 1280 * 720 * 4)
        for index in 0..<600 where recorder.isRecording {
            arc4random_buf(&noise, noise.count)
            for alpha in stride(from: 3, to: noise.count, by: 4) { noise[alpha] = 255 }
            texture.replace(region: MTLRegionMake2D(0, 0, 1280, 720), mipmapLevel: 0, withBytes: noise, bytesPerRow: 1280 * 4)
            append(texture, to: recorder, at: Double(index) / 30)
        }
        wait(for: [failed], timeout: 20)

        XCTAssertFalse(recorder.isRecording)
        let error = try XCTUnwrap(failure) as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        XCTAssertTrue(error.code == AVError.diskFull.rawValue || underlying?.code == Int(ENOSPC),
                      "the reason given is \(error.localizedDescription) (\(error.domain) \(error.code)) \(error.userInfo)")
        XCTAssertGreaterThan(recorder.framesWritten, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "what was written is kept")
    }

    func testFinishWithoutFramesLeavesNoFile() throws {
        let url = folder.appendingPathComponent("empty.mov")
        let recorder = MovieRecorder(device: device)
        try recorder.startWriting(to: url, settings: settings())

        XCTAssertNotNil(finish(recorder, at: 1))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFramesAfterFinishAreIgnored() throws {
        let texture = makeTexture(width: 320, height: 180)
        let (url, recorder) = try record(texture, count: 5, rate: 30, settings: settings())
        recorder.append(texture, flipped: false, atTime: 200)
        XCTAssertEqual(recorder.framesWritten, 5)
        XCTAssertEqual(try sampleCount(url), 5)
    }

    func testCodecNames() {
        XCTAssertEqual(MovieRecorderSettings.codecNames(), ["h264", "hevc", "prores422", "prores4444"])
        XCTAssertEqual(MovieRecorderSettings.name(for: .proRes4444), "prores4444")
        var codec = MovieCodec.H264
        XCTAssertTrue(MovieRecorderSettings.getCodec(&codec, forName: "hevc"))
        XCTAssertEqual(codec, .HEVC)
        XCTAssertFalse(MovieRecorderSettings.getCodec(&codec, forName: "hap"))
    }
}
