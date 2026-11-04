import XCTest
@testable import Harness

final class AudioSplitTests: XCTestCase {
    func testShortAudioIsNotSplit() {
        XCTAssertEqual(AudioSplit.parts(seconds: 30), 1)
        XCTAssertEqual(AudioSplit.parts(seconds: 119), 1)
        XCTAssertEqual(AudioSplit.parts(seconds: 600, requested: 1), 1)
    }

    func testPartsFollowLengthAndTheSetting() {
        XCTAssertEqual(AudioSplit.parts(seconds: 120), 2)
        XCTAssertEqual(AudioSplit.parts(seconds: 185), 3)
        XCTAssertEqual(AudioSplit.parts(seconds: 3600), 4)
        XCTAssertEqual(AudioSplit.parts(seconds: 3600, requested: 6), 6)
        XCTAssertEqual(AudioSplit.parts(seconds: 3600, requested: 100), AudioSplit.maximumParts)
        XCTAssertEqual(AudioSplit.parts(seconds: 150, requested: 6), 2)
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
}
