import XCTest
@testable import Harness

final class WAVRepairTests: XCTestCase {
    /// A 16-bit mono WAV with `samples` bytes of audio, with the sizes the header claims.
    func wav(samples: Int, riffSize: UInt32, dataSize: UInt32) -> Data {
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8)); d.append(riffSize.littleEndianData); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); d.append(UInt32(16).littleEndianData)
        d.append(contentsOf: [1, 0, 1, 0]); d.append(UInt32(16000).littleEndianData); d.append(UInt32(32000).littleEndianData); d.append(contentsOf: [2, 0, 16, 0])
        d.append(contentsOf: Array("data".utf8)); d.append(dataSize.littleEndianData)
        d.append(Data(repeating: 7, count: samples))
        return d
    }

    func testRepairsZeroSizes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("repair-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try wav(samples: 1000, riffSize: 0, dataSize: 0).write(to: url)
        XCTAssertTrue(try WAVRepair.repair(url))
        let fixed = try Data(contentsOf: url)
        XCTAssertEqual(fixed, wav(samples: 1000, riffSize: 1036, dataSize: 1000))
        XCTAssertFalse(try WAVRepair.repair(url))
    }

    func testRejectsOtherFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("repair-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("hello there, not a wav".utf8).write(to: url)
        XCTAssertThrowsError(try WAVRepair.repair(url))
    }
}
