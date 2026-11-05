import XCTest
@testable import Harness

final class TranscriptTextTests: XCTestCase {
    func testTitle() {
        XCTAssertEqual(TranscriptText.title("Buy milk\nand eggs"), "Buy milk")
        XCTAssertEqual(TranscriptText.title("\n\n  Second line is first  "), "Second line is first")
        let long = "The quick brown fox jumps over the lazy dog and keeps running through the forest"
        let t = TranscriptText.title(long)
        XCTAssertTrue(t.hasSuffix("…"))
        XCTAssertLessThanOrEqual(t.count, 61)
        XCTAssertEqual(t, "The quick brown fox jumps over the lazy dog and keeps…")
        XCTAssertEqual(TranscriptText.title("", status: .transcribing), "Transcribing…")
        XCTAssertEqual(TranscriptText.title("", status: .recording), "Recording…")
        XCTAssertEqual(TranscriptText.title("", status: .failed), "Transcription failed")
        XCTAssertEqual(TranscriptText.title("", status: .final), "Empty recording")
    }

    func testCopyAll() {
        let tz = TimeZone(identifier: "UTC")!
        let a = Recording(createdAt: Date(timeIntervalSince1970: 0), text: "first\n", status: .final)
        let b = Recording(createdAt: Date(timeIntervalSince1970: 3600 * 25), text: "second", status: .final)
        XCTAssertEqual(TranscriptText.copyAll([a, b], timeZone: tz), "1970-01-02 01:00\nsecond\n\n1970-01-01 00:00\nfirst")
        XCTAssertEqual(TranscriptText.copyAll([a, b], headers: false, timeZone: tz), "second\n\nfirst")
        XCTAssertEqual(TranscriptText.copyAll([], timeZone: tz), "")
    }

    func testClean() {
        XCTAssertEqual(TranscriptText.clean("  so   um, I  think\n\nyes. "), "so um, I think\n\nyes.")
        XCTAssertEqual(TranscriptText.clean("so um, I think uh yes", removeFillers: true), "so I think yes")
        XCTAssertEqual(TranscriptText.clean("Hmm.", removeFillers: true), "")
    }

    func testVocabularyPrompt() {
        XCTAssertEqual(TranscriptText.vocabularyPrompt([]), "")
        XCTAssertEqual(TranscriptText.vocabularyPrompt([" Holdnote ", "", "Ainigh"]), "Holdnote, Ainigh.")
    }

    func testJoinSegmentsIntoParagraphs() {
        let s = [Recording.Segment(start: 0, end: 1, text: " One. "), Recording.Segment(start: 1.2, end: 2, text: "Two."),
                 Recording.Segment(start: 5, end: 6, text: "Three."), Recording.Segment(start: 6, end: 6.5, text: "  ")]
        XCTAssertEqual(TranscriptText.join(s), "One. Two.\n\nThree.")
    }

    func testDuration() {
        XCTAssertEqual(TranscriptText.duration(0), "0:00")
        XCTAssertEqual(TranscriptText.duration(65.9), "1:05")
        XCTAssertEqual(TranscriptText.duration(3725), "1:02:05")
        XCTAssertEqual(TranscriptText.duration(-3), "0:00")
    }

    func testWordCount() {
        XCTAssertEqual(TranscriptText.wordCount(""), 0)
        XCTAssertEqual(TranscriptText.wordCount("  one  "), 1)
        XCTAssertEqual(TranscriptText.wordCount("one two\nthree\tfour"), 4)
    }
}
