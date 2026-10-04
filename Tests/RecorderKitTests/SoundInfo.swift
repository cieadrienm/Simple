import AVFoundation

/// What the tests check of a movie's sound track: its format, and its samples decoded as floats.
///
/// Times are on the movie's clock. An AAC track begins with an edit which hides the encoder's priming (2112 samples);
/// `AVAssetReader` honours it, and times are taken from the decoded buffers' own times, so they are right for AAC as
/// for linear PCM, and for a track which begins after the movie's 0.
struct SoundInfo {
    /// Four characters, such as "aac " or "lpcm"
    var codec: String
    var sampleRate: Double
    var channelCount: Int
    /// For linear PCM: 24, 16…; 0 for a compressed track
    var bitsPerChannel: Int
    /// The track's length on the movie's clock
    var duration: Double
    /// Interleaved, `channelCount` floats a frame
    var samples: [Float]
    /// The movie's time of the first decoded sample
    var start: Double

    var frameCount: Int { samples.count / max(channelCount, 1) }

    /// The first channel's sample at a frame
    func sample(_ frame: Int) -> Float { samples[frame * channelCount] }

    /// The movie's time of a frame
    func time(ofFrame frame: Int) -> Double { start + Double(frame) / sampleRate }

    /// The frame at a time of the movie, within the samples
    func frame(at time: Double) -> Int { min(max(Int(((time - start) * sampleRate).rounded()), 0), frameCount) }

    /// When the sound which is not silence begins, from a time on: the first sample louder than the threshold. nil if
    /// there is none.
    func soundStart(after: Double = 0, threshold: Float = 0.01) -> Double? {
        (frame(at: after)..<frameCount).first { abs(sample($0)) > threshold }.map { time(ofFrame: $0) }
    }

    /// The frequency of a tone between two times, by counting its zero crossings.
    func frequency(from: Double, to: Double) -> Double {
        let first = frame(at: from), last = frame(at: to)
        guard last > first + 1 else { return 0 }
        var crossings = 0
        for frame in (first + 1)..<last where (sample(frame - 1) < 0) != (sample(frame) < 0) {
            crossings += 1
        }
        return Double(crossings) / 2 / (Double(last - first) / sampleRate)
    }

    /// The times of isolated pulses: a sample louder than the threshold after at least `quiet` seconds of samples
    /// which are not.
    func clicks(threshold: Float = 0.3, quiet: Double = 0.05) -> [Double] {
        let quietFrames = Int(quiet * sampleRate)
        var times = [Double]()
        var lastLoud = -quietFrames - 1
        for frame in 0..<frameCount where abs(sample(frame)) > threshold {
            if frame - lastLoud > quietFrames {
                times.append(time(ofFrame: frame))
            }
            lastLoud = frame
        }
        return times
    }

    /// The largest sample between two times
    func peak(from: Double, to: Double) -> Float {
        let first = frame(at: from), last = frame(at: to)
        return last > first ? (first..<last).map { abs(sample($0)) }.max() ?? 0 : 0
    }

    /// Whether the movie has a sound track at all.
    static func hasSound(_ url: URL) throws -> Bool {
        try load { try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first != nil }
    }

    /// Reads a movie's sound track. Throws if it has none.
    init(_ url: URL) throws {
        self = try SoundInfo.load {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard let format = try await track.load(.formatDescriptions).first,
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let code = CMFormatDescriptionGetMediaSubType(format)
            let codec = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? ""
            let duration = try await track.load(.timeRange).duration.seconds

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false
            ])
            reader.add(output)
            reader.startReading()
            var samples = [Float]()
            var start = Double.nan
            while let buffer = output.copyNextSampleBuffer() {
                if start.isNaN && CMSampleBufferGetNumSamples(buffer) > 0 {
                    start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                }
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                samples += chunk
            }
            guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
            return SoundInfo(codec: codec, sampleRate: description.mSampleRate, channelCount: Int(description.mChannelsPerFrame),
                             bitsPerChannel: Int(description.mBitsPerChannel), duration: duration, samples: samples,
                             start: start.isNaN ? 0 : start)
        }
    }

    private init(codec: String, sampleRate: Double, channelCount: Int, bitsPerChannel: Int, duration: Double,
                 samples: [Float], start: Double) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerChannel = bitsPerChannel
        self.duration = duration
        self.samples = samples
        self.start = start
    }

    /// Runs AVFoundation's asynchronous loading to its end.
    private static func load<T>(_ work: @escaping () async throws -> T) throws -> T {
        let loaded = DispatchSemaphore(value: 0)
        var result: Result<T, Error> = .failure(CocoaError(.fileReadUnknown))
        Task.detached {
            do { result = .success(try await work()) } catch { result = .failure(error) }
            loaded.signal()
        }
        loaded.wait()
        return try result.get()
    }
}
