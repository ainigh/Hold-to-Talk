import XCTest
@testable import Harness

final class StoreTests: XCTestCase {
    func temp() throws -> RecordingStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("holdnote-test-\(UUID().uuidString)")
        return try RecordingStore(root: url)
    }

    func testRoundTrip() throws {
        let store = try temp()
        defer { try? FileManager.default.removeItem(at: store.root) }
        var r = Recording(createdAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 3.5, audioFile: "x.wav", machineText: "m", text: "t", segments: [.init(start: 0, end: 1, text: "m")], status: .final)
        try store.save(r)
        XCTAssertEqual(store.loadAll(), [r])
        r.text = "edited"
        try store.save(r)
        XCTAssertEqual(store.load(r.id)?.text, "edited")
        XCTAssertEqual(store.loadAll().count, 1)
        store.delete(r)
        XCTAssertEqual(store.loadAll(), [])
    }

    func testNewestFirstAndInterruptedStatusesSettle() throws {
        let store = try temp()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let old = Recording(createdAt: Date(timeIntervalSince1970: 10), text: "old", status: .transcribing)
        let new = Recording(createdAt: Date(timeIntervalSince1970: 20), status: .recording)
        try store.save(old)
        try store.save(new)
        let all = store.loadAll()
        XCTAssertEqual(all.map(\.id), [new.id, old.id])
        XCTAssertEqual(all[0].status, .failed)
        XCTAssertEqual(all[1].status, .final)
    }

    func testBadFileIsSkipped() throws {
        let store = try temp()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.save(Recording(status: .final))
        try Data("nope".utf8).write(to: store.recordingsFolder.appendingPathComponent("bad.json"))
        var problems = 0
        XCTAssertEqual(store.loadAll(problems: { _, _ in problems += 1 }).count, 1)
        XCTAssertEqual(problems, 1)
    }

    func testOrphanedAudioAndDeleteAudio() throws {
        let store = try temp()
        defer { try? FileManager.default.removeItem(at: store.root) }
        var r = Recording(audioFile: "a.wav", status: .final)
        try Data().write(to: store.audioFolder.appendingPathComponent("a.wav"))
        try Data().write(to: store.audioFolder.appendingPathComponent("b.wav"))
        try store.save(r)
        XCTAssertEqual(store.orphanedAudio(knownTo: [r]).map(\.lastPathComponent), ["b.wav"])
        try store.deleteAudio(of: &r)
        XCTAssertNil(r.audioFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioFolder.appendingPathComponent("a.wav").path))
        XCTAssertNil(store.load(r.id)?.audioFile)
    }

    func testMarkdown() {
        let r = Recording(createdAt: Date(timeIntervalSince1970: 0), duration: 61, text: "hi\n", status: .final)
        XCTAssertEqual(RecordingStore.markdown(r, timeZone: TimeZone(identifier: "UTC")!), "# 1970-01-01 00:00 · 1:01\n\nhi\n")
    }

    func testSettingsDefaultsAndCoding() throws {
        let s = Settings()
        XCTAssertEqual(s.hotkey, .fn)
        XCTAssertEqual(s.model, "large-v3-turbo")
        XCTAssertFalse(s.removeFillers)
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data), s)
        XCTAssertEqual(FnUsage(raw: nil), .showEmoji)
        XCTAssertTrue(FnUsage(raw: 0).isFine)
        XCTAssertEqual(FnUsage(raw: 3).title, "Start Dictation")
    }
}
