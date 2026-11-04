import Foundation

/// The stream: what the reader reads. `sentences.txt` is the source of truth for ids and
/// `stream.txt` the raw record; `additions.json` says when each paste was added. Transcripts
/// from Holdnote's own recordings join it once each (`sources.json` remembers which).
public enum ReaderStream {
    public struct Addition: Codable, Equatable, Sendable {
        public var added: String
        public var from: String
        public var to: String
        public var sentences: Int
        /// The recording this came from, when it did.
        public var source: String?
    }

    /// Numbers `text` after the last sentence and appends it to stream.txt, sentences.txt and
    /// additions.json. Returns the new sentences (empty for blank text).
    @discardableResult
    public static func append(_ text: String, to folder: NotesFolder, source: String? = nil, now: Date = Date()) throws -> [Sentence] {
        var count = 0
        if let existing = folder.read("sentences.txt"), !existing.isEmpty {
            count = Sentences.parse(existing).count
        } else if let raw = folder.read("stream.txt"), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let first = Sentences.split(raw)
            try folder.write("sentences.txt", Sentences.format(first))
            count = first.count
        }
        let added = Sentences.split(text, startIndex: count)
        guard !added.isEmpty else { return [] }
        try folder.append("stream.txt", (count > 0 ? "\n\n" : "") + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        try folder.append("sentences.txt", Sentences.format(added))
        var adds = folder.readJSON("additions.json", as: [Addition].self) ?? []
        adds.append(Addition(added: ISO8601DateFormatter().string(from: now), from: added[0].id, to: added[added.count - 1].id, sentences: added.count, source: source))
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

    /// Holdnote's recordings that are final, have text and are not yet in the stream, oldest first.
    public static func unfed(_ recordings: [Recording], in folder: NotesFolder) -> [Recording] {
        let fed = sources(in: folder)
        return recordings.filter { $0.status == .final && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !fed.contains($0.id.uuidString) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Adds every unfed transcript to the stream, oldest first, each under a date line so the
    /// reader knows when it was said. Returns how many sentences were added.
    @discardableResult
    public static func feed(_ recordings: [Recording], into folder: NotesFolder, timeZone: TimeZone = .current) throws -> (recordings: Int, sentences: Int) {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var n = 0, s = 0
        for r in unfed(recordings, in: folder) {
            let text = "\(formatter.string(from: r.createdAt)). " + r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let added = try append(text, to: folder, source: r.id.uuidString, now: r.createdAt)
            if !added.isEmpty { n += 1; s += added.count }
        }
        return (n, s)
    }

    /// Where the stream stands: how many sentences, how many not yet read by every active lens,
    /// and whether a night is part way through.
    public struct State: Equatable, Sendable {
        public var count = 0
        public var unread = 0
        public var averageChars = 0
        public var partial = false
        /// stream.txt exists but has not been numbered yet.
        public var rawPresent = false
        public var stale = false
    }

    public static func state(in folder: NotesFolder, config: ReaderConfig, lenses: [Lens]) -> State {
        var st = State()
        let parsed = sentences(in: folder)
        st.count = parsed.count
        st.averageChars = parsed.isEmpty ? 0 : parsed.reduce(0) { $0 + $1.text.count } / parsed.count
        let p = ReaderProgress.load(folder)
        st.stale = p.key != nil && p.key != config.progressKey
        let active = lenses.filter(\.on)
        func pos(_ l: Lens) -> Int { st.stale ? 0 : min(st.count, p.lenses[l.id]?.pos ?? 0) }
        let read = active.isEmpty ? st.count : active.map(pos).min() ?? st.count
        st.unread = st.count - read
        st.partial = !st.stale && (active.contains { pos($0) > 0 && pos($0) < st.count } || (p.questions != nil && !p.questionsDone))
        if st.count == 0, let raw = folder.read("stream.txt"), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { st.rawPresent = true }
        return st
    }

    // MARK: - The estimate

    public struct Plan: Equatable, Sendable {
        public var perWindow: Int
        public var perToken: Int
        public var windows: Int
        public var questionCalls: Int
        public var calls: Int { windows + questionCalls }
        /// A rough duration in seconds.
        public var seconds: Int
        public var durationText: String {
            let h = Double(seconds) / 3600
            return h < 1 ? "\(max(1, Int((Double(seconds) / 60).rounded()))) min" : String(format: "%.1f h", h)
        }
    }

    /// How many sentences fit one window, from the real average sentence length and the tightest active lens.
    public static func plan(config: ReaderConfig, lenses: [Lens], goals: String, unread: Int, averageChars: Int, tokens: TokenEstimator) -> Plan {
        let active = lenses.filter(\.on)
        let budgets = active.map { Night.sentenceBudget(config: config, lens: $0, goals: goals, tokens: tokens) }.filter { $0 > 0 }
        let budget = budgets.min() ?? Int(Double(config.windowTokens) * 0.7)
        let sample = "s00000\t" + String(repeating: "x", count: averageChars > 0 ? averageChars : 90) + "\n"
        let perToken = max(1, budget / max(1, tokens.estimate(sample)))
        let perWindow = config.maxSentences > 0 ? min(config.maxSentences, perToken) : perToken
        let windows = Int((Double(max(0, unread)) / Double(perWindow)).rounded(.up)) * active.count
        let qCalls = config.questionCount > 0 ? 1 + config.questionCount * min(config.morningSteps + 1, 4) : 0
        let calls = windows + qCalls
        return Plan(perWindow: perWindow, perToken: perToken, windows: windows, questionCalls: qCalls, seconds: calls * (config.coolOffSec + 25))
    }

    // MARK: - Questions for the author (the gaps lens)

    public struct Gap: Equatable, Identifiable, Sendable {
        public var id: String { question }
        public var question: String
        public var ids: [String]
    }

    /// Open questions from lenses/gaps.md: those not yet answered or skipped in answers.md.
    public static func gaps(in folder: NotesFolder) -> (open: [Gap], answered: Int)? {
        guard let md = folder.read("lenses/\(Lens.gapsId).md") else { return nil }
        let answered = Set((folder.read("answers.md") ?? "").components(separatedBy: "\n").compactMap { line -> String? in
            guard line.hasPrefix("- Q: ") else { return nil }
            return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        })
        var seen = Set<String>()
        var items: [Gap] = []
        for line in md.components(separatedBy: "\n") {
            guard line.hasPrefix("- ["), let close = line.firstIndex(of: "]") else { continue }
            let ids = line[line.index(line.startIndex, offsetBy: 3)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let q = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if q.isEmpty || q.lowercased().hasPrefix("none") || seen.contains(q) || answered.contains(q) { continue }
            seen.insert(q)
            items.append(Gap(question: q, ids: ids))
        }
        return (items, answered.count)
    }

    /// Records an answer (or a skip, with an empty answer) in answers.md; an answer also joins the
    /// stream as "Q: … A: …" so the next night reads it. Returns the sentences added.
    @discardableResult
    public static func answer(_ gap: Gap, with answer: String, in folder: NotesFolder, now: Date = Date()) throws -> [Sentence] {
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        var added: [Sentence] = []
        if !a.isEmpty { added = try append("Q: \(gap.question)\nA: \(a)", to: folder, now: now) }
        let day = ISO8601DateFormatter().string(from: now).prefix(10)
        let line = "- Q: \(gap.question)\n  A: \(a.isEmpty ? "(skipped)" : a)\n  ids: \(gap.ids.joined(separator: ", ")) · \(day)\n"
        if folder.read("answers.md") == nil {
            try folder.write("answers.md", "# Answers to the reader's questions\n\nQuestions the overnight reader asked, and what the author answered. Each answer was also added to the stream.\n\n" + line)
        } else {
            try folder.append("answers.md", line)
        }
        return added
    }

    // MARK: - Corrections and the conversation

    /// A flagged answer goes into corrections.md, which the morning reads before every answer.
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

    /// One turn of the morning conversation, kept in chat.json in the folder.
    public struct Turn: Codable, Equatable, Identifiable, Sendable {
        public var id = UUID()
        public var q: String
        public var answer: String = ""
        public var evidence: [String] = []
        public var unread: [String] = []
        public var steps = 0
        public var trace: [Morning.TraceStep] = []
        public var opened: [String] = []
        public var error: String?
        public var flagged = false
        public var at = Date()
        public init(q: String) { self.q = q }
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
