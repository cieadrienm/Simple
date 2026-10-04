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

    /// Sound made by a source from one time to another, in pieces which arrive when their last sample is made, as
    /// they do from a sender. The same value on both channels.
    private final class SoundFeed {
        let rate: Double, from: Double, to: Double, piece: Int
        let value: (Int) -> Float
        private(set) var given = 0

        init(rate: Double = 48000, from: Double, to: Double, pieceSeconds: Double = 0.01, value: @escaping (Int) -> Float) {
            self.rate = rate
            self.from = from
            self.to = to
            self.piece = Int(pieceSeconds * rate)
            self.value = value
        }

        /// A tone of half the full scale
        convenience init(rate: Double = 48000, from: Double, to: Double, frequency: Double = 1000) {
            self.init(rate: rate, from: from, to: to) { Float(0.5 * sin(2 * .pi * frequency * Double($0) / rate)) }
        }

        /// Gives the recorder the pieces which have arrived by a time.
        func give(to recorder: MovieRecorder, upTo time: Double) {
            let total = Int(((to - from) * rate).rounded())
            while true {
                let count = min(piece, total - given)
                guard count > 0 else { return }
                let arrival = from + Double(given + count) / rate
                guard arrival <= time + 1e-9 else { return }
                var samples = [Float](repeating: 0, count: count * 2)
                for index in 0..<count {
                    let value = value(given + index)
                    samples[2 * index] = value
                    samples[2 * index + 1] = value
                }
                recorder.append(SourceSound(interleavedStereoSamples: samples, frameCount: UInt(count), sampleRate: rate)!, atTime: arrival)
                given += count
            }
        }
    }

    private func soundSettings(_ codec: MovieCodec = .H264, width: Int = 0, height: Int = 0) -> MovieRecorderSettings {
        let settings = settings(codec, width: width, height: height)
        settings.recordsSound = true
        return settings
    }

    /// Records frames 30 times a second from one time to another and, before each, the sound which has arrived;
    /// finishes at `finish`.
    @discardableResult
    private func recordWithSound(_ recorder: MovieRecorder, name: String, settings: MovieRecorderSettings, startTime: Double = 100,
                                 frames: (from: Double, to: Double), sound: [SoundFeed], finish finishTime: Double) throws -> URL {
        let url = folder.appendingPathComponent("\(name).mov")
        let texture = makeTexture(width: 320, height: 180)
        try recorder.startWriting(to: url, settings: settings, startTime: startTime)
        let count = Int(((frames.to - frames.from) * 30).rounded())
        for index in 0..<count {
            let time = frames.from + Double(index) / 30
            sound.forEach { $0.give(to: recorder, upTo: time) }
            append(texture, to: recorder, at: time)
        }
        sound.forEach { $0.give(to: recorder, upTo: finishTime) }
        XCTAssertNil(finish(recorder, at: finishTime))
        return url
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

    func testWantsFrameFollowsTheFrameRate() throws {
        let recorder = MovieRecorder(device: device)
        XCTAssertFalse(recorder.wantsFrame(atTime: 0), "it is not recording")
        try recorder.startWriting(to: folder.appendingPathComponent("wants.mov"), settings: settings(fps: 30), startTime: 100)
        let texture = makeTexture(width: 320, height: 180)
        XCTAssertTrue(recorder.wantsFrame(atTime: 100))
        XCTAssertTrue(recorder.wantsFrame(atTime: 100), "asking takes nothing")
        append(texture, to: recorder, at: 100)
        XCTAssertFalse(recorder.wantsFrame(atTime: 100 + 1.0 / 120), "the frame of this thirtieth of a second is written")
        XCTAssertTrue(recorder.wantsFrame(atTime: 100 + 1.0 / 30))
        XCTAssertFalse(recorder.wantsFrame(atTime: 99), "before the movie begins")
        finish(recorder, at: 100.1)
        XCTAssertFalse(recorder.wantsFrame(atTime: 101))
    }

    func testAFrameIsNotWantedWhileTheEncoderIsBehind() throws {
        // Whoever composes a picture for the recorder asks first: a picture which would be dropped on arrival
        // must not be composed, as it would take the place of one which is still waiting to be read
        let recorder = MovieRecorder(device: device)
        try recorder.startWriting(to: folder.appendingPathComponent("behind.mov"), settings: settings(), startTime: 100)
        let texture = makeTexture(width: 3840, height: 2160)
        // The first frame makes the writer, which takes a moment: these three wait behind it
        for index in 0..<3 { recorder.append(texture, flipped: false, atTime: 100 + Double(index) / 60) }
        XCTAssertEqual(recorder.framesPending, 3)
        XCTAssertFalse(recorder.wantsFrame(atTime: 100.05))
        XCTAssertEqual(recorder.framesDropped, 1, "the frame it had no room for is counted")
        let deadline = Date().addingTimeInterval(10)
        while recorder.framesPending > 0 && Date() < deadline { usleep(1000) }
        XCTAssertTrue(recorder.wantsFrame(atTime: 100.1))
        XCTAssertEqual(recorder.framesDropped, 1, "asking when there is room counts nothing")
        finish(recorder, at: 100.2)
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

    // MARK: Sound

    func testAToneIsWrittenAndReadBack() throws {
        let recorder = MovieRecorder(device: device)
        let url = try recordWithSound(recorder, name: "tone", settings: soundSettings(), frames: (100, 102),
                                      sound: [SoundFeed(from: 100, to: 102)], finish: 102)

        let sound = try SoundInfo(url)
        XCTAssertEqual(sound.codec, "aac ")
        XCTAssertEqual(sound.sampleRate, 48000)
        XCTAssertEqual(sound.channelCount, 2)
        XCTAssertEqual(sound.duration, 2, accuracy: 0.03)
        XCTAssertEqual(sound.frequency(from: 0.2, to: 1.8), 1000, accuracy: 5)
        XCTAssertEqual(try XCTUnwrap(sound.soundStart()), 0, accuracy: 0.03)
        XCTAssertEqual(recorder.soundWritten, 2, accuracy: 0.03)
        XCTAssertEqual(recorder.soundLeftOut, 0)
        XCTAssertEqual(try sampleCount(url), 60, "the pictures are all there")
    }

    func testProResMoviesHaveLinearPCM() throws {
        let url = try recordWithSound(MovieRecorder(device: device), name: "prores", settings: soundSettings(.proRes422),
                                      frames: (100, 101), sound: [SoundFeed(from: 100, to: 101)], finish: 101)

        let sound = try SoundInfo(url)
        XCTAssertEqual(sound.codec, "lpcm")
        XCTAssertEqual(sound.bitsPerChannel, 24)
        XCTAssertEqual(sound.sampleRate, 48000)
        XCTAssertEqual(sound.channelCount, 2)
        XCTAssertEqual(sound.duration, 1, accuracy: 0.03)
        XCTAssertEqual(sound.frequency(from: 0.1, to: 0.9), 1000, accuracy: 5)
    }

    func testA44100HertzToneKeepsItsPitchAndLength() throws {
        let url = try recordWithSound(MovieRecorder(device: device), name: "44100", settings: soundSettings(), frames: (100, 102),
                                      sound: [SoundFeed(rate: 44100, from: 100, to: 102)], finish: 102)

        let sound = try SoundInfo(url)
        XCTAssertEqual(sound.sampleRate, 48000)
        XCTAssertEqual(sound.duration, 2, accuracy: 0.03)
        XCTAssertEqual(sound.frequency(from: 0.2, to: 1.8), 1000, accuracy: 5)
    }

    func testAChangeOfRateKeepsThePitch() throws {
        // The encoder converts only from the first rate it is given: a sender relaunched at another rate must not
        // change the pitch of what follows
        let url = try recordWithSound(MovieRecorder(device: device), name: "rates", settings: soundSettings(), frames: (100, 102),
                                      sound: [SoundFeed(rate: 44100, from: 100, to: 101), SoundFeed(rate: 48000, from: 101, to: 102)],
                                      finish: 102)

        let sound = try SoundInfo(url)
        XCTAssertEqual(sound.duration, 2, accuracy: 0.03)
        XCTAssertEqual(sound.frequency(from: 0.1, to: 0.9), 1000, accuracy: 5)
        XCTAssertEqual(sound.frequency(from: 1.1, to: 1.9), 1000, accuracy: 5)
    }

    func testSoundWhichStartsLateIsPlacedOnTheMoviesClock() throws {
        let recorder = MovieRecorder(device: device)
        let url = try recordWithSound(recorder, name: "late", settings: soundSettings(), frames: (100, 101.5),
                                      sound: [SoundFeed(from: 100.5, to: 101.5)], finish: 101.5)

        let sound = try SoundInfo(url)
        XCTAssertEqual(try XCTUnwrap(sound.soundStart()), 0.5, accuracy: 0.03)
        XCTAssertEqual(sound.duration, 1.5, accuracy: 0.03)
        XCTAssertEqual(recorder.soundWritten, 1.5, accuracy: 0.03, "the silence before it is written too")
    }

    func testTwoMoviesOfATakeHaveTheirSoundInStep() throws {
        // A click at 101: the first sample of the piece which arrives at 101.01
        let click: (Int) -> Float = { $0 == 48000 ? 1 : 0 }
        let first = MovieRecorder(device: device), second = MovieRecorder(device: device)
        let firstURL = folder.appendingPathComponent("first.mov"), secondURL = folder.appendingPathComponent("second.mov")
        try first.startWriting(to: firstURL, settings: soundSettings(), startTime: 100)
        try second.startWriting(to: secondURL, settings: soundSettings(.proRes422), startTime: 100)
        let firstSound = SoundFeed(from: 100, to: 102, value: click), secondSound = SoundFeed(from: 100, to: 102, value: click)
        let texture = makeTexture(width: 320, height: 180)
        for index in 0..<60 {
            let time = 100 + Double(index) / 30
            firstSound.give(to: first, upTo: time)
            secondSound.give(to: second, upTo: time)
            append(texture, to: first, at: time)
            // The second source's pictures start later
            if time >= 100.5 { append(texture, to: second, at: time) }
        }
        firstSound.give(to: first, upTo: 102)
        secondSound.give(to: second, upTo: 102)
        XCTAssertNil(finish(first, at: 102))
        XCTAssertNil(finish(second, at: 102))

        let firstClicks = try SoundInfo(firstURL).clicks(), secondClicks = try SoundInfo(secondURL).clicks()
        XCTAssertEqual(firstClicks.count, 1)
        XCTAssertEqual(secondClicks.count, 1)
        XCTAssertEqual(try XCTUnwrap(firstClicks.first), 1, accuracy: 0.03)
        XCTAssertEqual(try XCTUnwrap(firstClicks.first), try XCTUnwrap(secondClicks.first), accuracy: 1.0 / 30)
    }

    func testAMovieWithoutSoundIsAsBefore() throws {
        let recorder = MovieRecorder(device: device)
        let url = try recordWithSound(recorder, name: "silent", settings: settings(), frames: (100, 101),
                                      sound: [SoundFeed(from: 100, to: 101)], finish: 101)

        XCTAssertFalse(try SoundInfo.hasSound(url))
        XCTAssertEqual(recorder.soundWritten, 0)
        XCTAssertEqual(recorder.soundLeftOut, 0)
        XCTAssertEqual(try sampleCount(url), 30)
    }

    func testAMovieWhoseSoundNeverCameIsWhole() throws {
        // An empty audio input is left out by the writer: the movie has its pictures and no sound track
        let recorder = MovieRecorder(device: device)
        let url = try recordWithSound(recorder, name: "nosound", settings: soundSettings(), frames: (100, 102), sound: [], finish: 102)

        XCTAssertEqual(try sampleCount(url), 60)
        XCTAssertEqual(try MovieInfo(url).duration, 2, accuracy: 0.05)
        XCTAssertFalse(try SoundInfo.hasSound(url))
        XCTAssertEqual(recorder.soundWritten, 0)
    }

    func testSoundWhichStopsLeavesTheRestSilentOrShort() throws {
        let url = try recordWithSound(MovieRecorder(device: device), name: "stops", settings: soundSettings(), frames: (100, 103),
                                      sound: [SoundFeed(from: 100, to: 101)], finish: 103)

        XCTAssertEqual(try MovieInfo(url).duration, 3, accuracy: 0.05, "the movie plays to its pictures' end")
        XCTAssertEqual(try sampleCount(url), 90)
        let sound = try SoundInfo(url)
        XCTAssertLessThanOrEqual(sound.duration, 3.03)
        XCTAssertEqual(sound.frequency(from: 0.1, to: 0.9), 1000, accuracy: 5)
        XCTAssertLessThan(sound.peak(from: 1.1, to: sound.duration), 0.01, "nothing is heard after the sound stopped")
    }

    func testSoundIsLeftOutRatherThanPiledUp() throws {
        // No size is given: the movie is made when its first picture comes, and sound waits until then. Ten seconds
        // of it come at once, each piece with the time it was made: the two seconds which came last are kept.
        let recorder = MovieRecorder(device: device)
        let url = folder.appendingPathComponent("pileup.mov")
        try recorder.startWriting(to: url, settings: soundSettings(), startTime: 100)
        SoundFeed(from: 100, to: 110).give(to: recorder, upTo: 110)
        XCTAssertEqual(recorder.soundLeftOut, 8, accuracy: 0.05)
        XCTAssertEqual(recorder.soundWritten, 0)

        let texture = makeTexture(width: 320, height: 180)
        for index in 0..<30 { append(texture, to: recorder, at: 110 + Double(index) / 30) }
        XCTAssertNil(finish(recorder, at: 111))

        XCTAssertEqual(recorder.framesWritten, 30, "the pictures are not held back by the sound")
        XCTAssertEqual(try sampleCount(url), 30)
        XCTAssertEqual(recorder.soundLeftOut, 8, accuracy: 0.05)
        let sound = try SoundInfo(url)
        XCTAssertEqual(try XCTUnwrap(sound.soundStart()), 8, accuracy: 0.03, "what was kept is in its place, after silence")
        XCTAssertEqual(sound.frequency(from: 8.1, to: 9.9), 1000, accuracy: 5)
        XCTAssertEqual(recorder.soundWritten, 10, accuracy: 0.03, "the silence in place of what was left out is written")
    }

    func testFinishingKeepsTheSoundWrittenSoFar() throws {
        // Stopped in the middle of a sound: the last pieces are still waiting when the movie is finished
        let recorder = MovieRecorder(device: device)
        let url = folder.appendingPathComponent("stopped.mov")
        try recorder.startWriting(to: url, settings: soundSettings(width: 320, height: 180), startTime: 100)
        let tone = SoundFeed(from: 100, to: 110)
        let texture = makeTexture(width: 320, height: 180)
        for index in 0..<30 {
            let time = 100 + Double(index) / 30
            tone.give(to: recorder, upTo: time)
            append(texture, to: recorder, at: time)
        }
        tone.give(to: recorder, upTo: 101.5)
        XCTAssertNil(finish(recorder, at: 101.5))

        let sound = try SoundInfo(url)
        XCTAssertEqual(sound.duration, 1.5, accuracy: 0.03)
        XCTAssertEqual(sound.frequency(from: 1.1, to: 1.45), 1000, accuracy: 10, "the sound which came last is there")
        XCTAssertEqual(recorder.soundWritten, 1.5, accuracy: 0.03)
    }

    func testSoundDoesNotCountAsAFrame() throws {
        // The size is given: the movie's file is made at once, and sound is given to it
        let url = folder.appendingPathComponent("soundonly.mov")
        let recorder = MovieRecorder(device: device)
        try recorder.startWriting(to: url, settings: soundSettings(width: 320, height: 180), startTime: 100)
        SoundFeed(from: 100, to: 101).give(to: recorder, upTo: 101)

        XCTAssertNotNil(finish(recorder, at: 101), "no frame was received")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSoundAfterFinishIsIgnored() throws {
        let recorder = MovieRecorder(device: device)
        try recordWithSound(recorder, name: "after", settings: soundSettings(), frames: (100, 101),
                            sound: [SoundFeed(from: 100, to: 101)], finish: 101)
        let written = recorder.soundWritten
        SoundFeed(from: 101, to: 102).give(to: recorder, upTo: 102)
        XCTAssertEqual(recorder.soundWritten, written)
        XCTAssertEqual(recorder.soundLeftOut, 0)
    }
}
