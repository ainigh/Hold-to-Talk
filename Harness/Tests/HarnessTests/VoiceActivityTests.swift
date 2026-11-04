import XCTest
@testable import Harness

final class VoiceActivityTests: XCTestCase {
    /// Feeds `rms` every 50 ms from `from` to `to`, returning the events.
    func run(_ v: inout VoiceActivity, rms: Float, from: TimeInterval, to: TimeInterval) -> [VoiceActivity.Event] {
        var events: [VoiceActivity.Event] = []
        var t = from
        while t < to {
            if let e = v.feed(rms: rms, at: t) { events.append(e) }
            t += 0.05
        }
        return events
    }

    func testSpeechStartsAfter300msAndEndsAfter2sOfSilence() {
        var v = VoiceActivity()
        XCTAssertEqual(run(&v, rms: 0.001, from: 0, to: 1), [])
        XCTAssertFalse(v.isSpeaking)
        let started = run(&v, rms: 0.05, from: 1, to: 4)
        XCTAssertEqual(started, [.started(at: 1)])
        XCTAssertTrue(v.isSpeaking)
        let ended = run(&v, rms: 0.001, from: 4, to: 7)
        XCTAssertEqual(ended, [.ended(from: 1, at: 4, keep: true)])
        XCTAssertFalse(v.isSpeaking)
    }

    func testAClickIsNotSpeech() {
        var v = VoiceActivity()
        _ = run(&v, rms: 0.001, from: 0, to: 1)
        XCTAssertEqual(run(&v, rms: 0.1, from: 1, to: 1.2), [])
        XCTAssertEqual(run(&v, rms: 0.001, from: 1.2, to: 2), [])
        XCTAssertEqual(v.state, .idle)
    }

    func testShortSegmentIsDiscarded() {
        var v = VoiceActivity()
        _ = run(&v, rms: 0.001, from: 0, to: 1)
        XCTAssertEqual(run(&v, rms: 0.05, from: 1, to: 2), [.started(at: 1)])
        XCTAssertEqual(run(&v, rms: 0.001, from: 2, to: 5), [.ended(from: 1, at: 2, keep: false)])
    }

    func testAPauseShorterThan2sKeepsTheSegmentGoing() {
        var v = VoiceActivity()
        _ = run(&v, rms: 0.001, from: 0, to: 1)
        _ = run(&v, rms: 0.05, from: 1, to: 3)
        XCTAssertEqual(run(&v, rms: 0.001, from: 3, to: 4.5), [])
        XCTAssertTrue(v.isSpeaking)
        XCTAssertEqual(run(&v, rms: 0.05, from: 4.5, to: 6), [])
        XCTAssertEqual(run(&v, rms: 0.001, from: 6, to: 9), [.ended(from: 1, at: 6, keep: true)])
    }

    func testThresholdFollowsALoudRoom() {
        var v = VoiceActivity()
        _ = run(&v, rms: 0.02, from: 0, to: 5)  // a fan
        XCTAssertGreaterThan(v.threshold, 0.05)
        XCTAssertEqual(run(&v, rms: 0.03, from: 5, to: 7), [])  // a bit louder than the fan: not speech
        XCTAssertEqual(run(&v, rms: 0.2, from: 7, to: 9), [.started(at: 7)])
    }

    func testMaximumLengthCutsALongSegment() {
        var t = VoiceActivity.Tuning()
        t.maximumLength = 5
        var v = VoiceActivity(tuning: t)
        _ = run(&v, rms: 0.001, from: 0, to: 1)
        let events = run(&v, rms: 0.05, from: 1, to: 8)
        XCTAssertEqual(events.first, .started(at: 1))
        guard case let .ended(from, at, keep)? = events.dropFirst().first else { return XCTFail("no end: \(events)") }
        XCTAssertEqual(from, 1)
        XCTAssertEqual(at, 6, accuracy: 0.1)
        XCTAssertTrue(keep)
    }

    func testReset() {
        var v = VoiceActivity()
        _ = run(&v, rms: 0.05, from: 0, to: 1)
        v.reset()
        XCTAssertEqual(v.state, .idle)
    }
}
