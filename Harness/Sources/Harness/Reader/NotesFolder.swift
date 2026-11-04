import Foundation

/// Plain files in the folder the notes are written into. Paths are relative ("lenses/ledger.md").
public struct NotesFolder: Sendable {
    public let root: URL

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public var name: String { root.lastPathComponent }

    /// A safe URL inside the folder, or nil for a path that tries to leave it.
    public func url(_ path: String) -> URL? {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(where: { $0.hasPrefix("/") }) else { return nil }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    public func exists(_ path: String) -> Bool {
        url(path).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// The file's text, or nil when there is none.
    public func read(_ path: String) -> String? {
        guard let u = url(path), let data = try? Data(contentsOf: u) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ path: String, _ text: String) throws {
        guard let u = url(path) else { throw ReaderError("Not a file name inside the folder: \(path)") }
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u, options: .atomic)
    }

    public func append(_ path: String, _ text: String) throws {
        guard let u = url(path) else { throw ReaderError("Not a file name inside the folder: \(path)") }
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: u) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try Data(text.utf8).write(to: u, options: .atomic)
        }
    }

    public func size(_ path: String) -> Int {
        guard let u = url(path), let attrs = try? FileManager.default.attributesOfItem(atPath: u.path) else { return 0 }
        return (attrs[.size] as? Int) ?? 0
    }

    /// Every file, two levels deep, sorted; hidden folders skipped.
    public func list() -> [String] {
        func walk(_ dir: URL, _ prefix: String, _ depth: Int) -> [String] {
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            var out: [String] = []
            for item in items {
                let name = item.lastPathComponent
                if name.hasPrefix(".") { continue }
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir { if depth > 0 { out += walk(item, prefix + name + "/", depth - 1) } }
                else { out.append(prefix + name) }
            }
            return out
        }
        return walk(root, "", 2).sorted()
    }

    public func readJSON<T: Decodable>(_ path: String, as type: T.Type) -> T? {
        guard let u = url(path), let data = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func writeJSON<T: Encodable>(_ path: String, _ value: T) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(path, String(decoding: try e.encode(value), as: UTF8.self))
    }
}

public struct ReaderError: Error, LocalizedError, Sendable {
    public let message: String
    /// Will not fix itself between calls (a bad request, a missing model, a refused origin).
    public let fatal: Bool
    public let cancelled: Bool
    public init(_ message: String, fatal: Bool = false, cancelled: Bool = false) { self.message = message; self.fatal = fatal; self.cancelled = cancelled }
    public var errorDescription: String? { message }
    public static let cancelled = ReaderError("cancelled", cancelled: true)
}

/// Resume state for the night: where each lens has read to, its notebook and entries so far,
/// and the question pass. Written after every window.
public struct ReaderProgress: Codable, Equatable, Sendable {
    public struct LensState: Codable, Equatable, Sendable {
        public var pos = 0
        public var notebook = ""
        public var entries: [LensParse.Entry] = []
        public var skipped: [Skipped] = []
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pos = try c.decodeIfPresent(Int.self, forKey: .pos) ?? 0
            notebook = try c.decodeIfPresent(String.self, forKey: .notebook) ?? ""
            entries = try c.decodeIfPresent([LensParse.Entry].self, forKey: .entries) ?? []
            skipped = try c.decodeIfPresent([Skipped].self, forKey: .skipped) ?? []
        }
    }
    public struct Skipped: Codable, Equatable, Sendable {
        public var from: String
        public var to: String
        public var error: String
        public init(from: String, to: String, error: String) { self.from = from; self.to = to; self.error = error }
    }
    public struct QA: Codable, Equatable, Sendable {
        public var q: String
        public var answer: String
        public var evidence: [String]
        public var opened: [String]
        public init(q: String, answer: String, evidence: [String], opened: [String]) { self.q = q; self.answer = answer; self.evidence = evidence; self.opened = opened }
    }

    public var key: String?
    public var lenses: [String: LensState] = [:]
    public var questions: [String]?
    public var qIndex = 0
    public var qa: [QA] = []
    public var qPos: Int?
    public var questionsDone = false

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        lenses = try c.decodeIfPresent([String: LensState].self, forKey: .lenses) ?? [:]
        questions = try c.decodeIfPresent([String].self, forKey: .questions)
        qIndex = try c.decodeIfPresent(Int.self, forKey: .qIndex) ?? 0
        qa = try c.decodeIfPresent([QA].self, forKey: .qa) ?? []
        qPos = try c.decodeIfPresent(Int.self, forKey: .qPos)
        questionsDone = try c.decodeIfPresent(Bool.self, forKey: .questionsDone) ?? false
    }

    public static func load(_ folder: NotesFolder) -> ReaderProgress {
        folder.readJSON("progress.json", as: ReaderProgress.self) ?? ReaderProgress()
    }
}
