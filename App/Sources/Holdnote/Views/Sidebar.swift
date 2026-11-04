import AppKit
import Harness
import SwiftUI
import UniformTypeIdentifiers

/// What a row of the sidebar stands for: one of the reader's views, or a recording.
enum SidebarItem: Hashable {
    case reader(ReaderView)
    case recording(UUID)
}

/// The left pane: the reader's four views at the top, then the recordings newest first, grouped
/// by day, with a status dot while a transcript is on its way. One list, so the arrow keys walk
/// through everything; the model keeps the two selections apart (the pane, and the recordings).
struct Sidebar: View {
    @Bindable var model: AppModel

    private var reader: ReaderController { model.reader }

    var body: some View {
        let groups = DayGroup.group(model.listed)
        VStack(spacing: 0) {
            List(selection: selection) {
                if model.searchText.isEmpty {
                    Section("Reader") {
                        ForEach(ReaderView.allCases) { v in
                            HStack {
                                Label(v.title, systemImage: v.symbol)
                                Spacer()
                                Text(meta(v)).font(.system(size: 11)).foregroundStyle(attention(v) ? Color.accentColor : .secondary)
                            }
                            .tag(SidebarItem.reader(v))
                        }
                    }
                }
                ForEach(groups, id: \.day) { group in
                    Section(group.title) {
                        ForEach(group.recordings) { r in
                            RecordingRow(recording: r, progress: model.library.transcribing == r.id ? model.library.transcribingProgress : nil)
                                .tag(SidebarItem.recording(r.id))
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
            .onPasteCommand(of: [.plainText]) { _ in model.pasteText() }
            .onKeyPress(.space) {
                model.togglePlayback()
                return .handled
            }
            .overlay {
                if groups.isEmpty, !model.searchText.isEmpty {
                    Text("Nothing matches").foregroundStyle(.secondary)
                }
            }
            if model.pane != .recordings || reader.running {
                Divider()
                readerFooter
            }
        }
    }

    /// The list's selection, from the model's two: the pane, and the recordings picked. A click on
    /// a reader row changes the pane; a click on a recording goes back to the recordings.
    private var selection: Binding<Set<SidebarItem>> {
        Binding(
            get: {
                switch model.pane {
                case .recordings: Set(model.selection.map { SidebarItem.recording($0) })
                case let .reader(v): [.reader(v)]
                }
            },
            set: { new in
                var current: ReaderView?
                if case let .reader(v) = model.pane { current = v }
                var views: [ReaderView] = []
                var recordings: Set<UUID> = []
                for item in new {
                    switch item {
                    case let .reader(v): views.append(v)
                    case let .recording(id): recordings.insert(id)
                    }
                }
                if let v = views.first(where: { $0 != current }) {
                    model.selection = []
                    model.pane = .reader(v)
                } else if !recordings.isEmpty {
                    model.pane = .recordings
                    model.selection = recordings
                } else {
                    model.selection = []
                }
            })
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
            if model.pane == .recordings, model.selection.contains(r.id) { model.deleteSelected() } else { model.library.delete([r.id]) }
        }
    }

    // MARK: - The reader's corner

    /// Under the list while a reader view is showing (or a night runs): how far the night is, the
    /// notes folder, and the Ollama connection.
    private var readerFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if reader.running {
                Button { model.showReader(.night) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "moon.fill").foregroundStyle(Color.accentColor)
                            Text(reader.status.isEmpty ? "Reading" : reader.status).font(.system(size: 11)).lineLimit(2)
                        }
                        ProgressView(value: Double(min(100, max(0, reader.percent))), total: 100).controlSize(.small)
                    }
                }
                .buttonStyle(.plain)
                .help("Open the Night view")
            }
            Button { reader.chooseFolder() } label: {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Folder").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(reader.folder.map { $0.name + "/" } ?? "Choose a folder").font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    }
                } icon: { Image(systemName: "folder") }
            }
            .buttonStyle(.plain)
            .help(reader.folder.map { "Notes are written into \($0.root.path). Click to choose another folder." } ?? "Choose the folder the notes are written into")
            Button { model.showSettings(tab: .reader); reader.refreshModels() } label: {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ollama").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(ollamaLine).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    }
                } icon: {
                    Circle().fill(ollamaColor).frame(width: 8, height: 8)
                }
            }
            .buttonStyle(.plain)
            .help(ollamaDetail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var ollamaLine: String {
        switch reader.ollama {
        case .checking: "checking…"
        case .ok: reader.config.model.isEmpty ? "no model" : reader.config.model
        case .bad: "not connected"
        }
    }
    private var ollamaDetail: String {
        switch reader.ollama {
        case .checking: "Checking Ollama…"
        case let .ok(d), let .bad(d): d
        }
    }
    private var ollamaColor: Color {
        switch reader.ollama {
        case .checking: .secondary
        case .ok: .green
        case .bad: .orange
        }
    }

    private func meta(_ v: ReaderView) -> String {
        switch v {
        case .stream:
            if let g = reader.gaps, !g.open.isEmpty { return "\(g.open.count) question\(g.open.count == 1 ? "" : "s")" }
            return reader.stream.count > 0 ? reader.stream.count.formatted() : ""
        case .night:
            if reader.running { return "\(reader.percent)%" }
            return reader.stream.unread > 0 ? "\(reader.stream.unread.formatted()) unread" : ""
        case .morning: return reader.notesCount > 0 ? "\(reader.notesCount) note\(reader.notesCount == 1 ? "" : "s")" : ""
        case .notes: return reader.files.isEmpty ? "" : reader.files.count.formatted()
        }
    }

    private func attention(_ v: ReaderView) -> Bool {
        switch v {
        case .stream: (reader.gaps?.open.isEmpty == false) || (reader.folder != nil && reader.stream.count == 0 && !reader.stream.rawPresent)
        case .night: !reader.running && reader.stream.unread > 0 && reader.ollamaOK
        default: false
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
                    if recording.sessionID != nil { Text("· heard") }
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
