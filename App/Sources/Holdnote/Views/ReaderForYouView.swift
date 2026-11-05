import Harness
import SwiftUI

/// For you: what the reader could not work out from your words alone, with the recording each
/// question came from. Answer by voice (the next recording is the answer) or by typing; each
/// answer joins the stream and is read like everything else.
struct ReaderForYouView: View {
    let model: AppModel
    let go: (ReaderView) -> Void
    @StateObject private var flash = FlashState()

    private var reader: ReaderController { model.reader }

    var body: some View {
        ReaderPage(title: "Questions for you", lede: "What the reader could not work out from your words alone: who someone is, what a vague reference points to, what happened next. Answer by voice or by typing; your answer joins the stream and is read like everything else.") {
            if let gap = reader.voiceAnswer { VoiceAnswerBanner(model: model, gap: gap) }
            if let gaps = reader.gaps {
                HStack {
                    Text(gaps.open.isEmpty ? "\(gaps.answered) answered" : "\(gaps.open.count) open · \(gaps.answered) answered").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Flash(text: flash.text)
                }
                if gaps.open.isEmpty {
                    Card {
                        Text("Nothing to ask you right now.").font(.system(size: 13, weight: .medium))
                        Text("As the reader reads what you say, it asks here about whatever it can't place. A notification says so when you're elsewhere.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(grouped(gaps.open), id: \.key) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        if let r = group.recording {
                            Button { model.openRecording(r.id) } label: {
                                Label("From your recording of \(r.createdAt.formatted(date: .abbreviated, time: .shortened)): “\(r.title)”", systemImage: r.audioFile != nil ? "waveform" : "doc.text")
                                    .font(.system(size: 12)).lineLimit(1)
                            }
                            .buttonStyle(.link)
                        } else {
                            Text("From what you pasted or answered").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        ForEach(group.gaps) { gap in
                            GapRow(gap: gap, model: model) { msg in if let msg { flash.show(msg) } }
                        }
                    }
                }
            } else if !reader.lenses.contains(where: { $0.id == Lens.gapsId && $0.on }) {
                Card {
                    Text("The “Questions for you” lens is switched off.").font(.system(size: 13, weight: .medium))
                    Button("Open the lenses") { go(.reading) }.buttonStyle(.link)
                }
            } else {
                Card {
                    Text("No questions yet.").font(.system(size: 13, weight: .medium))
                    Text("They appear once the reader has read something you said.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }

    struct Group {
        var key: String
        var recording: Recording?
        var gaps: [ReaderStream.Gap]
    }

    /// Questions under the recording they came from, newest recording first.
    private func grouped(_ gaps: [ReaderStream.Gap]) -> [Group] {
        var out: [Group] = []
        for g in gaps {
            let r = reader.origin(of: g)
            let key = r?.id.uuidString ?? "other"
            if let i = out.firstIndex(where: { $0.key == key }) { out[i].gaps.append(g) } else { out.append(Group(key: key, recording: r, gaps: [g])) }
        }
        return out.sorted { ($0.recording?.createdAt ?? .distantPast) > ($1.recording?.createdAt ?? .distantPast) }
    }
}

/// While a question waits for a spoken answer.
struct VoiceAnswerBanner: View {
    let model: AppModel
    let gap: ReaderStream.Gap

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "mic.fill").foregroundStyle(.red).font(.system(size: 15)).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Hold \(model.settings.settings.hotkey.glyph) and say your answer").font(.system(size: 13, weight: .semibold))
                Text(gap.question).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("The next recording is taken as the answer once it's transcribed.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button("Cancel") { model.reader.disarmVoiceAnswer() }.controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.25)))
    }
}

/// One of the reader's questions, to answer by voice, by typing, or to skip.
struct GapRow: View {
    let gap: ReaderStream.Gap
    let model: AppModel
    var compact = false
    let done: (String?) -> Void
    @State private var answer = ""

    private var reader: ReaderController { model.reader }

    var body: some View {
        let armed = reader.voiceAnswer?.id == gap.id
        VStack(alignment: .leading, spacing: 6) {
            Text(gap.question).font(.system(size: 13, weight: .medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !compact { SentenceIds(ids: gap.ids, model: model) }
            HStack(alignment: .center, spacing: 6) {
                Button {
                    if armed { reader.disarmVoiceAnswer() } else { reader.armVoiceAnswer(gap); done("Hold \(model.settings.settings.hotkey.glyph) and say your answer") }
                } label: {
                    Label(armed ? "Listening for your answer…" : "Answer by voice", systemImage: armed ? "mic.fill" : "mic")
                }
                .controlSize(.small)
                .tint(armed ? .red : nil)
                .help(armed ? "Cancel: the next recording will not be taken as the answer" : "The next recording you make (hold \(model.settings.settings.hotkey.glyph)) becomes the answer")
                TextField("or type it", text: $answer)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { send(answer) }
                Button("Answer") { send(answer) }.disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty).controlSize(.small)
                Button("Skip") { send("") }.help("Do not ask this again").controlSize(.small)
            }
        }
        .padding(compact ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(armed ? Color.red.opacity(0.06) : Color.secondary.opacity(0.08)))
    }

    private func send(_ a: String) {
        let msg = reader.answer(gap, with: a)
        answer = ""
        done(msg ?? (a.isEmpty ? "Skipped" : "Answer saved"))
    }
}
