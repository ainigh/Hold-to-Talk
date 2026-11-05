import AppKit
import Harness
import SwiftUI
import UniformTypeIdentifiers

/// The second column when the Stream is chosen: search, then everything in it (recordings,
/// imported audio, pasted and dropped text), each an item that is or becomes text. Newest first
/// in day sections, or in your own order, where rows drag up and down and files dropped
/// between two rows land there. Choose an item for its text; choose none for the whole stream.
struct RecordingList: View {
    @Bindable var model: AppModel
    @FocusState private var searching: Bool

    private var custom: Bool { model.settings.settings.listOrder == .custom }

    var body: some View {
        let listed = model.listed
        VStack(spacing: 0) {
            ColumnHeader(title: "Stream") {
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
                Menu {
                    Button("Import audio or text files…") { model.importFiles() }
                    Button("Paste the clipboard as a note") { model.pasteText() }
                    Divider()
                    Text("Or hold \(model.settings.settings.hotkey.glyph) and talk, or drop files or text anywhere on the window.")
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Add to the stream: files (⌘⇧I), the clipboard (⌘⇧V), or your voice")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search the stream", text: $model.searchText)
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
                // ALL: the whole stream as one text, with the conversation about all of it.
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "text.alignleft").foregroundStyle(Color.accentColor)
                        Text("ALL").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(listed.count == 1 ? "1 item" : "\(listed.count) items").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(AppModel.allID)
                    .help("Everything in the stream as one text, exactly what the reader reads, with the conversation about all of it beside it (⌘⇧A)")
                }
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
            // ALL, or nothing chosen, shows the whole stream; an item chosen shows its own text.
            // ALL and items don't mix: whichever was added last wins.
            .onChange(of: model.selection) { old, new in
                if new.contains(AppModel.allID), new.count > 1 {
                    model.selection = old.contains(AppModel.allID) ? new.subtracting([AppModel.allID]) : [AppModel.allID]
                } else if new == [AppModel.allID] {
                    model.showingAll = true
                } else if !new.isEmpty {
                    model.showingAll = false
                }
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
        RecordingRow(recording: r, progress: model.library.transcribing == r.id ? model.library.transcribingProgress : nil, showDay: custom, reader: model.reader.rowMark(for: r))
            .tag(r.id)
            .contextMenu { rowMenu(r) }
    }

    @ViewBuilder
    private func rowMenu(_ r: Recording) -> some View {
        Button("Copy") { model.library.copy(r.text) }
        if r.status == .transcribing, model.library.transcribing == r.id {
            Button("Stop transcribing") { model.library.cancelTranscription() }
        } else {
            Button("Re-transcribe") { model.library.retranscribe(r.id) }.disabled(!r.hasAudio || r.status == .transcribing)
        }
        Button("Ask the reader about it") { model.askAbout(r) }.disabled(r.text.isEmpty)
        if r.hasAudio {
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
    /// What the reader has to say about it.
    var reader: ReaderController.RowMark? = nil

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
                    if let measure = ItemPresentation.measure(of: recording) { Text("· \(measure)") }
                    if let edited = ItemPresentation.editedWord(of: recording) { Text("· \(edited)") }
                    ForEach(ItemPresentation.originWords(of: recording), id: \.self) { Text("· \($0)") }
                    if let progress, progress > 0 { Text("· \(Int(progress * 100))%") }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            readerMark
            status
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var readerMark: some View {
        switch reader {
        case let .questions(n):
            HStack(spacing: 2) {
                Image(systemName: "questionmark.bubble.fill")
                Text("\(n)")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.top, 2)
            .help("The reader has \(n) question\(n == 1 ? "" : "s") about this recording")
        case .edited:
            Image(systemName: "pencil.circle").font(.system(size: 11)).foregroundStyle(.orange).padding(.top, 2)
                .help("Edited after it joined the reader's stream; the reader still has the earlier words")
        case .waiting, .unread:
            Image(systemName: "eyeglasses").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 3)
                .help(reader == .waiting ? "Joins the reader's stream soon" : "In the reader's stream, not read yet")
        case nil:
            EmptyView()
        }
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
