import XCTest
import RecorderKit
import Syphon
@testable import SimpleRecorder

final class SmokeTests: XCTestCase {
    /// The app's target is built from Swift, the Objective-C core and Syphon's framework together.
    func testTheAppTargetSeesTheCoreAndSyphon() {
        XCTAssertTrue(FramePacer(framesPerSecond: 30).decisionForFrame(atTime: 0).keep.boolValue)
        XCTAssertNotNil(SyphonServerDirectory.shared().servers)
        XCTAssertEqual(SimpleRecorderApp.name, "Simple Recorder")
    }
}
