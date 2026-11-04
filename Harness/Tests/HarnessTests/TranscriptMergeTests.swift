import XCTest
@testable import Harness

final class TranscriptMergeTests: XCTestCase {
    func testNoEditsTakesTheNewText() {
        XCTAssertEqual(TranscriptMerge.reapply(edits: "a b c", from: "a b c", onto: "a b d"), "a b d")
    }

    func testSameMachineTextKeepsEdits() {
        XCTAssertEqual(TranscriptMerge.reapply(edits: "a X c", from: "a b c", onto: "a b c"), "a X c")
    }

    func testCorrectionSurvivesAnUnrelatedChange() {
        let old = "I met Jon at the park and we talked about the project"
        let user = "I met John at the park and we talked about the project"
        let new = "I met Jon at the park and we talked about the budget"
        XCTAssertEqual(TranscriptMerge.reapply(edits: user, from: old, onto: new), "I met John at the park and we talked about the budget")
    }

    func testAddedSentenceSurvives() {
        let old = "First point. Second point."
        let user = "First point. Second point.\n\nMy own note at the end."
        let new = "First point, second point."
        XCTAssertEqual(TranscriptMerge.reapply(edits: user, from: old, onto: new), "First point, second point.\n\nMy own note at the end.")
    }

    func testDeletionSurvives() {
        let old = "one two three four"
        let user = "one three four"
        let new = "one two three four five"
        XCTAssertEqual(TranscriptMerge.reapply(edits: user, from: old, onto: new), "one three four five")
    }

    func testInsertionInTheMiddle() {
        let old = "alpha beta gamma"
        let user = "alpha (yes) beta gamma"
        let new = "Alpha, beta, gamma."
        XCTAssertEqual(TranscriptMerge.reapply(edits: user, from: old, onto: new), "Alpha, (yes) beta, gamma.")
    }

    func testEditWhosePlaceVanishedIsKept() {
        let old = "the cat sat on the mat"
        let user = "the cat sat on the RUG"
        let new = "the dog slept"
        let merged = TranscriptMerge.reapply(edits: user, from: old, onto: new)
        XCTAssertTrue(merged.contains("RUG"), merged)
        XCTAssertTrue(merged.hasPrefix("the dog"), merged)
    }

    func testParagraphsKept() {
        let old = "one two\n\nthree four"
        let user = "one two\n\nthree four\n\nfive"
        let new = "one two\n\nthree four"
        XCTAssertEqual(TranscriptMerge.reapply(edits: user, from: old, onto: new), "one two\n\nthree four\n\nfive")
    }

    func testDiffAndLcs() {
        XCTAssertEqual(TranscriptMerge.lcs(["a", "b", "c"], ["a", "c"]).map { [$0.0, $0.1] }, [[0, 0], [2, 1]])
        XCTAssertEqual(TranscriptMerge.diff(["a", "b"], ["b", "c"]), [.delete(0), .keep(1, 0), .insert(before: 2, 1)])
        XCTAssertEqual(TranscriptMerge.lcs([], ["a"]).count, 0)
    }

    func testRecordingReplaceMachineText() {
        var r = Recording(machineText: "hello wrld", text: "hello world", status: .final)
        r.replaceMachineText("hello world again", segments: [], language: "en", model: "x")
        XCTAssertEqual(r.text, "hello world again")
        XCTAssertEqual(r.machineText, "hello world again")
        XCTAssertEqual(r.status, .final)
        XCTAssertEqual(r.language, "en")
    }
}
