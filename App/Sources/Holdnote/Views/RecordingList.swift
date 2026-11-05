import AppKit
import Harness
import SwiftUI
import UniformTypeIdentifiers

/// The second column when Recordings is chosen: search, then the recordings and notes. Newest
/// first in day sections, or in your own order, where rows drag up and down and files dropped
/// between two rows land there.
struct RecordingList: View {
    @Bindable var model: AppModel
    @FocusState private var searching: Bool

    private var custom: Bool { model.settings.settings.listOrder == .custom }

    var body: some View {
        let listed = model.listed
        VStack(spacing: 0) {
            ColumnHeader(title: "Recordings") {
                Menu {
                    Picker("Order", selection: order) {
                        Text("Newest first, by day").tag(Settings.ListOrder.newestFirst)
                        Text("My own order (drag to arrange)").tag(Settings.ListOrder.custom)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: custom ? "line.3.horizontal" : "calendar")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help(custom ? "In your own order: drag rows to say what came from what. Click to sort by date instead." : "Newest first, by day. Click to arrange the list in your own order.")
                Button { model.importFiles() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add audio or text files (⌘⇧I). Or drop them here.")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search transcripts", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($searching)
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.6)))
            .padding(.horizontal, 10).padding(.vertical, 8)
            List(selection: $model.selection) {
                if custom {
                    ForEach(listed) { r in item(r) }
                        .onMove { from, to in
                            model.library.move(offsets: from, to: to, shown: listed.map(\.id))
                        }
                        .onInsert(of: [.fileURL, .plainText]) { index, providers in
                            let target = listed.indices.contains(index) ? listed[index].id : nil
                            _ = model.takeDrop(providers, before: target, atEnd: target == nil)
                        }
                } else {
                    ForEach(DayGroup.group(listed), id: \.day) { group in
                        Section(group.title) {
                            ForEach(group.recordings) { r in item(r) }
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
            .onPasteCommand(of: [.plainText]) { _ in model.pasteText() }
            .onKeyPress(.space) {
                model.togglePlayback()
                return .handled
            }
            .overlay {
                if listed.isEmpty {
                    Text(model.searchText.isEmpty ? "Nothing yet. Hold \(model.settings.settings.hotkey.glyph), or drop audio or text files here." : "Nothing matches")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
        }
        .onChange(of: model.searchRequests) { _, _ in searching = true }
    }

    private var order: Binding<Settings.ListOrder> {
        Binding(get: { model.settings.settings.listOrder }, set: { new in
            if new == .custom { model.library.adoptOrderIfEmpty() }
            model.settings.settings.listOrder = new
        })
    }

    private func item(_ r: Recording) -> some View {
        RecordingRow(recording: r, progress: model.library.transcribing == r.id ? model.library.transcribingProgress : nil, showDay: custom)
            .tag(r.id)
            .contextMenu { rowMenu(r) }
    }

    @ViewBuilder
    private func rowMenu(_ r: Recording) -> some View {
        Button("Copy") { model.library.copy(r.text) }
        Button("Re-transcribe") { model.library.retranscribe(r.id) }.disabled(r.audioFile == nil || r.status == .transcribing)
        if r.audioFile != nil {
            Button("Delete audio, keep text") { model.library.deleteAudio(r.id) }
        }
        if custom {
            Divider()
            Button("Move to Top") {
                let moving = ids(for: r)
                // Above the first row that isn't moving; already on top otherwise.
                if let top = model.library.ordered.first(where: { !moving.contains($0.id) }) { model.library.move(moving, before: top.id) }
            }
            Button("Move to Bottom") { model.library.move(ids(for: r), before: nil) }
        }
        Divider()
        Button("Delete", role: .destructive) {
            if model.selection.contains(r.id) { model.deleteSelected() } else { model.library.delete([r.id]) }
        }
    }

    /// The row and, when it is part of the selection, the rest of the selection with it (in list order).
    private func ids(for r: Recording) -> [UUID] {
        model.selection.contains(r.id) ? model.selectedRecordings.map(\.id) : [r.id]
    }
}

struct RecordingRow: View {
    let recording: Recording
    /// The transcriber's progress on this one, when it is working on it.
    let progress: Double?
    /// The date as well as the time (in your own order there are no day sections to say it).
    var showDay = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(recording.title)
                    .font(.system(size: 13))
                    .foregroundStyle(recording.text.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if showDay {
                        Text(recording.createdAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                    } else {
                        Text(recording.createdAt, format: .dateTime.hour().minute())
                    }
                    if recording.audioFile != nil || recording.duration > 0 {
                        Text("·")
                        Text(TranscriptText.duration(recording.duration))
                    }
                    if recording.isEdited { Text("· edited") }
                    if recording.audioFile == nil { Text("· text only") }
                    if recording.sessionID != nil { Text("· heard") }
                    if recording.sourceDevice?.hasPrefix("Imported") == true { Text("· imported") }
                    if let progress, progress > 0 { Text("· \(Int(progress * 100))%") }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
