import XCTest
import RecorderKit

final class FramePacerTests: XCTestCase {
    /// The times of the frames a pacer keeps, for frames arriving at `arrivals`.
    private func keptTimes(cap: Double, arrivals: [Double]) -> [Double] {
        let pacer = FramePacer(framesPerSecond: cap)
        return arrivals.compactMap { arrival in
            let decision = pacer.decisionForFrame(atTime: arrival)
            return decision.keep.boolValue ? decision.time : nil
        }
    }

    private func assertEqual(_ times: [Double], _ expected: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(times.count, expected.count, file: file, line: line)
        for (time, want) in zip(times, expected) {
            XCTAssertEqual(time, want, accuracy: 1e-9, file: file, line: line)
        }
    }

    func testFirstFrameIsKeptAtZero() {
        assertEqual(keptTimes(cap: 30, arrivals: [1234.5]), [0])
        assertEqual(keptTimes(cap: 0, arrivals: [1234.5]), [0])
    }

    func testNoCapKeepsEveryFrameAtItsArrivalTime() {
        assertEqual(keptTimes(cap: 0, arrivals: [10.0, 10.5, 10.7]), [0, 0.5, 0.7])
    }

    func testNoCapDiscardsFrameWhichDoesNotAdvance() {
        assertEqual(keptTimes(cap: 0, arrivals: [10.0, 10.5, 10.5, 10.4, 10.6]), [0, 0.5, 0.6])
    }

    func testSourceTwiceTheCapKeepsHalf() {
        let arrivals = (0..<120).map { 5.0 + Double($0) / 120 }
        // Slots are centred on their time: the last arrival, at 119/120 s, is the first of the slot at 1 s
        assertEqual(keptTimes(cap: 60, arrivals: arrivals), (0...60).map { Double($0) / 60 })
    }

    func testSourceAtTheCapWithJitterKeepsAll() {
        let arrivals = (0..<60).map { (index: Int) -> Double in
            let jitter = index % 2 == 0 ? 0.003 : -0.003
            return 5.0 + Double(index) / 60 + jitter
        }
        assertEqual(keptTimes(cap: 60, arrivals: arrivals), (0..<60).map { Double($0) / 60 })
    }

    func testSourceSlowerThanCapLeavesGaps() {
        let arrivals = (0..<10).map { 5.0 + Double($0) / 10 }
        assertEqual(keptTimes(cap: 60, arrivals: arrivals), (0..<10).map { Double($0 * 6) / 60 })
    }

    // MARK: An origin given from outside

    private func keptTimes(cap: Double, origin: Double, arrivals: [Double]) -> [Double] {
        let pacer = FramePacer(framesPerSecond: cap, origin: origin)
        return arrivals.compactMap { arrival in
            let decision = pacer.decisionForFrame(atTime: arrival)
            return decision.keep.boolValue ? decision.time : nil
        }
    }

    func testAnOriginPlacesTheFirstFrameWhereItArrived() {
        assertEqual(keptTimes(cap: 0, origin: 100, arrivals: [100.5, 100.75]), [0.5, 0.75])
        assertEqual(keptTimes(cap: 30, origin: 100, arrivals: [100.5, 100.5 + 1.0 / 30]), [0.5, 0.5 + 1.0 / 30])
    }

    func testAFrameBeforeTheOriginIsDiscarded() {
        assertEqual(keptTimes(cap: 0, origin: 100, arrivals: [99.9, 100.2]), [0.2])
        assertEqual(keptTimes(cap: 30, origin: 100, arrivals: [99.9, 100.2]), [0.2])
    }

    func testAFrameAtTheOriginIsKeptAtZero() {
        assertEqual(keptTimes(cap: 30, origin: 100, arrivals: [100, 100.001, 100.1]), [0, 0.1])
    }

    func testWithoutAnOriginTheFirstFrameIsZero() {
        assertEqual(keptTimes(cap: 30, origin: .nan, arrivals: [1234.5, 1234.6]), [0, 0.1])
    }

    // MARK: Asking without deciding

    func testWouldKeepAgreesWithTheDecisionAndChangesNothing() {
        for (cap, origin) in [(0.0, Double.nan), (30.0, Double.nan), (0.0, 100.0), (30.0, 100.0)] {
            let asked = FramePacer(framesPerSecond: cap, origin: origin)
            let plain = FramePacer(framesPerSecond: cap, origin: origin)
            for arrival in [100.0, 100.001, 100.02, 100.034, 100.034, 100.5, 100.49, 101.0] {
                // Asked any number of times, the answer is the same, and the decision is what it would have been
                let would = asked.wouldKeepFrame(atTime: arrival)
                XCTAssertEqual(asked.wouldKeepFrame(atTime: arrival), would)
                let decision = asked.decisionForFrame(atTime: arrival)
                let reference = plain.decisionForFrame(atTime: arrival)
                XCTAssertEqual(decision.keep.boolValue, would, "cap \(cap), origin \(origin), arrival \(arrival)")
                XCTAssertEqual(decision.keep.boolValue, reference.keep.boolValue)
                XCTAssertEqual(decision.time, reference.time, accuracy: 1e-9)
            }
        }
    }
}
