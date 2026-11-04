import Harness
import SwiftUI
import UniformTypeIdentifiers

/// What you wrote and said, and what you want to find out about it. Transcripts join the stream
/// by themselves; pastes and dropped text files join it here; the reader's questions are answered here.
struct ReaderStreamView: View {
    let model: AppModel
    let go: (ReaderView) -> Void
    @State private var addText = ""
    @State private var dropping = false
    @StateObject private var flash = FlashState()

    private var reader: ReaderController { model.reader }

    var body: some View {
        @Bindable var readerBinding = model.reader
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The stream").font(.title2.weight(.semibold))
                    Text("What you wrote and said, and what you want to find out about it. The night reads the stream through every lens; the morning answers from the notes it leaves behind.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                checklist
                ReaderBlock(title: "What are you trying to find out?", lede: "In your own words. Every lens reads this first, and the last pass of the night generates and answers questions around it.") {
                    TextEditor(text: $readerBinding.goals)
                        .font(.system(size: 13))
                        .frame(minHeight: 80, maxHeight: 160)
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
                if let gaps = reader.gaps { gapsBlock(gaps) }
                ReaderBlock(title: "Your transcripts", lede: "Every recording and pasted note in Holdnote joins the stream when a night starts (Settings → Reader turns that off), oldest first, with its date. Earlier sentences keep their ids and the next night reads only what is new.") {
                    HStack(spacing: 10) {
                        Text(reader.unfedCount > 0 ? "\(reader.unfedCount) transcript\(reader.unfedCount == 1 ? "" : "s") not yet in the stream" : "Every transcript is in the stream")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Add them now") {
                            if let fed = reader.feedTranscripts() { flash.show(fed.recordings > 0 ? "Added \(fed.recordings) transcripts (\(fed.sentences) sentences)" : "Nothing new to add") }
                        }
                        .disabled(reader.unfedCount == 0 || reader.running || reader.folder == nil)
                        .controlSize(.small)
                    }
                }
                ReaderBlock(title: "Add to the stream", lede: "Paste anything: a day's notes, a journal entry, an email to yourself. Or drop a text file on it.") {
                    TextEditor(text: $addText)
                        .font(.system(size: 13))
                        .frame(minHeight: 120, maxHeight: 240)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.background))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(dropping ? Color.accentColor : Color(nsColor: .quaternaryLabelColor), lineWidth: dropping ? 2 : 1))
                        .onDrop(of: [.fileURL, .plainText], isTargeted: $dropping) { providers in drop(providers) }
                    HStack {
                        Text(preview).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Text("⌘↵").font(.system(size: 11)).foregroundStyle(.tertiary)
                        Button("Add to stream") { add() }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(addText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reader.folder == nil || reader.running)
                    }
                    Text(streamState).font(.system(size: 11)).foregroundStyle(.secondary)
                    if let plan = reader.plan, reader.stream.count > 0 {
                        Text("Each lens reads about \(plan.perWindow.formatted()) sentences at a time (average sentence \(reader.stream.averageChars.formatted()) characters; W \(reader.config.windowTokens.formatted()) fits ≈ \(plan.perToken.formatted())\(reader.config.maxSentences > 0 ? ", capped at \(reader.config.maxSentences.formatted())" : "")).")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if !reader.additions.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(reader.additions.suffix(5).reversed().enumerated()), id: \.offset) { _, a in
                                Text("\(when(a.added)) · \(a.sentences.formatted()) sentences · \(a.from)–\(a.to)\(a.source != nil ? " · transcript" : "")")
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("The folder's stream.txt is the raw record and sentences.txt the numbered one; both are under Notes.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Flash(text: flash.text)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var preview: String {
        let t = addText.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return reader.folder == nil ? "Choose a folder to add text." : "" }
        let n = Sentences.split(t).count
        return "≈ \(n.formatted()) sentence\(n == 1 ? "" : "s"), ≈ \(reader.tokens.estimate(t).formatted()) tokens"
    }

    private var streamState: String {
        let s = reader.stream
        if s.count > 0 { return "\(s.count.formatted()) sentences in the stream · \(s.unread > 0 ? "\(s.unread.formatted()) not yet read by every lens" : "all read by every lens")" }
        if s.rawPresent { return "stream.txt is in the folder and will be numbered when the night starts" }
        return "The stream is empty. Record something, or paste above, to begin."
    }

    private func when(_ iso: String) -> String {
        guard let d = ISO8601DateFormatter().date(from: iso) else { return iso }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    private func add() {
        let t = addText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let added = reader.addText(t) else { return }
        addText = ""
        flash.show(added.isEmpty ? "Nothing to add" : "Added \(added.count.formatted()) sentences (\(added[0].id)–\(added[added.count - 1].id))")
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        var any = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            any = true
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { return }
                Task { @MainActor in
                    addText = (addText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : addText.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n") + text.trimmingCharacters(in: .whitespacesAndNewlines)
                    flash.show("Loaded \(url.lastPathComponent)")
                }
            }
        }
        return any
    }

    // MARK: - Before the first night

    struct Step: Identifiable {
        var id: String
        var ok: Bool
        var text: String
        var action: String
        var go: () -> Void
    }

    private var steps: [Step] {
        [
            Step(id: "ollama", ok: reader.ollamaOK, text: "Start Ollama and pull a model (ollama pull llama3.1:8b).", action: "Check", go: { model.showSettings(tab: .reader); reader.refreshModels() }),
            Step(id: "folder", ok: reader.folder != nil, text: "Choose a folder for the notes. The default is inside Holdnote's own folder.", action: "Choose", go: { reader.chooseFolder() }),
            Step(id: "goals", ok: !reader.goals.trimmingCharacters(in: .whitespaces).isEmpty, text: "Write what you are trying to find out.", action: "", go: {}),
            Step(id: "stream", ok: reader.stream.count > 0 || reader.stream.rawPresent || reader.unfedCount > 0, text: "Record something, or paste some text into the stream.", action: "", go: {}),
            Step(id: "night", ok: reader.hasNotes, text: "Start the night. It runs in the background; the window can be closed.", action: "Go to Night", go: { go(.night) }),
        ]
    }

    @ViewBuilder
    private var checklist: some View {
        let steps = self.steps
        if !steps.allSatisfy(\.ok) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Before the first night").font(.system(size: 13, weight: .semibold))
                ForEach(steps) { s in
                    HStack(spacing: 8) {
                        Image(systemName: s.ok ? "checkmark.circle.fill" : "circle").foregroundStyle(s.ok ? Color.green : Color.secondary)
                        Text(s.text).font(.system(size: 12)).foregroundStyle(s.ok ? .secondary : .primary).strikethrough(s.ok, color: .secondary)
                        if !s.ok, !s.action.isEmpty { Button(s.action, action: s.go).buttonStyle(.link).font(.system(size: 12)) }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        }
    }

    // MARK: - Questions for you

    private func gapsBlock(_ gaps: (open: [ReaderStream.Gap], answered: Int)) -> some View {
        ReaderBlock(title: "Questions for you", lede: "What the reader could not work out from the text alone. Answer in your own words, or hold the hotkey and say it, then paste the transcript in; each answer joins the stream and is read the next night.") {
            Text(gaps.open.isEmpty ? "\(gaps.answered) answered" : "\(gaps.open.count) open · \(gaps.answered) answered").font(.system(size: 11)).foregroundStyle(.secondary)
            if gaps.open.isEmpty {
                Text("Every question so far is answered. The next night may raise more.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(gaps.open) { gap in
                GapRow(gap: gap, model: model) { msg in if let msg { flash.show(msg) } }
            }
        }
    }
}

struct GapRow: View {
    let gap: ReaderStream.Gap
    let model: AppModel
    let done: (String?) -> Void
    @State private var answer = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(gap.question).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
            SentenceIds(ids: gap.ids) { model.reader.sentence($0) }
            HStack(alignment: .top, spacing: 8) {
                TextField("Your answer, in your own words", text: $answer, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send(answer) }
                Button("Use last transcript") {
                    if let last = model.library.recordings.first(where: { $0.status == .final && !$0.text.isEmpty }) { answer = last.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                .help("Put the newest recording's text here (hold the hotkey, say your answer, then click)")
                .controlSize(.small)
                Button("Answer") { send(answer) }.disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty || busy).controlSize(.small)
                Button("Skip") { send("") }.disabled(busy).help("Do not ask this again").controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }

    private func send(_ a: String) {
        busy = true
        let msg = model.reader.answer(gap, with: a)
        busy = false
        done(msg ?? (a.isEmpty ? "Skipped" : "Answer saved"))
    }
}
