import Foundation

/// Where everything lives: one folder you can back up, look into or delete.
///
/// ```
/// <root>/Recordings/<id>.json   one file per recording (text, times, segments)
/// <root>/Audio/<id>.wav         its audio
/// <root>/Models/                the transcriber's weights
/// ```
/// Each recording is its own file, so a bad one never takes the others with it and Time
/// Machine copies only what changed.
public final class RecordingStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()

    public init(root: URL) throws {
        self.root = root
        for sub in ["Recordings", "Audio", "Models"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    /// `~/Library/Application Support/Holdnote`.
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Holdnote")
    }

    public var recordingsFolder: URL { root.appendingPathComponent("Recordings") }
    public var audioFolder: URL { root.appendingPathComponent("Audio") }
    public var modelsFolder: URL { root.appendingPathComponent("Models") }

    public func audioURL(for recording: Recording) -> URL? {
        recording.audioFile.map { audioFolder.appendingPathComponent($0) }
    }

    /// A new audio file's name for a recording.
    public static func audioFileName(for id: UUID, ext: String = "wav") -> String { "\(id.uuidString).\(ext)" }

    private func file(for id: UUID) -> URL { recordingsFolder.appendingPathComponent("\(id.uuidString).json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Every recording, newest first. A file that can't be read is skipped (and reported), not fatal.
    public func loadAll(problems: ((URL, Error) -> Void)? = nil) -> [Recording] {
        lock.lock()
        defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: recordingsFolder, includingPropertiesForKeys: nil)) ?? []
        var all: [Recording] = []
        for url in files where url.pathExtension == "json" {
            do {
                var r = try Self.decoder.decode(Recording.self, from: Data(contentsOf: url))
                // The app quit mid-way: what was going is now either done or lost, not "transcribing" for ever.
                if r.status == .recording || r.status == .transcribing {
                    r.status = r.text.isEmpty ? .failed : .final
                    if r.text.isEmpty { r.failure = "The app quit before the transcript was made. Retry runs it again." }
                }
                all.append(r)
            } catch {
                problems?(url, error)
            }
        }
        return all.sorted { $0.createdAt > $1.createdAt }
    }

    /// Writes the recording's file (whole, then renamed into place, so a crash never leaves half of it).
    public func save(_ recording: Recording) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = try Self.encoder.encode(recording)
        try data.write(to: file(for: recording.id), options: .atomic)
    }

    public func load(_ id: UUID) -> Recording? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file(for: id)) else { return nil }
        return try? Self.decoder.decode(Recording.self, from: data)
    }

    /// Removes the recording and its audio from disk (not to the Trash).
    public func delete(_ recording: Recording) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: file(for: recording.id))
        if let audio = recording.audioFile {
            try? FileManager.default.removeItem(at: audioFolder.appendingPathComponent(audio))
        }
    }

    /// Removes only the audio, keeping the text as a note.
    public func deleteAudio(of recording: inout Recording) throws {
        if let audio = recording.audioFile {
            lock.lock()
            try? FileManager.default.removeItem(at: audioFolder.appendingPathComponent(audio))
            lock.unlock()
        }
        recording.audioFile = nil
        try save(recording)
    }

    /// Audio files no recording refers to (a crash between writing the audio and its record):
    /// each is a recording to recover.
    public func orphanedAudio(knownTo recordings: [Recording]) -> [URL] {
        let known = Set(recordings.compactMap(\.audioFile))
        let files = (try? FileManager.default.contentsOfDirectory(at: audioFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { !known.contains($0.lastPathComponent) && $0.pathExtension == "wav" }
    }

    // MARK: - The list's own order

    private var orderFile: URL { root.appendingPathComponent("order.json") }

    /// The order you put the list in (ids, top first); empty when you never did.
    public func loadOrder() -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: orderFile), let ids = try? Self.decoder.decode([UUID].self, from: data) else { return [] }
        return ids
    }

    public func saveOrder(_ ids: [UUID]) throws {
        lock.lock()
        defer { lock.unlock() }
        try Self.encoder.encode(ids).write(to: orderFile, options: .atomic)
    }

    /// Markdown of one recording, for export.
    public static func markdown(_ recording: Recording, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "# \(formatter.string(from: recording.createdAt)) · \(TranscriptText.duration(recording.duration))\n\n\(recording.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }
}
