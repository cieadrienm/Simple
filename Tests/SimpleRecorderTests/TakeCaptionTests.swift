import XCTest
@testable import SimpleRecorder

final class TakeCaptionTests: XCTestCase {
    private func caption(state: String, notice: String = "", failure: String = "", frames: Int = 0, dropped: Int = 0) -> TakeCaption {
        TakeCaption.of(state: state, notice: notice, failure: failure, frames: frames, dropped: dropped)
    }

    func testIdleSaysNothing() {
        XCTAssertEqual(caption(state: "idle"), .none)
    }

    func testRecordingSaysWhatIsWritten() {
        XCTAssertEqual(caption(state: "recording", frames: 120, dropped: 2), .progress(frames: 120, dropped: 2))
        XCTAssertEqual(caption(state: "finishing", frames: 120), .finishing)
    }

    func testAnErrorComesFirstForAsLongAsItIsShown() {
        XCTAssertEqual(caption(state: "recording", notice: "/codec …", frames: 120), .notice("/codec …"))
        XCTAssertEqual(caption(state: "idle", notice: "/codec …", failure: "disk full"), .notice("/codec …"))
    }

    func testAMovieWhichFailedShowsForAsLongAsTheTakeGoesOn() {
        // One movie of three has stopped (D41): the others go on, and this must stay in sight all the while
        XCTAssertEqual(caption(state: "recording", failure: "B: disk full", frames: 5000), .failure("B: disk full"))
        XCTAssertEqual(caption(state: "finishing", failure: "B: disk full"), .failure("B: disk full"))
    }

    func testWhyTheLastTakeEndedStaysWhenIdle() {
        XCTAssertEqual(caption(state: "idle", failure: "No frame was received"), .failure("No frame was received"))
    }
}
