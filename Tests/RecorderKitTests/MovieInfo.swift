import AVFoundation

/// What the tests check of a movie which was written.
struct MovieInfo {
    var size: CGSize
    var duration: Double
    var frameRate: Float
    /// When the picture starts in the movie: after 0 if the movie began before its first frame arrived
    var start: Double
    /// Four characters, such as "avc1"
    var codec: String

    /// Reads a movie's video track, waiting for AVFoundation's asynchronous loading.
    init(_ url: URL) throws {
        let loaded = DispatchSemaphore(value: 0)
        var result: Result<MovieInfo, Error> = .failure(CocoaError(.fileReadUnknown))
        Task.detached {
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let code = try await track.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
                result = .success(MovieInfo(size: try await track.load(.naturalSize),
                                            duration: try await asset.load(.duration).seconds,
                                            frameRate: try await track.load(.nominalFrameRate),
                                            start: try await MovieInfo.pictureStart(track),
                                            codec: String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? ""))
            } catch {
                result = .failure(error)
            }
            loaded.signal()
        }
        loaded.wait()
        self = try result.get()
    }

    private init(size: CGSize, duration: Double, frameRate: Float, start: Double, codec: String) {
        self.size = size
        self.duration = duration
        self.frameRate = frameRate
        self.start = start
        self.codec = codec
    }

    /// The time before the track's first picture: the track's own start, plus any empty stretch it begins with.
    private static func pictureStart(_ track: AVAssetTrack) async throws -> Double {
        var start = try await track.load(.timeRange).start.seconds
        for segment in try await track.load(.segments) {
            guard segment.isEmpty else { break }
            start += segment.timeMapping.target.duration.seconds
        }
        return start
    }

    /// The asset's video track, for an asset reader.
    static func videoTrack(_ asset: AVAsset) throws -> AVAssetTrack {
        let loaded = DispatchSemaphore(value: 0)
        var track: AVAssetTrack?
        Task.detached {
            track = try? await asset.loadTracks(withMediaType: .video).first
            loaded.signal()
        }
        loaded.wait()
        guard let track else { throw CocoaError(.fileReadCorruptFile) }
        return track
    }
}
