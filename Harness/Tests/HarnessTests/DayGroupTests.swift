import XCTest
@testable import Harness

final class DayGroupTests: XCTestCase {
    func testGroupsByDayNewestFirst() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 86400 * 10 + 3600 * 15)  // day 10, 15:00
        let today = Recording(createdAt: now.addingTimeInterval(-3600), status: .final)
        let todayEarlier = Recording(createdAt: now.addingTimeInterval(-7200), status: .final)
        let yesterday = Recording(createdAt: now.addingTimeInterval(-86400), status: .final)
        let older = Recording(createdAt: now.addingTimeInterval(-86400 * 5), status: .final)
        let groups = DayGroup.group([older, todayEarlier, yesterday, today], now: now, calendar: cal)
        XCTAssertEqual(groups.map(\.title).prefix(2), ["Today", "Yesterday"])
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].recordings.map(\.id), [today.id, todayEarlier.id])
        XCTAssertEqual(groups[2].recordings.map(\.id), [older.id])
        XCTAssertFalse(groups[2].title.isEmpty)
    }

    func testFilter() {
        let a = Recording(text: "Buy Milk", status: .final), b = Recording(text: "call mum", status: .final)
        XCTAssertEqual(DayGroup.filter([a, b], query: "milk").map(\.id), [a.id])
        XCTAssertEqual(DayGroup.filter([a, b], query: "  ").count, 2)
    }
}
