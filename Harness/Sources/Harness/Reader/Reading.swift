import Foundation

/// Reading the stream, whenever there is something new: a small chunk of sentences at a time,
/// through every lens at once (as many lenses in one call as the window and the output cap
/// allow, the rest in the next call on the same chunk), then the questions about your goals.
/// New words are read soon after they are said; each lens keeps its notebook from chunk to chunk.
/// Resumable through progress.json, which is written after every call.
public enum Reading {
    /// Where a lens is with the chunk in hand.
    public enum Mark: String, Sendable, Equatable { case waiting, now, done, failed }

    /// What the interface is told while reading. Every closure may be called off the main thread.
    public struct Control: Sendable {
        /// "Stop after this call."
        public var stopped: @Sendable () -> Bool = { false }
        public var log: @Sendable (String) -> Void = { _ in }
        public var status: @Sendable (String) -> Void = { _ in }
        /// A chunk begins: (index of its first sentence, index after its last, sentences in the stream, the lenses reading it).
        public var onChunk: @Sendable (Int, Int, Int, [String]) -> Void = { _, _, _, _ in }
        /// A lens's state for the chunk in hand.
        public var onLens: @Sendable (String, Mark) -> Void = { _, _ in }
        /// Sentences read by every lens, of all of them.
        public var onRead: @Sendable (Int, Int) -> Void = { _, _ in }
        /// (questions answered and up to date, of all of them, the one being answered or "").
        public var onQuestion: @Sendable (Int, Int, String) -> Void = { _, _, _ in }
        /// (label, system, user) before every call.
        public var onCall: @Sendable (String, String, String) -> Void = { _, _, _ in }
        public var onToken: @Sendable (String, String) -> Void = { _, _ in }
        /// Note files changed: a lens file after a chunk, questions.md after an answer.
        public var onNotes: @Sendable () -> Void = {}
        /// A request from the author, taken once: regenerate the questions, or refresh every answer.
        public var takeRequest: @Sendable () -> QuestionRequest? = { nil }
        public init() {}
    }

    public enum QuestionRequest: Sendable, Equatable { case regenerate, refreshAll }

    // MARK: - Prompts

    static let marker = "==="

    /// Said to the model before any text of the stream, whatever made it: the stream is treated
    /// as a transcript throughout, so a mis-heard word is read for what was meant, not as a fact.
    public static let transcriptNote = "The text was transcribed from speech by a machine (text the author typed is treated the same way), so expect a few mis-heard words, names spelled as they sound, missing punctuation and run-on sentences. Read for what was meant; when a word looks mis-transcribed, say so and give the likely word rather than building on the error."

    /// The model writes plain lines, not JSON: under one `=== <lens id> ===` header per lens, one
    /// entry per line starting with the ids in brackets, and (for lenses that carry one) a NOTEBOOK.
    public static func systemPrompt(lenses group: [Lens], goals: String) -> String {
        let id42 = Sentences.makeId(42), id43 = Sentences.makeId(43), id47 = Sentences.makeId(47)
        let carry = group.contains(where: \.carry)
        let first = group.first?.id ?? "lens"
        var s = "You are reading the author's own stream of thoughts, in order, a small chunk at a time. The stream is far larger than what you can see; you only have this chunk\(carry ? " and the notebooks kept between chunks" : ""). Sentences are numbered; every entry you write must cite the sentence ids it comes from, exactly as written (e.g. \(id42)). Never invent ids.\n\(transcriptNote)\n"
        if group.contains(where: { !$0.ignoreGoals }) {
            let g = goals.trimmingCharacters(in: .whitespacesAndNewlines)
            s += "\nThe author's goals:\n\(g.isEmpty ? "(none written)" : g)\n"
        }
        if group.count > 1 {
            s += "\nRead the chunk through each of these \(group.count) lenses and write one section per lens, in this order: \(group.map(\.id).joined(separator: ", ")).\n"
        } else {
            s += "\nRead the chunk through this lens.\n"
        }
        s += "Start \(group.count > 1 ? "each section" : "your reply") with the lens's header on a line of its own, e.g. \(marker) \(first) \(marker)\n"
        s += "Under the header, one entry per line, each starting with the sentence ids in square brackets:\n[\(id42)] what you found\n[\(id43), \(id47)] an entry drawn from two sentences\n"
        s += "If nothing in the chunk fits a lens, write only [none] under its header."
        if carry { s += "\nA lens that keeps a notebook ends its section with a line NOTEBOOK and, below it, its updated notebook: the only thing it keeps between chunks. Rewrite it whole, compact, keeping every id still needed." }
        s += "\nNo other headings, no numbering, no commentary."
        for l in group {
            s += "\n\nLENS \(l.id) (\(l.title))\(l.carry ? ", keeps a notebook" : "")\(l.ignoreGoals && group.contains(where: { !$0.ignoreGoals }) ? ", ignores the author's goals" : "")\n\(l.instructions)"
        }
        return s
    }

    static func userPrompt(lenses group: [Lens], chunk: [Sentence], notebooks: [String: String], digest: String) -> String {
        var parts: [String] = []
        if !digest.isEmpty { parts.append("## Notebooks of other lenses (read only)\n\(digest)") }
        for l in group where l.carry {
            let nb = notebooks[l.id] ?? ""
            parts.append("## Notebook of \(l.id) so far\n\(nb.isEmpty ? "(empty)" : nb)")
        }
        let text = chunk.map { "\($0.id)\t\($0.text)" }.joined(separator: "\n")
        parts.append("## The chunk: sentences \(chunk.first?.id ?? "")–\(chunk.last?.id ?? "")\n\(text)")
        parts.append(group.count > 1 ? "Now write the \(group.count) sections, starting with \(marker) \(group[0].id) \(marker)." : "Now write the section, starting with \(marker) \(group[0].id) \(marker).")
        return parts.joined(separator: "\n\n")
    }

    /// The notebooks of lenses a group reads but does not hold, clipped to the digest budget.
    static func digest(for group: [Lens], all: [Lens], notebooks: [String: String], config: ReaderConfig, tokens: TokenEstimator) -> (text: String, clipped: Bool) {
        let held = Set(group.map(\.id))
        var ids: [String] = []
        for l in group { for r in l.reads where !held.contains(r) && !ids.contains(r) { ids.append(r) } }
        let text = ids.compactMap { id -> String? in
            guard let nb = notebooks[id], !nb.isEmpty else { return nil }
            return "### \(all.first { $0.id == id }?.title ?? id)\n\(nb)"
        }.joined(separator: "\n\n")
        guard !text.isEmpty else { return ("", false) }
        let c = tokens.clip(text, config.digestTokens)
        return (c.text, c.clipped)
    }

    // MARK: - Chunks and groups

    /// What one lens is expected to write for a chunk of `n` sentences.
    static func outputEstimate(_ lens: Lens, sentences n: Int, notebook: String, config: ReaderConfig, tokens: TokenEstimator) -> Int {
        let entries = lens.id == "ledger" ? 20 + n * 30 : 40 + n * 14
        let nb = lens.carry ? min(config.notebookTokens, tokens.estimate(notebook) + 160) : 0
        return entries + nb + 12
    }

    /// Tokens left for sentences when each lens reads alone with a full notebook: what a chunk may hold.
    public static func chunkBudget(config: ReaderConfig, lenses: [Lens], goals: String, tokens: TokenEstimator) -> Int {
        lenses.map { l in
            config.windowTokens - tokens.estimate(systemPrompt(lenses: [l], goals: goals)) - (l.carry ? config.notebookTokens : 0)
                - (l.reads.isEmpty ? 0 : config.digestTokens) - 120
        }.min() ?? config.windowTokens
    }

    /// The next chunk from `start`: at most `chunkSentences`, within the token budget, before `limit`; at least one sentence.
    static func chunk(_ sentences: [Sentence], from start: Int, limit: Int, budget: Int, config: ReaderConfig, tokens: TokenEstimator) -> [Sentence] {
        var out: [Sentence] = []
        var used = 0
        var i = start
        while i < limit {
            let t = tokens.estimate(sentences[i].id + "\t" + sentences[i].text + "\n")
            if !out.isEmpty, used + t > budget || (config.chunkSentences > 0 && out.count >= config.chunkSentences) { break }
            out.append(sentences[i]); used += t; i += 1
        }
        return out
    }

    /// The lenses split into calls, in their order: as many in one call as the window, the output
    /// cap and `lensesPerCall` allow.
    public static func groups(_ lenses: [Lens], all: [Lens], chunk: [Sentence], notebooks: [String: String], goals: String, config: ReaderConfig, tokens: TokenEstimator) -> [[Lens]] {
        var out: [[Lens]] = []
        var current: [Lens] = []
        func fits(_ g: [Lens]) -> Bool {
            if config.lensesPerCall > 0, g.count > config.lensesPerCall { return false }
            let d = digest(for: g, all: all, notebooks: notebooks, config: config, tokens: tokens).text
            let input = tokens.estimate(systemPrompt(lenses: g, goals: goals)) + tokens.estimate(userPrompt(lenses: g, chunk: chunk, notebooks: notebooks, digest: d))
            let output = g.reduce(0) { $0 + outputEstimate($1, sentences: chunk.count, notebook: notebooks[$1.id] ?? "", config: config, tokens: tokens) }
            return input <= config.windowTokens && output <= config.outputTokens
        }
        for l in lenses {
            if current.isEmpty || fits(current + [l]) { current.append(l) } else { out.append(current); current = [l] }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: - Files

    public static func lensFile(_ lens: Lens, entries: [LensParse.Entry], notebook: String, done: Bool, skipped: [ReaderProgress.Skipped]) -> String {
        var lines = ["# \(lens.title)", "", lens.purpose.isEmpty ? "(no description)" : lens.purpose, "", "Each line cites the sentence ids it comes from. Open `sentences.txt` or ask for an id to see the author's exact words.", ""]
        for e in entries { lines.append("- [\(e.ids.joined(separator: ", "))] \(e.text)") }
        if lens.carry { lines += ["", "## Notebook (as of the last chunk read)", "", notebook.isEmpty ? "(empty)" : notebook] }
        if !skipped.isEmpty { lines += ["", "## Chunks this lens could not read", ""] + skipped.map { "- \($0.from)–\($0.to): \($0.error)" } }
        if !done { lines += ["", "_This lens has not read the whole stream yet._"] }
        return lines.joined(separator: "\n") + "\n"
    }

    static func questionsFile(_ questions: [String], qa: [ReaderProgress.QA], count: Int, refresh: Int) -> String {
        let byQ = Dictionary(qa.map { ($0.q, $0) }, uniquingKeysWith: { _, b in b })
        let answered = questions.filter { byQ[$0] != nil }.count
        var lines = ["# Questions about your goals", "", Lens.questionsPurpose, "", "\(answered) of \(questions.count) answered.", ""]
        for q in questions {
            lines += ["## \(q)", ""]
            guard let x = byQ[q] else { lines += ["(not answered yet)", ""]; continue }
            let behind = count - (x.asOf ?? 0)
            lines += [x.answer, "", "Evidence: \(x.evidence.isEmpty ? "none cited" : x.evidence.joined(separator: ", "))",
                      "Files opened: \(x.opened.isEmpty ? "none" : x.opened.joined(separator: ", "))",
                      "As of: \(x.asOf.map { $0 > 0 ? Sentences.makeId($0) : "the start" } ?? "an earlier reading")\(behind >= refresh ? " (the stream has grown since; to be refreshed)" : "")", ""]
        }
        return lines.joined(separator: "\n")
    }

    public static func writeIndex(_ folder: NotesFolder, lenses: [Lens], progress: ReaderProgress) throws {
        var lines = ["# Index of notes", "", "Written by Holdnote's reader as it reads. Every note line cites sentence ids; `sentences.txt` has the numbered stream.", ""]
        for l in lenses where l.on {
            let st = progress.lenses[l.id]
            lines.append("- lenses/\(l.id).md — \(l.purpose.isEmpty ? l.title : l.purpose)\(st.map { " (\($0.entries.count) entries)" } ?? "")")
        }
        if !progress.qa.isEmpty { lines.append("- questions.md — \(Lens.questionsPurpose) (\(progress.qa.count) answered)") }
        lines.append("- answers.md — the author's answers to the reader's questions.")
        lines.append("- corrections.md — the author's corrections to earlier answers; trust these over the notes.")
        lines.append("- goals.md — the author's stated goals and intent.")
        try folder.write("index.md", lines.joined(separator: "\n") + "\n")
    }

    static func rest(_ config: ReaderConfig, _ ctl: Control) async throws {
        let until = Date().addingTimeInterval(Double(max(0, config.coolOffSec)))
        while Date() < until, !ctl.stopped() {
            ctl.status("resting between calls, \(Int(until.timeIntervalSinceNow.rounded(.up)))s")
            try await Task.sleep(nanoseconds: UInt64(min(1, max(0.01, until.timeIntervalSinceNow)) * 1e9))
        }
        ctl.status("")
    }

    static func jlog(_ folder: NotesFolder, _ fields: [String: Any]) {
        var obj: [String: Any] = ["t": ISO8601DateFormatter().string(from: Date())]
        for (k, v) in fields { obj[k] = v }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
            try? folder.append("log.jsonl", String(decoding: data, as: UTF8.self) + "\n")
        }
    }

    static func isCancel(_ error: Error) -> Bool { (error as? ReaderError)?.cancelled == true || error is CancellationError }

    // MARK: - The questions

    /// The questions kept answered: the author's pinned ones first, then those generated from the goals.
    public static func questionList(progress: ReaderProgress, pinned: [String]) -> [String] {
        var seen = Set<String>()
        return (pinned + (progress.questions ?? [])).filter { seen.insert($0).inserted }
    }

    /// The questions that need an answer now, in the order to answer them: never answered first,
    /// then the most out of date.
    public static func pendingQuestions(progress: ReaderProgress, pinned: [String], count: Int, refresh: Int) -> [String] {
        let byQ = Dictionary(progress.qa.map { ($0.q, $0) }, uniquingKeysWith: { _, b in b })
        let list = questionList(progress: progress, pinned: pinned)
        let never = list.filter { byQ[$0] == nil }
        let stale = list.compactMap { q -> (String, Int)? in
            guard let x = byQ[q] else { return nil }
            let asOf = x.asOf ?? 0
            return count - asOf >= max(1, refresh) ? (q, asOf) : nil
        }.sorted { $0.1 < $1.1 }.map(\.0)
        return never + stale
    }

    // MARK: - Running

    /// Reads until everything is read and every question is answered and up to date. Returns true
    /// when caught up, false when stopped (progress saved). Text added to the stream while it runs
    /// is read in the same run.
    public static func run(folder: NotesFolder, config: ReaderConfig, lenses: [Lens], goals: String, chat: MeasuredChat, control ctl: Control) async throws -> Bool {
        let log = ctl.log
        if try ReaderStream.number(folder) { log("numbered stream.txt into sentences.txt") }
        let goalsTrimmed = goals.trimmingCharacters(in: .whitespacesAndNewlines)
        if !goalsTrimmed.isEmpty { try folder.write("goals.md", "# Goals and intent\n\n" + goalsTrimmed + "\n") }

        var progress = ReaderProgress.load(folder)
        let active = lenses.filter(\.on)
        if active.isEmpty { throw ReaderError("No lens is switched on. Turn at least one on, then start reading.") }
        func save() throws { try folder.writeJSON("progress.json", progress) }

        var readSomething = false
        while true {
            if ctl.stopped() { try save(); log("stopped"); return false }
            let sentences = ReaderStream.sentences(in: folder)
            if sentences.isEmpty { throw ReaderError("Nothing to read yet. Record something, or add text to the stream.") }
            let count = sentences.count
            func pos(_ l: Lens) -> Int { min(count, progress.lenses[l.id]?.pos ?? 0) }
            let start = active.map(pos).min() ?? count

            // 1. Lenses: the next chunk.
            if start < count {
                readSomething = true
                let finished = try await readChunk(sentences: sentences, start: start, active: active, all: lenses, goals: goals, progress: &progress, folder: folder, config: config, chat: chat, ctl: ctl)
                if !finished { return false }
                continue
            }
            if readSomething {
                try writeIndex(folder, lenses: lenses, progress: progress)
                readSomething = false
                log("every lens has read all \(count) sentences")
            }

            // 2. Questions about the goals, once the lenses are caught up.
            let request = ctl.takeRequest()
            if request == .regenerate { progress.questions = nil }
            if request == .refreshAll { for i in progress.qa.indices { progress.qa[i].asOf = Int.min / 2 } }
            let pinned = ReaderStream.pinned(in: folder)
            if config.questionCount > 0, progress.questions == nil || (progress.qGoals ?? "") != goalsTrimmed {
                if ctl.stopped() { try save(); log("stopped"); return false }
                guard try await generateQuestions(count: count, active: active, goals: goalsTrimmed, progress: &progress, folder: folder, config: config, chat: chat, ctl: ctl) else { return false }
                continue
            }
            if config.questionCount == 0, progress.questions?.isEmpty == false { progress.questions = [] }
            let list = questionList(progress: progress, pinned: pinned)
            let pending = pendingQuestions(progress: progress, pinned: pinned, count: count, refresh: config.questionRefresh)
            if let q = pending.first {
                if ctl.stopped() { try save(); log("stopped"); return false }
                ctl.onQuestion(list.count - pending.count, list.count, q)
                guard try await answer(q, sentences: sentences, lenses: lenses, progress: &progress, list: list, folder: folder, config: config, chat: chat, ctl: ctl) else { return false }
                ctl.onQuestion(list.count - pending.count + 1, list.count, "")
                continue
            }
            ctl.onQuestion(list.count, list.count, "")
            break
        }
        try save()
        try writeIndex(folder, lenses: lenses, progress: progress)
        log("caught up")
        return true
    }

    /// One chunk through every lens that has not read it. Returns false when stopped.
    static func readChunk(sentences: [Sentence], start: Int, active: [Lens], all: [Lens], goals: String, progress: inout ReaderProgress,
                          folder: NotesFolder, config: ReaderConfig, chat: MeasuredChat, ctl: Control) async throws -> Bool {
        let tokens = chat.tokens, log = ctl.log
        let count = sentences.count
        func pos(_ l: Lens) -> Int { min(count, progress.lenses[l.id]?.pos ?? 0) }
        // The lenses furthest behind read first, alone, until they reach the others.
        let readers = active.filter { pos($0) == start }
        let limit = active.map(pos).filter { $0 > start }.min() ?? count
        let budget = chunkBudget(config: config, lenses: readers, goals: goals, tokens: tokens)
        if budget < 150 { throw ReaderError("The window is too small for the lens instructions (\(budget) tokens left for sentences). Raise W in Settings → Reader, or shorten a lens.") }
        let chunk = Self.chunk(sentences, from: start, limit: limit, budget: budget, config: config, tokens: tokens)
        let end = start + chunk.count
        let range = "\(chunk[0].id)–\(chunk[chunk.count - 1].id)"
        let known = Set(sentences.map(\.id))
        ctl.onChunk(start, end, count, readers.map(\.id))
        for l in readers { ctl.onLens(l.id, .waiting) }

        func save() throws { try folder.writeJSON("progress.json", progress) }
        var notebooks: [String: String] { progress.lenses.mapValues(\.notebook) }

        /// Applies one lens's section. Returns false when stopped.
        func apply(_ lens: Lens, _ section: String, truncated: Bool) async throws -> Bool {
            var st = progress.lenses[lens.id] ?? ReaderProgress.LensState()
            let parsed = LensParse.lens(section)
            let entries = parsed.entries.map { LensParse.Entry(ids: $0.ids.filter { known.contains($0) }, text: $0.text) }.filter { !$0.ids.isEmpty }
            let dropped = parsed.entries.count - entries.count
            if dropped > 0 { log("\(lens.title), \(range): dropped \(dropped) entries whose ids are not in the stream") }
            let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
            if entries.isEmpty, !trimmed.isEmpty, trimmed.range(of: "[none]", options: .caseInsensitive) == nil, parsed.notebook.isEmpty {
                log("\(lens.title), \(range): no entry lines (\(trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(100))…)")
            }
            if truncated { log("\(lens.title), \(range): the reply hit the output cap (\(config.outputTokens) tokens); its last entries\(lens.carry ? " and the notebook" : "") may be missing. Raise the output cap, or read fewer sentences at a time.") }
            if lens.id == "ledger" {
                let covered = Set(entries.flatMap(\.ids))
                let missed = chunk.filter { !covered.contains($0.id) }
                if !missed.isEmpty { log("ledger, \(range): \(missed.count) sentences without a line (\(missed.prefix(5).map(\.id).joined(separator: ", "))\(missed.count > 5 ? "…" : ""))") }
            }
            st.entries += entries
            var notebook = lens.carry ? (parsed.notebook.isEmpty ? st.notebook : parsed.notebook) : ""
            if lens.carry, parsed.notebook.isEmpty, !entries.isEmpty { log("\(lens.title), \(range): no NOTEBOOK in the reply; the previous notebook is kept") }
            if lens.carry, tokens.estimate(notebook) > config.notebookTokens {
                log("\(lens.title): notebook \(tokens.estimate(notebook)) tokens > \(config.notebookTokens); compressing")
                do {
                    let sys = "Compress the notebook below to under \(Int(Double(config.notebookTokens) * 0.7)) tokens (about \(Int(Double(config.notebookTokens) * 0.5)) words). Keep every sentence id that matters, merge duplicates, drop wording. Reply with the compressed notebook only: no preamble, no heading."
                    let room = tokens.clip(notebook, config.windowTokens - tokens.estimate(sys) - 40)
                    ctl.onCall("\(lens.title): compressing the notebook", sys, room.text)
                    let c = try await chat.call(ChatRequest(system: sys, user: room.text, label: "\(lens.id) compress", onToken: ctl.onToken), config: config, budget: config.windowTokens)
                    let t = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { notebook = t }
                } catch {
                    if isCancel(error) { try save(); log("stopped"); return false }
                    log("compress failed: \((error as? ReaderError)?.message ?? error.localizedDescription)")
                }
                if tokens.estimate(notebook) > config.notebookTokens {
                    notebook = tokens.clip(notebook, config.notebookTokens).text + "\n[notebook overflowed and was cut here]"
                    log("\(lens.title): NOTEBOOK OVERFLOW, cut to \(config.notebookTokens) tokens")
                    jlog(folder, ["lens": lens.id, "chunk": range, "overflow": true])
                }
            }
            st.notebook = notebook
            st.pos = end
            progress.lenses[lens.id] = st
            try folder.write("lenses/\(lens.id).md", lensFile(lens, entries: st.entries, notebook: st.notebook, done: end >= count, skipped: st.skipped))
            try save()
            ctl.onLens(lens.id, .done)
            return true
        }

        func skip(_ lens: Lens, _ message: String) throws {
            var st = progress.lenses[lens.id] ?? ReaderProgress.LensState()
            st.skipped.append(ReaderProgress.Skipped(from: chunk[0].id, to: chunk[chunk.count - 1].id, error: message))
            st.pos = end
            progress.lenses[lens.id] = st
            try folder.write("lenses/\(lens.id).md", lensFile(lens, entries: st.entries, notebook: st.notebook, done: end >= count, skipped: st.skipped))
            try save()
            ctl.onLens(lens.id, .failed)
        }

        /// One call for a group; lenses it could not cover come back to be read on their own.
        /// Returns nil when stopped.
        func call(_ group: [Lens], alone: Bool) async throws -> [Lens]? {
            if ctl.stopped() { try save(); log("stopped"); return nil }
            for l in group { ctl.onLens(l.id, .now) }
            let d = digest(for: group, all: all, notebooks: notebooks, config: config, tokens: tokens)
            if d.clipped { log("\(range): notebooks of other lenses clipped to \(config.digestTokens) tokens") }
            let system = systemPrompt(lenses: group, goals: goals)
            let user = userPrompt(lenses: group, chunk: chunk, notebooks: notebooks, digest: d.text)
            let names = group.count == 1 ? group[0].title : "\(group.count) lenses"
            let label = "\(range) · \(names)"
            ctl.status("reading \(range) through \(names)")
            let res: ChatReply
            do {
                ctl.onCall(label, system, user)
                res = try await chat.call(ChatRequest(system: system, user: user, label: "\(group.map(\.id).joined(separator: "+")) \(chunk[0].id)", onToken: ctl.onToken), config: config, budget: config.windowTokens)
            } catch {
                let e = error as? ReaderError ?? ReaderError(error.localizedDescription, cancelled: error is CancellationError)
                jlog(folder, ["lenses": group.map(\.id), "chunk": range, "error": e.message])
                if e.cancelled { try save(); log("stopped during \(label); it is read again on resume"); for l in group { ctl.onLens(l.id, .waiting) }; return nil }
                if e.fatal {
                    try save()
                    throw ReaderError("\(label): \(e.message). Stopped without marking the chunk as read; it is read again once the model answers.", fatal: true)
                }
                if group.count > 1 { log("\(label): failed (\(e.message)); each lens tries again on its own"); return group }
                log("\(label): FAILED (\(e.message)); skipped")
                try skip(group[0], e.message)
                try await rest(config, ctl)
                return []
            }
            jlog(folder, ["lenses": group.map(\.id), "chunk": range, "promptTokens": res.promptTokens, "estTokens": res.estTokens, "outTokens": res.outTokens, "ms": res.ms])
            let tps = res.tokensPerSecond > 0 ? " at \(res.tokensPerSecond) tok/s" : ""
            log("\(label): \(res.promptTokens) prompt tokens, \(res.outTokens) out, \(String(format: "%.1f", Double(res.ms) / 1000))s\(tps)")
            let sections = LensParse.sections(res.text, lenses: group.map { ($0.id, $0.title) })
            var missing = group.filter { sections[$0.id] == nil }
            // A cut-off reply: the last section it reached is incomplete, so that lens reads again too.
            var lastCut: String?
            if res.truncated, group.count > 1, !alone {
                lastCut = group.last { sections[$0.id] != nil }?.id
            }
            if alone || group.count == 1 {
                // On its own there is no one else's section to confuse it with: whatever came back is its.
                let lens = group[0]
                guard try await apply(lens, sections[lens.id] ?? res.text, truncated: res.truncated) else { return nil }
                try await rest(config, ctl)
                return []
            }
            for lens in group where sections[lens.id] != nil && lens.id != lastCut {
                guard try await apply(lens, sections[lens.id] ?? "", truncated: false) else { return nil }
            }
            if let lastCut, let l = group.first(where: { $0.id == lastCut }) { missing.append(l) }
            if !missing.isEmpty { log("\(label): \(missing.map(\.title).joined(separator: ", ")) \(missing.count == 1 ? "was" : "were") missing from the reply; reading on \(missing.count == 1 ? "its" : "their") own") }
            for l in missing { ctl.onLens(l.id, .waiting) }
            try await rest(config, ctl)
            return group.filter { l in missing.contains { $0.id == l.id } }
        }

        // Groups are planned one at a time, so each sees the notebooks the groups before it just wrote.
        var left = readers
        while !left.isEmpty {
            let group = groups(left, all: all, chunk: chunk, notebooks: notebooks, goals: goals, config: config, tokens: tokens)[0]
            left.removeFirst(group.count)
            guard let again = try await call(group, alone: false) else { return false }
            for l in again {
                guard try await call([l], alone: true) != nil else { return false }
            }
        }
        let read = min(count, active.map { min(count, progress.lenses[$0.id]?.pos ?? 0) }.min() ?? count)
        ctl.onRead(read, count)
        ctl.onNotes()
        return true
    }

    /// Generates the questions about the goals. Returns false when stopped.
    static func generateQuestions(count: Int, active: [Lens], goals: String, progress: inout ReaderProgress,
                                  folder: NotesFolder, config: ReaderConfig, chat: MeasuredChat, ctl: Control) async throws -> Bool {
        let tokens = chat.tokens
        ctl.log("generating \(config.questionCount) questions from the goals and the notes")
        ctl.status("thinking of questions about your goals")
        ctl.onQuestion(0, 0, "")
        let perFile = max(150, (config.windowTokens - 1200) / max(1, active.count))
        let heads = active.map { lens -> String in
            let st = progress.lenses[lens.id] ?? ReaderProgress.LensState()
            let text = lens.carry && !st.notebook.isEmpty ? st.notebook : st.entries.suffix(60).map { "- [\($0.ids.joined(separator: ", "))] \($0.text)" }.joined(separator: "\n")
            return "## \(lens.title)\n\(tokens.clip(text, perFile).text)"
        }
        let system = "The author keeps a long stream of their own thoughts and asked for help thinking about it. \(transcriptNote) Their goals are below, followed by extracts from notes taken on the stream. Write \(config.questionCount) questions the author would most want answered about their own text, in the author's interest, grounded in what the notes show is actually there. Favour: what is present, what is associated with what, how feelings about something developed, where the author contradicts themselves, what was left open, and what the notes suggest the author has not noticed. Do not ask for counts or arithmetic. Each question should be answerable from the stream. Write one question per line and nothing else: no numbering, no headings, no preamble."
        let user = tokens.clip("## Goals\n\(goals.isEmpty ? "(none written; ask what a thoughtful reader of these notes would)" : goals)\n\n\(heads.joined(separator: "\n\n"))", config.windowTokens - tokens.estimate(system) - 60).text
        ctl.onCall("Questions about your goals", system, user)
        var qs: [String] = []
        do {
            let q = try await chat.call(ChatRequest(system: system, user: user, label: "qgen", onToken: ctl.onToken), config: config, budget: config.windowTokens)
            qs = LensParse.questions(q.text, max: config.questionCount)
        } catch {
            if isCancel(error) { try folder.writeJSON("progress.json", progress); ctl.log("stopped"); return false }
            if (error as? ReaderError)?.fatal == true { throw error }
            ctl.log("could not write the questions: \((error as? ReaderError)?.message ?? error.localizedDescription)")
        }
        if qs.isEmpty { ctl.log("the model wrote no questions; they are tried again when the goals change") }
        else { ctl.log("\(qs.count) questions about your goals") }
        progress.questions = qs
        progress.qGoals = goals
        // Answers to questions that are still asked are kept.
        let keep = Set(qs + ReaderStream.pinned(in: folder))
        progress.qa = progress.qa.filter { keep.contains($0.q) }
        try folder.writeJSON("progress.json", progress)
        try await rest(config, ctl)
        return true
    }

    /// Answers one question from the notes and keeps the answer. Returns false when stopped.
    static func answer(_ question: String, sentences: [Sentence], lenses: [Lens], progress: inout ReaderProgress, list: [String],
                       folder: NotesFolder, config: ReaderConfig, chat: MeasuredChat, ctl: Control) async throws -> Bool {
        ctl.status("answering: \(question.prefix(80))")
        var opts = Asking.Options()
        opts.includeQuestions = false
        opts.coolOffSec = config.coolOffSec
        opts.stopped = ctl.stopped
        opts.onCall = ctl.onCall
        opts.onToken = ctl.onToken
        opts.log = ctl.log
        opts.onStep = { s in ctl.status("answering: \(s)") }
        var r: Asking.Answer
        do { r = try await Asking.ask(question, folder: folder, config: config, lenses: lenses, sentences: sentences, chat: chat, options: opts) }
        catch {
            if isCancel(error) { try folder.writeJSON("progress.json", progress); ctl.log("stopped"); return false }
            if (error as? ReaderError)?.fatal == true { throw error }
            // Kept as the answer until the stream grows enough to try again, so one bad question cannot stall the rest.
            let message = (error as? ReaderError)?.message ?? error.localizedDescription
            ctl.log("could not answer “\(question.prefix(60))”: \(message)")
            r = Asking.Answer(answer: "(could not answer: \(message))", evidence: [], unread: [], steps: 0, trace: [], opened: [])
        }
        let qa = ReaderProgress.QA(q: question, answer: r.answer, evidence: r.evidence, opened: r.opened, asOf: sentences.count, at: Date())
        if let i = progress.qa.firstIndex(where: { $0.q == question }) { progress.qa[i] = qa } else { progress.qa.append(qa) }
        try folder.writeJSON("progress.json", progress)
        try folder.write("questions.md", questionsFile(list, qa: progress.qa, count: sentences.count, refresh: config.questionRefresh))
        ctl.log("answered “\(question.prefix(60))” (\(r.steps) steps)")
        ctl.onNotes()
        try await rest(config, ctl)
        return true
    }
}
