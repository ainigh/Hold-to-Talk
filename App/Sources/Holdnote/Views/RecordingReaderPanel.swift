import Harness
import SwiftUI

/// Beside a transcript: what the reader made of this recording. Whether it is in the stream yet
/// and read, the questions it raised for you (answer them here, by voice or typing), what each
/// lens noticed in it, and questions about this recording alone.
struct RecordingReaderPanel: View {
    let model: AppModel
    let recording: Recording
    @State private var question = ""
    @State private var expanded: Set<String> = []
    @StateObject private var flash = FlashState()

    private var reader: ReaderController { model.reader }

    var body: some View {
        let standing = reader.standing(of: recording)
        let ids: [Int] = { if case let .inStream(ids, _) = standing { return ids }; return [] }()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Reader", systemImage: "eyeglasses").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Flash(text: flash.text)
                }
                status(standing, ids: ids)
                if !ids.isEmpty {
                    let gaps = reader.gapsAbout(ids)
                    if !gaps.isEmpty {
                        section("It asks you", count: gaps.count) {
                            ForEach(gaps) { gap in
                                GapRow(gap: gap, model: model, compact: true) { msg in if let msg { flash.show(msg) } }
                            }
                        }
                    }
                    findings(ids)
                    askSection
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Where it stands

    @ViewBuilder
    private func status(_ standing: ReaderStream.Standing, ids: [Int]) -> some View {
        switch standing {
        case .notReady:
            line("hourglass", recording.status == .failed ? "Not transcribed, so there is nothing to read." : "Joins the stream once it's transcribed.")
        case .waiting:
            VStack(alignment: .leading, spacing: 6) {
                line("circle.dotted", reader.config.feedTranscripts
                     ? "Joins the stream about \(reader.config.settleSeconds) seconds after you stop editing it; then the reader reads it."
                     : "Not in the stream. Transcripts join only when added (Settings → Reader).")
                Button("Add it now") { reader.feed(recording) }.controlSize(.small).disabled(reader.folder == nil)
            }
        case let .inStream(_, edited):
            VStack(alignment: .leading, spacing: 6) {
                line(readSymbol(ids), readText(ids))
                if edited {
                    VStack(alignment: .leading, spacing: 4) {
                        line("pencil.circle", "You changed it after it joined; the reader still has the earlier words.", color: .orange)
                        Button("Add the corrected text") { reader.revise(recording); flash.show("The correction joins the stream") }
                            .controlSize(.small)
                            .help("The whole transcript joins again, marked as a correction of the earlier sentences, which keep their ids")
                    }
                }
            }
        }
    }

    private func range(_ ids: [Int]) -> String {
        guard let lo = ids.min(), let hi = ids.max() else { return "" }
        return lo == hi ? Sentences.makeId(lo) : "\(Sentences.makeId(lo))–\(Sentences.makeId(hi))"
    }

    private func readState(_ ids: [Int]) -> (read: Bool, now: Bool) {
        guard let hi = ids.max(), let lo = ids.min() else { return (false, false) }
        let read = reader.running ? reader.readCount : reader.stream.count - reader.stream.unread
        var now = false
        if reader.running, let c = reader.chunk, let a = Sentences.number(c.from), let b = Sentences.number(c.to) { now = a <= hi && b >= lo }
        return (hi <= read, now)
    }

    private func readSymbol(_ ids: [Int]) -> String {
        let s = readState(ids)
        return s.now ? "eyeglasses" : s.read ? "checkmark.circle" : "clock"
    }

    private func readText(_ ids: [Int]) -> String {
        let s = readState(ids)
        let place = "In the stream as \(range(ids))"
        if s.now { return "\(place) · being read now" }
        if s.read { return "\(place) · read by every lens" }
        return "\(place) · \(reader.config.autoRead ? "read soon, when you're not recording" : "not read yet")"
    }

    private func line(_ symbol: String, _ text: String, color: Color = .secondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(color)
            Text(text).font(.system(size: 12)).foregroundStyle(color == .secondary ? Color.secondary : color).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Content: View>(_ title: String, count: Int? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let count { Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            content()
        }
    }

    // MARK: - What it noticed

    @ViewBuilder
    private func findings(_ ids: [Int]) -> some View {
        let found = reader.findings(for: ids)
        if found.isEmpty {
            if readState(ids).read { line("text.magnifyingglass", "The lenses wrote nothing about it.") }
        } else {
            section("What it noticed") {
                ForEach(found) { item in
                    lensFindings(item.lens, item.entries)
                }
            }
        }
    }

    private func lensFindings(_ lens: Lens, _ entries: [LensParse.Entry]) -> some View {
        let open = expanded.contains(lens.id)
        let limit = lens.id == "ledger" ? 3 : 5
        let shown = open ? entries : Array(entries.prefix(limit))
        return VStack(alignment: .leading, spacing: 4) {
            Text(lens.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            ForEach(Array(shown.enumerated()), id: \.offset) { _, e in
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.text).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(e.ids.joined(separator: ", ")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            if entries.count > limit {
                Button(open ? "Fewer" : "\(entries.count - limit) more") {
                    if open { expanded.remove(lens.id) } else { expanded.insert(lens.id) }
                }
                .buttonStyle(.link).font(.system(size: 11))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.35)))
    }

    // MARK: - Asking about it

    private var askSection: some View {
        section("Ask about this recording") {
            ForEach(reader.turns(about: recording)) { turn in
                TurnView(model: model, turn: turn, pending: reader.asking && turn.id == reader.chat.last?.id, compact: true) { msg in flash.show(msg) }
            }
            HStack(spacing: 6) {
                TextField("e.g. What was I really worried about here?", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { ask() }
                Button(reader.asking ? "Cancel" : "Ask") { if reader.asking { reader.cancelAsk() } else { ask() } }
                    .controlSize(.small)
                    .disabled(!reader.asking && (question.trimmingCharacters(in: .whitespaces).isEmpty || reader.config.model.isEmpty))
            }
            Text("Answers come from this recording's sentences first, then the notes on everything else.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !reader.asking else { return }
        question = ""
        reader.ask(q, about: recording)
    }
}
