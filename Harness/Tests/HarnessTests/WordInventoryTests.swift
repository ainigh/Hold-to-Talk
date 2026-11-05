import XCTest
@testable import Harness

final class WordInventoryTests: XCTestCase {
    func testFallbackTaggerDropsClosedClassWords() {
        let words = WordInventory.tag("I went to the market with my brother, and we bought three apples.")
        XCTAssertEqual(words.map(\.lemma), ["went", "market", "brother", "bought", "apples"])
    }

    func testInventoryCountsByLemmaAndItem() {
        let tagged = [
            WordInventory.Tagged(lemma: "move", kind: .noun, surface: "move"),
            WordInventory.Tagged(lemma: "move", kind: .verb, surface: "moving"),
            WordInventory.Tagged(lemma: "move", kind: .verb, surface: "moved"),
            WordInventory.Tagged(lemma: "house", kind: .noun, surface: "house"),
        ]
        let inv = WordInventory.inventory(of: tagged, item: "a")
        XCTAssertEqual(inv.map(\.lemma), ["move", "house"])
        XCTAssertEqual(inv[0].count, 3)
        XCTAssertEqual(inv[0].kind, .verb)
        XCTAssertEqual(inv[0].items, ["a": 3])
    }

    func testAggregateAddsItemsUp() {
        let a = WordInventory.inventory(of: WordInventory.tag("plan plan house"), item: "a")
        let b = WordInventory.inventory(of: WordInventory.tag("house garden"), item: "b")
        let all = WordInventory.aggregate([a, b])
        XCTAssertEqual(all.map(\.lemma), ["house", "plan", "garden"])
        XCTAssertEqual(all[0].items, ["a": 1, "b": 1])
        XCTAssertEqual(all[0].count, 2)
    }

    func testKindTieBreaksTowardTheEarlierClass() {
        let e = WordInventory.Entry(lemma: "run", count: 2, kinds: [.noun: 1, .verb: 1], items: [:])
        XCTAssertEqual(e.kind, .noun)
    }
}
