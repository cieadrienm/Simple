import XCTest
import RecorderKit

final class SoundTimelineTests: XCTestCase {
    private let rate = 48000.0

    /// A piece of `frames` frames whose left samples count from 0 and right samples from -0 down.
    private func piece(_ frames: Int, rate: Double = 48000) -> SourceSound {
        var interleaved = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            interleaved[frame * 2] = Float(frame + 1)
            interleaved[frame * 2 + 1] = -Float(frame + 1)
        }
        return SourceSound(interleavedStereoSamples: interleaved, frameCount: UInt(frames), sampleRate: rate)!
    }

    private func frames(_ pieces: [SourceSound]) -> Int {
        pieces.reduce(0) { $0 + Int($1.frameCount) }
    }

    private func isSilence(_ sound: SourceSound) -> Bool {
        UnsafeBufferPointer(start: sound.samples, count: Int(sound.frameCount) * 2).allSatisfy { $0 == 0 }
    }

    /// The pieces for a sound, checking that they follow the stream's end without a break or an overlap.
    private func feed(_ timeline: SoundTimeline, _ sound: SourceSound, at time: TimeInterval,
                      file: StaticString = #filePath, line: UInt = #line) -> [SourceSound] {
        let before = timeline.writtenDuration
        let pieces = timeline.pieces(for: sound, arrivedAtTime: time)
        let written = pieces.reduce(0.0) { $0 + $1.duration }
        XCTAssertEqual(timeline.writtenDuration - before, written, accuracy: 1e-9, file: file, line: line)
        return pieces
    }

    func testPiecesWhichFollowAreWrittenAsTheyAre() {
        let origin = 100.0
        let timeline = SoundTimeline(origin: origin)
        let sound = piece(1024)
        for k in 0..<20 {
            let pieces = feed(timeline, sound, at: origin + Double(k + 1) * sound.duration)
            XCTAssertEqual(pieces.count, 1)
            XCTAssertTrue(pieces.first === sound)
        }
        XCTAssertEqual(timeline.writtenDuration, 20 * 1024 / rate, accuracy: 1e-12)
        XCTAssertEqual(timeline.silenceAdded, 0)
        XCTAssertEqual(timeline.soundLeftOut, 0)
    }

    /// Deterministic jitter, uniform in ±1 with a mean of zero.
    private struct Jitter {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    func testTheFirstPieceIsAnchoredExactly() {
        let sound = piece(1024)
        // Its place is 0.05 s after the origin: exactly that much silence first, though within the tolerance
        let late = SoundTimeline(origin: 0)
        var pieces = feed(late, sound, at: 0.05 + sound.duration)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].frameCount, 2400)
        XCTAssertTrue(isSilence(pieces[0]))
        XCTAssertTrue(pieces[1] === sound)
        XCTAssertEqual(late.silenceAdded, 0.05, accuracy: 1e-12)

        // Its place is 0.01 s before the origin: exactly that much left out
        let early = SoundTimeline(origin: 0)
        pieces = feed(early, sound, at: -0.01 + sound.duration)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].frameCount, 1024 - 480)
        XCTAssertEqual(pieces[0].samples[0], 481)
        XCTAssertEqual(early.soundLeftOut, 0.01, accuracy: 1e-12)
        XCTAssertEqual(early.silenceAdded, 0)
    }

    func testJitterAloneChangesNothing() {
        let origin = 5.0
        let timeline = SoundTimeline(origin: origin)
        let sound = piece(960)
        var jitter = Jitter(state: 1)
        XCTAssertEqual(feed(timeline, sound, at: origin + sound.duration).count, 1)
        // 30 s of 20 ms pieces, each arriving up to 40 ms before or after its time
        for k in 1..<1500 {
            let pieces = feed(timeline, sound, at: origin + Double(k + 1) * sound.duration + 0.04 * jitter.next())
            XCTAssertEqual(pieces.count, 1)
            XCTAssertTrue(pieces.first === sound)
        }
        XCTAssertEqual(timeline.silenceAdded, 0)
        XCTAssertEqual(timeline.soundLeftOut, 0)
    }

    /// Pieces of 20 ms for a minute, the first on time and the others `offset` late; the corrections made, with the
    /// time of each.
    private func corrections(forSteadyOffset offset: Double) -> (timeline: SoundTimeline, made: [(at: Double, by: Double)]) {
        let origin = 7.0
        let timeline = SoundTimeline(origin: origin)
        let sound = piece(960)
        XCTAssertEqual(feed(timeline, sound, at: origin + sound.duration).count, 1)
        var made: [(at: Double, by: Double)] = []
        for k in 1..<3000 {
            let silence = timeline.silenceAdded
            let leftOut = timeline.soundLeftOut
            _ = feed(timeline, sound, at: origin + Double(k + 1) * sound.duration + offset)
            let by = (timeline.silenceAdded - silence) - (timeline.soundLeftOut - leftOut)
            if by != 0 {
                made.append((Double(k) * sound.duration, by))
            }
        }
        return (timeline, made)
    }

    func testASteadyOffsetIsFoundAndRemoved() {
        for offset in [0.03, -0.03] {
            let (timeline, made) = corrections(forSteadyOffset: offset)
            // One correction, within a few seconds, of the soft tolerance (the smoothed error crosses it on its way
            // to the offset): what is left is within the soft tolerance, and stays
            XCTAssertEqual(made.count, 1, "\(offset)")
            guard let correction = made.first else { continue }
            XCTAssertLessThan(correction.at, 5)
            XCTAssertGreaterThanOrEqual(abs(correction.by), 0.0199)
            XCTAssertLessThanOrEqual(abs(correction.by), 0.021)
            XCTAssertEqual(correction.by.sign, offset.sign)
            XCTAssertLessThanOrEqual(abs(offset - correction.by), 0.02)
            XCTAssertEqual(offset > 0 ? timeline.soundLeftOut : timeline.silenceAdded, 0)
        }
    }

    func testSoundWhichStartsLateIsPrecededBySilence() {
        let timeline = SoundTimeline(origin: 0)
        let sound = piece(1024)
        let pieces = feed(timeline, sound, at: 0.5)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].frameCount, 24000 - 1024)
        XCTAssertEqual(pieces[0].sampleRate, rate)
        XCTAssertTrue(isSilence(pieces[0]))
        XCTAssertTrue(pieces[1] === sound)
        XCTAssertEqual(timeline.writtenDuration, 0.5, accuracy: 1e-12)
        XCTAssertEqual(timeline.silenceAdded, Double(24000 - 1024) / rate, accuracy: 1e-12)
        XCTAssertEqual(timeline.soundLeftOut, 0)
    }

    func testSilenceFillsWhatIsMissing() {
        let origin = 20.0
        let timeline = SoundTimeline(origin: origin)
        let sound = piece(1024)
        var due = origin
        for _ in 0..<50 {
            due += sound.duration
            XCTAssertEqual(feed(timeline, sound, at: due).count, 1)
        }

        // None for 2 s: one silence of exactly 2 s, then the piece
        due += 2 + sound.duration
        var pieces = feed(timeline, sound, at: due)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].frameCount, 96000)
        XCTAssertTrue(isSilence(pieces[0]))
        XCTAssertTrue(pieces[1] === sound)
        XCTAssertEqual(timeline.silenceAdded, 2, accuracy: 1e-12)
        XCTAssertEqual(timeline.writtenDuration, due - origin, accuracy: 1e-9)

        for _ in 0..<10 {
            due += sound.duration
            XCTAssertEqual(feed(timeline, sound, at: due).count, 1)
        }

        // None for 25 s: the silence comes in pieces of no more than 10 s
        due += 25 + sound.duration
        pieces = feed(timeline, sound, at: due)
        let silences = pieces.dropLast()
        XCTAssertGreaterThanOrEqual(silences.count, 3)
        XCTAssertTrue(silences.allSatisfy { $0.frameCount <= 480000 && isSilence($0) })
        XCTAssertEqual(frames(Array(silences)), 1200000)
        XCTAssertTrue(pieces.last === sound)
        XCTAssertEqual(timeline.silenceAdded, 27, accuracy: 1e-12)
        XCTAssertEqual(timeline.writtenDuration, due - origin, accuracy: 1e-9)
        XCTAssertEqual(timeline.soundLeftOut, 0)
    }

    func testSoundBeforeTheOriginIsLeftOut() {
        let origin = 10.0
        let early = SoundTimeline(origin: origin)
        XCTAssertEqual(feed(early, piece(1024), at: 9.0).count, 0)
        XCTAssertEqual(early.writtenDuration, 0)
        XCTAssertEqual(early.soundLeftOut, 1024 / rate, accuracy: 1e-12)

        // One second of sound which arrives half a second after the origin: its first half was made before it
        let straddling = SoundTimeline(origin: origin)
        let pieces = feed(straddling, piece(48000), at: origin + 0.5)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].frameCount, 24000)
        XCTAssertEqual(pieces[0].samples[0], 24001)
        XCTAssertEqual(straddling.writtenDuration, 0.5, accuracy: 1e-12)
        XCTAssertEqual(straddling.soundLeftOut, 0.5, accuracy: 1e-12)
        XCTAssertEqual(straddling.silenceAdded, 0)
    }

    func testAnEarlyPieceIsCutOrLeftOut() {
        let origin = 0.0
        let timeline = SoundTimeline(origin: origin)
        let short = piece(1024)
        var due = origin
        for _ in 0..<10 {
            due += short.duration
            XCTAssertEqual(feed(timeline, short, at: due).count, 1)
        }

        // One second of sound made 0.2 s before the stream's end: its first 0.2 s overlap what is written
        let long = piece(48000)
        due += long.duration - 0.2
        var pieces = feed(timeline, long, at: due)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].frameCount, 48000 - 9600)
        XCTAssertEqual(pieces[0].samples[0], 9601)
        XCTAssertEqual(timeline.soundLeftOut, 0.2, accuracy: 1e-12)
        XCTAssertEqual(timeline.writtenDuration, (10 * 1024 + 38400) / rate, accuracy: 1e-12)

        // A short piece which lies entirely in what is written
        let end = timeline.writtenDuration
        pieces = feed(timeline, short, at: origin + end - 0.2 + short.duration)
        XCTAssertEqual(pieces.count, 0)
        XCTAssertEqual(timeline.writtenDuration, end)
        XCTAssertEqual(timeline.soundLeftOut, 0.2 + 1024 / rate, accuracy: 1e-12)
        XCTAssertEqual(timeline.silenceAdded, 0)
    }

    /// Feeds pieces made by a clock running at `speed` times ours, for `seconds` of our clock, each arriving up to
    /// `jitter` before or after its time; returns the time of the last, what was fed and the corrections made.
    private func feedDrift(_ timeline: SoundTimeline, _ sound: SourceSound, origin: Double, from start: Double,
                           seconds: Double, speed: Double, jitter: Double, random: inout Jitter)
        -> (end: Double, fed: Double, corrections: [Double]) {
        let interval = sound.duration / speed
        var count = 0
        var arrival = start
        var fed = 0.0
        var corrections: [Double] = []
        // Only the first of each failure is told: an hour could give thousands
        var broken = false
        var away = false
        while arrival < start + seconds {
            count += 1
            arrival = start + Double(count) * interval
            // The timeline's first piece on time: it is anchored exactly where it arrives, and what is measured
            // here is what follows
            let late = timeline.writtenDuration == 0 ? 0 : jitter * random.next()
            autoreleasepool {
                let before = timeline.writtenDuration
                let silence = timeline.silenceAdded
                let leftOut = timeline.soundLeftOut
                let pieces = timeline.pieces(for: sound, arrivedAtTime: arrival + late)
                let written = pieces.reduce(0.0) { $0 + $1.duration }
                // Every piece out follows the one before
                if !broken && abs(timeline.writtenDuration - before - written) > 1e-9 {
                    broken = true
                    XCTFail("A break at \(arrival)")
                }
                // The end of the stream stays on the clock
                if !away && abs(timeline.writtenDuration - (arrival - origin)) > 0.02 + jitter + sound.duration {
                    away = true
                    XCTFail("The stream's end left the clock at \(arrival): \(timeline.writtenDuration)")
                }
                let by = (timeline.silenceAdded - silence) + (timeline.soundLeftOut - leftOut)
                if by > 0 {
                    corrections.append(by)
                }
            }
            fed += sound.duration
        }
        return (arrival, fed, corrections)
    }

    func testALongDriftIsCorrectedWithoutABreak() {
        let origin = 1000.0
        let timeline = SoundTimeline(origin: origin)
        let sound = piece(1024)
        var random = Jitter(state: 7)

        // An hour from a source whose clock is 100 ppm fast: 0.36 s too much, cut in steps of the soft tolerance
        let fast = feedDrift(timeline, sound, origin: origin, from: origin, seconds: 3600, speed: 1.0001,
                             jitter: 0.02, random: &random)
        XCTAssertEqual(timeline.silenceAdded, 0)
        XCTAssertEqual(timeline.soundLeftOut, 0.36, accuracy: 0.025)
        XCTAssertGreaterThan(fast.corrections.count, 10)
        XCTAssertTrue(fast.corrections.allSatisfy { $0 > 0.019 && $0 < 0.025 }, "\(fast.corrections)")
        XCTAssertEqual(timeline.writtenDuration, fast.fed - timeline.soundLeftOut, accuracy: 1e-6)

        // Then an hour 100 ppm slow: 0.36 s missing, give or take what each hour leaves within the soft tolerance
        let leftOut = timeline.soundLeftOut
        let slow = feedDrift(timeline, sound, origin: origin, from: fast.end, seconds: 3600, speed: 0.9999,
                             jitter: 0.02, random: &random)
        XCTAssertEqual(timeline.soundLeftOut, leftOut)
        XCTAssertEqual(timeline.silenceAdded, 0.36, accuracy: 0.05)
        XCTAssertGreaterThan(slow.corrections.count, 10)
        XCTAssertTrue(slow.corrections.allSatisfy { $0 > 0.019 && $0 < 0.025 }, "\(slow.corrections)")
        XCTAssertEqual(timeline.writtenDuration, fast.fed + slow.fed + timeline.silenceAdded - timeline.soundLeftOut,
                       accuracy: 1e-6)
    }

    /// A timeline which has written ten pieces of 1024 frames on time, and the time the next one is due.
    private func onTime(origin: Double) -> (SoundTimeline, Double) {
        let timeline = SoundTimeline(origin: origin)
        let sound = piece(1024)
        var due = origin
        for _ in 0..<10 {
            due += sound.duration
            XCTAssertEqual(feed(timeline, sound, at: due).count, 1)
        }
        return (timeline, due + sound.duration)
    }

    func testTheHardToleranceActsAtOnceAndOnePieceWithinItDoesNot() {
        let sound = piece(1024)

        // 0.09 s late: one piece is not evidence enough, it follows, and so do the pieces on time after it
        var (timeline, due) = onTime(origin: 3)
        var pieces = feed(timeline, sound, at: due + 0.09)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertTrue(pieces[0] === sound)
        for k in 1...100 {
            XCTAssertEqual(feed(timeline, sound, at: due + Double(k) * sound.duration).count, 1)
        }
        XCTAssertEqual(timeline.silenceAdded, 0)
        XCTAssertEqual(timeline.soundLeftOut, 0)

        // 0.11 s late: exactly that much silence at once
        (timeline, due) = onTime(origin: 3)
        pieces = feed(timeline, sound, at: due + 0.11)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].frameCount, 5280)
        XCTAssertTrue(isSilence(pieces[0]))
        XCTAssertTrue(pieces[1] === sound)
        XCTAssertEqual(timeline.silenceAdded, 0.11, accuracy: 1e-12)

        // 0.09 s early: kept whole, and the pieces on time after it follow
        (timeline, due) = onTime(origin: 3)
        pieces = feed(timeline, sound, at: due - 0.09)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertTrue(pieces[0] === sound)
        for k in 1...100 {
            XCTAssertEqual(feed(timeline, sound, at: due + Double(k) * sound.duration).count, 1)
        }
        XCTAssertEqual(timeline.silenceAdded, 0)
        XCTAssertEqual(timeline.soundLeftOut, 0)

        // 0.11 s early: cut by exactly that much at once
        let long = piece(48000)
        (timeline, due) = onTime(origin: 3)
        pieces = feed(timeline, long, at: due - sound.duration + long.duration - 0.11)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].frameCount, 48000 - 5280)
        XCTAssertEqual(pieces[0].samples[0], 5281)
        XCTAssertEqual(timeline.soundLeftOut, 0.11, accuracy: 1e-12)
    }

    func testAnHourAwayCostsOneBufferOfSilence() {
        let (timeline, due) = onTime(origin: 0)
        let sound = piece(1024)
        let start = Date()
        let pieces = feed(timeline, sound, at: due + 3600.5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertTrue(pieces.last === sound)
        let silences = pieces.dropLast()
        XCTAssertEqual(frames(Array(silences)), Int(3600.5 * rate))
        XCTAssertTrue(silences.allSatisfy { $0.frameCount <= 480000 })
        // The full pieces of silence are one and the same, so an hour holds no more than two buffers
        XCTAssertLessThanOrEqual(Set(silences.map { ObjectIdentifier($0) }).count, 2)
        XCTAssertTrue(isSilence(silences[0]))
        XCTAssertTrue(isSilence(silences[silences.count - 1]))
        XCTAssertEqual(timeline.silenceAdded, 3600.5, accuracy: 1e-9)
    }

    func testATimeOutOfReachIsIgnored() {
        let sound = piece(1024)
        let (timeline, due) = onTime(origin: 0)
        let written = timeline.writtenDuration
        for time in [Double.infinity, -Double.infinity, Double.nan, 1e300, -1e300] {
            let start = Date()
            XCTAssertEqual(timeline.pieces(for: sound, arrivedAtTime: time).count, 0)
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
            XCTAssertEqual(timeline.writtenDuration, written)
            XCTAssertEqual(timeline.silenceAdded, 0)
            XCTAssertEqual(timeline.soundLeftOut, 0)
        }
        // Still usable: the next ordinary piece follows
        let pieces = feed(timeline, sound, at: due)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertTrue(pieces[0] === sound)
        XCTAssertEqual(timeline.writtenDuration, written + sound.duration, accuracy: 1e-12)
    }

    func testAChangeOfRateAnchorsAgainExactly() {
        let origin = 50.0
        let timeline = SoundTimeline(origin: origin)
        let at48 = piece(1024)
        var due = origin
        for _ in 0..<47 {
            due += at48.duration
            XCTAssertEqual(feed(timeline, at48, at: due).count, 1)
        }
        let first = timeline.writtenDuration

        // The source goes to 44.1 kHz, its first piece 0.05 s late: exactly that much silence, at the new rate
        let at44 = piece(441, rate: 44100)
        due += 0.05 + at44.duration
        var pieces = feed(timeline, at44, at: due)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].sampleRate, 44100)
        XCTAssertEqual(pieces[0].frameCount, 2205)
        XCTAssertTrue(isSilence(pieces[0]))
        XCTAssertTrue(pieces[1] === at44)
        XCTAssertEqual(timeline.writtenDuration, first + 0.06, accuracy: 1e-9)

        // Then its pieces follow
        for k in 0..<100 {
            due += at44.duration
            pieces = feed(timeline, at44, at: due)
            XCTAssertEqual(pieces.count, 1)
            XCTAssertTrue(pieces.first === at44)
            XCTAssertEqual(timeline.writtenDuration, first + 0.06 + Double(k + 1) * 0.01, accuracy: 1e-9)
        }

        // Late by a second at the new rate: silence at that rate
        due += 1 + at44.duration
        pieces = feed(timeline, at44, at: due)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].sampleRate, 44100)
        XCTAssertEqual(pieces[0].frameCount, 44100)
        XCTAssertTrue(isSilence(pieces[0]))
        XCTAssertEqual(timeline.silenceAdded, 1.05, accuracy: 1e-9)
        XCTAssertEqual(timeline.writtenDuration, due - origin, accuracy: 1e-9)

        // And back to 48 kHz, its first piece 0.01 s early: exactly that much left out
        due += at48.duration - 0.01
        pieces = feed(timeline, at48, at: due)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].frameCount, 1024 - 480)
        XCTAssertEqual(timeline.writtenDuration, due - origin, accuracy: 1e-9)
        XCTAssertEqual(timeline.silenceAdded, 1.05, accuracy: 1e-9)
        XCTAssertEqual(timeline.soundLeftOut, 0.01, accuracy: 1e-9)
    }
}
