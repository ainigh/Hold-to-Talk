import AppKit
import Foundation
import Harness
import Observation

/// The reader inside Holdnote: the stream (your transcripts and pastes), the night that reads it
/// through every lens, the morning that answers from the notes, and the note files. The engine
/// is the harness's `Night`, `Morning` and `Stream`; this is the state the window shows and the
/// menu bar reports, and what runs it. The night keeps running with the window closed.
@MainActor
@Observable
final class ReaderController {
    // MARK: - Persisted

    private static let configKey = "reader.config", lensesKey = "reader.lenses", goalsKey = "reader.goals", folderKey = "reader.folder", gapsOfferedKey = "reader.gapsOffered", cptKey = "reader.cpt"

    var config: ReaderConfig { didSet { save(); if !running { refreshStream() } } }
    var lenses: [Lens] { didSet { save() } }
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
    private(set) var gaps: (open: [ReaderStream.Gap], answered: Int)?
    private(set) var unfedCount = 0
    private(set) var plan: ReaderStream.Plan?
    @ObservationIgnored private var sentencesCache: [Sentence]?

    // MARK: - The night

    struct TapeRow: Identifiable, Equatable {
        var id: String
        var title: String
        var n: Int
        var done: Int
        var cells: [Night.TapeState]
        var finished = false
        var percent: Int { finished ? 100 : Int(100 * Double(done) / Double(max(1, n))) }
    }
    struct LiveCall: Equatable {
        var label = ""
        var system = ""
        var user = ""
        var output = ""
        var thinking = ""
        var started = Date()
        var note = ""
    }

    private(set) var running = false
    private(set) var stopping = false
    private(set) var status = ""
    private(set) var log: [String] = []
    private(set) var tape: [TapeRow] = []
    private(set) var live: LiveCall?
    private(set) var percent = 0
    /// Said once in the window after the night ends.
    private(set) var lastOutcome: String?
    @ObservationIgnored private var nightTask: Task<Void, Never>?
    /// "Stop after this call": read by the night from its own task.
    @ObservationIgnored private let stopFlag = Flag()
    @ObservationIgnored private var awake: NSObjectProtocol?
    @ObservationIgnored private var scheduleTimer: Timer?
    @ObservationIgnored private var scheduledToday: String?
    let tokens = TokenEstimator()

    // MARK: - The morning

    private(set) var chat: [ReaderStream.Turn] = []
    private(set) var asking = false
    private(set) var askStep = ""
    private(set) var askLive = ""
    @ObservationIgnored private var askTask: Task<Void, Never>?

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

    /// Holdnote's recordings, for feeding the stream.
    @ObservationIgnored var recordings: () -> [Recording] = { [] }

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
        lenses = l
        goals = d.string(forKey: Self.goalsKey) ?? ""
        let cpt = d.double(forKey: Self.cptKey)
        tokens.charsPerToken = cpt > 0 ? cpt : config.charsPerToken
    }

    /// Once the app has launched: the folder, Ollama, the schedule.
    func start() {
        let path = UserDefaults.standard.string(forKey: Self.folderKey)
        setFolder(path.map { URL(fileURLWithPath: $0) } ?? Self.defaultFolder)
        refreshModels()
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSchedule() }
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
                self.refreshPlan()
                Task { try? await Task.sleep(for: .seconds(1.5)); if self.goalsState == "saved" { self.goalsState = "" } }
            }
        }
    }

    // MARK: - Folder

    func chooseFolder() {
        if running { addLog("The night is running; stop it before changing folders."); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        panel.message = "The notes the night writes go into this folder. Empty is fine, or one with a stream.txt."
        panel.directoryURL = folder?.root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url)
    }

    func useDefaultFolder() { setFolder(Self.defaultFolder) }

    func setFolder(_ url: URL) {
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
                contextNote = "\(model) is trained for \(info.contextLength.formatted()) tokens\(info.modelfileCtx > 0 ? " (its Modelfile sets num_ctx \(info.modelfileCtx.formatted()))" : ""). W is now \(w.formatted()) and num_ctx will be \(config.numCtx.formatted()). A context this large needs memory in proportion; if Ollama slows to a crawl or spills to the CPU, lower W. Small models also miss more in long windows, so a smaller W with a carried notebook often reads better."
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

    func sentence(_ id: String) -> String? { sentences.first { $0.id == id }?.text }

    func refreshStream() {
        guard let folder else { stream = ReaderStream.State(); additions = []; gaps = nil; plan = nil; return }
        sentencesCache = nil
        stream = ReaderStream.state(in: folder, config: config, lenses: lenses)
        additions = ReaderStream.additions(in: folder)
        gaps = lenses.contains { $0.id == Lens.gapsId } ? ReaderStream.gaps(in: folder) : nil
        unfedCount = ReaderStream.unfed(recordings(), in: folder).count
        refreshPlan()
        refreshNotesCount()
    }

    /// Called by the window when the library changed, so "n transcripts not yet in the stream" is right.
    func libraryChanged() {
        guard let folder else { return }
        unfedCount = ReaderStream.unfed(recordings(), in: folder).count
    }

    func refreshPlan() {
        guard folder != nil, stream.unread > 0 else { plan = nil; return }
        plan = ReaderStream.plan(config: config, lenses: lenses, goals: goals, unread: stream.unread, averageChars: stream.averageChars, tokens: tokens)
    }

    /// Pasted or dropped text joins the stream. Returns what was added.
    @discardableResult
    func addText(_ text: String) -> [Sentence]? {
        guard let folder else { addLog("Choose a folder first."); return nil }
        if running { addLog("Wait for the night to stop before adding text."); return nil }
        do {
            let added = try ReaderStream.append(text, to: folder)
            if !added.isEmpty { addLog("added \(added.count) sentences (\(added[0].id)–\(added[added.count - 1].id))") }
            refreshStream()
            return added
        } catch { addLog("add failed: \(error.localizedDescription)"); return nil }
    }

    /// Every final transcript not yet in the stream joins it, oldest first.
    @discardableResult
    func feedTranscripts() -> (recordings: Int, sentences: Int)? {
        guard let folder else { return nil }
        do {
            let fed = try ReaderStream.feed(recordings(), into: folder)
            if fed.recordings > 0 { addLog("added \(fed.recordings) transcript\(fed.recordings == 1 ? "" : "s") (\(fed.sentences) sentences) to the stream") }
            refreshStream()
            return fed
        } catch { addLog("could not add transcripts: \(error.localizedDescription)"); return nil }
    }

    func answer(_ gap: ReaderStream.Gap, with answer: String) -> String? {
        guard let folder else { return "Choose a folder first." }
        if running, !answer.isEmpty { return "Wait for the night to stop before answering; the answer goes into the stream." }
        do {
            let added = try ReaderStream.answer(gap, with: answer, in: folder)
            refreshStream()
            return added.isEmpty ? nil : "Answer added to the stream (\(added[0].id)–\(added[added.count - 1].id))"
        } catch { return "Could not save the answer: \(error.localizedDescription)" }
    }

    // MARK: - Readiness

    /// What stands between the user and a first night, in the order to fix it.
    var blocker: (text: String, step: String)? {
        if folder == nil { return ("Choose a folder for the notes first.", "folder") }
        if stream.count == 0, !stream.rawPresent { return ("The stream is empty.", "stream") }
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

    var startTitle: String {
        if running { return "Reading…" }
        return stream.partial ? "Resume the night" : "Start the night"
    }

    // MARK: - The night

    func addLog(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.append("[\(f.string(from: Date()))] \(message)")
        if log.count > 600 { log.removeFirst(log.count - 600) }
    }

    var logText: String { log.joined(separator: "\n") }

    func startNight() {
        guard !running else { return }
        guard let folder else { addLog("Choose a folder first."); return }
        if config.model.isEmpty { addLog("No model selected. Is Ollama running?"); refreshModels(); return }
        if !lenses.contains(where: \.on) { addLog("No lens is switched on."); return }
        if config.feedTranscripts { feedTranscripts() }
        if goals.trimmingCharacters(in: .whitespaces).isEmpty { addLog("note: goals are empty; the lenses and the question pass work better with a sentence or two of intent") }
        UserDefaults.standard.set(goals, forKey: Self.goalsKey)
        let cfg = config.clamped()
        running = true; stopping = false; stopFlag.value = false
        lastOutcome = nil
        live = nil; tape = []; percent = 0
        tokens.charsPerToken = cfg.charsPerToken
        if cfg.keepAwake { awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Reading the stream overnight") }
        addLog("starting: model \(cfg.model), W \(cfg.windowTokens), M \(cfg.notebookTokens), num_ctx \(cfg.numCtx), \(cfg.coolOffSec)s between calls, thinking \(cfg.think ? "left to the model" : "off")")
        status = "starting…"
        let lenses = self.lenses, goals = self.goals
        let chat = MeasuredChat(model: OllamaClient(base: cfg.base), tokens: tokens)
        var ctl = Night.Control()
        let stopFlag = self.stopFlag
        ctl.stopped = { stopFlag.value }
        ctl.log = { [weak self] m in Task { @MainActor in self?.addLog(m) } }
        ctl.status = { [weak self] s in Task { @MainActor in self?.status = s } }
        ctl.onTape = { [weak self] id, i, n, state in Task { @MainActor in self?.onTape(id, i, n, state) } }
        ctl.onCall = { [weak self] label, system, user in Task { @MainActor in self?.live = LiveCall(label: label, system: system, user: user) } }
        ctl.onToken = { [weak self] text, thinking in Task { @MainActor in self?.live?.output = text; self?.live?.thinking = thinking } }
        nightTask = Task { [weak self] in
            var finished = false
            var problem: String?
            do { finished = try await Night.run(folder: folder, config: cfg, lenses: lenses, goals: goals, chat: chat, control: ctl) }
            catch { problem = (error as? ReaderError)?.message ?? error.localizedDescription }
            await MainActor.run { self?.nightEnded(finished: finished, problem: problem) }
        }
    }

    private func nightEnded(finished: Bool, problem: String?) {
        running = false; stopping = false; status = ""
        nightTask = nil
        if let awake { ProcessInfo.processInfo.endActivity(awake); self.awake = nil }
        if let problem {
            addLog("ERROR: \(problem)")
            lastOutcome = problem
            Notifier.post(title: "The night stopped", body: problem)
        } else if finished {
            lastOutcome = "The night is done. Ask about it below."
            Notifier.post(title: "The night is done", body: "Open Holdnote's reader to ask about what it found.")
        } else {
            lastOutcome = "Stopped. Press Resume to carry on where it left off."
        }
        live?.note = finished ? "the night is done" : "stopped"
        config.charsPerToken = (tokens.charsPerToken * 100).rounded() / 100
        UserDefaults.standard.set(tokens.charsPerToken, forKey: Self.cptKey)
        refreshStream()
        refreshFiles()
    }

    private func onTape(_ id: String, _ i: Int, _ n: Int, _ state: Night.TapeState) {
        var row = tape.first { $0.id == id } ?? TapeRow(id: id, title: id == "questions" ? "Questions" : (lenses.first { $0.id == id }?.title ?? id), n: 0, done: 0, cells: [])
        if row.n != n { row.n = n; row.cells = Array(repeating: .initial, count: max(1, min(n, 160))) }
        let cells = row.cells.count
        let k = max(0, min(cells - 1, i * cells / max(1, n)))
        if i < 0 { row.cells = Array(repeating: .done, count: cells); row.finished = true }
        else {
            switch state {
            case .now: row.cells[k] = .now
            case .done, .bad: row.cells[k] = state; row.done = i + 1
            case .initial: for j in 0..<i { row.cells[j * cells / n] = .done }; row.done = i
            }
        }
        if let idx = tape.firstIndex(where: { $0.id == id }) { tape[idx] = row } else { tape.append(row) }
        let total = tape.reduce(0) { $0 + $1.n }, fin = tape.reduce(0) { $0 + ($1.finished ? $1.n : $1.done) }
        if total > 0 { percent = Int(100 * Double(fin) / Double(total)) }
    }

    func stopAfterCall() {
        guard running else { return }
        stopFlag.value = true; stopping = true
        addLog("will stop after the current call")
    }

    func stopNow() {
        guard running else { return }
        stopFlag.value = true; stopping = true
        addLog("stopping now; the call in progress is cut short")
        nightTask?.cancel()
    }

    func clearProgress() {
        guard let folder, !running else { return }
        try? folder.write("progress.json", "{}")
        addLog("progress cleared")
        refreshStream()
    }

    /// A night that starts by itself at the set time of day, once a day, when there is something to read.
    private func checkSchedule() {
        guard config.scheduleEnabled, !running, folder != nil else { return }
        let now = Date()
        let minute = Calendar.current.component(.hour, from: now) * 60 + Calendar.current.component(.minute, from: now)
        let day = ISO8601DateFormatter().string(from: now).prefix(10).description
        guard minute >= config.scheduleMinute, minute < config.scheduleMinute + 10, scheduledToday != day else { return }
        scheduledToday = day
        if config.feedTranscripts { feedTranscripts() }
        guard stream.unread > 0 || stream.rawPresent || (config.questionCount > 0 && !hasNotes), blocker == nil else { addLog("scheduled start skipped: \(blocker?.text ?? "nothing new to read")"); return }
        addLog("starting on schedule")
        startNight()
    }

    // MARK: - The morning

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking, let folder else { return }
        if config.model.isEmpty { addLog("No model selected. Is Ollama running?"); return }
        asking = true; askStep = "reading the notes"; askLive = ""
        let turn = ReaderStream.Turn(q: q)
        chat.append(turn)
        let cfg = config.clamped()
        let lenses = self.lenses, sentences = self.sentences
        let chatModel = MeasuredChat(model: OllamaClient(base: cfg.base), tokens: tokens)
        var opts = Morning.Options()
        opts.onStep = { [weak self] s in Task { @MainActor in self?.askStep = s; self?.askLive = "" } }
        opts.onToken = { [weak self] text, _ in Task { @MainActor in self?.askLive = text } }
        opts.log = { [weak self] m in Task { @MainActor in self?.addLog("morning: " + m) } }
        askTask = Task { [weak self] in
            var done = turn
            do {
                let r = try await Morning.ask(q, folder: folder, config: cfg, lenses: lenses, sentences: sentences, chat: chatModel, options: opts)
                done.answer = r.answer; done.evidence = r.evidence; done.unread = r.unread; done.steps = r.steps; done.trace = r.trace; done.opened = r.opened
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
            if currentFile == "sentences.txt" { sentencesCache = nil; refreshStream() }
            if currentFile.hasPrefix("lenses/") || currentFile == "questions.md" || currentFile == "answers.md" { refreshStream(); refreshFiles() }
            return "Saved \(currentFile)"
        } catch { return "Could not save: \(error.localizedDescription)" }
    }

    // MARK: - Lenses

    func addLens() -> String {
        let id = uniqueLensId("new-lens")
        lenses.append(Lens(id: id, title: "New lens", instructions: "Describe what to look for in each window and what each entry should say. Every entry must cite ids."))
        return id
    }

    func uniqueLensId(_ base: String, except: String? = nil) -> String {
        var id = base, k = 2
        while lenses.contains(where: { $0.id == id && $0.id != except }) { id = "\(base)-\(k)"; k += 1 }
        return id
    }

    /// A lens of the user's own follows its title; a default lens keeps its id (and its file).
    func rename(_ id: String, to title: String) {
        guard let i = lenses.firstIndex(where: { $0.id == id }) else { return }
        lenses[i].title = title
        guard !Lens.defaults.contains(where: { $0.id == id }) else { return }
        let newId = uniqueLensId(Lens.slug(title), except: id)
        if newId != id {
            lenses[i].id = newId
            for j in lenses.indices { lenses[j].reads = lenses[j].reads.map { $0 == id ? newId : $0 } }
        }
    }

    func move(_ id: String, by delta: Int) {
        guard let i = lenses.firstIndex(where: { $0.id == id }), lenses.indices.contains(i + delta) else { return }
        lenses.swapAt(i, i + delta)
    }

    func removeLens(_ id: String) { lenses.removeAll { $0.id == id } }

    func resetLenses() { lenses = Lens.defaults }

    /// Problems with what a lens reads: ids that do not exist, lenses that run later, that carry no notebook or are off.
    func readsProblems(of lens: Lens) -> [String] {
        guard let idx = lenses.firstIndex(where: { $0.id == lens.id }) else { return [] }
        var out: [String] = []
        for id in lens.reads {
            guard let j = lenses.firstIndex(where: { $0.id == id && $0.id != lens.id }) else { out.append("no lens has the id “\(id)”"); continue }
            if j > idx { out.append("“\(lenses[j].title)” runs after this lens, so its notebook will be stale or empty") }
            else if !lenses[j].carry { out.append("“\(lenses[j].title)” carries no notebook") }
            else if !lenses[j].on { out.append("“\(lenses[j].title)” is switched off") }
        }
        return out
    }
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
