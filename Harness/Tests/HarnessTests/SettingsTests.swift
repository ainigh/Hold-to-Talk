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
