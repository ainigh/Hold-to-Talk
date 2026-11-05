import XCTest
@testable import Harness

final class SettingsTests: XCTestCase {
    func testAnOlderFileKeepsDefaultsForWhatItLacks() throws {
        let old = Data(#"{"hotkey":"rightOption","model":"small","vocabulary":["Holdnote"]}"#.utf8)
        let s = try JSONDecoder().decode(Settings.self, from: old)
        XCTAssertEqual(s.hotkey, .rightOption)
        XCTAssertEqual(s.model, "small")
        XCTAssertEqual(s.vocabulary, ["Holdnote"])
        XCTAssertEqual(s.parallelParts, 0)
        XCTAssertEqual(s.copyAllHeaders, true)
        XCTAssertNil(s.inputDeviceID)
    }

    func testRoundTrip() throws {
        var s = Settings()
        s.parallelParts = 3
        s.inputDeviceID = "mic-1"
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }
}

final class OrderStoreTests: XCTestCase {
    func testOrderRoundTripsThroughTheStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        XCTAssertEqual(store.loadOrder(), [])
        let ids = [UUID(), UUID(), UUID()]
        try store.saveOrder(ids)
        XCTAssertEqual(store.loadOrder(), ids)
    }

    func testCopyAllCanKeepTheGivenOrder() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let a = Recording(createdAt: t, text: "first", status: .final)
        let b = Recording(createdAt: t.addingTimeInterval(60), text: "second", status: .final)
        XCTAssertEqual(TranscriptText.copyAll([a, b], headers: false), "second\n\nfirst")
        XCTAssertEqual(TranscriptText.copyAll([a, b], headers: false, keepOrder: true), "first\n\nsecond")
    }

    func testAnUnknownListOrderFallsBackToDate() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"listOrder":"sideways"}"#.utf8))
        XCTAssertEqual(s.listOrder, .newestFirst)
    }
}
