import XCTest
@testable import Harness

final class VectorStoreTests: XCTestCase {
    private func folder() throws -> NotesFolder {
        try NotesFolder(root: FileManager.default.temporaryDirectory.appendingPathComponent("vs-\(UUID().uuidString)"))
    }

    func testAppendSearchAndReload() throws {
        let f = try folder()
        var store = VectorStore(model: "test", dim: 3)
        try store.append([(1, [1, 0, 0]), (2, [0, 2, 0]), (3, [1, 1, 0])], to: f)
        XCTAssertEqual(store.count, 3)
        XCTAssertTrue(store.has(2)); XCTAssertFalse(store.has(4))
        let hits = store.search([1, 0.1, 0], top: 2)
        XCTAssertEqual(hits.map(\.n), [1, 3])
        XCTAssertEqual(hits[0].score, 1, accuracy: 0.02)
        // The file holds the same; a later append carries on from it.
        var again = try XCTUnwrap(VectorStore.load(from: f, model: "test"))
        XCTAssertEqual(again.count, 3)
        XCTAssertEqual(again.search([0, 1, 0], top: 1).map(\.n), [2])
        try again.append([(4, [0, 0, 1])], to: f)
        XCTAssertEqual(VectorStore.load(from: f, model: "test")?.count, 4)
        XCTAssertEqual(again.missing(in: [Sentence(id: "s00004", text: ""), Sentence(id: "s00005", text: "")]), [5])
        // Another model's store is not reused.
        XCTAssertNil(VectorStore.load(from: f, model: "other"))
        // A wrong dimension is refused.
        XCTAssertThrowsError(try again.append([(6, [1, 2])], to: f))
    }

    func testEmptyAndMissingFolder() throws {
        let f = try folder()
        XCTAssertNil(VectorStore.load(from: f, model: "test"))
        let store = VectorStore(model: "test", dim: 3)
        XCTAssertEqual(store.search([1, 0, 0], top: 3).count, 0)
    }
}
