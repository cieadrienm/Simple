import XCTest
@testable import SimpleRecorder

final class TakeCaptionTests: XCTestCase {
    private func caption(state: String, notice: String = "", failure: String = "", frames: Int = 0, dropped: Int = 0, soundLost: Double = 0) -> TakeCaption {
        TakeCaption.of(state: state, notice: notice, failure: failure, frames: frames, dropped: dropped, soundLost: soundLost)
    }

    func testIdleSaysNothing() {
        XCTAssertEqual(caption(state: "idle"), .none)
    }

    func testRecordingSaysWhatIsWritten() {
        XCTAssertEqual(caption(state: "recording", frames: 120, dropped: 2), .progress(frames: 120, dropped: 2, soundLost: 0))
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

    func testTheCaptionSaysWhenSoundWasLost() {
        XCTAssertEqual(caption(state: "recording", frames: 10, soundLost: 3), .progress(frames: 10, dropped: 0, soundLost: 3))
        XCTAssertEqual(TakeCaption.soundLostText(0), "")
        XCTAssertEqual(TakeCaption.soundLostText(0.4), "0.4 s")
        XCTAssertEqual(TakeCaption.soundLostText(3), "3.0 s")
        XCTAssertEqual(TakeCaption.soundLostText(12.3), "12 s")
        // The model rounds to a tenth before the caption sees it
        XCTAssertEqual(TakeCaption.soundLostText(9.9), "9.9 s")
        XCTAssertEqual(TakeCaption.soundLostText(10.0), "10 s")
        XCTAssertEqual(caption(state: "recording", frames: 10, soundLost: 0), .progress(frames: 10, dropped: 0, soundLost: 0))
    }
}
