// movie-info <file>...: prints the size, duration, frame count, frame rate and codec of each movie's video track,
// and whether the file is fragmented, to check recordings from a script.
// movie-info --png <picture.png> <file>: also saves the frame in the middle of the movie.
import AVFoundation
import AppKit

func fourCharacters(_ code: FourCharCode) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "????"
}

var failed = false
var arguments = Array(CommandLine.arguments.dropFirst())
var picture: URL?
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
            let fragmented = (try? Data(contentsOf: url, options: .mappedIfSafe))?.range(of: Data("moof".utf8)) != nil
            print(String(format: "%@: %d x %d, %.2f s, %d frames, %.2f fps, %@, %.2f Mbit/s%@",
                         url.lastPathComponent, Int(size.width), Int(size.height), duration, frames, rate, codec, bitrate,
                         fragmented ? ", fragmented" : ""))
        } catch {
            print("\(url.lastPathComponent): \(error.localizedDescription)")
            failed = true
        }
    }
    done.wait()
}
exit(failed ? 1 : 0)
