import Harness
import SwiftUI
import UniformTypeIdentifiers

/// What goes into the stream: your transcripts (each joins by itself a minute after it settles),
/// text you paste or drop, and your answers to the reader's questions; and what joined lately.
struct ReaderStreamView: View {
    let model: AppModel
    let go: (ReaderView) -> Void
    @State private var addText = ""
    @State private var dropping = false
    @StateObject private var flash = FlashState()

    private var reader: ReaderController { model.reader }

    var body: some View {
        ReaderPage(title: "The stream", lede: "Everything the reader reads, in the order it happened: what you say (every transcript joins by itself), what you paste here, and your answers to its questions. Sentences are numbered once and keep their ids, so notes stay valid as the stream grows.") {
            ReaderBlock(title: "Your recordings", lede: reader.config.feedTranscripts
                        ? "Every transcript and note in Holdnote joins the stream about \(reader.config.settleSeconds) seconds after it is final and you've stopped editing it, with its date. Edit one after it joined and it can join again as a correction."
                        : "Transcripts join only when you add them (Settings → Reader turns joining by themselves back on).") {
                HStack(spacing: 10) {
                    Text(reader.unfedCount > 0 ? "\(reader.unfedCount) transcript\(reader.unfedCount == 1 ? "" : "s") not yet in the stream" : "Every transcript is in the stream")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Add them now") {
                        if let fed = reader.feedTranscripts() { flash.show(fed.recordings > 0 ? "Added \(fed.recordings) transcripts (\(fed.sentences) sentences)" : "Nothing new to add") }
                    }
                    .disabled(reader.unfedCount == 0 || reader.folder == nil)
                    .controlSize(.small)
                    Spacer()
                    Flash(text: flash.text)
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
                        .disabled(addText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reader.folder == nil)
                }
                Text(streamState).font(.system(size: 11)).foregroundStyle(.secondary)
                if let plan = reader.plan, reader.stream.count > 0, reader.stream.unread > 0 {
                    Text("The reader takes about \(plan.perChunk.formatted()) sentences at a time (average sentence \(reader.stream.averageChars.formatted()) characters; W \(reader.config.windowTokens.formatted()) fits more\(reader.config.chunkSentences > 0 ? ", but Settings → Reader keeps chunks to \(reader.config.chunkSentences.formatted())" : "")).")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if !reader.additions.isEmpty {
                ReaderBlock(title: "Lately", lede: "") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(reader.additions.suffix(8).reversed().enumerated()), id: \.offset) { _, a in
                            additionRow(a)
                        }
                    }
                    Text("The folder's stream.txt is the raw record and sentences.txt the numbered one; both are under Notes.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func additionRow(_ a: ReaderStream.Addition) -> some View {
        let r = a.source.flatMap(UUID.init(uuidString:)).flatMap { model.library.recording($0) }
        HStack(spacing: 6) {
            Text("\(a.from)–\(a.to)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Text("· \(a.sentences.formatted()) sentence\(a.sentences == 1 ? "" : "s") · \(kind(a))").font(.system(size: 11)).foregroundStyle(.secondary)
            if let r {
                Button(r.title) { model.openRecording(r.id) }.buttonStyle(.link).font(.system(size: 11)).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(when(a.added)).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private func kind(_ a: ReaderStream.Addition) -> String {
        switch a.kind ?? "" {
        case "answer": a.source != nil ? "answer, spoken" : "answer"
        case "revision": "corrected transcript"
        default: a.source != nil ? "transcript" : "pasted"
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
        if s.rawPresent { return "stream.txt is in the folder and is numbered when reading starts" }
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
}

/// What stands between you and the reader's first answers, in the order to fix it.
struct GettingStarted: View {
    let model: AppModel
    let go: (ReaderView) -> Void

    private var reader: ReaderController { model.reader }

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
            Step(id: "goals", ok: !reader.goals.trimmingCharacters(in: .whitespaces).isEmpty, text: "Write what you are trying to find out (below).", action: "", go: {}),
            Step(id: "stream", ok: reader.stream.count > 0 || reader.stream.rawPresent || reader.unfedCount > 0, text: "Record something (hold \(model.settings.settings.hotkey.glyph)), or paste text into the stream.", action: "Paste text", go: { go(.stream) }),
            Step(id: "read", ok: reader.hasNotes, text: reader.config.autoRead ? "That's all: it reads by itself, whenever you're not recording." : "Read: it runs in the background, and the window can be closed.", action: reader.config.autoRead ? "" : "Read now", go: { reader.startReading() }),
        ]
    }

    var body: some View {
        let steps = self.steps
        if !steps.allSatisfy(\.ok) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Getting started").font(.system(size: 13, weight: .semibold))
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
}
