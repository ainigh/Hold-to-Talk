import Harness
import SwiftUI

/// Ask: what you are trying to find out, the questions the reader keeps answered about it (from
/// your goals, and any you pinned), and anything else you want to ask. The model can only open
/// a note file or read sentences by number; every answer cites sentence ids, and each id leads
/// back to your words and the recording they were said in. Flag anything wrong and it goes into
/// corrections.md.
struct ReaderAskView: View {
    let model: AppModel
    let go: (ReaderView) -> Void

    private var reader: ReaderController { model.reader }

    var body: some View {
        ReaderPage(title: "Ask", lede: "What you want to find out, and what the reader has found. It reads everything you record a chunk at a time, through every lens at once, and keeps these answers up to date as you talk.") {
            GettingStarted(model: model, go: go)
            ReaderStatusStrip(model: model, go: go)
            GoalsBlock(model: model)
            KeptQuestions(model: model)
            AskBlock(model: model)
        }
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
                Button(b.step == "ollama" ? "Check Ollama" : b.step == "folder" ? "Choose a folder" : "Open Reading") {
                    switch b.step {
                    case "ollama": model.showSettings(tab: .reader); reader.refreshModels()
                    case "folder": reader.chooseFolder()
                    case "stream": go(.stream)
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
        if reader.unfedCount > 0 { return "\(reader.unfedCount) transcript\(reader.unfedCount == 1 ? "" : "s") about to join the stream" }
        if s.questionsPending > 0 || s.questionsToWrite { return "Questions to answer from what was read" }
        return "Up to date · \(s.count.formatted()) sentences read"
    }
}

/// What you are trying to find out: every lens reads it, and the questions are written from it.
struct GoalsBlock: View {
    let model: AppModel

    var body: some View {
        @Bindable var reader = model.reader
        ReaderBlock(title: "What are you trying to find out?", lede: "In your own words. Every lens reads this, and the questions below are written from it; change it and they are written again.") {
            TextEditor(text: $reader.goals)
                .font(.system(size: 13))
                .frame(minHeight: 64, maxHeight: 140)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .overlay(alignment: .topLeading) {
                    if reader.goals.isEmpty {
                        Text("e.g. I want to understand why I keep circling back to the move, what I actually feel about the people involved, and which of my plans I’ve quietly abandoned.")
                            .font(.system(size: 13)).foregroundStyle(.tertiary).padding(11).allowsHitTesting(false)
                    }
                }
            Text(reader.goalsState).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// The questions the reader keeps answered: from your goals, and the ones you pinned. Each answer
/// is refreshed as the stream grows.
struct KeptQuestions: View {
    let model: AppModel
    @State private var open: Set<String> = []

    private var reader: ReaderController { model.reader }

    var body: some View {
        ReaderBlock(title: "Questions about your goals", lede: "Written from your goals (and any you pin from below), answered from the notes with your words cited, and answered again once you have said more.") {
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

/// Anything else: the conversation, with a field under it.
struct AskBlock: View {
    let model: AppModel
    @State private var question = ""
    @StateObject private var flash = FlashState()

    private var reader: ReaderController { model.reader }

    static let suggestions = [
        "What do I keep coming back to?",
        "Where do I contradict myself?",
        "What did I leave open and never come back to?",
        "Where did I first sound unsure, and about what?",
        "Which of my goals does my own writing argue against?",
    ]

    var body: some View {
        ReaderBlock(title: "Ask anything", lede: "The model can only open a note file or read sentences by number. Every answer cites sentence ids; click one to see your exact words and the recording they came from. Flag anything wrong and it goes into corrections.md.") {
            HStack {
                Text(stateLine).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Flash(text: flash.text)
                if !reader.chat.isEmpty {
                    Button("Clear conversation") {
                        confirm("Clear this conversation?", detail: "Flags already written to corrections.md are kept.", button: "Clear") { reader.clearChat() }
                    }
                    .buttonStyle(.link).font(.system(size: 11))
                }
            }
            if reader.chat.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing asked yet. Try one of these, or write your own below.").font(.system(size: 12)).foregroundStyle(.secondary)
                    ForEach(Self.suggestions, id: \.self) { s in
                        Button(s) { reader.ask(s) }.buttonStyle(.link).font(.system(size: 13)).disabled(!canAsk)
                    }
                }
            }
            ForEach(reader.chat) { turn in
                TurnView(model: model, turn: turn, pending: reader.asking && turn.id == reader.chat.last?.id) { msg in flash.show(msg) }
            }
            HStack(spacing: 10) {
                TextField("Ask anything about what you said and wrote… (↵ to ask)", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { ask() }
                Button(reader.asking ? "Cancel" : "Ask") { if reader.asking { reader.cancelAsk() } else { ask() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!reader.asking && (!canAsk || question.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
    }

    private var canAsk: Bool { reader.folder != nil && !reader.config.model.isEmpty && !reader.asking }

    private var stateLine: String {
        guard let folder = reader.folder else { return "Choose a folder for the notes first." }
        if reader.notesCount == 0 { return "No notes in \(folder.name)/ yet; until something is read, answers have little to go on." }
        let n = reader.sentences.count
        return "Reading from \(folder.name)/ · \(reader.notesCount) note file\(reader.notesCount == 1 ? "" : "s") · \(n.formatted()) sentences\(reader.stream.unread > 0 ? " · \(reader.stream.unread.formatted()) not read yet" : "")"
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, canAsk else { return }
        if reader.running { flash.show("Reading is running; this answer shares the model with it.") }
        question = ""
        reader.ask(q)
    }
}

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
            if !compact, let about = turn.about, let label = turn.aboutLabel {
                Button {
                    if let id = UUID(uuidString: about) { model.openRecording(id) }
                } label: { Label("About \(label)", systemImage: "waveform").font(.system(size: 11)) }
                .buttonStyle(.link)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(turn.q).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
                Spacer(minLength: 6)
                if !pending, turn.error == nil, turn.about == nil {
                    let isPinned = reader.pinned.contains(turn.q)
                    Button { if isPinned { reader.unpin(turn.q) } else { reader.pin(turn.q) } } label: {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                    }
                    .buttonStyle(.borderless)
                    .help(isPinned ? "Kept answered under Questions about your goals; click to stop" : "Keep this question answered as you say more")
                }
            }
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
                DisclosureGroup(isExpanded: $showTrace) {
                    Text(trace).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("\(turn.steps) step\(turn.steps == 1 ? "" : "s") · opened \(turn.opened.isEmpty ? "nothing" : turn.opened.joined(separator: ", "))").font(.system(size: 11)).foregroundStyle(.secondary)
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
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
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
