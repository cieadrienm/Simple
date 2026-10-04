// movie-info <file>...: prints the size, duration, frame count, frame rate and codec of each movie's video track,
// when its picture starts if that is not at once, and whether the file is fragmented, to check recordings from a script.
// When a movie has a sound track a second line gives its codec, sample rate, channels, duration and where sound which is
// not silence begins; a movie without one gets no more than the first line.
// movie-info --png <picture.png> <file>: also saves the frame in the middle of the movie.
// movie-info --sync <file> [--region x y w h]: for a movie made from `ndi-send --tone`, the time of each flash (the first
// picture whose mean luminance is high, after one which was not) and of each click (the first sample above 0.9 after
// 100 ms below 0.5), their difference (picture minus click) in milliseconds, and its minimum, maximum and mean. The region
// (fractions of the picture, 0 to 1) restricts the flashes to one source's place in an assembled picture.
import AVFoundation
import AppKit

func fourCharacters(_ code: FourCharCode) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "????"
}

/// The sound of a movie as 32-bit floats, interleaved: each buffer's first sample time, its samples, and the format.
struct SoundBuffer { var start: Double; var samples: [Float] }
func readSound(_ asset: AVAsset, _ track: AVAssetTrack) throws -> (buffers: [SoundBuffer], rate: Double, channels: Int) {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
    reader.add(output)
    reader.startReading()
    var buffers: [SoundBuffer] = []
    var rate = 0.0, channels = 0
    while let sample = output.copyNextSampleBuffer() {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { continue }
        rate = description.mSampleRate
        channels = Int(description.mChannelsPerFrame)
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard let block = CMSampleBufferGetDataBuffer(sample),
              CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { continue }
        let floats = Array(UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self), count: length / 4))
        buffers.append(SoundBuffer(start: CMSampleBufferGetPresentationTimeStamp(sample).seconds, samples: floats))
    }
    if reader.status == .failed, let error = reader.error { throw error }
    return (buffers, rate, channels)
}

/// Times of the clicks in channel 0: the first sample above 0.9 after 100 ms below 0.5.
func clickTimes(_ buffers: [SoundBuffer], rate: Double, channels: Int) -> [Double] {
    var times: [Double] = []
    var quiet = 0
    var armed = false // 100 ms below 0.5 have come before the sound which is now above it
    let needed = Int(rate * 0.1)
    for buffer in buffers where channels > 0 {
        for index in 0..<(buffer.samples.count / channels) {
            let value = abs(buffer.samples[index * channels])
            if value < 0.5 {
                quiet += 1
                armed = false
            } else {
                if quiet >= needed { armed = true }
                quiet = 0
                if armed, value > 0.9 {
                    times.append(buffer.start + Double(index) / rate)
                    armed = false
                }
            }
        }
    }
    return times
}

/// Times of the flashes: the first picture whose mean luminance (0 to 255) over `region` is above 200, after one which was not.
func flashTimes(_ asset: AVAsset, _ track: AVAssetTrack, region: [Double]) throws -> [Double] {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    reader.startReading()
    var times: [Double] = []
    var wasBright = false
    while let sample = output.copyNextSampleBuffer() {
        guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { continue }
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image), stride = CVPixelBufferGetBytesPerRow(image)
        let x0 = Int(region[0] * Double(width)), y0 = Int(region[1] * Double(height))
        let x1 = min(width, max(x0 + 1, Int((region[0] + region[2]) * Double(width)))), y1 = min(height, max(y0 + 1, Int((region[1] + region[3]) * Double(height))))
        var sum = 0.0, count = 0.0
        for y in Swift.stride(from: y0, to: y1, by: 2) {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in Swift.stride(from: x0, to: x1, by: 2) {
                sum += 0.114 * Double(row[x * 4]) + 0.587 * Double(row[x * 4 + 1]) + 0.299 * Double(row[x * 4 + 2])
                count += 1
            }
        }
        let bright = count > 0 && sum / count > 200
        if bright && !wasBright { times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
        wasBright = bright
    }
    return times
}

/// --sync: pairs each flash with the nearest click and prints how far the picture is from the sound.
func sync(_ url: URL, region: [Double]) async throws -> Bool {
    let asset = AVURLAsset(url: url)
    guard let video = try await asset.loadTracks(withMediaType: .video).first else { print("\(url.lastPathComponent): no video track"); return false }
    guard let audio = try await asset.loadTracks(withMediaType: .audio).first else { print("\(url.lastPathComponent): no sound track"); return false }
    let flashes = try flashTimes(asset, video, region: region)
    let sound = try readSound(asset, audio)
    let clicks = clickTimes(sound.buffers, rate: sound.rate, channels: sound.channels)
    var differences: [Double] = []
    for (second, flash) in flashes.enumerated() {
        guard let click = clicks.min(by: { abs($0 - flash) < abs($1 - flash) }), abs(click - flash) < 0.5 else {
            print(String(format: "second %d: flash at %.3f s, no click", second + 1, flash))
            continue
        }
        differences.append((flash - click) * 1000)
        print(String(format: "second %d: flash at %.3f s, click at %.3f s, picture minus click %+.1f ms", second + 1, flash, click, (flash - click) * 1000))
    }
    guard let low = differences.min(), let high = differences.max() else {
        print("\(url.lastPathComponent): \(flashes.count) flashes, \(clicks.count) clicks, none paired")
        return false
    }
    print(String(format: "%@: %d flashes, %d clicks, picture minus click: min %+.1f ms, max %+.1f ms, mean %+.1f ms",
                 url.lastPathComponent, flashes.count, clicks.count, low, high, differences.reduce(0, +) / Double(differences.count)))
    return true
}

var failed = false
var arguments = Array(CommandLine.arguments.dropFirst())
var picture: URL?
if arguments.first == "--sync", arguments.count >= 2 {
    var region = [0.0, 0.0, 1.0, 1.0]
    if arguments.count == 7, arguments[2] == "--region" {
        region = arguments[3...].compactMap { Double($0) }
        guard region.count == 4, region[2] > 0, region[3] > 0, region.allSatisfy({ $0 >= 0 && $0 <= 1 }) else {
            print("--region takes x y w h, fractions of the picture from 0 to 1"); exit(2)
        }
    } else if arguments.count != 2 {
        print("usage: movie-info --sync <movie> [--region x y w h]"); exit(2)
    }
    let url = URL(fileURLWithPath: arguments[1])
    let done = DispatchSemaphore(value: 0)
    Task {
        defer { done.signal() }
        do { failed = !(try await sync(url, region: region)) } catch { print("\(url.lastPathComponent): \(error.localizedDescription)"); failed = true }
    }
    done.wait()
    exit(failed ? 1 : 0)
}
if arguments.first == "--png", arguments.count >= 2 {
    picture = URL(fileURLWithPath: arguments[1])
    arguments.removeFirst(2)
}
for path in arguments {
    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)
    let done = DispatchSemaphore(value: 0)
    Task {
        defer { done.signal() }
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                print("\(url.lastPathComponent): no video track")
                failed = true
                return
            }
            let size = try await track.load(.naturalSize)
            let duration = try await asset.load(.duration).seconds
            let rate = try await track.load(.nominalFrameRate)
            let codec = try await track.load(.formatDescriptions).first.map { fourCharacters(CMFormatDescriptionGetMediaSubType($0)) } ?? "????"
            let bitrate = try await track.load(.estimatedDataRate) / 1_000_000

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            reader.startReading()
            var frames = 0
            while let sample = output.copyNextSampleBuffer() {
                if CMSampleBufferGetNumSamples(sample) > 0 { frames += 1 }
            }
            if let picture {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let image = try await generator.image(at: CMTime(seconds: duration / 2, preferredTimescale: 600)).image
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: picture)
            }
            // A movie of a take which began before its source delivered a frame starts with an empty stretch
            var start = try await track.load(.timeRange).start.seconds
            for segment in try await track.load(.segments) {
                guard segment.isEmpty else { break }
                start += segment.timeMapping.target.duration.seconds
            }
            let fragmented = (try? Data(contentsOf: url, options: .mappedIfSafe))?.range(of: Data("moof".utf8)) != nil
            print(String(format: "%@: %d x %d, %.2f s, %d frames, %.2f fps, %@, %.2f Mbit/s%@%@",
                         url.lastPathComponent, Int(size.width), Int(size.height), duration, frames, rate, codec, bitrate,
                         start > 0.01 ? String(format: ", picture from %.2f s", start) : "", fragmented ? ", fragmented" : ""))
            if let audio = try await asset.loadTracks(withMediaType: .audio).first {
                let format = try await audio.load(.formatDescriptions).first
                let code = format.map { fourCharacters(CMFormatDescriptionGetMediaSubType($0)) } ?? "????"
                let seconds = try await audio.load(.timeRange).duration.seconds
                let sound = try readSound(asset, audio)
                var begins: Double?
                search: for buffer in sound.buffers {
                    for (index, value) in buffer.samples.enumerated() where abs(value) > 0.002 {
                        begins = buffer.start + Double(index / max(sound.channels, 1)) / sound.rate
                        break search
                    }
                }
                print(String(format: "  sound: %@, %.0f Hz, %d channels, %.2f s, %@", code, sound.rate, sound.channels, seconds,
                             begins.map { String(format: "begins at %.2f s", $0) } ?? "silent"))
            }
        } catch {
            print("\(url.lastPathComponent): \(error.localizedDescription)")
            failed = true
        }
    }
    done.wait()
}
exit(failed ? 1 : 0)
