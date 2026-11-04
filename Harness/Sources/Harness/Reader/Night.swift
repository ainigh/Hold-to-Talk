import Foundation

/// The overnight passes: each lens is one full pass over the unread stream, window by window,
/// with a notebook carried between windows for lenses that keep one; then the question pass.
/// Resumable through progress.json, which is written after every window.
public enum Night {
    public enum TapeState: String, Sendable { case initial, now, done, bad }

    /// What the interface is told while the night runs. Every closure may be called off the main thread.
    public struct Control: Sendable {
        /// "Stop after this call."
        public var stopped: @Sendable () -> Bool = { false }
        public var log: @Sendable (String) -> Void = { _ in }
        /// Progress of one lens (or "questions"): window i of n, or i = -1 for "nothing to read".
        public var onTape: @Sendable (String, Int, Int, TapeState) -> Void = { _, _, _, _ in }
        public var status: @Sendable (String) -> Void = { _ in }
        /// (label, system, user) before every call.
        public var onCall: @Sendable (String, String, String) -> Void = { _, _, _ in }
        public var onToken: @Sendable (String, String) -> Void = { _, _ in }
        public init() {}
    }

    /// The model writes plain lines, not JSON: one entry per line starting with the ids in brackets,
    /// and (for lenses that carry one) a NOTEBOOK section at the end.
    public static func systemPrompt(lens: Lens, goals: String) -> String {
        let carry = lens.carry
        let id42 = Sentences.makeId(42), id43 = Sentences.makeId(43), id47 = Sentences.makeId(47)
        var s = "You are reading the author's own stream of thoughts, in order, one window at a time. The stream is far larger than what you can see; you only have this window\(carry ? " and your notebook from earlier windows" : ""). Sentences are numbered; every entry you write must cite the sentence ids it comes from, exactly as written (e.g. \(id42)). Never invent ids.\n"
        s += lens.ignoreGoals ? "" : "The author's goals for this reading:\n\(goals)\n"
        s += "\nYour lens for this pass: \(lens.title).\n\(lens.instructions)\n\n"
        s += "Write your entries as plain lines, one entry per line, each starting with the sentence ids in square brackets:\n[\(id42)] what you found\n[\(id43), \(id47)] an entry drawn from two sentences\nNo headings, no numbering, no commentary before or between entries."
        if carry { s += "\nThen, on a line of its own, write NOTEBOOK and below it your notebook: the only thing you keep between windows. Keep it compact and keep every id you still need." }
        s += "\nIf nothing in this window fits the lens, write only: [none] nothing in this window."
        return s
    }

    /// Packs sentences into windows by estimated tokens, and by count when maxSentences is set.
    public static func windows(_ sentences: [Sentence], inputBudget: Int, maxSentences: Int = 0, tokens: TokenEstimator) -> [[Sentence]] {
        var out: [[Sentence]] = []
        var cur: [Sentence] = []
        var used = 0
        for s in sentences {
            let t = tokens.estimate(s.id + "\t" + s.text + "\n")
            if !cur.isEmpty, used + t > inputBudget || (maxSentences > 0 && cur.count >= maxSentences) { out.append(cur); cur = []; used = 0 }
            cur.append(s); used += t
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Tokens left for sentences in one window of a lens, after its instructions, digest and notebook.
    public static func sentenceBudget(config: ReaderConfig, lens: Lens, goals: String, tokens: TokenEstimator) -> Int {
        let digest = lens.reads.isEmpty ? 0 : config.digestTokens
        let fixed = tokens.estimate(systemPrompt(lens: lens, goals: goals)) + digest + 60
        return config.windowTokens - fixed - (lens.carry ? config.notebookTokens : 0)
    }

    public static func lensFile(_ lens: Lens, entries: [LensParse.Entry], notebook: String, done: Bool, skipped: [ReaderProgress.Skipped]) -> String {
        var lines = ["# \(lens.title)", "", lens.purpose.isEmpty ? "(no description)" : lens.purpose, "", "Each line cites the sentence ids it comes from. Open `sentences.txt` or ask for an id to see the author's exact words.", ""]
        for e in entries { lines.append("- [\(e.ids.joined(separator: ", "))] \(e.text)") }
        if lens.carry { lines += ["", "## Notebook (state at the end of the pass)", "", notebook.isEmpty ? "(empty)" : notebook] }
        if !skipped.isEmpty { lines += ["", "## Windows this pass could not read", ""] + skipped.map { "- \($0.from)–\($0.to): \($0.error)" } }
        if !done { lines += ["", "_This pass is not finished yet._"] }
        return lines.joined(separator: "\n") + "\n"
    }

    static func questionsFile(_ qa: [ReaderProgress.QA], total: Int) -> String {
        var lines = ["# Questions asked overnight", "", Lens.questionsPurpose, "", "\(qa.count) of \(total) answered.", ""]
        for x in qa {
            lines += ["## \(x.q)", "", x.answer, "", "Evidence: \(x.evidence.isEmpty ? "none cited" : x.evidence.joined(separator: ", "))", "Files opened: \(x.opened.isEmpty ? "none" : x.opened.joined(separator: ", "))", ""]
        }
        return lines.joined(separator: "\n")
    }

    public static func writeIndex(_ folder: NotesFolder, lenses: [Lens], progress: ReaderProgress) throws {
        var lines = ["# Index of notes", "", "Written overnight by Holdnote's reader. Every note line cites sentence ids; `sentences.txt` has the numbered stream.", ""]
        for l in lenses where l.on {
            let st = progress.lenses[l.id]
            lines.append("- lenses/\(l.id).md — \(l.purpose.isEmpty ? l.title : l.purpose)\(st.map { " (\($0.entries.count) entries)" } ?? "")")
        }
        if !progress.qa.isEmpty { lines.append("- questions.md — \(Lens.questionsPurpose) (\(progress.qa.count) questions)") }
        lines.append("- corrections.md — the author's corrections to earlier answers; trust these over the notes.")
        lines.append("- goals.md — the author's stated goals and intent.")
        try folder.write("index.md", lines.joined(separator: "\n") + "\n")
    }

    static func rest(_ config: ReaderConfig, _ ctl: Control) async throws {
        let until = Date().addingTimeInterval(Double(max(0, config.coolOffSec)))
        while Date() < until, !ctl.stopped() {
            ctl.status("cooling off, \(Int(until.timeIntervalSinceNow.rounded(.up)))s")
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

    /// Runs the whole night. Returns true when it finished, false when it was stopped (progress saved).
    public static func run(folder: NotesFolder, config: ReaderConfig, lenses: [Lens], goals: String, chat: MeasuredChat, control ctl: Control) async throws -> Bool {
        let tokens = chat.tokens
        let log = ctl.log

        // 1. sentences
        var sentences: [Sentence]
        if let existing = folder.read("sentences.txt"), !existing.isEmpty {
            sentences = Sentences.parse(existing)
        } else {
            guard let raw = folder.read("stream.txt"), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ReaderError("Nothing to read yet. Add text to the stream first.")
            }
            sentences = Sentences.split(raw)
            try folder.write("sentences.txt", Sentences.format(sentences))
            log("split stream.txt into \(sentences.count) sentences → sentences.txt")
        }
        let goalsTrimmed = goals.trimmingCharacters(in: .whitespacesAndNewlines)
        if !goalsTrimmed.isEmpty { try folder.write("goals.md", "# Goals and intent\n\n" + goalsTrimmed + "\n") }

        // 2. progress
        var progress = ReaderProgress.load(folder)
        let key = config.progressKey
        if let old = progress.key, old != key { log("window or notebook size changed (\(old) → \(key)); every lens reads from the start again") }
        if progress.key != key { progress = ReaderProgress(); progress.key = key }
        let known = Set(sentences.map(\.id))
        func save() throws { try folder.writeJSON("progress.json", progress) }

        // 3. lenses
        let active = lenses.filter(\.on)
        if active.isEmpty { throw ReaderError("No lens is switched on. Turn at least one on, then start the night.") }
        for lens in active {
            var st = progress.lenses[lens.id] ?? ReaderProgress.LensState()
            progress.lenses[lens.id] = st
            if st.pos >= sentences.count { log("\(lens.title): nothing new to read"); ctl.onTape(lens.id, -1, 1, .done); continue }

            let digest = lens.reads.compactMap { id -> String? in
                guard let nb = progress.lenses[id]?.notebook, !nb.isEmpty else { return nil }
                return "## Notebook from the \"\(lenses.first { $0.id == id }?.title ?? id)\" pass\n\(nb)"
            }.joined(separator: "\n\n")
            let digestClip = tokens.clip(digest, config.digestTokens)
            if digestClip.clipped { log("\(lens.title): prior-lens digest clipped to \(config.digestTokens) tokens") }

            let system = systemPrompt(lens: lens, goals: goals)
            let fixed = tokens.estimate(system) + tokens.estimate(digestClip.text) + 60
            let inputBudget = config.windowTokens - fixed - (lens.carry ? config.notebookTokens : 0)
            if inputBudget < 200 { throw ReaderError("\(lens.title): window too small after instructions (\(inputBudget) tokens left). Raise W or shorten the lens.") }
            let ws = windows(Array(sentences[st.pos...]), inputBudget: inputBudget, maxSentences: config.maxSentences, tokens: tokens)
            log("\(lens.title): \(sentences.count - st.pos) new sentences in \(ws.count) windows of ≈\(inputBudget) tokens\(config.maxSentences > 0 ? " and at most \(config.maxSentences) sentences" : "")\(lens.carry ? ", notebook ≤ \(config.notebookTokens)" : "")")
            ctl.onTape(lens.id, 0, ws.count, .initial)

            for i in 0..<ws.count {
                if ctl.stopped() { progress.lenses[lens.id] = st; try save(); log("stopped"); return false }
                ctl.onTape(lens.id, i, ws.count, .now)
                ctl.status("\(lens.title), window \(i + 1) of \(ws.count): calling \(config.model)")
                let w = ws[i]
                let windowText = w.map { "\($0.id)\t\($0.text)" }.joined(separator: "\n")
                let user = [digestClip.text,
                            lens.carry ? "## Your notebook so far\n\(st.notebook.isEmpty ? "(empty)" : st.notebook)" : "",
                            "## Window \(i + 1) of \(ws.count) (sentences \(w[0].id)–\(w[w.count - 1].id))\n\(windowText)"]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n")
                let label = "\(lens.title), window \(i + 1) of \(ws.count)"
                let res: ChatReply
                do {
                    ctl.onCall(label, system, user)
                    res = try await chat.call(ChatRequest(system: system, user: user, label: "\(lens.id) w\(i + 1)", onToken: ctl.onToken), config: config, budget: config.windowTokens)
                } catch {
                    let e = error as? ReaderError ?? ReaderError(error.localizedDescription, cancelled: error is CancellationError)
                    ctl.onTape(lens.id, i, ws.count, .bad)
                    jlog(folder, ["lens": lens.id, "window": i, "error": e.message])
                    // Nothing is marked read: the night stops here and resumes from this window.
                    if e.cancelled { progress.lenses[lens.id] = st; try save(); log("stopped during \(label); it will be read again on resume"); return false }
                    if e.fatal {
                        progress.lenses[lens.id] = st; try save()
                        throw ReaderError("\(lens.title) window \(i + 1): \(e.message). Stopped without marking the window as read; press Resume once Ollama is fixed.")
                    }
                    log("\(lens.title) window \(i + 1): FAILED (\(e.message)); skipped, continuing")
                    st.skipped.append(ReaderProgress.Skipped(from: w[0].id, to: w[w.count - 1].id, error: e.message))
                    st.pos += w.count; progress.lenses[lens.id] = st; try save()
                    try await rest(config, ctl)
                    continue
                }
                let parsed = LensParse.lens(res.text)
                let entries = parsed.entries.map { LensParse.Entry(ids: $0.ids.filter { known.contains($0) }, text: $0.text) }.filter { !$0.ids.isEmpty }
                let dropped = parsed.entries.count - entries.count
                if dropped > 0 { log("\(lens.title) window \(i + 1): dropped \(dropped) entries whose ids are not in the stream") }
                let trimmed = res.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if entries.isEmpty, !trimmed.isEmpty, trimmed.range(of: "[none]", options: .caseInsensitive) == nil {
                    log("\(lens.title) window \(i + 1): the reply had no entry lines (\(trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120))…)")
                }
                if res.truncated { log("\(lens.title) window \(i + 1): the reply hit the output cap (\(config.outputTokens) tokens); the window's last entries\(lens.carry ? " and the notebook" : "") may be missing. Raise the output cap or lower W.") }
                if lens.id == "ledger" {
                    let covered = Set(entries.flatMap(\.ids))
                    let missed = w.filter { !covered.contains($0.id) }
                    if !missed.isEmpty { log("ledger window \(i + 1): \(missed.count) sentences not covered (\(missed.prefix(5).map(\.id).joined(separator: ", "))\(missed.count > 5 ? "…" : ""))") }
                }
                st.entries += entries

                var notebook = lens.carry ? (parsed.notebook.isEmpty ? st.notebook : parsed.notebook) : ""
                if lens.carry, parsed.notebook.isEmpty { log("\(lens.title) window \(i + 1): no NOTEBOOK section in the reply; keeping the previous notebook") }
                if lens.carry, tokens.estimate(notebook) > config.notebookTokens {
                    log("\(lens.title) window \(i + 1): notebook \(tokens.estimate(notebook)) > \(config.notebookTokens), asking to compress")
                    do {
                        let sys = "Compress the notebook below to under \(Int(Double(config.notebookTokens) * 0.7)) tokens (about \(Int(Double(config.notebookTokens) * 0.5)) words). Keep every sentence id that matters, merge duplicates, drop wording. Reply with the compressed notebook only: no preamble, no heading."
                        let room = tokens.clip(notebook, config.windowTokens - tokens.estimate(sys) - 40)
                        if room.clipped { log("\(lens.title) window \(i + 1): notebook larger than the window; its tail was cut before compressing") }
                        ctl.onCall("\(lens.title), compressing the notebook", sys, room.text)
                        let c = try await chat.call(ChatRequest(system: sys, user: room.text, label: "\(lens.id) compress", onToken: ctl.onToken), config: config, budget: config.windowTokens)
                        let t = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { notebook = t }
                    } catch {
                        if (error as? ReaderError)?.cancelled == true || error is CancellationError { progress.lenses[lens.id] = st; try save(); log("stopped"); return false }
                        log("compress failed: \(error.localizedDescription)")
                    }
                    if tokens.estimate(notebook) > config.notebookTokens {
                        notebook = tokens.clip(notebook, config.notebookTokens).text + "\n[notebook overflowed and was cut here]"
                        log("\(lens.title) window \(i + 1): NOTEBOOK OVERFLOW, cut to budget")
                        jlog(folder, ["lens": lens.id, "window": i, "overflow": true])
                    }
                }
                st.notebook = notebook
                st.pos += w.count
                jlog(folder, ["lens": lens.id, "window": i, "promptTokens": res.promptTokens, "estTokens": res.estTokens, "outTokens": res.outTokens, "ms": res.ms, "entries": entries.count])
                let finished = st.pos >= sentences.count && i == ws.count - 1
                try folder.write("lenses/\(lens.id).md", lensFile(lens, entries: st.entries, notebook: st.notebook, done: finished, skipped: st.skipped))
                progress.lenses[lens.id] = st
                try save()
                ctl.onTape(lens.id, i, ws.count, .done)
                let tps = res.tokensPerSecond > 0 ? " at \(res.tokensPerSecond) tok/s" : ""
                log("\(lens.title) \(i + 1)/\(ws.count): \(entries.count) entries, \(res.promptTokens) prompt tokens, \(res.outTokens) out, \(String(format: "%.1f", Double(res.ms) / 1000))s\(tps)")
                try await rest(config, ctl)
            }
            try folder.write("lenses/\(lens.id).md", lensFile(lens, entries: st.entries, notebook: st.notebook, done: st.pos >= sentences.count, skipped: st.skipped))
            progress.lenses[lens.id] = st
            try save()
            ctl.status("\(lens.title): finished")
            log("\(lens.title): finished, \(st.entries.count) entries → lenses/\(lens.id).md")
        }

        // 4. index
        try writeIndex(folder, lenses: lenses, progress: progress)

        // 5. questions
        if let qPos = progress.qPos, qPos < sentences.count, progress.questionsDone {
            log("stream grew since the last question pass; questions will be regenerated")
            progress.questionsDone = false; progress.questions = nil; progress.qIndex = 0; progress.qa = []
        }
        if config.questionCount > 0, !progress.questionsDone {
            if ctl.stopped() { return false }
            log("generating \(config.questionCount) questions from the goals")
            ctl.status("generating questions from the goals and the notes")
            ctl.onTape("questions", 0, config.questionCount, .initial)
            var heads: [String] = []
            let perFile = max(150, (config.windowTokens - 1200) / max(1, active.count))
            for lens in active {
                let st = progress.lenses[lens.id] ?? ReaderProgress.LensState()
                let text = lens.carry && !st.notebook.isEmpty ? st.notebook : st.entries.prefix(60).map { "- [\($0.ids.joined(separator: ", "))] \($0.text)" }.joined(separator: "\n")
                heads.append("## \(lens.title)\n\(tokens.clip(text, perFile).text)")
            }
            var questions = progress.questions
            if questions == nil {
                let system = "The author wrote a long stream of thoughts and asked for help thinking about it. Their goals are below, followed by extracts from notes taken on the stream. Generate \(config.questionCount) questions the author would most want answered about their own text, in the author's interest, grounded in what the notes show is actually there. Favour: what is present, what is associated with what, how feelings about something developed, where the author contradicts themselves, what was left open, and what the notes suggest the author has not noticed. Do not ask for counts or arithmetic. Each question should be answerable from the stream. Write one question per line and nothing else: no numbering, no headings, no preamble."
                let user = "## Goals\n\(goals)\n\n\(heads.joined(separator: "\n\n"))"
                ctl.onCall("Generating questions from the goals", system, user)
                let q: ChatReply
                do { q = try await chat.call(ChatRequest(system: system, user: user, label: "qgen", onToken: ctl.onToken), config: config, budget: config.windowTokens) }
                catch {
                    if (error as? ReaderError)?.cancelled == true || error is CancellationError { try save(); log("stopped"); return false }
                    throw error
                }
                let qs = LensParse.questions(q.text, max: config.questionCount)
                if qs.isEmpty { log("the model wrote no questions; the question pass is skipped for this night") }
                questions = qs
                progress.questions = qs; progress.qIndex = 0; progress.qa = []; progress.qPos = sentences.count
                try save()
                try await rest(config, ctl)
            }
            let qlist = questions ?? []
            var i = progress.qIndex
            while i < qlist.count {
                if ctl.stopped() { try save(); log("stopped"); return false }
                ctl.onTape("questions", i, qlist.count, .now)
                ctl.status("question \(i + 1) of \(qlist.count): \(qlist[i].prefix(80))")
                var opts = Morning.Options()
                opts.includeQuestions = false
                opts.coolOffSec = config.coolOffSec
                opts.stopped = ctl.stopped
                opts.onCall = ctl.onCall
                opts.onToken = ctl.onToken
                opts.log = log
                let n = i
                opts.onStep = { s in ctl.status("question \(n + 1) of \(qlist.count): \(s)") }
                let r: Morning.Answer
                do { r = try await Morning.ask(qlist[i], folder: folder, config: config, lenses: lenses, sentences: sentences, chat: chat, options: opts) }
                catch {
                    if (error as? ReaderError)?.cancelled == true || error is CancellationError { try save(); log("stopped"); return false }
                    throw error
                }
                progress.qa.append(ReaderProgress.QA(q: qlist[i], answer: r.answer, evidence: r.evidence, opened: r.opened))
                progress.qIndex = i + 1
                try folder.write("questions.md", questionsFile(progress.qa, total: qlist.count))
                try save()
                ctl.onTape("questions", i, qlist.count, .done)
                log("question \(i + 1)/\(qlist.count) answered (\(r.steps) steps)")
                try await rest(config, ctl)
                i += 1
            }
            progress.questionsDone = true
            try save()
            try writeIndex(folder, lenses: lenses, progress: progress)
        }
        log("the night is done")
        return true
    }
}
