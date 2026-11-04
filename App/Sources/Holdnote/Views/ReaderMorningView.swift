import Harness
import SwiftUI

/// Ask about the stream. The model can only open a note file or read sentences by number; every
/// answer cites sentence ids. Flag anything wrong and it goes into corrections.md.
struct ReaderMorningView: View {
    let model: AppModel
    @State private var question = ""
    @State private var confirmClear = false
    @StateObject private var flash = FlashState()
    @FocusState private var focused: Bool

    private var reader: ReaderController { model.reader }

    static let suggestions = [
        "What do I keep coming back to?",
        "Where do I contradict myself?",
        "What did I leave open and never come back to?",
        "Where did I first sound unsure, and about what?",
        "Which of my goals does my own writing argue against?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask about the stream").font(.title2.weight(.semibold))
                Text("The model can only open a note file or read sentences by number. Every answer cites sentence ids; click one to see your exact words. Flag anything wrong and it goes into corrections.md.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(stateLine).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Flash(text: flash.text)
                    if !reader.chat.isEmpty { Button("Clear conversation") { confirmClear = true }.buttonStyle(.link).font(.system(size: 11)) }
                }
            }
            .padding(24)
            .padding(.bottom, 0)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if reader.chat.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Nothing asked yet. Try one of these, or write your own below.").font(.system(size: 12)).foregroundStyle(.secondary)
                                FlowRow(spacing: 6) {
                                    ForEach(Self.suggestions, id: \.self) { s in
                                        Button(s) { reader.ask(s) }.controlSize(.small).disabled(!canAsk)
                                    }
                                }
                            }
                        }
                        ForEach(reader.chat) { turn in
                            TurnView(model: model, turn: turn, pending: reader.asking && turn.id == reader.chat.last?.id) { msg in flash.show(msg) }
                                .id(turn.id)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 760, alignment: .leading)
                }
                .onChange(of: reader.chat.count) { _, _ in if let last = reader.chat.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: reader.askLive.count) { _, _ in if reader.asking, let last = reader.chat.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask anything about what you wrote…", text: $question, axis: .vertical)
                    .lineLimit(2...8)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { ask() }
                    .onKeyPress(.escape) { if reader.asking { reader.cancelAsk(); return .handled }; return .ignored }
                VStack(spacing: 4) {
                    Button(reader.asking ? "Cancel" : "Ask") { if reader.asking { reader.cancelAsk() } else { ask() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!reader.asking && (!canAsk || question.trimmingCharacters(in: .whitespaces).isEmpty))
                    Text("↵").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .padding(16)
        }
        .onAppear { focused = true }
        .confirmationDialog("Clear this conversation? Flags already written to corrections.md are kept.", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { reader.clearChat() }
        }
    }

    private var canAsk: Bool { reader.folder != nil && !reader.config.model.isEmpty && !reader.asking }

    private var stateLine: String {
        guard let folder = reader.folder else { return "Choose a folder in the sidebar to read the notes the night wrote." }
        if reader.notesCount == 0 { return "No notes in \(folder.name)/ yet. Run a night first; until then answers have nothing to read." }
        let n = reader.sentences.count
        return "Reading from \(folder.name)/ · \(reader.notesCount) note file\(reader.notesCount == 1 ? "" : "s") · \(n.formatted()) sentences\(reader.stream.unread > 0 ? " · \(reader.stream.unread.formatted()) not yet read by every lens" : "")"
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, canAsk else { return }
        if reader.running { flash.show("The night is running; this answer will share the model with it.") }
        question = ""
        reader.ask(q)
    }
}

struct TurnView: View {
    let model: AppModel
    let turn: ReaderStream.Turn
    let pending: Bool
    let flash: (String) -> Void
    @State private var note = ""
    @State private var showTrace = false

    private var reader: ReaderController { model.reader }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.q).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
            if pending {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(reader.askStep.isEmpty ? "reading the notes" : reader.askStep).font(.system(size: 12)).foregroundStyle(.secondary) }
                if !reader.askLive.isEmpty {
                    Text(reader.askLive).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(12)
                }
            } else if let error = turn.error {
                Text("Could not answer: \(error)").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                Text(turn.answer).font(.system(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                SentenceIds(ids: turn.evidence, unread: turn.unread) { reader.sentence($0) }
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
        .padding(12)
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
