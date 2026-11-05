import Foundation

/// Asking: one question answered with three moves, open a note file (one page at a time), read
/// sentences by id, or find the sentences a word appears in (a page at a time), and a fourth
/// when an embedding model is there: the sentences nearest in meaning to a phrase. The model
/// replies in plain lines; `LensParse.action` reads them.
public enum Asking {
    public struct TraceStep: Codable, Equatable, Sendable {
        public var action: String
        public var file: String
        public var offset: Int
        public var ids: [String]
        public var why: String
    }

    public struct Answer: Codable, Equatable, Sendable {
        public var answer: String
        public var evidence: [String]
        /// Cited but never read during this answer.
        public var unread: [String]
        public var steps: Int
        public var trace: [TraceStep]
        public var opened: [String]
    }

    public struct Options: Sendable {
        public var includeQuestions = true
        public var coolOffSec = 0
        public var stopped: @Sendable () -> Bool = { false }
        public var onStep: (@Sendable (String) -> Void)?
        public var onCall: (@Sendable (String, String, String) -> Void)?
        public var onToken: (@Sendable (String, String) -> Void)?
        public var log: (@Sendable (String) -> Void)?
        /// What the question is about, said to the model (e.g. "your recording of Tuesday 14:05").
        public var about: String?
        /// Sentence ids the question is about; the model is told to read them first.
        public var focus: [String] = []
        /// The words the stream uses most (one per line: word, kind, times), for context and as
        /// things worth a FIND. Empty for none.
        public var words = ""
        /// The SIMILAR move: given a phrase and an offset, the page of nearest sentences and the
        /// ids on it. Nil when there is no embedding model; the prompt then does not offer it.
        public var similar: (@Sendable (String, Int) async throws -> (text: String, ids: [String]))?
        public init() {}
    }

    public static func system(goals: String, toc: String, corrections: String, words: String = "", similar: Bool = false) -> String {
        let id42 = Sentences.makeId(42), id43 = Sentences.makeId(43)
        let similarBlock = similar ? """

        SIMILAR <a phrase, a few words that say what you are looking for> offset <match number, 0 to start>
        WHY: one line on what you are looking for
        """ : ""
        let similarRule = similar ? " When the question does not name a thing to FIND (a feeling, a theme, a situation), use SIMILAR: it returns the sentences nearest in meaning to your phrase, best first, a page at a time, with ids." : ""
        var s = """
        You answer questions about the author's own stream of thoughts, spoken and written. The stream has been read through several lenses and notes were written into files; every note line cites sentence ids like \(id42). You cannot see the stream directly, but you can search it for a word\(similar ? " or for a meaning" : ""). \(Reading.transcriptNote)

        Each turn, reply with exactly ONE action, in this plain format and nothing else:

        OPEN <file name from the list below> offset <line number, 0 to start>
        WHY: one line on what you expect to find

        READ \(id42) \(id43)
        WHY: one line on why these sentences

        FIND <a word or short phrase, as the author would have said it> offset <match number, 0 to start>
        WHY: one line on what you are looking for
        \(similarBlock)
        ANSWER
        Your answer, in prose, as many lines as you need.
        EVIDENCE: \(id42), \(id43)

        Rules. Start by opening the file most likely to hold the answer (the list below says what each file is for), or by FIND when the question names a thing: FIND returns every sentence the word appears in, with its id, a page at a time.\(similarRule) Before answering, READ or FIND\(similar ? " or SIMILAR" : "") the raw sentences you intend to cite; cite only ids you have seen in a result. When asked how the author felt, quote their words rather than paraphrasing. For "is X present" or "what things are there" questions, check the ledger or FIND the word, and say which files you checked when something is absent. Say plainly what you are unsure of. Answer in the second person ("you"), as a thoughtful reader of the author's notes, not as a search engine. Do not ask the author questions back; answer with what you have. Never wrap the reply in JSON or code fences.

        ## The author's goals
        \(goals)

        ## Files you can open
        \(toc)

        """
        if !words.isEmpty { s += "\n## The words the stream uses most (word · kind · times), the ones worth a FIND\n\(words)\n" }
        if !corrections.isEmpty { s += "\n## The author's corrections to earlier answers (trust these over the notes)\n\(corrections)" }
        return s
    }

    /// The sentences `word` appears in (case-insensitive, as a whole word or the start of one),
    /// from the `offset`th match on, within `budget` tokens: one `id<TAB>text` per line and a
    /// footer saying where the page ends. Returns the ids shown, so they count as read.
    public static func find(_ word: String, in sentences: [Sentence], offset: Int, budget: Int, tokens: TokenEstimator) -> (text: String, ids: [String]) {
        let needle = fold(word)
        guard !needle.isEmpty else { return ("(no word given)", []) }
        let matches = sentences.filter { contains(fold($0.text, keepingEnds: true), needle) }
        guard !matches.isEmpty else { return ("No sentence contains “\(word)”. Try another form of the word (as it would have been said), or a shorter one.", []) }
        guard offset < matches.count else { return ("No more matches for “\(word)”: \(matches.count) in all, offsets 0–\(matches.count - 1).", []) }
        let start = max(0, offset)
        var used = 0, end = start
        var lines: [String] = []
        while end < matches.count {
            let line = "\(matches[end].id)\t\(matches[end].text)"
            let t = tokens.estimate(line) + 1
            if used + t > budget, end > start { break }
            lines.append(line); used += t; end += 1
        }
        let footer = end < matches.count
            ? "\n[matches \(start)–\(end - 1) of \(matches.count) for “\(word)”; to continue, FIND the same word offset \(end)]"
            : "\n[matches \(start)–\(end - 1) of \(matches.count) for “\(word)”; that is all of them]"
        return (lines.joined(separator: "\n") + footer, matches[start..<end].map(\.id))
    }

    /// One page of SIMILAR hits (best first), from the `offset`th on, within `budget` tokens:
    /// `id<TAB>text` lines with the similarity, and a footer like FIND's.
    public static func similarPage(_ phrase: String, hits: [(n: Int, score: Float)], sentences byId: [String: String], offset: Int, budget: Int, tokens: TokenEstimator) -> (text: String, ids: [String]) {
        guard !hits.isEmpty else { return ("Nothing in the stream is close to “\(phrase)”.", []) }
        guard offset < hits.count else { return ("No more matches for “\(phrase)”: \(hits.count) in all, offsets 0–\(hits.count - 1).", []) }
        let start = max(0, offset)
        var used = 0, end = start
        var lines: [String] = []
        var ids: [String] = []
        while end < hits.count {
            let id = Sentences.makeId(hits[end].n)
            let line = "\(id)\t\(byId[id] ?? "(no such sentence)")\t(\(String(format: "%.2f", hits[end].score)))"
            let t = tokens.estimate(line) + 1
            if used + t > budget, end > start { break }
            lines.append(line); ids.append(id); used += t; end += 1
        }
        let footer = end < hits.count
            ? "\n[matches \(start)–\(end - 1) of \(hits.count) nearest to “\(phrase)”, best first; to continue, SIMILAR the same phrase offset \(end)]"
            : "\n[matches \(start)–\(end - 1) of \(hits.count) nearest to “\(phrase)”; that is all of them]"
        return (lines.joined(separator: "\n") + footer, ids)
    }

    /// Lowercased, apostrophes straightened, runs of whitespace one space, and (for the needle)
    /// punctuation off the ends, so "Lisbon." finds Lisbon and "the  move" finds "the move".
    static func fold(_ s: String, keepingEnds: Bool = false) -> String {
        var t = s.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return keepingEnds ? t : t.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    /// `needle` (folded) is in `text` (folded) at a word's start: "plan" finds "plans" and
    /// "planning", not "airplane".
    static func contains(_ text: String, _ needle: String) -> Bool {
        let low = text
        var search = low.startIndex
        while let r = low.range(of: needle, range: search..<low.endIndex) {
            if r.lowerBound == low.startIndex || !(low[low.index(before: r.lowerBound)].isLetter) { return true }
            search = r.upperBound
        }
        return false
    }

    /// One page of a file, by line offset, within `budget` tokens.
    public static func page(of text: String, offset: Int, budget: Int, tokens: TokenEstimator) -> String {
        let lines = text.components(separatedBy: "\n")
        let start = max(0, min(offset, lines.count))
        var used = 0, end = start
        while end < lines.count {
            let t = tokens.estimate(lines[end]) + 1
            if used + t > budget, end > start { break }
            used += t; end += 1
        }
        let body = lines[start..<end].joined(separator: "\n")
        let more = end < lines.count ? "\n[lines \(start)–\(end - 1) of \(lines.count); to continue, OPEN the same file with offset \(end)]" : "\n[lines \(start)–\(end - 1); end of file]"
        return body + more
    }

    /// The files the model may open, with what each is for.
    public static func tableOfContents(folder: NotesFolder, lenses: [Lens], includeQuestions: Bool) -> [String] {
        let files = folder.list()
        var toc: [String] = []
        for l in lenses where l.on && files.contains("lenses/\(l.id).md") { toc.append("- lenses/\(l.id).md — \(l.purpose.isEmpty ? l.title : l.purpose)") }
        if includeQuestions, files.contains("questions.md") { toc.append("- questions.md — \(Lens.questionsPurpose)") }
        for f in files where !f.hasPrefix("lenses/") && f.hasSuffix(".md") && !["index.md", "goals.md", "corrections.md", "questions.md"].contains(f) { toc.append("- \(f)") }
        return toc
    }

    /// Answers one question.
    public static func ask(_ question: String, folder: NotesFolder, config: ReaderConfig, lenses: [Lens], sentences: [Sentence],
                           chat: MeasuredChat, options: Options = Options()) async throws -> Answer {
        let tokens = chat.tokens
        let goals = folder.read("goals.md") ?? "(no goals written)"
        let corrections = folder.read("corrections.md") ?? ""
        let byId = Dictionary(sentences.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
        let tocLines = tableOfContents(folder: folder, lenses: lenses, includeQuestions: options.includeQuestions)
        let system = Self.system(goals: goals, toc: tocLines.isEmpty ? "(no note files yet; nothing has been read)" : tocLines.joined(separator: "\n"),
                                 corrections: tokens.clip(corrections, 600).text, words: tokens.clip(options.words, 500).text, similar: options.similar != nil)
        var steps: [(action: String, result: String)] = []
        var trace: [TraceStep] = []
        var opened: [String] = []
        var evidenceRead = Set<String>()

        func buildUser(final: Bool) -> String {
            var parts = ["## Question\n\(question)"]
            if !options.focus.isEmpty {
                let ids = options.focus.count > 2 ? "\(options.focus[0])–\(options.focus[options.focus.count - 1])" : options.focus.joined(separator: ", ")
                parts[0] += "\n\nThis question is about \(options.about ?? "a part of the stream"): sentences \(ids). READ them first, then open notes if you need more."
            }
            let fixed = tokens.estimate(system) + tokens.estimate(parts[0]) + 120
            let budget = config.windowTokens - fixed
            var shown = steps
            var total = shown.reduce(0) { $0 + tokens.estimate($1.action) + tokens.estimate($1.result) }
            var i = 0
            while i < shown.count, total > budget {
                total -= tokens.estimate(shown[i].result)
                shown[i].result = "[result elided to fit the window; open again if needed]"
                total += tokens.estimate(shown[i].result)
                i += 1
            }
            for (k, s) in shown.enumerated() { parts.append("## Step \(k + 1)\nYou did: \(s.action)\nResult:\n\(s.result)") }
            parts.append(final ? "## Now answer\nYou have used all your steps. Reply with ANSWER now, with what you have, citing only ids you read." : "## Next action (step \(steps.count + 1) of \(config.askSteps))")
            return parts.joined(separator: "\n\n")
        }

        for step in 0...config.askSteps {
            let final = step == config.askSteps
            let user = buildUser(final: final)
            options.onStep?(final ? "writing the answer" : step == 0 ? "deciding where to look" : "step \(step + 1): deciding what to do next")
            options.onCall?("Asking, step \(step + 1) of \(config.askSteps + 1)", system, user)
            let res = try await chat.call(ChatRequest(system: system, user: user, label: "ask s\(step + 1)", onToken: options.onToken), config: config, budget: config.windowTokens)
            let a = LensParse.action(res.text)
            switch a {
            case let .open(file, offset, why): trace.append(TraceStep(action: "open", file: file, offset: offset, ids: [], why: why))
            case let .read(ids, why): trace.append(TraceStep(action: "read", file: "", offset: 0, ids: ids, why: why))
            case let .find(word, offset, why): trace.append(TraceStep(action: "find", file: word, offset: offset, ids: [], why: why))
            case let .similar(phrase, offset, why): trace.append(TraceStep(action: "similar", file: phrase, offset: offset, ids: [], why: why))
            case let .answer(_, _, why, _): trace.append(TraceStep(action: "answer", file: "", offset: 0, ids: [], why: why))
            case let .none(why): trace.append(TraceStep(action: "none", file: "", offset: 0, ids: [], why: why))
            }
            var answered: (String, [String])? = nil
            if case let .answer(text, evidence, _, implied) = a {
                if implied { options.log?("the reply had no action word; taken as the answer") }
                answered = (text, evidence)
            } else if final || { if case .none = a { return true }; return false }() {
                answered = ("", [])
            }
            if let (text, evidence) = answered {
                var seen = Set<String>()
                let ev = evidence.compactMap(Sentences.normId).filter { byId[$0] != nil && seen.insert($0).inserted }
                let unread = ev.filter { !evidenceRead.contains($0) }
                if !unread.isEmpty { options.log?("cited \(unread.count) ids it never read: \(unread.joined(separator: ", "))") }
                let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return Answer(answer: answer.isEmpty ? "(no answer given)" : answer, evidence: ev, unread: unread, steps: steps.count, trace: trace, opened: opened)
            }
            // Rest between tool steps only while reading; the caller rests after the answer itself.
            if options.coolOffSec > 0 {
                let until = Date().addingTimeInterval(Double(options.coolOffSec))
                while Date() < until, !options.stopped() {
                    try await Task.sleep(nanoseconds: UInt64(min(1, until.timeIntervalSinceNow) * 1e9))
                }
                if options.stopped() { throw ReaderError.cancelled }
            }
            switch a {
            case let .open(file, offset, _):
                var name = file.trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("./") { name.removeFirst(2) } else if name.hasPrefix("/") { name.removeFirst() }
                name = name.replacingOccurrences(of: "..", with: "")
                options.onStep?("opening \(name.isEmpty ? "a file" : name)\(offset > 0 ? " at line \(offset)" : "")")
                let text = name.isEmpty ? nil : folder.read(name)
                if !opened.contains(name) { opened.append(name) }
                let names = tocLines.map { String($0.dropFirst(2)).components(separatedBy: " — ")[0] }.joined(separator: ", ")
                steps.append(("OPEN \(name) offset \(offset)", text.map { page(of: $0, offset: offset, budget: config.pageTokens, tokens: tokens) } ?? "No file named \(name). Files: \(names)"))
            case let .read(ids, _):
                let ids = Array(ids.prefix(40))
                options.onStep?("reading \(ids.count) sentence\(ids.count == 1 ? "" : "s"): \(ids.prefix(6).joined(separator: ", "))\(ids.count > 6 ? "…" : "")")
                let out = ids.map { id -> String in
                    if let t = byId[id] { evidenceRead.insert(id); return "\(id)\t\(t)" }
                    return "\(id)\t(no such sentence)"
                }
                let joined = tokens.clip(out.joined(separator: "\n"), config.pageTokens).text
                steps.append(("READ \(ids.joined(separator: " "))", joined.isEmpty ? "(no ids given)" : joined))
            case let .find(word, offset, _):
                options.onStep?("finding “\(word)”\(offset > 0 ? " from match \(offset)" : "")")
                let found = find(word, in: sentences, offset: offset, budget: config.pageTokens, tokens: tokens)
                for id in found.ids { evidenceRead.insert(id) }
                steps.append(("FIND \(word) offset \(offset)", found.text))
            case let .similar(phrase, offset, _):
                options.onStep?("looking for what is like “\(phrase)”\(offset > 0 ? " from match \(offset)" : "")")
                if let similar = options.similar {
                    do {
                        let page = try await similar(phrase, offset)
                        for id in page.ids { evidenceRead.insert(id) }
                        steps.append(("SIMILAR \(phrase) offset \(offset)", page.text))
                    } catch {
                        if error is CancellationError || (error as? ReaderError)?.cancelled == true { throw error }
                        options.log?("similar failed: \(error.localizedDescription)")
                        steps.append(("SIMILAR \(phrase) offset \(offset)", "SIMILAR could not run (\((error as? ReaderError)?.message ?? error.localizedDescription)). Use FIND or OPEN instead."))
                    }
                } else {
                    steps.append(("SIMILAR \(phrase) offset \(offset)", "SIMILAR is not available (no embedding model). Use FIND for a word, or OPEN a file."))
                }
            default: break
            }
        }
        return Answer(answer: "(no answer)", evidence: [], unread: [], steps: steps.count, trace: trace, opened: opened)
    }
}
