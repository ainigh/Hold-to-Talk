import XCTest
@testable import Harness

final class UsageTests: XCTestCase {
    let sample = UsageSample(systemCPU: 0.234, appCPU: 0.051, cores: 8, memoryUsed: 31_000_000_000, memoryTotal: 64_000_000_000,
                             appMemory: 1_900_000_000, thermal: .nominal)

    func testFormatting() {
        XCTAssertEqual(UsageText.percent(0.234), "23%")
        XCTAssertEqual(UsageText.percent(1.7), "100%")
        XCTAssertEqual(UsageText.percent(-1), "0%")
        XCTAssertEqual(UsageText.bytes(1_900_000_000), "1.9 GB")
        XCTAssertEqual(UsageText.bytes(64_000_000_000), "64 GB")
        XCTAssertEqual(UsageText.bytes(640_000_000), "640 MB")
    }

    func testLines() {
        XCTAssertEqual(UsageText.cpu(sample), "CPU 23% in use · Holdnote 5%")
        XCTAssertEqual(UsageText.memory(sample), "Memory 31 GB of 64 GB · Holdnote 1.9 GB")
        XCTAssertEqual(UsageText.line(sample), "CPU 23% in use · Holdnote 5% · Memory 31 GB of 64 GB · Holdnote 1.9 GB")
        var hot = sample
        hot.thermal = .serious
        XCTAssertTrue(UsageText.line(hot).hasSuffix(" · Hot: slowing down"))
    }

    func testFractionsAndShare() {
        XCTAssertEqual(sample.memoryFraction, 31.0 / 64.0, accuracy: 0.0001)
        XCTAssertEqual(sample.appShareOfCPU!, 0.051 / 0.234, accuracy: 0.0001)
        var idle = sample
        idle.systemCPU = 0
        XCTAssertNil(idle.appShareOfCPU)
        var busy = sample
        busy.appCPU = 0.5
        XCTAssertEqual(busy.appShareOfCPU, 1)
    }

    func testExplanation() {
        let t = UsageText.explanation(sample, transcribing: true)
        XCTAssertTrue(t.contains("8 cores"))
        XCTAssertTrue(t.contains("22% of what's busy"))
        XCTAssertTrue(t.contains("transcriber is running"))
        XCTAssertTrue(UsageText.explanation(sample, transcribing: false).contains("speech model"))
    }
}
