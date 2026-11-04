import AppKit
import Harness
import SwiftUI

/// The left pane: newest first, grouped by day, with a status dot while a transcript is on its way.
struct RecordingList: View {
    @Bindable var model: AppModel

    var body: some View {
        let groups = DayGroup.group(model.listed)
        List(selection: $model.selection) {
            ForEach(groups, id: \.day) { group in
                Section(group.title) {
                    ForEach(group.recordings) { r in
                        RecordingRow(recording: r, progress: model.library.transcribing == r.id ? model.library.transcribingProgress : nil)
                            .tag(r.id)
                            .contextMenu { rowMenu(r) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { model.deleteSelected() }
        .onCopyCommand {
            model.copySelected()
            return []
        }
        .onKeyPress(.space) {
            model.togglePlayback()
            return .handled
        }
        .overlay {
            if groups.isEmpty, !model.searchText.isEmpty {
                Text("Nothing matches").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ r: Recording) -> some View {
        Button("Copy") { model.library.copy(r.text) }
        Button("Re-transcribe") { model.library.retranscribe(r.id) }.disabled(r.audioFile == nil || r.status == .transcribing)
        if r.audioFile != nil {
            Button("Delete audio, keep text") { model.library.deleteAudio(r.id) }
        }
        Divider()
        Button("Delete", role: .destructive) {
            if model.selection.contains(r.id) { model.deleteSelected() } else { model.library.delete([r.id]) }
        }
    }
}

struct RecordingRow: View {
    let recording: Recording
    /// The transcriber's progress on this one, when it is working on it.
    let progress: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(recording.title)
                    .font(.system(size: 13))
                    .foregroundStyle(recording.text.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(recording.createdAt, format: .dateTime.hour().minute())
                    Text("·")
                    Text(TranscriptText.duration(recording.duration))
                    if recording.isEdited { Text("· edited") }
                    if recording.audioFile == nil { Text("· text only") }
                    if let progress, progress > 0 { Text("· \(Int(progress * 100))%") }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            status
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var status: some View {
        switch recording.status {
        case .recording: Circle().fill(Color.red).frame(width: 7, height: 7).padding(.top, 5)
        case .transcribing: Circle().fill(Color.secondary.opacity(0.5)).frame(width: 7, height: 7).padding(.top, 5)
        case .failed: Circle().fill(Color.orange).frame(width: 7, height: 7).padding(.top, 5)
        case .final: EmptyView()
        }
    }
}
