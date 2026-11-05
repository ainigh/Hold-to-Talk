import XCTest
@testable import Harness

final class ManualOrderTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func rec(_ minutes: Double) -> Recording { Recording(createdAt: t0.addingTimeInterval(minutes * 60), text: "\(minutes)", status: .final) }

    func testEmptyOrderIsNewestFirst() {
        let a = rec(1), b = rec(2), c = rec(3)
        XCTAssertEqual(ManualOrder.apply([], to: [a, b, c]).map(\.id), [c.id, b.id, a.id])
    }

    func testKnownOrderIsKeptAndGoneIdsAreSkipped() {
        let a = rec(1), b = rec(2), c = rec(3)
        XCTAssertEqual(ManualOrder.apply([a.id, UUID(), c.id, b.id], to: [a, b, c]).map(\.id), [a.id, c.id, b.id])
    }

    func testANewRecordingLandsOnTop() {
        let a = rec(1), b = rec(2), new = rec(10)
        XCTAssertEqual(ManualOrder.apply([a.id, b.id], to: [a, b, new]).map(\.id), [new.id, a.id, b.id])
    }

    func testAnOldImportLandsAmongItsTime() {
        let a = rec(1), c = rec(3), e = rec(5), old = rec(2)
        // Above the first known one older than it.
        XCTAssertEqual(ManualOrder.apply([e.id, c.id, a.id], to: [a, c, e, old]).map(\.id), [e.id, c.id, old.id, a.id])
    }

    func testMoveAboveATarget() {
        let ids = (0..<5).map { _ in UUID() }
        XCTAssertEqual(ManualOrder.move([ids[4]], in: ids, before: ids[1]), [ids[0], ids[4], ids[1], ids[2], ids[3]])
        XCTAssertEqual(ManualOrder.move([ids[0], ids[2]], in: ids, before: nil), [ids[1], ids[3], ids[4], ids[0], ids[2]])
        XCTAssertEqual(ManualOrder.move([ids[3], ids[1]], in: ids, before: ids[0]), [ids[1], ids[3], ids[0], ids[2], ids[4]])
    }

    func testMoveByOffsetsLikeOnMove() {
        let ids = (0..<5).map { _ in UUID() }
        // Drag row 3 to the top.
        XCTAssertEqual(ManualOrder.move(offsets: [3], to: 0, shown: ids, in: ids), [ids[3], ids[0], ids[1], ids[2], ids[4]])
        // Drag row 0 to below row 2 (destination 3).
        XCTAssertEqual(ManualOrder.move(offsets: [0], to: 3, shown: ids, in: ids), [ids[1], ids[2], ids[0], ids[3], ids[4]])
        // Drag row 1 to the very end.
        XCTAssertEqual(ManualOrder.move(offsets: [1], to: 5, shown: ids, in: ids), [ids[0], ids[2], ids[3], ids[4], ids[1]])
    }

    func testMoveWithinASearch() {
        let ids = (0..<6).map { _ in UUID() }
        let shown = [ids[1], ids[3], ids[5]]
        // Row "5" dragged above row "3": lands just above 3 in the full order.
        XCTAssertEqual(ManualOrder.move(offsets: [2], to: 1, shown: shown, in: ids), [ids[0], ids[1], ids[2], ids[5], ids[3], ids[4]])
        // Row "1" dragged below the last shown row: lands just below 5, not after hidden ones further down.
        XCTAssertEqual(ManualOrder.move(offsets: [0], to: 3, shown: shown, in: ids), [ids[0], ids[2], ids[3], ids[4], ids[5], ids[1]])
    }
}
