import Foundation

/// The morning: one question answered with exactly two moves, open a note file (one page at a
/// time) or read sentences by id. The model replies in plain lines; `LensParse.action` reads them.
public enum Morning {
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
        public init() {}
    }

    public static func system(goals: String, toc: String, corrections: String) -> String {
        let id42 = Sentences.makeId(42), id43 = Sentences.makeId(43)
        var s = """
        You answer questions about the author's own written stream of thoughts. Overnight the stream was read several times and notes were written into files; every note line cites sentence ids like \(id42). You cannot see the stream directly.

        Each turn, reply with exactly ONE action, in this plain format and nothing else:

        OPEN <file name from the list below> offset <line number, 0 to start>
        WHY: one line on what you expect to find

        READ \(id42) \(id43)
        WHY: one line on why these sentences

        ANSWER
        Your answer, in prose, as many lines as you need.
        EVIDENCE: \(id42), \(id43)

        Rules. Start by opening the file most likely to hold the answer (the list below says what each file is for). Before answering, READ the raw sentences you intend to cite; cite only ids you have actually read. When asked how the author felt, quote their words rather than paraphrasing. For "is X present" or "what things are there" questions, check the ledger, and say which files you checked when something is absent. Say plainly what you are unsure of. Answer in the second person ("you"), as a thoughtful reader of the author's notes, not as a search engine. Do not ask the author questions back; answer with what you have. Never wrap the reply in JSON or code fences.

        ## The author's goals
        \(goals)

        ## Files you can open
        \(toc)

        """
        if !corrections.isEmpty { s += "\n## The author's corrections to earlier answers (trust these over the notes)\n\(corrections)" }
        return s
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
        let system = Self.system(goals: goals, toc: tocLines.isEmpty ? "(no note files yet; the night has not run)" : tocLines.joined(separator: "\n"),
                                 corrections: tokens.clip(corrections, 600).text)
        var steps: [(action: String, result: String)] = []
        var trace: [TraceStep] = []
        var opened: [String] = []
        var evidenceRead = Set<String>()

        func buildUser(final: Bool) -> String {
            var parts = ["## Question\n\(question)"]
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
            parts.append(final ? "## Now answer\nYou have used all your steps. Reply with ANSWER now, with what you have, citing only ids you read." : "## Next action (step \(steps.count + 1) of \(config.morningSteps))")
            return parts.joined(separator: "\n\n")
        }

        for step in 0...config.morningSteps {
            let final = step == config.morningSteps
            let user = buildUser(final: final)
            options.onStep?(final ? "writing the answer" : step == 0 ? "deciding where to look" : "step \(step + 1): deciding what to do next")
            options.onCall?("Morning, step \(step + 1) of \(config.morningSteps + 1)", system, user)
            let res = try await chat.call(ChatRequest(system: system, user: user, label: "morning s\(step + 1)", onToken: options.onToken), config: config, budget: config.windowTokens)
            let a = LensParse.action(res.text)
            switch a {
            case let .open(file, offset, why): trace.append(TraceStep(action: "open", file: file, offset: offset, ids: [], why: why))
            case let .read(ids, why): trace.append(TraceStep(action: "read", file: "", offset: 0, ids: ids, why: why))
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
            // Cool off between tool steps only (overnight); the caller rests after the answer itself.
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
            default: break
            }
        }
        return Answer(answer: "(no answer)", evidence: [], unread: [], steps: steps.count, trace: trace, opened: opened)
    }
}
