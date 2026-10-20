import XCTest
import CoreAudio
import RecorderKit

final class ComputerSoundTests: XCTestCase {
    private func samples(of sound: SourceSound) -> [Float] {
        Array(UnsafeBufferPointer(start: sound.samples, count: Int(sound.frameCount) * 2))
    }

    private func convertInterleaved(_ floats: [Float], channels: UInt32, rate: Float64 = 44100,
                                    flags: AudioFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                    bits: UInt32 = 32, ignoreIfSilent: Bool = false) -> SourceSound? {
        var mutable = floats
        return mutable.withUnsafeMutableBufferPointer { pointer in
            let bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: channels,
                    mDataByteSize: UInt32(pointer.count * MemoryLayout<Float>.size),
                    mData: pointer.baseAddress
                )
            )
            let format = AudioStreamBasicDescription(
                mSampleRate: rate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: flags,
                mBytesPerPacket: channels * (bits / 8),
                mFramesPerPacket: 1,
                mBytesPerFrame: channels * (bits / 8),
                mChannelsPerFrame: channels,
                mBitsPerChannel: bits,
                mReserved: 0
            )
            return withUnsafePointer(to: bufferList) { listPointer in
                ComputerSound.sound(from: listPointer, format: format, ignoreIfSilent: ignoreIfSilent)
            }
        }
    }

    func testInterleavedStereoIsKept() throws {
        // CoreAudio's stereo global tap delivers packed 32-bit float stereo at the output's sample rate
        let sound = try XCTUnwrap(convertInterleaved([0.25, -0.25, 0.5, -0.5, 0.75, -0.75], channels: 2, rate: 44100))
        XCTAssertEqual(sound.frameCount, 3)
        XCTAssertEqual(sound.sampleRate, 44100)
        XCTAssertEqual(samples(of: sound), [0.25, -0.25, 0.5, -0.5, 0.75, -0.75])
    }

    func testInterleavedMonoIsDuplicatedToStereo() throws {
        let sound = try XCTUnwrap(convertInterleaved([0.2, -0.4, 0.6], channels: 1, rate: 48000))
        XCTAssertEqual(sound.frameCount, 3)
        XCTAssertEqual(sound.sampleRate, 48000)
        XCTAssertEqual(samples(of: sound), [0.2, 0.2, -0.4, -0.4, 0.6, 0.6])
    }

    func testInterleavedMultiChannelKeepsTheFirstTwoChannels() throws {
        let sound = try XCTUnwrap(convertInterleaved([1, 2, 9, 9, 3, 4, 9, 9], channels: 4, rate: 48000))
        XCTAssertEqual(sound.frameCount, 2)
        XCTAssertEqual(samples(of: sound), [1, 2, 3, 4])
    }

    func testNonInterleavedStereoIsInterleaved() throws {
        var left: [Float] = [1, 2, 3]
        var right: [Float] = [10, 20, 30]
        let sound = try XCTUnwrap(left.withUnsafeMutableBufferPointer { leftPointer in
            right.withUnsafeMutableBufferPointer { rightPointer -> SourceSound? in
                let listSize = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)! + 2 * MemoryLayout<AudioBuffer>.stride
                let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
                defer { raw.deallocate() }
                let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
                list.pointee.mNumberBuffers = 2
                let buffers = UnsafeMutableAudioBufferListPointer(list)
                buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 12, mData: leftPointer.baseAddress)
                buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 12, mData: rightPointer.baseAddress)
                let format = AudioStreamBasicDescription(
                    mSampleRate: 48000,
                    mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
                    mBytesPerPacket: 4,
                    mFramesPerPacket: 1,
                    mBytesPerFrame: 4,
                    mChannelsPerFrame: 2,
                    mBitsPerChannel: 32,
                    mReserved: 0
                )
                return ComputerSound.sound(from: list, format: format, ignoreIfSilent: false)
            }
        })
        XCTAssertEqual(sound.frameCount, 3)
        XCTAssertEqual(samples(of: sound), [1, 10, 2, 20, 3, 30])
    }

    func testSilentBuffersAreIgnoredUntilTheFirstSoundThenKept() throws {
        // Before permission is granted or while nothing plays, CoreAudio delivers zeros: they must not start a silent track
        XCTAssertNil(convertInterleaved([0, 0, 0, 0, 0, 0], channels: 2, ignoreIfSilent: true))
        // Once sound has begun, a silent stretch is kept so the timeline stays whole
        let silent = try XCTUnwrap(convertInterleaved([0, 0, 0, 0, 0, 0], channels: 2, ignoreIfSilent: false))
        XCTAssertEqual(samples(of: silent), [0, 0, 0, 0, 0, 0])
        // Any non-zero sample is heard even when ignoreIfSilent is true
        let heard = try XCTUnwrap(convertInterleaved([0, 0, 0, 0.1, 0, 0], channels: 2, ignoreIfSilent: true))
        XCTAssertEqual(samples(of: heard), [0, 0, 0, 0.1, 0, 0])
    }

    func testUnsupportedFormatsGiveNothing() {
        XCTAssertNil(convertInterleaved([], channels: 2))
        XCTAssertNil(convertInterleaved([1, 2], channels: 0))
        XCTAssertNil(convertInterleaved([1, 2], channels: 2, flags: kAudioFormatFlagIsSignedInteger))
        XCTAssertNil(convertInterleaved([1, 2], channels: 2, bits: 16))
    }

    func testStartAndStopAreIdempotent() {
        let computer = ComputerSound()
        computer.stop()
        if computer.start() {
            XCTAssertTrue(computer.start(), "starting again while running succeeds")
            computer.stop()
            computer.stop()
        }
    }
}
