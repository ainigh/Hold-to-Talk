import XCTest
@testable import Harness

final class HoldGestureTests: XCTestCase {
    func testShortPressDoesNothing() {
        var g = HoldGesture()
        XCTAssertEqual(g.pressed(at: 0), [])
        XCTAssertEqual(g.tick(at: 0.1), [])
        XCTAssertEqual(g.released(at: 0.2), [])
        XCTAssertEqual(g.state, .idle)
        XCTAssertFalse(g.isRecording)
    }

    func testHoldStartsAndReleaseKeeps() {
        var g = HoldGesture()
        _ = g.pressed(at: 0)
        XCTAssertEqual(g.tick(at: 0.2), [])
        XCTAssertEqual(g.tick(at: 0.25), [.start(locked: false)])
        XCTAssertTrue(g.isRecording)
        XCTAssertEqual(g.recordingSince, 0)
        XCTAssertEqual(g.tick(at: 1), [])
        XCTAssertEqual(g.released(at: 3), [.stop(keep: true)])
        XCTAssertEqual(g.state, .idle)
    }

    func testAccidentalHoldIsDiscarded() {
        var g = HoldGesture()
        _ = g.pressed(at: 0)
        XCTAssertEqual(g.tick(at: 0.3), [.start(locked: false)])
        XCTAssertEqual(g.released(at: 1.2), [.stop(keep: false)])
    }

    func testReleaseBeforeTickStillCountsAsHold() {
        var g = HoldGesture()
        _ = g.pressed(at: 0)
        XCTAssertEqual(g.released(at: 2), [.start(locked: false), .stop(keep: true)])
        _ = g.pressed(at: 3)
        XCTAssertEqual(g.released(at: 3.4), [.start(locked: false), .stop(keep: false)])
    }

    func testDoubleTapLocksAndNextTapStops() {
        var g = HoldGesture()
        _ = g.pressed(at: 0)
        XCTAssertEqual(g.released(at: 0.1), [])
        XCTAssertEqual(g.pressed(at: 0.3), [.start(locked: true)])
        XCTAssertTrue(g.isLocked)
        // The locking press's release does not stop it.
        XCTAssertEqual(g.released(at: 0.4), [])
        XCTAssertTrue(g.isRecording)
        XCTAssertEqual(g.tick(at: 30), [])
        // The next tap does.
        XCTAssertEqual(g.pressed(at: 60), [])
        XCTAssertEqual(g.released(at: 60.1), [.stop(keep: true)])
        XCTAssertEqual(g.state, .idle)
    }

    func testSlowSecondTapIsNotADoubleTap() {
        var g = HoldGesture()
        _ = g.pressed(at: 0)
        _ = g.released(at: 0.1)
        XCTAssertEqual(g.pressed(at: 0.6), [])
        XCTAssertEqual(g.state, .pressed(since: 0.6))
        XCTAssertEqual(g.released(at: 0.7), [])
    }

    func testAHoldDoesNotLeadIntoALock() {
        var g = HoldGesture()
        _ = g.pressed(at: 0)
        _ = g.tick(at: 0.3)
        _ = g.released(at: 2)
        // A press right after a hold is a new press, not the second tap of a double tap.
        XCTAssertEqual(g.pressed(at: 2.1), [])
        XCTAssertEqual(g.state, .pressed(since: 2.1))
    }

    func testLockedRecordingStopsAtTheLimit() {
        var t = HoldGesture.Timing()
        t.lockLimit = 10
        var g = HoldGesture(timing: t)
        _ = g.pressed(at: 0); _ = g.released(at: 0.1); _ = g.pressed(at: 0.2); _ = g.released(at: 0.3)
        XCTAssertTrue(g.isLocked)
        XCTAssertEqual(g.tick(at: 9), [])
        XCTAssertEqual(g.tick(at: 10.2), [.stop(keep: true)])
        XCTAssertEqual(g.state, .idle)
    }

    func testResetForgetsEverything() {
        var g = HoldGesture()
        _ = g.pressed(at: 0); _ = g.tick(at: 0.3)
        g.reset()
        XCTAssertEqual(g.state, .idle)
        XCTAssertEqual(g.released(at: 1), [])
    }
}
