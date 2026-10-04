import XCTest
import RecorderKit

final class SourceSoundTests: XCTestCase {
    private func samples(of sound: SourceSound) -> [Float] {
        Array(UnsafeBufferPointer(start: sound.samples, count: Int(sound.frameCount) * 2))
    }

    func testTwoPlanesAreInterleaved() throws {
        let planes: [Float] = [1, 2, 3, 10, 20, 30]
        let sound = try XCTUnwrap(SourceSound(planarSamples: planes, channelCount: 2, frameCount: 3,
                                              channelStrideInBytes: 3 * 4, sampleRate: 48000))
        XCTAssertEqual(sound.frameCount, 3)
        XCTAssertEqual(sound.sampleRate, 48000)
        XCTAssertEqual(sound.duration, 3.0 / 48000, accuracy: 1e-12)
        XCTAssertEqual(samples(of: sound), [1, 10, 2, 20, 3, 30])
    }

    func testOneChannelBecomesTwo() throws {
        let plane: [Float] = [0.5, -0.5, 0.25]
        let sound = try XCTUnwrap(SourceSound(planarSamples: plane, channelCount: 1, frameCount: 3,
                                              channelStrideInBytes: 3 * 4, sampleRate: 44100))
        XCTAssertEqual(samples(of: sound), [0.5, 0.5, -0.5, -0.5, 0.25, 0.25])
    }

    func testTheFirstTwoOfSeveralChannelsAreKept() throws {
        // Four planes of two frames, each followed by two floats which belong to no channel
        let planes: [Float] = [1, 2, -9, -9,
                               3, 4, -9, -9,
                               5, 6, -9, -9,
                               7, 8, -9, -9]
        let sound = try XCTUnwrap(SourceSound(planarSamples: planes, channelCount: 4, frameCount: 2,
                                              channelStrideInBytes: 4 * 4, sampleRate: 48000))
        XCTAssertEqual(samples(of: sound), [1, 3, 2, 4])
    }

    func testTheSamplesAreCopied() throws {
        var planes: [Float] = [1, 2]
        let sound = try XCTUnwrap(SourceSound(planarSamples: planes, channelCount: 1, frameCount: 2,
                                              channelStrideInBytes: 2 * 4, sampleRate: 48000))
        planes[0] = 99
        XCTAssertEqual(samples(of: sound), [1, 1, 2, 2])
    }

    func testNothingGivesNothing() {
        let planes = [Float](repeating: 0.5, count: 8)
        XCTAssertNil(SourceSound(planarSamples: planes, channelCount: 2, frameCount: 0, channelStrideInBytes: 16, sampleRate: 48000))
        XCTAssertNil(SourceSound(planarSamples: planes, channelCount: 0, frameCount: 4, channelStrideInBytes: 16, sampleRate: 48000))
        XCTAssertNil(SourceSound(planarSamples: nil, channelCount: 2, frameCount: 4, channelStrideInBytes: 16, sampleRate: 48000))
        XCTAssertNil(SourceSound(planarSamples: planes, channelCount: 2, frameCount: 4, channelStrideInBytes: 16, sampleRate: 0))
        XCTAssertNil(SourceSound(planarSamples: planes, channelCount: 2, frameCount: 4, channelStrideInBytes: 16, sampleRate: -48000))
        XCTAssertNil(SourceSound(planarSamples: planes, channelCount: 2, frameCount: 4, channelStrideInBytes: 16, sampleRate: .nan))
        XCTAssertNil(SourceSound(planarSamples: planes, channelCount: 2, frameCount: 4, channelStrideInBytes: 16, sampleRate: .infinity))
        // A stride shorter than a plane would read one channel in the other, or past the end
        XCTAssertNil(SourceSound(planarSamples: planes, channelCount: 2, frameCount: 4, channelStrideInBytes: 12, sampleRate: 48000))
        XCTAssertNil(SourceSound(planarSamples: planes, channelCount: 2, frameCount: 4, channelStrideInBytes: 0, sampleRate: 48000))

        XCTAssertNil(SourceSound(interleavedStereoSamples: planes, frameCount: 0, sampleRate: 48000))
        XCTAssertNil(SourceSound(interleavedStereoSamples: nil, frameCount: 4, sampleRate: 48000))
        XCTAssertNil(SourceSound(interleavedStereoSamples: planes, frameCount: 4, sampleRate: 0))
        XCTAssertNil(SourceSound(interleavedStereoSamples: planes, frameCount: 4, sampleRate: .nan))
    }

    func testTheStrideIsReadOnlyForSeveralChannels() throws {
        let planes = [Float](repeating: 0.5, count: 8)
        // One channel: the stride is not used, 0 is fine
        let mono = try XCTUnwrap(SourceSound(planarSamples: planes, channelCount: 1, frameCount: 4,
                                             channelStrideInBytes: 0, sampleRate: 48000))
        XCTAssertEqual(mono.frameCount, 4)
        // Two: a stride which is not a whole number of floats is refused
        XCTAssertNil(SourceSound(planarSamples: planes, channelCount: 2, frameCount: 3,
                                 channelStrideInBytes: 3 * 4 + 1, sampleRate: 48000))
    }

    func testInterleavedSamplesAreKeptAsTheyAre() throws {
        let interleaved: [Float] = [1, 2, 3, 4, 5, 6]
        let sound = try XCTUnwrap(SourceSound(interleavedStereoSamples: interleaved, frameCount: 3, sampleRate: 48000))
        XCTAssertEqual(samples(of: sound), interleaved)
    }

    func testSilenceIsZeros() {
        let silence = SourceSound.silence(ofFrameCount: 1000, sampleRate: 48000)
        XCTAssertEqual(silence.frameCount, 1000)
        XCTAssertEqual(silence.sampleRate, 48000)
        XCTAssertEqual(silence.duration, 1000.0 / 48000, accuracy: 1e-12)
        XCTAssertEqual(samples(of: silence), [Float](repeating: 0, count: 2000))
    }

    func testAPieceCanBeCutFromAFrameOn() throws {
        let interleaved: [Float] = [1, 2, 3, 4, 5, 6, 7, 8]
        let sound = try XCTUnwrap(SourceSound(interleavedStereoSamples: interleaved, frameCount: 4, sampleRate: 48000))
        let tail = try XCTUnwrap(sound.fromFrame(1))
        XCTAssertEqual(tail.frameCount, 3)
        XCTAssertEqual(tail.sampleRate, 48000)
        XCTAssertEqual(samples(of: tail), [3, 4, 5, 6, 7, 8])
        XCTAssertEqual(samples(of: try XCTUnwrap(sound.fromFrame(3))), [7, 8])
        XCTAssertEqual(samples(of: try XCTUnwrap(sound.fromFrame(0))), interleaved)
        XCTAssertNil(sound.fromFrame(4))
        XCTAssertNil(sound.fromFrame(100))
    }
}
