import Harness
import SwiftUI

/// The top right of the window: what Holdnote is doing right now, in one line, with the way to
/// stop it. A recording in progress; the transcriber's phase (reading the file, cutting it into
/// chunks, transcribing: chunks done and running) with Stop; the reader reading with Pause.
/// Quiet when nothing is going on. Clicking the line opens the thing it describes.
struct ActivityStatus: View {
    let model: AppModel

    private var library: Library { model.library }
    private var reader: ReaderController { model.reader }

    var body: some View {
        HStack(spacing: 8) {
            if model.capture.isRecording {
                line("record.circle.fill", "Recording", color: .red) { model.show(.recordings) }
                Button("Stop") { model.capture.stopFromMenu() }.controlSize(.small)
            } else if let id = library.transcribing {
                line("waveform.badge.magnifyingglass", transcribingText, color: .accentColor) { model.openRecording(id) }
                if library.transcribingPhase == .transcribing {
                    ProgressView(value: library.transcribingProgress).frame(width: 70).controlSize(.small)
                }
                Button(library.transcribingStopping ? "Stopping…" : "Stop") { library.cancelTranscription() }
                    .controlSize(.small)
                    .disabled(library.transcribingStopping)
                    .help("Stop transcribing. The audio is kept; Retry runs it again.")
            } else if reader.running {
                line("eyeglasses", readingText, color: .accentColor) { model.showReader(.reading) }
                ProgressView(value: Double(min(100, max(0, reader.percent))), total: 100).frame(width: 70).controlSize(.small)
                Button(reader.stopping ? "Stopping…" : "Pause") { reader.stopAfterCall() }
                    .controlSize(.small)
                    .disabled(reader.stopping)
                    .help("Finish the call in progress, save, then pause. Read now carries on from the same place.")
            } else if model.capture.isListening {
                line("ear", model.capture.isSpeaking ? "Hearing you…" : "Listening", color: model.capture.isSpeaking ? .red : .secondary) { model.show(.recordings) }
            }
        }
        .font(.system(size: 12))
    }

    private func line(_ symbol: String, _ text: String, color: Color, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(text).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help("Open what this is about")
    }

    private var transcribingText: String {
        switch library.transcribingPhase {
        case .reading: return "Reading the file…"
        case .cutting: return "Cutting into chunks…"
        case .transcribing:
            let chunks = library.transcribingChunks
            if chunks.count > 1 {
                let done = chunks.filter { $0.state == .done }.count
                let running = chunks.filter { $0.state == .running }.count
                return "Transcribing · \(done) of \(chunks.count) chunks, \(running) running"
            }
            return "Transcribing \(Int(library.transcribingProgress * 100))%"
        }
    }

    private var readingText: String {
        if let c = reader.chunk { return "Reading \(c.from)–\(c.to)" }
        if let q = reader.questionInfo, !q.current.isEmpty { return "Answering \(q.done + 1) of \(q.total)" }
        return reader.status.isEmpty ? "Reading" : reader.status
    }
}
