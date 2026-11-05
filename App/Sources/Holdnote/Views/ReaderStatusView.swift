import Harness
import SwiftUI

/// Status's pages, in the window's second column: Now (what is running, with its stop), Reading
/// (what the reader is doing in detail), Setup (what the hotkey needs).
struct StatusList: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(title: "Status") { EmptyView() }
            List(selection: Binding(get: { model.statusTab }, set: { if let t = $0 { model.statusTab = t } })) {
                ForEach(AppModel.StatusTab.allCases) { t in
                    HStack {
                        Label(t.title, systemImage: t == .setup && !model.capture.hotkeyRunning ? "exclamationmark.triangle" : t.symbol)
                        Spacer()
                        Text(meta(t)).font(.system(size: 11)).foregroundStyle(attention(t) ? Color.accentColor : .secondary)
                    }
                    .tag(t)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func meta(_ t: AppModel.StatusTab) -> String {
        switch t {
        case .now:
            if model.capture.isRecording { return "recording" }
            if model.library.transcribing != nil { return "transcribing" }
            if model.reader.running { return "\(model.reader.percent)%" }
            return ""
        case .reading:
            if model.reader.running { return "\(model.reader.percent)%" }
            return model.reader.stream.unread > 0 ? "\(model.reader.stream.unread.formatted()) unread" : ""
        case .setup: return model.capture.hotkeyRunning ? "" : "hotkey off"
        }
    }

    private func attention(_ t: AppModel.StatusTab) -> Bool {
        switch t {
        case .now: model.capture.isRecording || model.library.transcribing != nil
        case .reading: !model.reader.running && model.reader.stream.unread > 0 && model.reader.ollamaOK && !model.reader.config.autoRead
        case .setup: !model.capture.hotkeyRunning
        }
    }
}

/// Now: everything that is running, each with the way to stop it, and what stands in the way
/// of the reader's first answers.
struct StatusNowView: View {
    let model: AppModel

    private var reader: ReaderController { model.reader }
    private var library: Library { model.library }

    var body: some View {
        ReaderPage(title: "Now", lede: "What Holdnote is doing, and how to stop it. The same line sits at the top of the window.") {
            GettingStarted(model: model, go: { model.showReader($0) })
            Card {
                HStack {
                    Label(model.capture.isRecording ? "Recording" : (model.capture.isListening ? (model.capture.isSpeaking ? "Listening · hearing you" : "Listening for speech") : "Not recording"),
                          systemImage: model.capture.isRecording ? "record.circle.fill" : "mic")
                        .foregroundStyle(model.capture.isRecording ? Color.red : .primary)
                    Spacer()
                    if model.capture.isRecording {
                        Button("Stop recording") { model.capture.stopFromMenu() }.controlSize(.small)
                    } else if model.capture.isListening {
                        Button("Stop listening") { model.listening = false }.controlSize(.small)
                    }
                }
                Text(model.capture.paused ? "The hotkey is paused (the switch at the top of the window)." : "Hold \(model.settings.settings.hotkey.glyph) anywhere to record; tap it twice to record hands-free.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Card {
                HStack {
                    Label("Transcriber", systemImage: "waveform").foregroundStyle(library.transcribing != nil ? Color.accentColor : .primary)
                    Spacer()
                    if library.transcribing != nil {
                        Button(library.transcribingStopping ? "Stopping…" : "Stop transcribing") { library.cancelTranscription() }
                            .controlSize(.small).disabled(library.transcribingStopping)
                    }
                }
                TranscriberStatus(model: model)
            }
            Card {
                HStack {
                    Label("Reader", systemImage: "eyeglasses").foregroundStyle(reader.running ? Color.accentColor : .primary)
                    Spacer()
                    if reader.running {
                        Button(reader.stopping ? "Stopping…" : "Pause after this call") { reader.stopAfterCall() }.controlSize(.small).disabled(reader.stopping)
                        Button("Stop now") { reader.stopNow() }.controlSize(.small)
                    } else if reader.asking {
                        Button("Cancel the answer") { reader.cancelAsk() }.controlSize(.small)
                    } else if reader.hasWork, reader.blocker == nil {
                        Button("Read now") { reader.startReading() }.controlSize(.small)
                    }
                }
                ReaderStatusStrip(model: model, go: { model.showReader($0) })
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 11)).foregroundStyle(reader.indexer.isUnavailable ? Color.orange : reader.indexer.available ? Color.accentColor : Color.secondary)
                    Text(reader.indexer.line).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                .help("The SIMILAR move: every sentence is turned into a vector by an embedding model as it joins the stream, so the model can ask for the sentences nearest in meaning to a phrase. Settings → Reader names the model; without one the move is not offered.")
                Button("Details") { model.statusTab = .reading }.buttonStyle(.link).font(.system(size: 12))
            }
        }
    }
}

/// Your goals as a text (KINDS.md): what you are trying to find out, full width, Copy first in
/// the footer, and beside it the reader's take (the questions it writes from the goals and
/// keeps answered), the conversation, or its words. In the stream's list above ALL, because
/// every lens reads it with every chunk.
struct GoalsView: View {
    let model: AppModel
    @FocusState private var editing: Bool

    var body: some View {
        @Bindable var reader = model.reader
        let goals = reader.goals
        TextFrame(offered: [.reader, .ask, .words]) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Goals · what are you trying to find out?").font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    Text("\(TranscriptText.wordCount(goals).formatted()) word\(TranscriptText.wordCount(goals) == 1 ? "" : "s")")
                    if !reader.goalsState.isEmpty { Text("· \(reader.goalsState)") }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .help("Your goals: what you are trying to find out. Every lens reads this with every chunk.")
        } content: {
            TextEditor(text: $reader.goals)
                .font(.system(size: 16))
                .lineSpacing(6)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focused($editing)
                .overlay(alignment: .topLeading) {
                    if goals.isEmpty {
                        Text("e.g. I want to understand why I keep circling back to the move, what I actually feel about the people involved, and which of my plans I’ve quietly abandoned.")
                            .font(.system(size: 16)).foregroundStyle(.tertiary).padding(.horizontal, 25).padding(.vertical, 12).allowsHitTesting(false)
                    }
                }
        } footer: {
            CopyButton(text: goals) { model.library.copy($0) }
            AppendButton(text: $reader.goals, editing: $editing)
            Spacer()
        } side: { panel in
            switch panel {
            case .ask: AskPanel(model: model)
            case .words: WordsPanel(model: model, items: [Recording(id: AppModel.goalsID, sourceDevice: "Goals", machineText: goals, text: goals, status: .final)])
            default: StandingQuestionsPanel(model: model)
            }
        }
    }
}

/// One line on the transcriber: what it is at now, or how its last run went.
struct TranscriberStatus: View {
    let model: AppModel

    private var library: Library { model.library }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform").foregroundStyle(library.transcribing != nil ? Color.accentColor : Color.secondary)
            Text(line).font(.system(size: 12)).lineLimit(2)
            Spacer(minLength: 8)
            if let id = library.transcribing {
                Button("Open") { model.openRecording(id) }.buttonStyle(.link).font(.system(size: 12))
            } else {
                Button("Settings") { model.showSettings(tab: .transcription) }.buttonStyle(.link).font(.system(size: 12))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))
    }

    private var line: String {
        if library.transcribing != nil {
            let phase = library.transcribingPhase.rawValue
            let chunks = library.transcribingChunks
            if library.transcribingPhase == .transcribing, chunks.count > 1 {
                let done = chunks.filter { $0.state == .done }.count, running = chunks.filter { $0.state == .running }.count
                return "\(phase) with \(library.transcribingModel): \(done) of \(chunks.count) chunks done, \(running) running, \(library.transcribingAtOnce) at once"
            }
            return "\(phase) with \(library.transcribingModel)…"
        }
        if let r = library.lastRun {
            let pace = r.elapsed > 0 ? String(format: ", %.1f× real time", r.audioSeconds / r.elapsed) : ""
            return "Last transcription: \(TranscriptText.duration(r.audioSeconds)) of audio with \(r.model) \(r.stopped ? "stopped after" : "in") \(TranscriptText.duration(r.elapsed))\(pace) · \(r.chunks) chunk\(r.chunks == 1 ? "" : "s"), \(r.atOnce) at once"
        }
        return "Transcriber idle · \(model.settings.settings.model)\(library.transcriber.hasModel(model.settings.settings.model) ? "" : " (not downloaded)")"
    }
}

/// Ask, beside the stream or beside one item: the conversation, newest at the bottom, with the
/// field under it. With `about`, questions are about that item (its sentences are read first)
/// and only that item's turns show. Every answer cites sentence ids; click one to see your
/// exact words. Flag anything wrong and it goes into corrections.md.
struct AskPanel: View {
    let model: AppModel
    var about: Recording? = nil
    @State private var question = ""
    @FocusState private var focused: Bool
    @StateObject private var flash = FlashState()

    private var reader: ReaderController { model.reader }
    private var turns: [ReaderStream.Turn] { about.map { reader.turns(about: $0) } ?? reader.chat.filter { $0.about == nil } }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(panel: .ask) {
                Flash(text: flash.text)
                Text(about == nil ? "about everything" : "about this item").font(.system(size: 11)).foregroundStyle(.secondary)
                if !turns.isEmpty, about == nil {
                    Button {
                        confirm("Clear this conversation?", detail: "Flags already written to corrections.md are kept.", button: "Clear") { reader.clearChat() }
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help("Clear the conversation")
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if turns.isEmpty { suggestions }
                        ForEach(turns) { turn in
                            TurnView(model: model, turn: turn, pending: reader.asking && turn.id == reader.chat.last?.id, compact: true) { msg in flash.show(msg) }
                                .id(turn.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: reader.chat.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: reader.askLive.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(about == nil ? "Ask anything about the stream… (↵ to ask, ⌥↵ for a new line)" : "e.g. What was I really worried about here?", text: $question, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .focused($focused)
                        .onSubmit { ask() }
                    Button(reader.asking ? "Cancel" : "Ask") { if reader.asking { reader.cancelAsk() } else { ask() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!reader.asking && (!canAsk || question.trimmingCharacters(in: .whitespaces).isEmpty))
                }
                Text(stateLine).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(2)
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .onAppear { takeDraft() }
        .onChange(of: model.askDraftRequests) { _, _ in takeDraft() }
    }

    static let suggestions = [
        "What do I keep coming back to?",
        "Where do I contradict myself?",
        "What did I leave open and never come back to?",
        "Where did I first sound unsure, and about what?",
    ]

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(about == nil ? "Nothing asked yet. Select a passage in the text and right-click to ask about it, or try one of these." : "Nothing asked about this item yet. Answers come from its sentences first, then the notes on everything else.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if about == nil {
                ForEach(Self.suggestions, id: \.self) { s in
                    Button(s) { reader.ask(s) }.buttonStyle(.link).font(.system(size: 12)).disabled(!canAsk)
                }
            }
        }
    }

    private var canAsk: Bool { reader.folder != nil && !reader.config.model.isEmpty && !reader.asking }

    private var stateLine: String {
        guard let folder = reader.folder else { return "Choose a folder for the notes first (Settings → Reader)." }
        if reader.config.model.isEmpty { return "Pick a model in Settings → Reader." }
        if reader.notesCount == 0 { return "No notes in \(folder.name)/ yet; until something is read, answers have little to go on." }
        return "Answers cite sentence ids; click one to see your words. The model only opens notes and reads sentences by id.\(reader.stream.unread > 0 ? " \(reader.stream.unread.formatted()) sentences not read yet." : "")"
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, canAsk else { return }
        if reader.running { flash.show("Reading is running; this answer shares the model with it.") }
        question = ""
        reader.ask(q, about: about)
    }

    /// A passage picked in the stream, or "Ask the reader about it" on a row, lands here when
    /// this panel is the one meant.
    private func takeDraft() {
        guard model.askDraftTarget == about?.id else { return }
        if !model.askDraft.isEmpty { question = model.askDraft; model.askDraft = "" }
        focused = true
    }
}

/// One line on what the reader is doing, with a way to the Reading view.
struct ReaderStatusStrip: View {
    let model: AppModel
    let go: (ReaderView) -> Void

    private var reader: ReaderController { model.reader }

    var body: some View {
        HStack(spacing: 8) {
            if reader.running {
                ProgressView().controlSize(.small)
                Text(line).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 8)
                Button("Details") { go(.reading) }.buttonStyle(.link).font(.system(size: 12))
            } else if let b = reader.blocker {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(b.text).font(.system(size: 12))
                Spacer(minLength: 8)
                Button(b.step == "ollama" ? "Check Ollama" : b.step == "folder" ? "Choose a folder" : b.step == "stream" ? "Open the stream" : "Open Reading") {
                    switch b.step {
                    case "ollama": model.showSettings(tab: .reader); reader.refreshModels()
                    case "folder": reader.chooseFolder()
                    case "stream": model.show(.recordings)
                    default: go(.reading)
                    }
                }
                .buttonStyle(.link).font(.system(size: 12))
            } else {
                Image(systemName: reader.hasWork ? "circle.dotted" : "checkmark.circle").foregroundStyle(reader.hasWork ? Color.secondary : Color.green)
                Text(line).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 8)
                if reader.hasWork { Button("Read now") { reader.startReading() }.controlSize(.small) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))
    }

    private var line: String {
        if reader.running {
            if let c = reader.chunk { return "Reading \(c.from)–\(c.to) through \(c.readers.count) lens\(c.readers.count == 1 ? "" : "es") · \(reader.readCount.formatted()) of \(reader.totalCount.formatted()) read" }
            if let q = reader.questionInfo, !q.current.isEmpty { return "Answering: \(q.current)" }
            return reader.status.isEmpty ? "Reading…" : reader.status
        }
        let s = reader.stream
        if s.unread > 0 { return "\(s.unread.formatted()) sentence\(s.unread == 1 ? "" : "s") not read yet\(reader.config.autoRead && reader.pausedUntil == nil ? " · reads by itself when you're not recording" : "")" }
        if reader.unfedCount > 0 { return "\(reader.unfedCount) item\(reader.unfedCount == 1 ? "" : "s") about to join the reader's stream" }
        if s.questionsPending > 0 || s.questionsToWrite { return "Questions to answer from what was read" }
        return "Up to date · \(s.count.formatted()) sentences read"
    }
}

/// The questions the reader keeps answered: from your goals, and the ones you pinned. Each answer
/// is refreshed as the stream grows.
struct KeptQuestions: View {
    let model: AppModel
    /// With its own title and lede (on a page), or bare (inside a side panel that has a header).
    var heading = true
    @State private var open: Set<String> = []

    private var reader: ReaderController { model.reader }

    var body: some View {
        if heading {
            ReaderBlock(title: "Questions about your goals", lede: "Written from your goals (and any you pin from the conversation), answered from the notes with your words cited, and answered again once you have said more.") { list }
        } else {
            VStack(alignment: .leading, spacing: 8) { list }
        }
    }

    @ViewBuilder
    private var list: some View {
            HStack(spacing: 10) {
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("New questions") { reader.regenerateQuestions() }
                    .controlSize(.small)
                    .disabled(reader.blocker != nil || reader.config.questionCount == 0)
                    .help("Write the questions again from your goals; answers to questions still asked are kept")
                Button("Answer again") { reader.refreshAnswers() }
                    .controlSize(.small)
                    .disabled(reader.blocker != nil || reader.questions.isEmpty)
                    .help("Answer every question again from the notes as they are now")
            }
            if reader.questions.isEmpty {
                Text(empty).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(reader.questions, id: \.self) { q in
                questionRow(q)
            }
    }

    private var summary: String {
        let n = reader.questions.count
        guard n > 0 else { return "" }
        let answered = reader.questions.filter { reader.answers[$0] != nil }.count
        let pending = reader.stream.questionsPending
        return "\(answered) of \(n) answered\(pending > 0 ? " · \(pending) to answer or refresh" : "")"
    }

    private var empty: String {
        if reader.config.questionCount == 0 { return "Turned off in Settings → Reader (questions to keep answered: 0). Pinned questions are still answered." }
        if reader.stream.count == 0 { return "Once there is something to read, the reader writes questions from your goals and answers them." }
        return "They are written once the lenses have read what there is."
    }

    @ViewBuilder
    private func questionRow(_ q: String) -> some View {
        let qa = reader.answers[q]
        let isPinned = reader.pinned.contains(q)
        let current = reader.running && reader.questionInfo?.current == q
        let stale = qa.map { reader.stream.count - ($0.asOf ?? 0) >= reader.config.questionRefresh } ?? false
        let isOpen = open.contains(q)
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    if isOpen { open.remove(q) } else { open.insert(q) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(isOpen ? 90 : 0)).foregroundStyle(.secondary)
                        Text(q).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 6)
                if current { ProgressView().controlSize(.mini) }
                else if qa == nil { Badge("not answered yet") }
                else if stale { Badge("you've said more since", .orange) }
                if isPinned { Badge("pinned", .accentColor) }
                Button { if isPinned { reader.unpin(q) } else { reader.pin(q) } } label: {
                    Image(systemName: isPinned ? "pin.slash" : "pin")
                }
                .buttonStyle(.borderless)
                .help(isPinned ? "Stop keeping this question answered" : "Keep this question even when the questions are written again")
            }
            if let qa {
                Text(qa.answer)
                    .font(.system(size: 13))
                    .lineLimit(isOpen ? nil : 3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if isOpen {
                    SentenceIds(ids: qa.evidence, model: model)
                    Text("Answered \(qa.at.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "earlier") from \(qa.opened.isEmpty ? "the sentences" : qa.opened.joined(separator: ", "))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One exchange: your question, the answer with its citations, the trace, and a flag.
struct TurnView: View {
    let model: AppModel
    let turn: ReaderStream.Turn
    let pending: Bool
    var compact = false
    let flash: (String) -> Void
    @State private var note = ""
    @State private var showTrace = false

    private var reader: ReaderController { model.reader }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Your question, on the right like a message you sent.
            HStack(alignment: .top) {
                if !compact { Spacer(minLength: 40) }
                VStack(alignment: .trailing, spacing: 4) {
                    if !compact, let about = turn.about, let label = turn.aboutLabel {
                        Button {
                            if let id = UUID(uuidString: about) { model.openRecording(id) }
                        } label: { Label("About \(label)", systemImage: "waveform").font(.system(size: 11)) }
                        .buttonStyle(.link)
                    }
                    Text(turn.q).font(.system(size: 13)).textSelection(.enabled).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.15)))
                }
            }
            // The answer, on the left.
            VStack(alignment: .leading, spacing: 8) {
                if pending {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(reader.askStep.isEmpty ? "reading the notes" : reader.askStep).font(.system(size: 12)).foregroundStyle(.secondary) }
                    if !reader.askLive.isEmpty {
                        Text(reader.askLive).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(12)
                    }
                } else if let error = turn.error {
                    Text("Could not answer: \(error)").font(.system(size: 13)).foregroundStyle(.secondary)
                } else {
                    Text(turn.answer).font(.system(size: compact ? 13 : 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    SentenceIds(ids: turn.evidence, unread: turn.unread, model: model)
                    HStack(spacing: 10) {
                        DisclosureGroup(isExpanded: $showTrace) {
                            Text(trace).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            Text("\(turn.steps) step\(turn.steps == 1 ? "" : "s") · opened \(turn.opened.isEmpty ? "nothing" : turn.opened.joined(separator: ", "))").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if turn.about == nil {
                            let isPinned = reader.pinned.contains(turn.q)
                            Button { if isPinned { reader.unpin(turn.q) } else { reader.pin(turn.q) } } label: {
                                Label(isPinned ? "Pinned" : "Keep answered", systemImage: isPinned ? "pin.fill" : "pin").font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)
                            .help(isPinned ? "Kept answered under Goals as you say more; click to stop" : "Keep this question answered as you say more")
                        }
                    }
                    if turn.flagged {
                        Label("Flagged → corrections.md", systemImage: "flag.fill").font(.system(size: 11)).foregroundStyle(.orange)
                    } else {
                        HStack(spacing: 8) {
                            TextField("Wrong or missing something? Say what, and it goes into corrections.md", text: $note)
                                .textFieldStyle(.roundedBorder).controlSize(.small)
                                .onSubmit { flag() }
                            Button("Flag") { flag() }.controlSize(.small)
                        }
                    }
                }
            }
            .padding(compact ? 10 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))
        }
    }

    private var trace: String {
        turn.trace.enumerated().map { i, t in
            "\(i + 1). \(t.action) \(t.file)\(t.offset > 0 ? " @\(t.offset)" : "") \(t.ids.joined(separator: ","))\n   why: \(t.why)"
        }.joined(separator: "\n")
    }

    private func flag() {
        if let problem = reader.flag(turn, note: note) { flash(problem) } else { flash("Saved to corrections.md") }
    }
}
