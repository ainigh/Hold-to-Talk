import XCTest
@testable import Harness

final class AudioSplitTests: XCTestCase {
    func testShortAudioIsNotSplit() {
        XCTAssertEqual(AudioSplit.parts(seconds: 30), 1)
        XCTAssertEqual(AudioSplit.parts(seconds: 119), 1)
        // Splitting off: one chunk however long.
        XCTAssertEqual(AudioSplit.parts(seconds: 7200, workers: 1), 1)
    }

    func testWorkersFollowTheSetting() {
        XCTAssertEqual(AudioSplit.workers(requested: 0), AudioSplit.automaticAtOnce)
        XCTAssertEqual(AudioSplit.workers(requested: 1), 1)
        XCTAssertEqual(AudioSplit.workers(requested: 6), 6)
        XCTAssertEqual(AudioSplit.workers(requested: 100), AudioSplit.maximumAtOnce)
    }

    func testChunksAreAboutFiveMinutesAndKeepTheWorkersBusy() {
        // Two hours: 24 chunks of five minutes, whatever the worker count.
        XCTAssertEqual(AudioSplit.parts(seconds: 7200), 24)
        XCTAssertEqual(AudioSplit.parts(seconds: 7200, workers: 8), 24)
        // An hour: 12. Seventeen minutes: four (a 5 min ceiling rounds up).
        XCTAssertEqual(AudioSplit.parts(seconds: 3600), 12)
        XCTAssertEqual(AudioSplit.parts(seconds: 17 * 60), 4)
        // Short enough for one chunk by length, but cut so every worker has something: a
        // four-minute hold runs as four minute-long chunks, as it did before.
        XCTAssertEqual(AudioSplit.parts(seconds: 120), 2)
        XCTAssertEqual(AudioSplit.parts(seconds: 185), 3)
        XCTAssertEqual(AudioSplit.parts(seconds: 240), 4)
        XCTAssertEqual(AudioSplit.parts(seconds: 420), 4)
        XCTAssertEqual(AudioSplit.parts(seconds: 420, workers: 8), 7)
        XCTAssertEqual(AudioSplit.parts(seconds: 150, workers: 6), 2)
        // Never a chunk under a minute.
        for seconds in stride(from: 120.0, through: 7200, by: 37) {
            let n = AudioSplit.parts(seconds: seconds, workers: 8)
            XCTAssertGreaterThanOrEqual(seconds / Double(n), AudioSplit.minimumPart - 0.001, "\(seconds) s in \(n)")
            XCTAssertLessThanOrEqual(seconds / Double(n), AudioSplit.targetPart + 0.001, "\(seconds) s in \(n)")
        }
    }

    func testOnePartIsTheWholeThing() {
        let s = [Float](repeating: 0.5, count: 1000)
        XCTAssertEqual(AudioSplit.ranges(s, rate: 100, parts: 1), [0..<1000])
    }

    func testCutsLandOnTheQuietMomentNearTheMiddle() {
        // 100 s at 100 Hz, loud throughout except a half-second of silence at 47 s.
        let rate = 100
        var s = [Float](repeating: 0.5, count: 100 * rate)
        for i in (47 * rate)..<(47 * rate + rate / 2) { s[i] = 0 }
        let r = AudioSplit.ranges(s, rate: rate, parts: 2)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].lowerBound, 0)
        XCTAssertEqual(r[1].upperBound, s.count)
        XCTAssertEqual(r[0].upperBound, r[1].lowerBound)
        // Inside the silence, not at the even middle (50 s).
        XCTAssertGreaterThanOrEqual(r[0].upperBound, 47 * rate)
        XCTAssertLessThanOrEqual(r[0].upperBound, 47 * rate + rate / 2)
    }

    func testRangesCoverEverythingInOrder() {
        let rate = 100
        let s = (0..<(1000 * rate)).map { Float(sin(Double($0) / 7)) * 0.3 }
        for parts in 2...8 {
            let r = AudioSplit.ranges(s, rate: rate, parts: parts)
            XCTAssertEqual(r.count, parts)
            XCTAssertEqual(r.first?.lowerBound, 0)
            XCTAssertEqual(r.last?.upperBound, s.count)
            for (a, b) in zip(r, r.dropFirst()) { XCTAssertEqual(a.upperBound, b.lowerBound) }
            // Each part is near the even length: within the 8 s search either side.
            for part in r { XCTAssertEqual(Double(part.count) / Double(rate), 1000 / Double(parts), accuracy: 16.1) }
        }
    }

    func testSilenceEverywhereCutsEvenly() {
        let s = [Float](repeating: 0, count: 10_000)
        let r = AudioSplit.ranges(s, rate: 100, parts: 4)
        XCTAssertEqual(r.map(\.lowerBound), [0, 2505, 5005, 7505])
    }

    func testJoinedKeepsOrderAndOffsets() {
        let a = [Recording.Segment(start: 0, end: 2, text: "Hello there."), Recording.Segment(start: 2, end: 4, text: "How are you?")]
        let b = [Recording.Segment(start: 300, end: 302, text: "Fine, thanks.")]
        XCTAssertEqual(AudioSplit.joined([a, b]), a + b)
        XCTAssertEqual(AudioSplit.joined([]), [])
        XCTAssertEqual(AudioSplit.joined([[], a, []]), a)
    }

    func testJoinedDropsTheWordsHeardTwiceAtACut() {
        let a = [Recording.Segment(start: 0, end: 2, text: "Hello there."), Recording.Segment(start: 298, end: 300, text: "and then we left")]
        let b = [Recording.Segment(start: 300, end: 301.5, text: "And then we left."), Recording.Segment(start: 302, end: 304, text: "for the day.")]
        let j = AudioSplit.joined([a, b])
        XCTAssertEqual(j.map(\.text), ["Hello there.", "and then we left", "for the day."])
        // The kept segment reaches to where the repeat ended.
        XCTAssertEqual(j[1].end, 301.5)
    }

    func testJoinedDropsAnEchoWithinAChunk() {
        let a = [Recording.Segment(start: 0, end: 2, text: "Thank you."), Recording.Segment(start: 2, end: 4, text: "Thank you."), Recording.Segment(start: 4, end: 6, text: "Thank you very much.")]
        XCTAssertEqual(AudioSplit.joined([a]).map(\.text), ["Thank you.", "Thank you very much."])
        // Empty text is never a reason to drop.
        let e = [Recording.Segment(start: 0, end: 1, text: "..."), Recording.Segment(start: 1, end: 2, text: "...")]
        XCTAssertEqual(AudioSplit.joined([e]).count, 2)
    }
}
