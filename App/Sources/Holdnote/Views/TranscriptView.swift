import AppKit
import Harness
import SwiftUI

/// The right pane: the date, duration and play button above an editable transcript. Everything
/// you type is saved as you type. While playing, the sentence being spoken is highlighted;
/// click a sentence to hear it. Beside it (or under it, when the pane is narrow), what the reader
/// made of this recording.
struct TranscriptView: View {
    let model: AppModel
    let recording: Recording
    @State private var text: String
    @State private var copied = false
    @FocusState private var editing: Bool
    @AppStorage("transcriptReaderPanel") private var showReader = true

    init(model: AppModel, recording: Recording) {
        self.model = model
        self.recording = recording
        _text = State(initialValue: recording.text)
    }

    private var live: Recording { model.library.recording(recording.id) ?? recording }
    private var audioURL: URL? { model.library.store.audioURL(for: live) }
    private var isPlayingThis: Bool { model.player.playing == recording.id }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 660
            if showReader, wide {
                HStack(spacing: 0) {
                    transcript
                    Divider()
                    RecordingReaderPanel(model: model, recording: live).frame(width: min(340, max(280, geo.size.width * 0.34)))
                }
            } else if showReader {
                VSplitView {
                    transcript.frame(minHeight: 200)
                    RecordingReaderPanel(model: model, recording: live).frame(minHeight: 140, idealHeight: 260)
                }
            } else {
                transcript
            }
        }
        .onChange(of: live.text) { _, new in
            // A transcript landing from the transcriber (or a merge) replaces what's shown,
            // unless you are mid-edit of the same text.
            if new != text, !editing || text == recording.text { text = new }
        }
        .onChange(of: text) { _, new in model.library.setText(new, of: recording.id) }
        .onDisappear { model.library.saveNow() }
    }

    private var transcript: some View {
        let r = live
        return VStack(spacing: 0) {
            header(r)
            Divider()
            if r.status == .failed, let failure = r.failure {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(failure).font(.system(size: 12)).lineLimit(2)
                    Spacer()
                    Button("Retry") { model.library.retranscribe(r.id) }.disabled(r.audioFile == nil)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.08))
            }
            if r.status == .transcribing && r.text.isEmpty {
                VStack(spacing: 10) {
                    ProgressView(value: model.library.transcribing == r.id ? model.library.transcribingProgress : 0)
                        .frame(width: 200)
                    Text(model.library.transcribing == r.id ? "Transcribing…" : "Waiting to transcribe…")
                        .foregroundStyle(.secondary)
                    if model.library.transcribing == r.id, !model.library.transcribingNote.isEmpty {
                        Text(model.library.transcribingNote).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isPlayingThis, !r.segments.isEmpty, !editing {
                PlaybackText(recording: r, time: model.player.time) { t in
                    if let audioURL { model.player.play(audioURL, id: r.id, from: t) }
                }
            } else {
                editor(r)
            }
            Divider()
            footer(r)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ r: Recording) -> some View {
        HStack(spacing: 12) {
            if let audioURL {
                Button {
                    model.player.toggle(audioURL, id: r.id)
                } label: {
                    Image(systemName: isPlayingThis && model.player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .clipShape(Circle())
                .help("Play (Space)")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(r.createdAt, format: .dateTime.weekday(.wide).day().month(.wide).hour().minute())
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    Text(TranscriptText.duration(r.duration))
                    if let device = r.sourceDevice { Text("· \(device)") }
                    if let language = r.language, let name = Locale.current.localizedString(forLanguageCode: language) { Text("· \(name)") }
                    if r.isEdited { Text("· edited") }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if isPlayingThis, model.player.duration > 0 {
                Slider(value: Binding(get: { model.player.time }, set: { model.player.seek(to: $0) }), in: 0...model.player.duration)
                    .frame(width: 160)
                Text(TranscriptText.duration(model.player.time))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: $showReader) {
                Label(readerLabel(r), systemImage: "eyeglasses")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(showReader ? "Hide what the reader made of this recording" : "Show what the reader made of this recording: its questions for you, what each lens noticed, and asking about it")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// "Reader", with the number of questions it has about this recording.
    private func readerLabel(_ r: Recording) -> String {
        if case let .questions(n) = model.reader.rowMark(for: r) { return "Reader · \(n)?" }
        return "Reader"
    }

    private func editor(_ r: Recording) -> some View {
        TextEditor(text: $text)
            .font(.system(size: 16))
            .lineSpacing(6)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focused($editing)
            .opacity(r.status == .transcribing ? 0.7 : 1)
            .animation(.easeOut(duration: 0.3), value: r.status)
    }

    private func footer(_ r: Recording) -> some View {
        HStack(spacing: 10) {
            Button {
                model.library.copy(text)
                copied = true
                Task { try? await Task.sleep(for: .milliseconds(1200)); copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .help("Copy the transcript (⌘C with the list focused, ⌘⌥C anywhere)")
            Button {
                // A new paragraph at the end, with the cursor there.
                if !text.hasSuffix("\n\n") { text = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" }
                editing = true
                NSApp.sendAction(#selector(NSTextView.moveToEndOfDocument(_:)), to: nil, from: nil)
            } label: { Label("Append", systemImage: "text.append") }
            .help("Add a paragraph at the end. Or hold ⌥ with the hotkey to add by voice.")
            Button { model.library.retranscribe(r.id) } label: { Label("Re-transcribe", systemImage: "arrow.clockwise") }
                .disabled(r.audioFile == nil || r.status == .transcribing)
                .help("Run the transcriber again (after adding to the vocabulary, say). Your edits are kept.")
            Spacer()
            Button(role: .destructive) { model.library.delete([r.id]); model.selection = [] } label: { Label("Delete", systemImage: "trash") }
                .help("Delete (⌫). Ten seconds to undo.")
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

/// The transcript while playing: its sentences, the one being spoken highlighted, each a button to seek.
struct PlaybackText: View {
    let recording: Recording
    let time: TimeInterval
    let seek: (TimeInterval) -> Void

    var body: some View {
        ScrollView {
            FlowText(segments: recording.segments, time: time, seek: seek)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }
}

struct FlowText: View {
    let segments: [Recording.Segment]
    let time: TimeInterval
    let seek: (TimeInterval) -> Void

    var body: some View {
        // One Text, so the sentences wrap as prose.
        var text = Text("")
        for (i, s) in segments.enumerated() {
            let current = time >= s.start && time < s.end
            let piece = Text(s.text + (i < segments.count - 1 ? " " : ""))
                .foregroundColor(current ? .accentColor : .primary)
            text = text + piece
        }
        return text
            .font(.system(size: 16))
            .lineSpacing(6)
            .textSelection(.enabled)
            .overlay {
                // Clicks: the nearest sentence by position isn't knowable from one Text, so a
                // click seeks by its fraction of the text's height, which is close enough.
                GeometryReader { geo in
                    Color.clear.contentShape(Rectangle()).onTapGesture { point in
                        guard let last = segments.last, geo.size.height > 0 else { return }
                        let fraction = max(0, min(1, point.y / geo.size.height))
                        seek(fraction * last.end)
                    }
                }
            }
    }
}
