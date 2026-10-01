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
}
