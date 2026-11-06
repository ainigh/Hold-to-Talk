import Foundation

/// The stream: what the reader reads. `sentences.txt` is the source of truth for ids and
/// `stream.txt` the raw record; `additions.json` says when each addition was made and where it
/// came from. Transcripts from Holdnote's own recordings join it once each, once they settle
/// (`sources.json` remembers which); an edited transcript can join again as a revision.
public enum ReaderStream {
    public struct Addition: Codable, Equatable, Sendable {
        public var added: String
        public var from: String
        public var to: String
        public var sentences: Int
        /// The recording this came from, when it did.
        public var source: String?
        /// A short fingerprint of the recording's text as it joined, so a later edit can be noticed.
        public var hash: String?
        /// What it was: nil for a transcript or a paste, "answer" or "revision".
        public var kind: String?
    }

    /// A short, stable fingerprint of a text (FNV-1a, 64 bits), whitespace-insensitive.
    public static func fingerprint(_ text: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.split(whereSeparator: \.isWhitespace).joined(separator: " ").utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// Numbers stream.txt into sentences.txt when only the raw stream is there. Says whether it did.
    @discardableResult
    public static func number(_ folder: NotesFolder) throws -> Bool {
        if let existing = folder.read("sentences.txt"), !existing.isEmpty { return false }
        guard let raw = folder.read("stream.txt"), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        try folder.write("sentences.txt", Sentences.format(Sentences.split(raw)))
        return true
    }

    /// Numbers `text` after the last sentence and appends it to stream.txt, sentences.txt and
    /// additions.json. Returns the new sentences (empty for blank text).
    @discardableResult
    public static func append(_ text: String, to folder: NotesFolder, source: String? = nil, hash: String? = nil, kind: String? = nil, now: Date = Date()) throws -> [Sentence] {
        var count = 0
        // sentences.txt is yours to edit: new ids follow the highest one there (a deleted line
        // must not make the next sentence reuse an id), on a line of their own.
        var joint = ""
        if let existing = folder.read("sentences.txt"), !existing.isEmpty {
            let parsed = Sentences.parse(existing)
            count = parsed.compactMap { Sentences.number($0.id) }.max() ?? parsed.count
            if !existing.hasSuffix("\n") { joint = "\n" }
        } else if let raw = folder.read("stream.txt"), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let first = Sentences.split(raw)
            try folder.write("sentences.txt", Sentences.format(first))
            count = first.count
        }
        let added = Sentences.split(text, startIndex: count)
        guard !added.isEmpty else { return [] }
        try folder.append("stream.txt", (count > 0 ? "\n\n" : "") + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        try folder.append("sentences.txt", joint + Sentences.format(added))
        var adds = folder.readJSON("additions.json", as: [Addition].self) ?? []
        adds.append(Addition(added: ISO8601DateFormatter().string(from: now), from: added[0].id, to: added[added.count - 1].id, sentences: added.count, source: source, hash: hash, kind: kind))
        try folder.writeJSON("additions.json", adds)
        if let source {
            var sources = folder.readJSON("sources.json", as: [String: String].self) ?? [:]
            sources[source] = "\(added[0].id)–\(added[added.count - 1].id)"
            try folder.writeJSON("sources.json", sources)
        }
        return added
    }

    public static func sentences(in folder: NotesFolder) -> [Sentence] {
        folder.read("sentences.txt").map(Sentences.parse) ?? []
    }

    public static func additions(in folder: NotesFolder) -> [Addition] {
        folder.readJSON("additions.json", as: [Addition].self) ?? []
    }

    /// Ids of the recordings already in the stream.
    public static func sources(in folder: NotesFolder) -> Set<String> {
        Set((folder.readJSON("sources.json", as: [String: String].self) ?? [:]).keys)
    }

    /// The transcripts not yet in the stream, oldest first; or, with `keepOrder`, in the order
    /// given (the list's own order, read from the bottom up: what came first goes in first).
    public static func unfed(_ recordings: [Recording], in folder: NotesFolder, keepOrder: Bool = false) -> [Recording] {
        let fed = sources(in: folder)
        let left = recordings.filter { $0.status == .final && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !fed.contains($0.id.uuidString) }
        return keepOrder ? left : left.sorted { $0.createdAt < $1.createdAt }
    }

    /// Adds every unfed transcript to the stream, oldest first, each under a date line so the
    /// reader knows when it was said. Returns how many recordings and sentences were added.
    @discardableResult
    public static func feed(_ recordings: [Recording], into folder: NotesFolder, keepOrder: Bool = false, timeZone: TimeZone = .current) throws -> (recordings: Int, sentences: Int) {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var n = 0, s = 0
        for r in unfed(recordings, in: folder, keepOrder: keepOrder) {
            let text = "\(formatter.string(from: r.createdAt)). " + r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let added = try append(text, to: folder, source: r.id.uuidString, hash: fingerprint(r.text), now: r.createdAt)
            if !added.isEmpty { n += 1; s += added.count }
        }
        return (n, s)
    }

    // MARK: - Where things came from

    /// A run of sentences and the recording it came from.
    public struct Span: Equatable, Sendable {
        public var from: Int
        public var to: Int
        public var source: String?
        public var kind: String?
        public var added: String
    }

    /// Every addition as a run of sentence numbers, in stream order.
    public static func spans(in folder: NotesFolder) -> [Span] {
        additions(in: folder).compactMap { a in
            guard let f = Sentences.number(a.from), let t = Sentences.number(a.to) else { return nil }
            return Span(from: f, to: t, source: a.source, kind: a.kind, added: a.added)
        }
    }

    /// The span holding sentence number `n` (spans in stream order).
    public static func span(of n: Int, in spans: [Span]) -> Span? {
        var lo = 0, hi = spans.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if n < spans[mid].from { hi = mid - 1 } else if n > spans[mid].to { lo = mid + 1 } else { return spans[mid] }
        }
        return nil
    }

    /// Where a recording stands with the reader.
    public enum Standing: Equatable, Sendable {
        /// No text yet, or not final.
        case notReady
        /// Final, not in the stream.
        case waiting
        /// In the stream as these sentence numbers (every addition from it, revisions included);
        /// `edited` when the text changed after it last joined.
        case inStream(ids: [Int], edited: Bool)
    }

    /// Where a recording stands, from the additions (additions.json): every addition it made,
    /// and whether its text changed after the last time it joined.
    public static func standing(of r: Recording, additions all: [Addition]) -> Standing {
        let adds = all.filter { $0.source == r.id.uuidString }
        guard !adds.isEmpty else {
            return r.status == .final && !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .waiting : .notReady
        }
        let ids = adds.flatMap { a -> [Int] in
            guard let f = Sentences.number(a.from), let t = Sentences.number(a.to), f <= t else { return [] }
            return Array(f...t)
        }
        // The last transcript or revision of it; an answer given by voice is not its text.
        let last = adds.last { $0.kind == nil || $0.kind == "revision" }
        let edited = last?.hash.map { $0 != fingerprint(r.text) } ?? false
        return .inStream(ids: ids, edited: edited && !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    public static func standing(of r: Recording, in folder: NotesFolder) -> Standing {
        standing(of: r, additions: additions(in: folder))
    }

    /// An edited transcript joins again, whole, marked as a revision of what it replaces, so the
    /// reader reads the correction without earlier ids changing.
    @discardableResult
    public static func revise(_ r: Recording, in folder: NotesFolder, timeZone: TimeZone = .current, now: Date = Date()) throws -> [Sentence] {
        let prior = additions(in: folder).filter { $0.source == r.id.uuidString && ($0.kind == nil || $0.kind == "revision") }
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let was = prior.last.map { " (it replaces \($0.from)–\($0.to))" } ?? ""
        let text = "Corrected transcript of what the author said at \(formatter.string(from: r.createdAt))\(was). " + r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return try append(text, to: folder, source: r.id.uuidString, hash: fingerprint(r.text), kind: "revision", now: now)
    }

    // MARK: - Where the stream stands

    /// How many sentences, how many not yet read by every active lens, and the questions.
    public struct State: Equatable, Sendable {
        public var count = 0
        public var unread = 0
        public var averageChars = 0
        /// Some lens is part way through the stream.
        public var partial = false
        /// stream.txt exists but has not been numbered yet.
        public var rawPresent = false
        /// Questions about the goals that need an answer, of how many.
        public var questionsPending = 0
        public var questionsTotal = 0
        /// The questions have not been written from the goals yet (or the goals changed).
        public var questionsToWrite = false
        public init() {}
        /// There is reading or answering to do.
        public var hasWork: Bool { unread > 0 || rawPresent || questionsPending > 0 || (questionsToWrite && count > 0) }
    }

    public static func state(in folder: NotesFolder, config: ReaderConfig, lenses: [Lens], goals: String = "") -> State {
        var st = State()
        let parsed = sentences(in: folder)
        st.count = parsed.count
        st.averageChars = parsed.isEmpty ? 0 : parsed.reduce(0) { $0 + $1.text.count } / parsed.count
        let p = ReaderProgress.load(folder)
        let active = lenses.filter(\.on)
        func pos(_ l: Lens) -> Int { min(st.count, p.lenses[l.id]?.pos ?? 0) }
        let read = active.isEmpty ? st.count : active.map(pos).min() ?? st.count
        st.unread = st.count - read
        st.partial = active.contains { pos($0) > 0 && pos($0) < st.count }
        if st.count == 0, let raw = folder.read("stream.txt"), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { st.rawPresent = true }
        let pinned = Self.pinned(in: folder)
        st.questionsToWrite = config.questionCount > 0 && (p.questions == nil || (p.qGoals ?? "") != goals.trimmingCharacters(in: .whitespacesAndNewlines))
        st.questionsTotal = Reading.questionList(progress: p, pinned: pinned).count
        st.questionsPending = Reading.pendingQuestions(progress: p, pinned: pinned, count: st.count, refresh: config.questionRefresh).count
        return st
    }

    // MARK: - The estimate

    public struct Plan: Equatable, Sendable {
        /// Sentences read at a time.
        public var perChunk: Int
        /// Calls per chunk, with notebooks half full.
        public var callsPerChunk: Int
        public var chunks: Int
        public var questionCalls: Int
        public var calls: Int { chunks * callsPerChunk + questionCalls }
        /// A rough duration in seconds.
        public var seconds: Int
        public var durationText: String {
            let h = Double(seconds) / 3600
            return h < 1 ? "\(max(1, Int((Double(seconds) / 60).rounded()))) min" : String(format: "%.1f h", h)
        }
    }

    /// How the unread part will be read: sentences per chunk from the real average sentence
    /// length, and how many calls each chunk takes with notebooks half full.
    public static func plan(config: ReaderConfig, lenses: [Lens], goals: String, unread: Int, averageChars: Int, pendingQuestions: Int = 0, tokens: TokenEstimator) -> Plan {
        let active = lenses.filter(\.on)
        let budget = Reading.chunkBudget(config: config, lenses: active, goals: goals, tokens: tokens)
        let avg = averageChars > 0 ? averageChars : 90
        let perToken = max(1, budget / max(1, tokens.estimate("s00000\t" + String(repeating: "x", count: avg) + "\n")))
        let perChunk = config.chunkSentences > 0 ? min(config.chunkSentences, perToken) : perToken
        let sample = (0..<perChunk).map { Sentence(id: Sentences.makeId($0 + 1), text: String(repeating: "x", count: avg)) }
        let half = String(repeating: "x", count: Int(Double(config.notebookTokens / 2) * tokens.charsPerToken))
        let notebooks = Dictionary(active.filter(\.carry).map { ($0.id, half) }, uniquingKeysWith: { a, _ in a })
        let calls = active.isEmpty ? 0 : Reading.groups(active, all: lenses, chunk: sample, notebooks: notebooks, goals: goals, config: config, tokens: tokens).count
        let chunks = Int((Double(max(0, unread)) / Double(max(1, perChunk))).rounded(.up))
        let qCalls = pendingQuestions * min(config.askSteps + 1, 4)
        let total = chunks * calls + qCalls
        return Plan(perChunk: perChunk, callsPerChunk: calls, chunks: chunks, questionCalls: qCalls, seconds: total * (config.coolOffSec + 25))
    }

    // MARK: - Questions for the author (the gaps lens)

    public struct Gap: Equatable, Identifiable, Sendable {
        public var id: String { question }
        public var question: String
        public var ids: [String]
    }

    /// Two questions are the same when their words are.
    static func key(_ q: String) -> String {
        q.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// Open questions from lenses/gaps.md: those not yet answered or skipped in answers.md, and
    /// not settled by the text since ("settled: …" entries).
    public static func gaps(in folder: NotesFolder) -> (open: [Gap], answered: Int)? {
        guard let md = folder.read("lenses/\(Lens.gapsId).md") else { return nil }
        let answeredLines = (folder.read("answers.md") ?? "").components(separatedBy: "\n").compactMap { line -> String? in
            guard line.hasPrefix("- Q: ") else { return nil }
            return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        var done = Set(answeredLines.map(key))
        var seen = Set<String>()
        var items: [Gap] = []
        for line in md.components(separatedBy: "\n") {
            // The entries end where the notebook (or the list of skipped chunks) begins.
            if line.hasPrefix("## ") { break }
            guard line.hasPrefix("- ["), let close = line.firstIndex(of: "]") else { continue }
            let ids = line[line.index(line.startIndex, offsetBy: 3)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let q = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            let low = q.lowercased()
            if low.hasPrefix("settled:") || low.hasPrefix("settled ") || low.hasPrefix("resolved:") {
                done.insert(key(String(q.drop(while: { $0 != ":" && $0 != " " }).dropFirst())))
                continue
            }
            let k = key(q)
            if q.isEmpty || low.hasPrefix("none") || k.isEmpty || seen.contains(k) { continue }
            seen.insert(k)
            items.append(Gap(question: q, ids: ids))
        }
        return (items.filter { !done.contains(key($0.question)) }, answeredLines.count)
    }

    /// Records an answer (or a skip, with an empty answer) in answers.md; an answer also joins the
    /// stream as "Q: … A: …" so it is read like everything else. `source` is the recording the
    /// answer was spoken in, which then does not join the stream a second time.
    @discardableResult
    public static func answer(_ gap: Gap, with answer: String, in folder: NotesFolder, source: String? = nil, now: Date = Date()) throws -> [Sentence] {
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        var added: [Sentence] = []
        if !a.isEmpty { added = try append("Q: \(gap.question)\nA: \(a)", to: folder, source: source, kind: "answer", now: now) }
        let day = ISO8601DateFormatter().string(from: now).prefix(10)
        let line = "- Q: \(gap.question)\n  A: \(a.isEmpty ? "(skipped)" : a.replacingOccurrences(of: "\n", with: " "))\n  ids: \(gap.ids.joined(separator: ", ")) · \(day)\n"
        if folder.read("answers.md") == nil {
            try folder.write("answers.md", "# Answers to the reader's questions\n\nQuestions the reader asked, and what the author answered. Each answer was also added to the stream.\n\n" + line)
        } else {
            try folder.append("answers.md", line)
        }
        return added
    }

    // MARK: - Questions the author keeps asked

    /// Questions the author pinned: kept answered and refreshed like the ones from the goals.
    public static func pinned(in folder: NotesFolder) -> [String] {
        folder.readJSON("pinned.json", as: [String].self) ?? []
    }

    public static func pin(_ question: String, in folder: NotesFolder) throws {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        var list = pinned(in: folder)
        if !list.contains(q) { list.append(q) }
        try folder.writeJSON("pinned.json", list)
    }

    public static func unpin(_ question: String, in folder: NotesFolder) throws {
        try folder.writeJSON("pinned.json", pinned(in: folder).filter { $0 != question })
    }

    /// The answers kept for the questions, by question.
    public static func answers(in folder: NotesFolder) -> [String: ReaderProgress.QA] {
        Dictionary(ReaderProgress.load(folder).qa.map { ($0.q, $0) }, uniquingKeysWith: { _, b in b })
    }

    // MARK: - Transcripts settling

    /// When a transcript has settled enough to join the stream: final, with text, and unchanged for
    /// `seconds` (so a correction typed right after it lands goes in with it). Recordings already
    /// older than that when first seen count as settled.
    public struct Settle: Sendable {
        var seen: [UUID: (hash: String, since: Date)] = [:]
        public init() {}

        public mutating func ready(_ recordings: [Recording], fed: Set<String>, now: Date = Date(), seconds: TimeInterval) -> [Recording] {
            var out: [Recording] = []
            var live = Set<UUID>()
            for r in recordings where r.status == .final && !fed.contains(r.id.uuidString) && !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                live.insert(r.id)
                let h = fingerprint(r.text)
                if seen[r.id]?.hash != h {
                    let old = seen[r.id] == nil && r.createdAt.addingTimeInterval(r.duration + seconds) < now
                    seen[r.id] = (h, old ? .distantPast : now)
                }
                if let s = seen[r.id], now.timeIntervalSince(s.since) >= seconds { out.append(r) }
            }
            seen = seen.filter { live.contains($0.key) }
            return out
        }

        /// When the next one will be ready, if any is waiting.
        public func nextReady(seconds: TimeInterval) -> Date? {
            seen.values.map { $0.since.addingTimeInterval(seconds) }.min()
        }
    }

    // MARK: - Corrections and the conversation

    /// A flagged answer goes into corrections.md, which is read before every answer.
    public static func flag(question: String, answer: String, note: String, in folder: NotesFolder, now: Date = Date()) throws {
        let day = ISO8601DateFormatter().string(from: now).prefix(10)
        let given = answer.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(300)
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = "- \(day) — Q: \(question)\n  A given: \(given)\n  Correction: \(n.isEmpty ? "the author marked this answer as wrong" : n)\n"
        if folder.read("corrections.md") == nil {
            try folder.write("corrections.md", "# Corrections\n\nThe author's corrections to earlier answers. The morning reads this before answering.\n\n" + line)
        } else {
            try folder.append("corrections.md", line)
        }
    }

    /// One turn of the conversation, kept in chat.json in the folder.
    public struct Turn: Codable, Equatable, Identifiable, Sendable {
        public var id = UUID()
        public var q: String
        public var answer: String = ""
        public var evidence: [String] = []
        public var unread: [String] = []
        public var steps = 0
        public var trace: [Asking.TraceStep] = []
        public var opened: [String] = []
        public var error: String?
        public var flagged = false
        public var at = Date()
        /// The recording the question was about, and how it was named to the model.
        public var about: String?
        public var aboutLabel: String?
        public init(q: String, about: String? = nil, aboutLabel: String? = nil) { self.q = q; self.about = about; self.aboutLabel = aboutLabel }
    }

    public static func loadChat(in folder: NotesFolder) -> [Turn] {
        guard let u = folder.url("chat.json"), let data = try? Data(contentsOf: u) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode([Turn].self, from: data)) ?? []
    }

    public static func saveChat(_ turns: [Turn], in folder: NotesFolder) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try folder.write("chat.json", String(decoding: try e.encode(Array(turns.suffix(60))), as: UTF8.self))
    }
}
