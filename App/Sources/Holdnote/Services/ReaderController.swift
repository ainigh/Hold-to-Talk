import AppKit
import Foundation
import Harness
import Observation

/// The reader inside Holdnote: the stream (your transcripts, pastes and answers), the reading
/// that goes through it a small chunk at a time with every lens at once, the questions it keeps
/// answered and the ones it asks you, and the note files. It reads whenever there is something
/// new (a transcript joins the stream a minute after it settles), never while you record or
/// transcribe. The engine is the harness's `Reading`, `Asking` and `ReaderStream`; this is the
/// state the window shows and what runs it.
@MainActor
@Observable
final class ReaderController {
    // MARK: - Persisted

    private static let configKey = "reader.config", lensesKey = "reader.lenses", goalsKey = "reader.goals", folderKey = "reader.folder", gapsOfferedKey = "reader.gapsOffered", cptKey = "reader.cpt"

    var config: ReaderConfig { didSet { save(); if !running { refreshStream() } } }
    var lenses: [Lens] { didSet { save(); if !running { refreshStream() } } }
    var goals: String { didSet { saveGoalsSoon() } }
    private(set) var folder: NotesFolder?

    // MARK: - Ollama

    enum Ollama: Equatable { case checking, ok(String), bad(String) }
    private(set) var ollama: Ollama = .checking
    private(set) var models: [String] = []
    var ollamaOK: Bool { if case .ok = ollama { return true }; return false }
    private(set) var contextNote = ""
    @ObservationIgnored private var ollamaRetry: Timer?

    // MARK: - The stream

    private(set) var stream = ReaderStream.State()
    private(set) var additions: [ReaderStream.Addition] = []
    @ObservationIgnored private var spans: [ReaderStream.Span] = []
    private(set) var gaps: (open: [ReaderStream.Gap], answered: Int)?
    private(set) var unfedCount = 0
    private(set) var plan: ReaderStream.Plan?
    /// What every lens has written so far, by lens id (from progress.json).
    private(set) var entries: [String: [LensParse.Entry]] = [:]
    /// The questions kept answered (pinned first), and their answers.
    private(set) var questions: [String] = []
    private(set) var pinned: [String] = []
    private(set) var answers: [String: ReaderProgress.QA] = [:]
    /// By recording id: the sentence numbers it put in the stream, and its text's fingerprint when it last joined.
    private(set) var bySource: [String: (ids: [Int], hash: String?)] = [:]
    /// By recording id: the reader's open questions about it.
    private(set) var questionsBySource: [String: Int] = [:]
    @ObservationIgnored private var sentencesCache: [Sentence]?
    @ObservationIgnored private var fed: Set<String> = []
    @ObservationIgnored private var settle = ReaderStream.Settle()

    // MARK: - Reading

    struct LiveCall: Equatable {
        var label = ""
        var system = ""
        var user = ""
        var output = ""
        var thinking = ""
        var started = Date()
        var note = ""
    }
    struct ChunkInfo: Equatable {
        var from: String
        var to: String
        var readers: [String]
    }
    struct QuestionInfo: Equatable {
        var done: Int
        var total: Int
        var current: String
    }

    private(set) var running = false
    private(set) var stopping = false
    /// Started by itself (new material), not by a click.
    private(set) var runningAuto = false
    private(set) var status = ""
    private(set) var log: [String] = []
    private(set) var live: LiveCall?
    private(set) var chunk: ChunkInfo?
    private(set) var marks: [String: Reading.Mark] = [:]
    private(set) var readCount = 0
    private(set) var totalCount = 0
    private(set) var questionInfo: QuestionInfo?
    /// Said once in the window after reading ends.
    private(set) var lastOutcome: String?
    /// After a failure, reading does not start by itself again until then (a click still starts it).
    private(set) var pausedUntil: Date?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var readStarted = Date()
    /// "Stop after this call": read by the reading from its own task.
    @ObservationIgnored private let stopFlag = Flag()
    @ObservationIgnored private let requests = RequestBox()
    @ObservationIgnored private var awake: NSObjectProtocol?
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var notesRefresh: Task<Void, Never>?
    let tokens = TokenEstimator()

    /// How far reading has come, 0–100: sentences read by every lens, then the questions.
    var percent: Int {
        if totalCount > 0, readCount < totalCount { return Int(100 * Double(readCount) / Double(totalCount)) }
        if let q = questionInfo, q.total > 0 { return Int(100 * Double(q.done) / Double(q.total)) }
        return running ? 0 : 100
    }

    // MARK: - Asking

    private(set) var chat: [ReaderStream.Turn] = []
    private(set) var asking = false
    private(set) var askStep = ""
    private(set) var askLive = ""
    @ObservationIgnored private var askTask: Task<Void, Never>?

    // MARK: - Answering by voice

    /// The question the next recording answers, and since when.
    private(set) var voiceAnswer: ReaderStream.Gap?
    @ObservationIgnored private var voiceArmedAt = Date()

    // MARK: - Notes

    struct NoteFile: Identifiable, Equatable {
        var name: String
        var size: Int
        var id: String { name }
        /// "folder" for a file at the root, else the first path part.
        var group: String { name.contains("/") ? String(name[..<name.firstIndex(of: "/")!]) : "folder" }
        var shortName: String { name.contains("/") ? String(name[name.index(after: name.firstIndex(of: "/")!)...]) : name }
    }
    private(set) var files: [NoteFile] = []
    var currentFile: String?
    var fileBody = ""
    @ObservationIgnored private var loadedBody = ""
    var fileDirty: Bool { currentFile != nil && fileBody != loadedBody }

    /// Holdnote's recordings in the order things happened (the list read from the bottom up),
    /// for feeding the stream.
    @ObservationIgnored var recordings: () -> [Recording] = { [] }
    /// A recording, by id, for "where did this sentence come from".
    @ObservationIgnored var recording: (UUID) -> Recording? = { _ in nil }
    /// Something is being recorded or transcribed: reading does not start by itself then.
    @ObservationIgnored var isBusy: () -> Bool = { false }
    /// The window is in front, so a notification is not needed.
    @ObservationIgnored var isWindowKey: () -> Bool = { false }
    /// The words the stream uses most, one per line (word · kind · times), for the asking prompt.
    @ObservationIgnored var wordsSummary: () -> String = { "" }
    /// The sentences as vectors, for the SIMILAR move.
    let indexer = EmbeddingIndexer()

    init() {
        let d = UserDefaults.standard
        config = (d.data(forKey: Self.configKey).flatMap { try? JSONDecoder().decode(ReaderConfig.self, from: $0) } ?? ReaderConfig()).clamped()
        var l = d.data(forKey: Self.lensesKey).flatMap { try? JSONDecoder().decode([Lens].self, from: $0) } ?? []
        if l.isEmpty { l = Lens.defaults }
        // Lenses added to the defaults after a user first saved theirs are offered once, at the end of their list.
        else if !d.bool(forKey: Self.gapsOfferedKey), !l.contains(where: { $0.id == Lens.gapsId }), let gaps = Lens.defaults.first(where: { $0.id == Lens.gapsId }) {
            l.append(gaps)
            d.set(true, forKey: Self.gapsOfferedKey)
        }
        // Default lenses whose instructions were never edited follow the defaults as they change.
        let legacy = Self.legacyInstructions
        for i in l.indices {
            if let def = Lens.defaults.first(where: { $0.id == l[i].id }), let old = legacy[l[i].id], l[i].instructions == old { l[i].instructions = def.instructions; l[i].purpose = def.purpose }
        }
        lenses = l
        goals = d.string(forKey: Self.goalsKey) ?? ""
        let cpt = d.double(forKey: Self.cptKey)
        tokens.charsPerToken = cpt > 0 ? cpt : config.charsPerToken
    }

    /// Once the app has launched: the folder, Ollama, the clock that feeds and reads.
    func start() {
        let path = UserDefaults.standard.string(forKey: Self.folderKey)
        setFolder(path.map { URL(fileURLWithPath: $0) } ?? Self.defaultFolder)
        refreshModels()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    static var defaultFolder: URL { RecordingStore.defaultRoot.appendingPathComponent("Reader") }

    private func save() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(config) { d.set(data, forKey: Self.configKey) }
        if let data = try? JSONEncoder().encode(lenses) { d.set(data, forKey: Self.lensesKey) }
    }

    @ObservationIgnored private var goalsTimer: Timer?
    private(set) var goalsState = ""
    private func saveGoalsSoon() {
        goalsState = "saving…"
        goalsTimer?.invalidate()
        goalsTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                UserDefaults.standard.set(self.goals, forKey: Self.goalsKey)
                self.goalsState = "saved"
                if !self.running { self.refreshStream() }
                Task { try? await Task.sleep(for: .seconds(1.5)); if self.goalsState == "saved" { self.goalsState = "" } }
            }
        }
    }

    // MARK: - Folder

    func chooseFolder() {
        if running { addLog("Reading is running; stop it before changing folders."); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        panel.message = "The reader's notes go into this folder. Empty is fine, or one with a stream.txt."
        panel.directoryURL = folder?.root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url)
    }

    func useDefaultFolder() { setFolder(Self.defaultFolder) }

    func setFolder(_ url: URL) {
        if running { addLog("Reading is running; stop it before changing folders."); return }
        do {
            folder = try NotesFolder(root: url)
            UserDefaults.standard.set(url.path, forKey: Self.folderKey)
        } catch {
            addLog("Could not open the folder \(url.path): \(error.localizedDescription)")
            if url.path != Self.defaultFolder.path { setFolder(Self.defaultFolder) }
            return
        }
        sentencesCache = nil
        if let folder, let g = folder.read("goals.md"), goals.trimmingCharacters(in: .whitespaces).isEmpty {
            goals = g.replacingOccurrences(of: "# Goals and intent\n", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        chat = folder.map(ReaderStream.loadChat) ?? []
        currentFile = nil; fileBody = ""; loadedBody = ""
        indexer.reset()
        refreshStream()
        refreshFiles()
    }

    func showFolderInFinder() {
        if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder.root]) }
    }

    // MARK: - Ollama

    func refreshModels(quiet: Bool = false) {
        if !quiet { ollama = .checking }
        let client = OllamaClient(base: config.base)
        let wanted = config.model
        Task {
            do {
                let list = try await client.listModels()
                models = list
                if !wanted.isEmpty, !list.contains(wanted), let first = list.first {
                    addLog("the model “\(wanted)” is no longer pulled; using \(first)")
                    config.model = first
                } else if wanted.isEmpty, let first = list.first {
                    config.model = first
                }
                if list.isEmpty {
                    ollama = .bad("Ollama is running but has no models. Pull one, e.g. ollama pull llama3.1:8b")
                } else {
                    let p = await client.probe(model: config.model)
                    if p.ok { ollama = .ok("Connected · \(list.count) model\(list.count == 1 ? "" : "s") at \(client.base)") }
                    else { ollama = .bad("Ollama lists models but refused a test call\(p.status > 0 ? " with \(p.status)" : "")\(p.error.map { ": " + $0 } ?? "")") }
                }
            } catch {
                models = []
                ollama = .bad("Could not reach \(client.base). Is Ollama running? Start it with `ollama serve`, or open the Ollama app.")
            }
            ollamaRetry?.invalidate()
            if !ollamaOK {
                ollamaRetry = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshModels(quiet: true) }
                }
            } else {
                // A failure that was Ollama's is over once it answers again (a pause by hand is kept).
                if pausedUntil != .distantFuture { pausedUntil = nil }
            }
            refreshPlan()
        }
    }

    /// Reads the model's trained context length and sizes W to it; memory, not the trained length,
    /// is the real ceiling, so the result is shown and left for the user to keep or trim.
    func useModelMaximum() {
        guard !config.model.isEmpty else { contextNote = "No model selected."; return }
        contextNote = "Asking Ollama…"
        let client = OllamaClient(base: config.base)
        let model = config.model
        Task {
            do {
                let info = try await client.modelInfo(model)
                guard info.contextLength > 0 else { contextNote = "Ollama did not report a context length for \(model)."; return }
                let w = max(1000, (info.contextLength - config.outputTokens - 512) / 500 * 500)
                config.windowTokens = w
                contextNote = "\(model) is trained for \(info.contextLength.formatted()) tokens\(info.modelfileCtx > 0 ? " (its Modelfile sets num_ctx \(info.modelfileCtx.formatted()))" : ""). W is now \(w.formatted()) and num_ctx will be \(config.numCtx.formatted()). A context this large needs memory in proportion; if Ollama slows to a crawl or spills to the CPU, lower W. A larger W lets more lenses share one call."
            } catch { contextNote = "Could not read the model: \(error.localizedDescription)" }
        }
    }

    // MARK: - The stream

    var sentences: [Sentence] {
        if let sentencesCache { return sentencesCache }
        let s = folder.map(ReaderStream.sentences) ?? []
        sentencesCache = s
        return s
    }

    func sentence(_ id: String) -> String? {
        let all = sentences
        if let n = Sentences.number(id), n >= 1, n <= all.count, all[n - 1].id == id { return all[n - 1].text }
        return all.first { $0.id == id }?.text
    }

    /// The recording a sentence came from, when it came from one still in the list.
    func origin(of id: String) -> Recording? {
        guard let n = Sentences.number(id), let source = ReaderStream.span(of: n, in: spans)?.source, let uuid = UUID(uuidString: source) else { return nil }
        return recording(uuid)
    }

    func refreshStream() {
        guard let folder else {
            stream = ReaderStream.State(); additions = []; spans = []; gaps = nil; plan = nil; entries = [:]; questions = []; answers = [:]; pinned = []
            bySource = [:]; questionsBySource = [:]; unfedCount = 0
            return
        }
        sentencesCache = nil
        stream = ReaderStream.state(in: folder, config: config, lenses: lenses, goals: goals)
        indexer.schedule(folder: folder, sentences: sentences, base: config.base, model: config.embedModel)
        additions = ReaderStream.additions(in: folder)
        spans = ReaderStream.spans(in: folder)
        fed = ReaderStream.sources(in: folder)
        var by: [String: (ids: [Int], hash: String?)] = [:]
        for a in additions {
            guard let source = a.source, let f = Sentences.number(a.from), let t = Sentences.number(a.to), f <= t else { continue }
            var item = by[source] ?? ([], nil)
            item.ids += Array(f...t)
            if a.kind == nil || a.kind == "revision" { item.hash = a.hash }
            by[source] = item
        }
        bySource = by
        refreshNotes()
        unfedCount = ReaderStream.unfed(recordings(), in: folder, keepOrder: true).count
        refreshPlan()
    }

    /// What the lenses wrote and the questions' answers, from progress.json; the questions for you.
    private func refreshNotes() {
        guard let folder else { return }
        let p = ReaderProgress.load(folder)
        entries = p.lenses.mapValues(\.entries)
        pinned = ReaderStream.pinned(in: folder)
        questions = Reading.questionList(progress: p, pinned: pinned)
        answers = Dictionary(p.qa.map { ($0.q, $0) }, uniquingKeysWith: { _, b in b })
        gaps = lenses.contains { $0.id == Lens.gapsId && $0.on } ? ReaderStream.gaps(in: folder) : nil
        var counts: [String: Int] = [:]
        for g in gaps?.open ?? [] {
            let sources = Set(g.ids.compactMap { Sentences.number($0).flatMap { ReaderStream.span(of: $0, in: spans)?.source } })
            for source in sources { counts[source, default: 0] += 1 }
        }
        questionsBySource = counts
        if !running { totalCount = stream.count; readCount = stream.count - stream.unread }
        refreshNotesCount()
    }

    /// Called by the window when the library changed, so "n transcripts not yet in the stream" is right.
    func libraryChanged() {
        guard let folder else { return }
        unfedCount = ReaderStream.unfed(recordings(), in: folder).count
    }

    func refreshPlan() {
        guard folder != nil, stream.unread > 0 || stream.questionsPending > 0 else { plan = nil; return }
        plan = ReaderStream.plan(config: config, lenses: lenses, goals: goals, unread: stream.unread, averageChars: stream.averageChars, pendingQuestions: stream.questionsPending, tokens: tokens)
    }

    /// Pasted or dropped text joins the stream. Returns what was added.
    @discardableResult
    func addText(_ text: String) -> [Sentence]? {
        guard let folder else { addLog("Choose a folder first."); return nil }
        do {
            let added = try ReaderStream.append(text, to: folder)
            if !added.isEmpty { addLog("added \(added.count) sentences (\(added[0].id)–\(added[added.count - 1].id))") }
            refreshStream()
            return added
        } catch { addLog("add failed: \(error.localizedDescription)"); return nil }
    }

    /// Every final transcript not yet in the stream joins it now, settled or not, in the order things happened.
    @discardableResult
    func feedTranscripts() -> (recordings: Int, sentences: Int)? {
        guard let folder else { return nil }
        do {
            let fed = try ReaderStream.feed(recordings(), into: folder, keepOrder: true)
            if fed.recordings > 0 { addLog("added \(fed.recordings) transcript\(fed.recordings == 1 ? "" : "s") (\(fed.sentences) sentences) to the stream") }
            refreshStream()
            return fed
        } catch { addLog("could not add transcripts: \(error.localizedDescription)"); return nil }
    }

    /// One recording joins the stream now.
    func feed(_ r: Recording) {
        guard let folder else { return }
        do {
            let fed = try ReaderStream.feed([r], into: folder, keepOrder: true)
            if fed.recordings > 0 { addLog("added a transcript (\(fed.sentences) sentences) to the stream") }
            refreshStream()
        } catch { addLog("could not add the transcript: \(error.localizedDescription)") }
    }

    /// An edited transcript joins again as a correction.
    func revise(_ r: Recording) {
        guard let folder else { return }
        do {
            let added = try ReaderStream.revise(r, in: folder)
            if !added.isEmpty { addLog("added the corrected transcript (\(added[0].id)–\(added[added.count - 1].id))") }
            refreshStream()
        } catch { addLog("could not add the correction: \(error.localizedDescription)") }
    }

    /// Transcripts that have settled join the stream (once a minute or so after they are final and unedited).
    private func feedSettled() {
        guard let folder, config.feedTranscripts else { return }
        let ready = settle.ready(recordings(), fed: fed, seconds: TimeInterval(config.settleSeconds))
        guard !ready.isEmpty else { return }
        do {
            let n = try ReaderStream.feed(ready, into: folder, keepOrder: true)
            if n.recordings > 0 { addLog("\(n.recordings) transcript\(n.recordings == 1 ? "" : "s") joined the stream (\(n.sentences) sentences)") }
        } catch { addLog("could not add transcripts: \(error.localizedDescription)") }
        refreshStream()
    }

    func standing(of r: Recording) -> ReaderStream.Standing {
        ReaderStream.standing(of: r, additions: additions)
    }

    /// What a row in the recordings list shows about the reader.
    enum RowMark: Equatable { case waiting, unread, edited, questions(Int) }

    func rowMark(for r: Recording) -> RowMark? {
        guard folder != nil, r.status == .final, !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let id = r.id.uuidString
        guard let s = bySource[id] else { return config.feedTranscripts ? .waiting : nil }
        if let q = questionsBySource[id], q > 0 { return .questions(q) }
        if let h = s.hash, h != ReaderStream.fingerprint(r.text) { return .edited }
        let read = running ? readCount : stream.count - stream.unread
        if (s.ids.max() ?? 0) > read { return .unread }
        return nil
    }

    struct Finding: Identifiable {
        var lens: Lens
        var entries: [LensParse.Entry]
        var id: String { lens.id }
    }

    /// What each lens wrote that cites any of these sentences, lens by lens in their order.
    func findings(for ids: [Int]) -> [Finding] {
        guard let lo = ids.min(), let hi = ids.max() else { return [] }
        let set = Set(ids)
        return lenses.filter { $0.on && $0.id != Lens.gapsId }.compactMap { lens in
            let mine = (entries[lens.id] ?? []).filter { e in e.ids.contains { id in Sentences.number(id).map { $0 >= lo && $0 <= hi && set.contains($0) } ?? false } }
            return mine.isEmpty ? nil : Finding(lens: lens, entries: mine)
        }
    }

    /// The reader's open questions that these sentences raised.
    func gapsAbout(_ ids: [Int]) -> [ReaderStream.Gap] {
        let set = Set(ids)
        return (gaps?.open ?? []).filter { g in g.ids.contains { Sentences.number($0).map(set.contains) ?? false } }
    }

    /// The recording a question for you came from.
    func origin(of gap: ReaderStream.Gap) -> Recording? {
        for id in gap.ids { if let r = origin(of: id) { return r } }
        return nil
    }

    /// Answers one of the reader's questions; with `source`, the recording it was spoken in.
    func answer(_ gap: ReaderStream.Gap, with answer: String, source: UUID? = nil) -> String? {
        guard let folder else { return "Choose a folder first." }
        do {
            let added = try ReaderStream.answer(gap, with: answer, in: folder, source: source?.uuidString)
            if voiceAnswer?.id == gap.id { voiceAnswer = nil }
            refreshStream()
            return added.isEmpty ? nil : "Answer added to the stream (\(added[0].id)–\(added[added.count - 1].id))"
        } catch { return "Could not save the answer: \(error.localizedDescription)" }
    }

    /// The next recording answers this question.
    func armVoiceAnswer(_ gap: ReaderStream.Gap) {
        voiceAnswer = gap
        voiceArmedAt = Date()
    }

    func disarmVoiceAnswer() { voiceAnswer = nil }

    /// A recording's transcript is in. Says whether it answered the question waiting for a voice answer.
    @discardableResult
    func transcriptFinished(_ r: Recording) -> Bool {
        guard let gap = voiceAnswer, r.createdAt >= voiceArmedAt.addingTimeInterval(-1), !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let msg = answer(gap, with: r.text, source: r.id)
        addLog(msg ?? "answered “\(gap.question)” by voice")
        return true
    }

    // MARK: - Readiness

    /// What stands between the user and reading, in the order to fix it.
    var blocker: (text: String, step: String)? {
        if folder == nil { return ("Choose a folder for the notes first.", "folder") }
        if stream.count == 0, !stream.rawPresent, unfedCount == 0 { return ("Nothing to read yet. Record something, or paste text into the stream.", "stream") }
        if !ollamaOK { return ("Ollama is not reachable, or has no model.", "ollama") }
        if !lenses.contains(where: \.on) { return ("No lens is switched on.", "lenses") }
        return nil
    }

    var hasNotes: Bool { notesCount > 0 }
    private(set) var notesCount = 0
    private func refreshNotesCount() {
        guard let folder else { notesCount = 0; return }
        let list = folder.list()
        notesCount = list.filter { $0.hasPrefix("lenses/") && $0.hasSuffix(".md") }.count + (list.contains("questions.md") ? 1 : 0)
    }

    /// Something to do: unread sentences, transcripts waiting, questions to answer.
    var hasWork: Bool { stream.hasWork || unfedCount > 0 }

    var startTitle: String {
        if running { return "Reading…" }
        return hasWork ? "Read now" : "Up to date"
    }

    // MARK: - Reading

    func addLog(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.append("[\(f.string(from: Date()))] \(message)")
        if log.count > 600 { log.removeFirst(log.count - 600) }
    }

    var logText: String { log.joined(separator: "\n") }

    /// Every few seconds: settled transcripts join the stream, and reading starts by itself when
    /// there is something new, nothing is being recorded or transcribed, and Ollama answers.
    private func tick() {
        guard folder != nil, !running else { return }
        feedSettled()
        guard config.autoRead, ollamaOK, blocker == nil, !isBusy(), !asking else { return }
        if let pausedUntil, Date() < pausedUntil { return }
        guard stream.hasWork else { return }
        startReading(auto: true)
    }

    func startReading(auto: Bool = false) {
        guard !running else { return }
        guard let folder else { addLog("Choose a folder first."); return }
        if config.model.isEmpty { addLog("No model selected. Is Ollama running?"); refreshModels(); return }
        if !lenses.contains(where: \.on) { addLog("No lens is switched on."); return }
        if !auto {
            pausedUntil = nil
            if config.feedTranscripts { feedTranscripts() }
        }
        do { if try ReaderStream.number(folder) { refreshStream() } } catch { addLog("could not number stream.txt: \(error.localizedDescription)") }
        guard stream.count > 0 else { addLog("Nothing to read yet. Record something, or paste text into the stream."); return }
        UserDefaults.standard.set(goals, forKey: Self.goalsKey)
        let cfg = config.clamped()
        running = true; stopping = false; runningAuto = auto; stopFlag.value = false
        lastOutcome = nil
        live = nil; chunk = nil; marks = [:]; questionInfo = nil
        totalCount = stream.count; readCount = stream.count - stream.unread
        readStarted = Date()
        tokens.charsPerToken = cfg.charsPerToken
        if cfg.keepAwake { awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Reading the stream") }
        addLog("\(auto ? "new material; reading" : "reading"): model \(cfg.model), W \(cfg.windowTokens), \(cfg.chunkSentences == 0 ? "as many sentences as fit" : "\(cfg.chunkSentences) sentences") at a time, \(cfg.lensesPerCall == 0 ? "as many lenses per call as fit" : "\(cfg.lensesPerCall) lens\(cfg.lensesPerCall == 1 ? "" : "es") per call"), \(cfg.coolOffSec)s between calls")
        status = "starting…"
        let lenses = self.lenses, goals = self.goals
        let chat = MeasuredChat(model: OllamaClient(base: cfg.base), tokens: tokens)
        var ctl = Reading.Control()
        let stopFlag = self.stopFlag, requests = self.requests
        ctl.stopped = { stopFlag.value }
        ctl.takeRequest = { requests.take() }
        ctl.log = { [weak self] m in Task { @MainActor in self?.addLog(m) } }
        ctl.status = { [weak self] s in Task { @MainActor in self?.status = s } }
        ctl.onChunk = { [weak self] a, b, n, readers in Task { @MainActor in self?.onChunk(a, b, n, readers) } }
        ctl.onLens = { [weak self] id, mark in Task { @MainActor in self?.marks[id] = mark } }
        ctl.onRead = { [weak self] read, total in Task { @MainActor in self?.readCount = read; self?.totalCount = total } }
        ctl.onQuestion = { [weak self] done, total, q in Task { @MainActor in self?.questionInfo = QuestionInfo(done: done, total: total, current: q); self?.chunk = nil } }
        ctl.onCall = { [weak self] label, system, user in Task { @MainActor in self?.live = LiveCall(label: label, system: system, user: user) } }
        ctl.onToken = { [weak self] text, thinking in Task { @MainActor in self?.live?.output = text; self?.live?.thinking = thinking } }
        ctl.onNotes = { [weak self] in Task { @MainActor in self?.notesChanged() } }
        readTask = Task { [weak self] in
            var finished = false
            var problem: String?
            do { finished = try await Reading.run(folder: folder, config: cfg, lenses: lenses, goals: goals, chat: chat, control: ctl) }
            catch {
                // Stop now while resting between calls cancels the sleep: a stop, not a failure.
                if !(error is CancellationError || (error as? ReaderError)?.cancelled == true) {
                    problem = (error as? ReaderError)?.message ?? error.localizedDescription
                }
            }
            await MainActor.run { self?.readingEnded(finished: finished, problem: problem) }
        }
    }

    private func onChunk(_ a: Int, _ b: Int, _ n: Int, _ readers: [String]) {
        chunk = ChunkInfo(from: Sentences.makeId(a + 1), to: Sentences.makeId(b), readers: readers)
        totalCount = n
        questionInfo = nil
    }

    /// Lens files changed during reading: what the window shows follows, at most every couple of seconds.
    private func notesChanged() {
        guard notesRefresh == nil else { return }
        notesRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else { return }
            self.notesRefresh = nil
            let before = self.gaps?.open.count ?? 0
            self.sentencesCache = nil
            self.refreshNotes()
            self.newQuestionsForYou += max(0, (self.gaps?.open.count ?? 0) - before)
            self.refreshFiles()
        }
    }

    /// Questions for you raised since reading started (for one notification at the end).
    @ObservationIgnored private var newQuestionsForYou = 0

    private func readingEnded(finished: Bool, problem: String?) {
        let auto = runningAuto
        running = false; stopping = false; runningAuto = false; status = ""
        readTask = nil
        chunk = nil
        if let awake { ProcessInfo.processInfo.endActivity(awake); self.awake = nil }
        let raised = newQuestionsForYou
        newQuestionsForYou = 0
        if let problem {
            addLog("ERROR: \(problem)")
            lastOutcome = problem
            // Not again by itself for a while; a click (or Ollama coming back) clears it.
            pausedUntil = Date().addingTimeInterval(10 * 60)
            if !isWindowKey() { Notifier.post(title: "The reader stopped", body: problem, open: ReaderView.reading.rawValue) }
        } else if finished {
            lastOutcome = "Up to date. Ask about it, or answer what the reader asked you."
            let long = Date().timeIntervalSince(readStarted) > 120
            if !isWindowKey() {
                if raised > 0 {
                    Notifier.post(title: "The reader has \(raised) question\(raised == 1 ? "" : "s") for you", body: "About what you said. Answer by voice or by typing.", open: ReaderView.forYou.rawValue)
                } else if !auto && long {
                    Notifier.post(title: "The reader is up to date", body: "Ask about what it found.", open: "stream")
                }
            }
        } else {
            // A stop by hand is a wish to pause (stopAfterCall and stopNow set pausedUntil): not
            // again by itself until Read now.
            lastOutcome = "Paused. Read now carries on from the same place\(config.autoRead ? " and lets it read by itself again" : "")."
        }
        live?.note = finished ? "up to date" : "stopped"
        config.charsPerToken = (tokens.charsPerToken * 100).rounded() / 100
        UserDefaults.standard.set(tokens.charsPerToken, forKey: Self.cptKey)
        refreshStream()
        refreshFiles()
        let todo = afterStop
        afterStop = []
        for action in todo { action() }
    }

    // MARK: - Starting over

    /// Runs `action` once reading has stopped (stopping it now if it runs), so nothing it saves
    /// lands after a reset.
    func whenIdle(_ action: @escaping @MainActor () -> Void) {
        if running { afterStop.append(action); stopNow() } else { action() }
    }
    @ObservationIgnored private var afterStop: [@MainActor () -> Void] = []

    /// The files the reader writes; a reset moves only these, so a folder of your own keeps its other files.
    static let readerFiles = ["sentences.txt", "stream.txt", "additions.json", "sources.json", "goals.md", "lenses", "answers.md",
                              "questions.md", "pinned.json", "index.md", "corrections.md", "chat.json", "progress.json", "log.jsonl",
                              VectorStore.file, VectorStore.meta]

    /// The reader starts from nothing: its files go to the Trash in one folder, and the goals,
    /// the conversation and what it was doing are forgotten. Lenses and settings stay. Call it
    /// through `whenIdle`. Returns where the old files went, or the problem.
    func reset() -> Result<URL?, Error> {
        guard let folder, !running else { return .success(nil) }
        askTask?.cancel()
        let moved: URL?
        do { moved = try StartOver.trash(Self.readerFiles.map { folder.root.appendingPathComponent($0) }, named: "Holdnote reader notes", in: folder.root) }
        catch { return .failure(error) }
        goals = ""
        UserDefaults.standard.removeObject(forKey: Self.goalsKey)
        chat = []; voiceAnswer = nil
        log = []; lastOutcome = nil; live = nil; chunk = nil; marks = [:]; questionInfo = nil; status = ""
        pausedUntil = nil
        settle = ReaderStream.Settle()
        sentencesCache = nil
        currentFile = nil; fileBody = ""; loadedBody = ""
        newQuestionsForYou = 0
        indexer.reset()
        addLog("started over: the reader's notes went to the Trash")
        refreshStream()
        refreshFiles()
        return .success(moved)
    }

    func stopAfterCall() {
        guard running else { return }
        stopFlag.value = true; stopping = true
        pausedUntil = .distantFuture
        addLog("will stop after the current call")
    }

    func stopNow() {
        guard running else { return }
        stopFlag.value = true; stopping = true
        pausedUntil = .distantFuture
        addLog("stopping now; the call in progress is cut short")
        readTask?.cancel()
    }

    /// Reading by itself again after a stop (new material also does it).
    func resumeAuto() { pausedUntil = nil }

    func clearProgress() {
        guard let folder, !running else { return }
        try? folder.write("progress.json", "{}")
        addLog("progress cleared; every lens reads from the start")
        refreshStream()
    }

    // MARK: - The questions about your goals

    func pin(_ question: String) {
        guard let folder else { return }
        try? ReaderStream.pin(question, in: folder)
        refreshStream()
    }

    func unpin(_ question: String) {
        guard let folder else { return }
        try? ReaderStream.unpin(question, in: folder)
        refreshStream()
    }

    /// New questions from the goals; the answers to ones still asked are kept.
    func regenerateQuestions() {
        requests.put(.regenerate)
        if !running { startReading() }
    }

    /// Every answer again, from the notes as they are now.
    func refreshAnswers() {
        requests.put(.refreshAll)
        if !running { startReading() }
    }

    // MARK: - Asking

    /// A question about the stream; with `about`, about one recording (its sentences are read first).
    func ask(_ question: String, about r: Recording? = nil) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking, let folder else { return }
        if config.model.isEmpty { addLog("No model selected. Is Ollama running?"); return }
        var opts = Asking.Options()
        let cfgBase = config.base
        var label: String?
        if let r, case let .inStream(ids, _) = standing(of: r) {
            label = "your recording of \(r.createdAt.formatted(date: .abbreviated, time: .shortened))"
            opts.about = label
            opts.focus = ids.map(Sentences.makeId)
        }
        opts.words = wordsSummary()
        if indexer.available {
            let indexer = self.indexer, base = cfgBase, embedModel = config.embedModel, byId = Dictionary(sentences.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
            let budget = config.clamped().pageTokens, tokens = self.tokens
            opts.similar = { phrase, offset in
                try await indexer.similar(phrase, offset: offset, base: base, model: embedModel, sentences: byId, budget: budget, tokens: tokens)
            }
        }
        asking = true; askStep = "reading the notes"; askLive = ""
        let turn = ReaderStream.Turn(q: q, about: r?.id.uuidString, aboutLabel: label)
        chat.append(turn)
        let cfg = config.clamped()
        let lenses = self.lenses, sentences = self.sentences
        let chatModel = MeasuredChat(model: OllamaClient(base: cfg.base), tokens: tokens)
        opts.onStep = { [weak self] s in Task { @MainActor in self?.askStep = s; self?.askLive = "" } }
        opts.onToken = { [weak self] text, _ in Task { @MainActor in self?.askLive = text } }
        opts.log = { [weak self] m in Task { @MainActor in self?.addLog("asking: " + m) } }
        let options = opts
        askTask = Task { [weak self] in
            var done = turn
            do {
                let res = try await Asking.ask(q, folder: folder, config: cfg, lenses: lenses, sentences: sentences, chat: chatModel, options: options)
                done.answer = res.answer; done.evidence = res.evidence; done.unread = res.unread; done.steps = res.steps; done.trace = res.trace; done.opened = res.opened
            } catch {
                let e = error as? ReaderError
                done.error = (e?.cancelled == true || error is CancellationError) ? "cancelled" : (e?.message ?? error.localizedDescription)
            }
            let finished = done
            await MainActor.run { self?.askEnded(finished) }
        }
    }

    private func askEnded(_ turn: ReaderStream.Turn) {
        asking = false; askTask = nil; askStep = ""; askLive = ""
        if let i = chat.firstIndex(where: { $0.id == turn.id }) { chat[i] = turn }
        if let folder { try? ReaderStream.saveChat(chat, in: folder) }
        UserDefaults.standard.set(tokens.charsPerToken, forKey: Self.cptKey)
    }

    func cancelAsk() { askTask?.cancel() }

    func turns(about r: Recording) -> [ReaderStream.Turn] {
        let id = r.id.uuidString
        return chat.filter { $0.about == id }
    }

    func flag(_ turn: ReaderStream.Turn, note: String) -> String? {
        guard let folder else { return "Choose a folder first." }
        do {
            try ReaderStream.flag(question: turn.q, answer: turn.answer, note: note, in: folder)
            if let i = chat.firstIndex(where: { $0.id == turn.id }) { chat[i].flagged = true }
            try ReaderStream.saveChat(chat, in: folder)
            return nil
        } catch { return "Could not write corrections.md: \(error.localizedDescription)" }
    }

    func clearChat() {
        chat = []
        if let folder { try? ReaderStream.saveChat(chat, in: folder) }
    }

    // MARK: - Notes

    func refreshFiles() {
        guard let folder else { files = []; return }
        files = folder.list().map { NoteFile(name: $0, size: folder.size($0)) }
        refreshNotesCount()
        // The file open in the editor follows the reader's writes unless you are editing it.
        if let currentFile, !fileDirty, let text = folder.read(currentFile), text != loadedBody { loadedBody = text; fileBody = text }
    }

    /// Opens a file in the editor. Returns false when unsaved changes are in the way.
    @discardableResult
    func openFile(_ name: String, discarding: Bool = false) -> Bool {
        guard let folder else { return false }
        if name == currentFile { return true }
        if fileDirty, !discarding { return false }
        guard let text = folder.read(name) else { addLog("Could not read \(name). It may have been moved or deleted."); refreshFiles(); return true }
        currentFile = name; loadedBody = text; fileBody = text
        return true
    }

    func saveFile() -> String? {
        guard let folder, let currentFile, fileDirty else { return nil }
        do {
            try folder.write(currentFile, fileBody)
            loadedBody = fileBody
            refreshStream(); refreshFiles()
            return "Saved \(currentFile)"
        } catch { return "Could not save: \(error.localizedDescription)" }
    }

    // MARK: - Lenses

    func addLens() -> String {
        let id = uniqueLensId("new-lens")
        lenses.append(Lens(id: id, title: "New lens", instructions: "Describe what to look for in each chunk and what each entry should say. Every entry must cite ids."))
        return id
    }

    func uniqueLensId(_ base: String, except: String? = nil) -> String {
        var id = base, k = 2
        while lenses.contains(where: { $0.id == id && $0.id != except }) { id = "\(base)-\(k)"; k += 1 }
        return id
    }

    /// A lens of the user's own follows its title; a default lens keeps its id (and its file).
    /// Returns the lens's id afterwards.
    @discardableResult
    func rename(_ id: String, to title: String) -> String {
        guard let i = lenses.firstIndex(where: { $0.id == id }) else { return id }
        lenses[i].title = title
        guard !Lens.defaults.contains(where: { $0.id == id }) else { return id }
        let newId = uniqueLensId(Lens.slug(title), except: id)
        if newId != id {
            lenses[i].id = newId
            for j in lenses.indices { lenses[j].reads = lenses[j].reads.map { $0 == id ? newId : $0 } }
        }
        return newId
    }

    func move(_ id: String, by delta: Int) {
        guard let i = lenses.firstIndex(where: { $0.id == id }), lenses.indices.contains(i + delta) else { return }
        lenses.swapAt(i, i + delta)
    }

    func removeLens(_ id: String) { lenses.removeAll { $0.id == id } }

    func resetLenses() { lenses = Lens.defaults }

    /// Problems with what a lens reads: ids that do not exist, lenses that carry no notebook or are off.
    func readsProblems(of lens: Lens) -> [String] {
        guard let idx = lenses.firstIndex(where: { $0.id == lens.id }) else { return [] }
        var out: [String] = []
        for id in lens.reads {
            guard let j = lenses.firstIndex(where: { $0.id == id && $0.id != lens.id }) else { out.append("no lens has the id “\(id)”"); continue }
            if j > idx { out.append("“\(lenses[j].title)” comes after this lens, so it sees that notebook as of the chunk before") }
            else if !lenses[j].carry { out.append("“\(lenses[j].title)” carries no notebook") }
            else if !lenses[j].on { out.append("“\(lenses[j].title)” is switched off") }
        }
        return out
    }

    /// The default instructions as they read before chunks, so unedited lenses can follow the new ones.
    private static let legacyInstructions: [String: String] = {
        var out: [String: String] = [:]
        for l in Lens.defaults {
            var old = l.instructions
            old = old.replacingOccurrences(of: "For EVERY sentence in the chunk, write", with: "For EVERY sentence in the window, write")
            old = old.replacingOccurrences(of: "you cannot find in the chunk or the notebooks", with: "you cannot find in the window or the notebooks")
            old = old.replacingOccurrences(of: "At most 3 per chunk; if the chunk raises nothing new, write [none].\nWhen a sentence in this chunk answers one of your earlier questions, write an entry \"settled: <the earlier question, word for word>\" citing the ids that answer it.", with: "At most 5 per window; if the window raises nothing new, write [none].")
            if old != l.instructions { out[l.id] = old }
        }
        return out
    }()
}

/// A bool read from any thread.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

/// A request for the questions, handed to the reading from any thread and taken once.
final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: Reading.QuestionRequest?
    func put(_ r: Reading.QuestionRequest) { lock.lock(); request = r; lock.unlock() }
    func take() -> Reading.QuestionRequest? { lock.lock(); defer { lock.unlock() }; let r = request; request = nil; return r }
}
