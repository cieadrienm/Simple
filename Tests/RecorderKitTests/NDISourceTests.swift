import XCTest
import AVFoundation
import Metal
import RecorderKit
import NDITestSupport

/// What a source's handler saw, on the source's thread: read on the main thread.
private final class FrameLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _sizes: [CGSize] = []
    private var _pixels: [String: (Int, Int) -> [UInt8]] = [:]

    /// The handler to give the source. It reads each frame at once: the ring writes a texture again eleven frames on.
    var handler: (MTLTexture) -> Void {
        { [self] texture in
            let rowBytes = texture.width * 4
            var bytes = [UInt8](repeating: 0, count: rowBytes * texture.height)
            texture.getBytes(&bytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            let size = CGSize(width: texture.width, height: texture.height)
            lock.withLock {
                _count += 1
                if _sizes.last != size { _sizes.append(size) }
                _pixels["\(texture.width)x\(texture.height)"] = { x, y in Array(bytes[(y * rowBytes + x * 4)..<(y * rowBytes + x * 4 + 4)]) }
            }
        }
    }

    var count: Int { lock.withLock { _count } }
    /// The sizes of the frames, each once a change
    var sizes: [CGSize] { lock.withLock { _sizes } }
    /// The last frame of this size, as blue, green, red, alpha at x, y
    func pixels(_ width: Int, _ height: Int) -> ((Int, Int) -> [UInt8])? {
        lock.withLock { _pixels["\(width)x\(height)"] }
    }
}

/// The pieces of sound a source's handler gave, on the source's thread: read on the main thread.
private final class SoundLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _pieces: [SourceSound] = []

    /// The handler to give the source. A piece never changes: it is kept as it is.
    var handler: (SourceSound) -> Void {
        { [self] sound in lock.withLock { _pieces.append(sound) } }
    }

    var pieces: [SourceSound] { lock.withLock { _pieces } }
    var count: Int { lock.withLock { _pieces.count } }
    /// Samples in each channel, all pieces together
    var frameCount: Int { lock.withLock { _pieces.reduce(0) { $0 + Int($1.frameCount) } } }
    var sampleRates: Set<Double> { Set(pieces.map(\.sampleRate)) }

    /// One of the two channels of the pieces, joined, the first piece left out (it may begin anywhere)
    func channel(_ channel: Int) -> [Float] {
        var samples = [Float]()
        for piece in pieces.dropFirst() {
            let frames = Int(piece.frameCount)
            for frame in 0..<frames { samples.append(piece.samples[frame * 2 + channel]) }
        }
        return samples
    }

    /// The frequency of a tone on a channel, by counting its zero crossings
    func frequency(channel: Int, sampleRate: Double) -> Double {
        let samples = self.channel(channel)
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        for index in 1..<samples.count where (samples[index - 1] < 0) != (samples[index] < 0) {
            crossings += 1
        }
        return Double(crossings) / 2 / (Double(samples.count) / sampleRate)
    }
}

// Other NDI sources may be on this Mac or its network (Adrien's applications): the tests connect to their own senders
// only, which they always stop.
final class NDISourceTests: XCTestCase {
    private let library = NDILibrary.shared()
    private var device: MTLDevice!

    private let blue: [UInt8] = [255, 0, 0, 255]
    private let orange: [UInt8] = [0, 165, 255, 255]

    override func setUpWithError() throws {
        try XCTSkipUnless(library.isAvailable, library.reason)
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    }

    // MARK: Helpers

    /// A sender of this test, stopped at the end of the test, and the suffix of its NDI name ("HOST (name)")
    private func makeSender() throws -> (sender: NDITestSender, suffix: String) {
        let name = "Test \(UUID().uuidString)"
        let sender = try XCTUnwrap(NDITestSender(library: library, name: name))
        addTeardownBlock { sender.stop() }
        return (sender, "(\(name))")
    }

    private func send(_ sender: NDITestSender, _ width: Int, _ height: Int, colour: [UInt8]? = nil, marked: Bool = true,
                      hasAlpha: Bool = true) {
        var bgra = colour ?? blue
        sender.send(width: Int32(width), height: Int32(height), colour: &bgra, marked: marked, hasAlpha: hasAlpha,
                    padding: 0, framesPerSecond: 30)
    }

    /// A source connected to the sender without a finder, stopped at the end of the test
    private func connect(_ sender: NDITestSender) throws -> NDISource {
        let source = try XCTUnwrap(NDISource(title: sender.sourceName, name: sender.sourceName, url: sender.sourceURL,
                                             library: library, device: device))
        addTeardownBlock { source.stop() }
        return source
    }

    /// Runs the main run loop until the condition holds or the time has passed
    private func wait(_ what: String, seconds: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
                      until condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        XCTAssertTrue(condition(), "\(what) within \(seconds) s", file: file, line: line)
    }

    /// NDI compresses its pictures (SpeedHQ, in YUV): a colour comes back nearly as it was sent
    private func assertColour(_ pixel: [UInt8]?, _ expected: [UInt8], tolerance: Int = 24, _ message: String = "",
                              file: StaticString = #filePath, line: UInt = #line) {
        guard let pixel else { return XCTFail("no pixel \(message)", file: file, line: line) }
        let close = zip(pixel, expected).prefix(3).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
        XCTAssertTrue(close, "\(message) got \(pixel), expected \(expected)", file: file, line: line)
    }

    // MARK: Frames

    func testFramesArriveAtTheSendersSize() throws {
        let (sender, _) = try makeSender()
        send(sender, 96, 54)
        let source = try connect(sender)
        let log = FrameLog()
        source.frameHandler = log.handler

        wait("frames") { log.count >= 3 }
        XCTAssertEqual(log.sizes, [CGSize(width: 96, height: 54)])
        XCTAssertEqual(source.title, sender.sourceName)
    }

    func testThePictureIsUpright() throws {
        let (sender, _) = try makeSender()
        send(sender, 64, 32, marked: true)
        let source = try connect(sender)
        XCTAssertFalse(source.flipped)
        let log = FrameLog()
        source.frameHandler = log.handler

        wait("a frame") { log.pixels(64, 32) != nil }
        let read = try XCTUnwrap(log.pixels(64, 32))
        assertColour(read(0, 0), orange, "the top left quarter")
        assertColour(read(31, 15), orange, "the top left quarter")
        assertColour(read(63, 0), blue, "the top right quarter")
        assertColour(read(0, 31), blue, "the bottom left quarter")
    }

    func testAPictureSentWithoutAlphaIsOpaque() throws {
        let (sender, _) = try makeSender()
        // BGRX: the fourth byte is not alpha, and is 0 here
        send(sender, 32, 16, colour: [255, 0, 0, 0], marked: false, hasAlpha: false)
        let source = try connect(sender)
        let log = FrameLog()
        source.frameHandler = log.handler

        wait("a frame") { log.pixels(32, 16) != nil }
        let read = try XCTUnwrap(log.pixels(32, 16))
        for (x, y) in [(0, 0), (31, 0), (0, 15), (31, 15), (16, 8)] {
            assertColour(read(x, y), blue, "pixel \(x), \(y)")
            XCTAssertEqual(read(x, y)[3], 255, "the alpha of pixel \(x), \(y)")
        }
    }

    func testASenderWhichChangesSizeIsFollowed() throws {
        let (sender, _) = try makeSender()
        send(sender, 32, 16)
        let source = try connect(sender)
        let log = FrameLog()
        source.frameHandler = log.handler
        wait("the first size") { log.sizes.contains(CGSize(width: 32, height: 16)) }

        send(sender, 48, 64)
        wait("the second size") { log.sizes.last == CGSize(width: 48, height: 64) }
        let read = try XCTUnwrap(log.pixels(48, 64))
        assertColour(read(0, 0), orange)
        assertColour(read(47, 63), blue)
    }

    // MARK: Life

    func testASourceWhoseSenderHasGoneIsNotAlive() throws {
        let (sender, _) = try makeSender()
        send(sender, 32, 16)
        let made = Date()
        let source = try connect(sender)
        let log = FrameLog()
        source.frameHandler = log.handler
        wait("frames") { log.count >= 3 }
        XCTAssertTrue(source.isAlive)
        // Past the moment a source just made is given to connect: alive because it is connected
        RunLoop.main.run(until: made.addingTimeInterval(3.5))
        XCTAssertTrue(source.isAlive, "connected")

        sender.stop()
        wait("not alive", seconds: 10) { !source.isAlive }
    }

    func testNoFrameIsDeliveredAfterStop() throws {
        let (sender, _) = try makeSender()
        send(sender, 32, 16)
        let log = FrameLog()
        weak var released: NDISource?
        try autoreleasepool {
            let source = try XCTUnwrap(NDISource(title: sender.sourceName, name: sender.sourceName, url: sender.sourceURL,
                                                 library: library, device: device))
            released = source
            // The handler does not hold the source
            source.frameHandler = log.handler
            wait("frames") { log.count >= 3 }

            source.stop()
            let count = log.count
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
            XCTAssertEqual(log.count, count, "a frame after stop")
            XCTAssertFalse(source.isAlive)
            source.stop()   // twice is harmless
        }
        // Its thread does not keep it alive
        XCTAssertNil(released)
    }

    func testAReleasedSourceStops() throws {
        let (sender, _) = try makeSender()
        send(sender, 32, 16)
        let log = FrameLog()
        weak var released: NDISource?
        try autoreleasepool {
            let source = try XCTUnwrap(NDISource(title: sender.sourceName, name: sender.sourceName, url: sender.sourceURL,
                                                 library: library, device: device))
            released = source
            source.frameHandler = log.handler
            wait("frames") { log.count >= 3 }
        }
        XCTAssertNil(released)
        // Released, it stopped: its thread delivers nothing more
        let count = log.count
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        XCTAssertEqual(log.count, count, "a frame after the source was released")
    }

    // A handler which holds its source can make its thread let go of the source last: the source then stops on its own
    // thread, which must not wait for itself
    func testASourceReleasedByItsOwnHandlerStops() throws {
        let (sender, _) = try makeSender()
        send(sender, 32, 16)
        let log = FrameLog()
        let record = log.handler
        weak var released: NDISource?
        try autoreleasepool {
            let source = try XCTUnwrap(NDISource(title: sender.sourceName, name: sender.sourceName, url: sender.sourceURL,
                                                 library: library, device: device))
            released = source
            source.frameHandler = { texture in
                record(texture)
                // Lets go of the source from its own thread
                if log.count >= 3 { source.frameHandler = nil }
            }
        }
        wait("released") { released == nil }
        let count = log.count
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        XCTAssertEqual(log.count, count, "a frame after the source was released")
    }

    // MARK: Sound

    /// A source connected to a sender of a picture and a tone, once a second of sound has arrived
    private func receiveTone(_ frequency: Double, channels: Int32, rate: Int32) throws -> SoundLog {
        let (sender, _) = try makeSender()
        send(sender, 32, 16)
        sender.sendTone(frequency: frequency, channelCount: channels, sampleRate: rate)
        let source = try connect(sender)
        let log = SoundLog()
        source.soundHandler = log.handler
        wait("a second of sound") { log.frameCount >= Int(rate) + 4800 }
        // No more pieces: the log is read as it is now
        source.soundHandler = nil
        return log
    }

    func testATonesPitchArrives() throws {
        let log = try receiveTone(1000, channels: 2, rate: 48000)
        XCTAssertEqual(log.sampleRates, [48000])
        XCTAssertEqual(log.frequency(channel: 0, sampleRate: 48000), 1000, accuracy: 10)
        // The second channel at twice the frequency: the sender's
        XCTAssertEqual(log.frequency(channel: 1, sampleRate: 48000), 2000, accuracy: 20)
    }

    func testOneChannelArrivesAsTwo() throws {
        let log = try receiveTone(1000, channels: 1, rate: 48000)
        XCTAssertEqual(log.channel(0), log.channel(1))
        XCTAssertEqual(log.frequency(channel: 0, sampleRate: 48000), 1000, accuracy: 10)
    }

    func testFourChannelsArriveAsTheFirstTwo() throws {
        // Sent at 500, 1000, 1500 and 2000 Hz
        let log = try receiveTone(500, channels: 4, rate: 48000)
        XCTAssertEqual(log.frequency(channel: 0, sampleRate: 48000), 500, accuracy: 5)
        XCTAssertEqual(log.frequency(channel: 1, sampleRate: 48000), 1000, accuracy: 10)
    }

    func testA44100HertzSenderIsGivenAsItIs() throws {
        let log = try receiveTone(1000, channels: 2, rate: 44100)
        XCTAssertEqual(log.sampleRates, [44100])
        XCTAssertEqual(log.frequency(channel: 0, sampleRate: 44100), 1000, accuracy: 10)
    }

    func testHasSoundFollowsTheSender() throws {
        let (sender, _) = try makeSender()
        send(sender, 32, 16)
        let source = try connect(sender)
        let frames = FrameLog()
        source.frameHandler = frames.handler
        wait("frames") { frames.count >= 3 }
        XCTAssertFalse(source.hasSound, "a sender of pictures only")

        sender.sendTone(frequency: 1000, channelCount: 2, sampleRate: 48000)
        wait("sound", seconds: 5) { source.hasSound }

        sender.stopSound()
        wait("no sound", seconds: 5) { !source.hasSound }
        XCTAssertGreaterThan(frames.count, 3, "pictures go on")
    }

    func testNoSoundIsDeliveredAfterStop() throws {
        let (sender, _) = try makeSender()
        send(sender, 32, 16)
        sender.sendTone(frequency: 1000, channelCount: 2, sampleRate: 48000)
        let log = SoundLog()
        weak var released: NDISource?
        try autoreleasepool {
            let source = try XCTUnwrap(NDISource(title: sender.sourceName, name: sender.sourceName, url: sender.sourceURL,
                                                 library: library, device: device))
            released = source
            source.soundHandler = log.handler
            wait("sound") { log.count >= 3 }

            source.stop()
            let count = log.count
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
            XCTAssertEqual(log.count, count, "sound after stop")
            XCTAssertNil(source.soundHandler)
        }
        XCTAssertNil(released)
    }

    func testASenderOfPicturesOnlyIsReceivedAsBefore() throws {
        let (sender, _) = try makeSender()
        send(sender, 96, 54)
        let source = try connect(sender)
        let frames = FrameLog()
        let sound = SoundLog()
        source.frameHandler = frames.handler
        source.soundHandler = sound.handler
        wait("frames") { frames.count >= 3 }
        let count = frames.count
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        // 30 pictures a second
        XCTAssertGreaterThanOrEqual(frames.count - count, 20)
        XCTAssertEqual(frames.sizes, [CGSize(width: 96, height: 54)])
        XCTAssertEqual(sound.count, 0)
        XCTAssertFalse(source.hasSound)
    }

    // A measurement as much as a test: a click and a white picture sent together, received by a source whose two
    // handlers feed a movie with their arrival times, are found in the movie this far apart.
    func testSoundAndPictureAreInStep() throws {
        let (sender, _) = try makeSender()
        var blue = self.blue
        // 60 pictures a second: a click waits less for its picture
        sender.send(width: 64, height: 36, colour: &blue, marked: true, hasAlpha: true, padding: 0, framesPerSecond: 60)
        sender.sendSilenceWithClicks(channelCount: 2, sampleRate: 48000)
        let source = try connect(sender)
        let frames = FrameLog()
        source.frameHandler = frames.handler
        wait("frames") { frames.count >= 3 }
        wait("sound") { source.hasSound }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NDISourceTests-\(UUID().uuidString).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let recorder = MovieRecorder(device: device)
        let settings = MovieRecorderSettings()
        settings.codec = .proRes422
        settings.recordsSound = true
        try recorder.startWriting(to: url, settings: settings, startTime: CACurrentMediaTime())
        source.frameHandler = { texture in recorder.append(texture, flipped: false, atTime: CACurrentMediaTime()) }
        source.soundHandler = { sound in recorder.append(sound, atTime: CACurrentMediaTime()) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        for _ in 0..<5 {
            sender.click()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        }
        source.frameHandler = nil
        source.soundHandler = nil
        var finished = false
        var failure: Error?
        recorder.finish(atTime: CACurrentMediaTime()) { error in
            failure = error
            finished = true
        }
        wait("finished", seconds: 20) { finished }
        XCTAssertNil(failure)

        let clicks = try SoundInfo(url).clicks()
        let whites = try whitePictures(url)
        XCTAssertEqual(clicks.count, 5, "clicks \(clicks)")
        XCTAssertEqual(whites.count, 5, "white pictures \(whites)")
        // Each click with the white picture nearest to it: which comes first is what is measured
        let steps = clicks.compactMap { click in whites.min { abs($0 - click) < abs($1 - click) }.map { $0 - click } }
        let text = steps.map { String(format: "%+.1f", $0 * 1000) }.joined(separator: ", ")
        if !steps.isEmpty {
            let mean = steps.reduce(0, +) / Double(steps.count)
            print(String(format: "Sound and picture: picture − click, ms: %@; min %+.1f, max %+.1f, mean %+.1f", text,
                         steps.min()! * 1000, steps.max()! * 1000, mean * 1000))
        }
        for step in steps {
            XCTAssertLessThanOrEqual(abs(step), 0.05, "picture − click, ms: \(text)")
        }
    }

    /// The times at which a movie's picture becomes white all over (the marked quarter included)
    private func whitePictures(_ url: URL) throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try MovieInfo.videoTrack(asset),
                                              outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        var times = [Double]()
        var wasWhite = false
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(image, .readOnly)
            let rowBytes = CVPixelBufferGetBytesPerRow(image)
            let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
            // In the marked quarter, in the blue, and in the middle
            let white = [(8, 4), (48, 27), (32, 18)].allSatisfy { x, y in
                (0..<3).allSatisfy { bytes[y * rowBytes + x * 4 + $0] > 200 }
            }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            if white && !wasWhite { times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
            wasWhite = white
        }
        return times
    }

    // MARK: Directory

    func testTheDirectoryConnects() throws {
        let (sender, suffix) = try makeSender()
        send(sender, 32, 16)
        let directory = NDIDirectory(library: library)
        wait("listed") { directory.availableSources().contains { $0.title.hasSuffix(suffix) } }
        let title = try XCTUnwrap(directory.availableSources().first { $0.title.hasSuffix(suffix) }?.title)

        let source = try XCTUnwrap(directory.connectToSource(withTitle: title, device: device))
        addTeardownBlock { source.stop() }
        XCTAssertEqual(source.title, title)
        XCTAssertFalse(source.flipped)
        let log = FrameLog()
        source.frameHandler = log.handler
        wait("frames") { log.count >= 3 }
        XCTAssertEqual(log.sizes, [CGSize(width: 32, height: 16)])

        XCTAssertNil(directory.connectToSource(withTitle: "NOBODY (Test \(UUID().uuidString))", device: device))
    }

    func testAnNDISourceIsRecorded() throws {
        let (sender, suffix) = try makeSender()
        send(sender, 128, 64, marked: true)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NDISourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaultsName = "NDISourceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let directory = NDIDirectory(library: library)
        let controller = RecorderController(device: device, directory: directory, defaults: defaults)
        controller.folder = folder.path
        addTeardownBlock {
            // The place is emptied first: its source stops before the sender
            controller.removeSource(atPlace: 1)
            controller.stopNetwork()
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: folder)
        }

        wait("listed") { controller.availableSources.contains { $0.title.hasSuffix(suffix) } }
        let title = try XCTUnwrap(controller.availableSources.first { $0.title.hasSuffix(suffix) }?.title)
        XCTAssertTrue(controller.addSource(matching: title))
        wait("frames") { controller.places.first?.latestFrame != nil }

        controller.name = "ndi"
        XCTAssertTrue(controller.start())
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        controller.stop(completionHandler: nil)
        wait("finished", seconds: 20) { controller.state == "idle" }
        XCTAssertEqual(controller.error, "")

        let movie = URL(fileURLWithPath: controller.file)
        XCTAssertEqual(try MovieInfo(movie).size, CGSize(width: 128, height: 64))
        XCTAssertGreaterThan(try MovieInfo(movie).duration, 0.5)
        let read = try firstPicture(movie)
        assertColour(read(8, 8), orange, tolerance: 40, "the top left quarter")
        assertColour(read(120, 8), blue, tolerance: 40, "the top right quarter")
        assertColour(read(8, 56), blue, tolerance: 40, "the bottom left quarter")
    }

    /// A movie's first picture, as blue, green, red, alpha at x, y. The movie starts with the take, its pictures with
    /// their first frame: until then the reader gives a black picture dated 0, which is skipped.
    private func firstPicture(_ url: URL) throws -> (Int, Int) -> [UInt8] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try MovieInfo.videoTrack(asset),
                                              outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        let start = try MovieInfo(url).start
        var buffer: CVPixelBuffer?
        while buffer == nil, let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetPresentationTimeStamp(sample).seconds >= start - 0.001 else { continue }
            buffer = CMSampleBufferGetImageBuffer(sample)
        }
        let image = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let rowBytes = CVPixelBufferGetBytesPerRow(image)
        let data = Data(bytes: CVPixelBufferGetBaseAddress(image)!, count: rowBytes * CVPixelBufferGetHeight(image))
        return { x, y in (0..<4).map { data[y * rowBytes + x * 4 + $0] } }
    }
}
