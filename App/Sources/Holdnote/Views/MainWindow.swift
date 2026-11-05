import AppKit
import Harness
import SwiftUI
import UniformTypeIdentifiers

/// The one window, in columns. The first names the three things you use (the Stream, Ask, For
/// you), what is under the hood, and settings; choosing a row opens the columns it needs: the
/// stream's items, the note files or the settings pages, then the page itself on the right.
/// The Stream is the real input: everything you add, as one text, or one item of it at a time.
struct MainWindow: View {
    @Bindable var model: AppModel
    @AppStorage("listColumnWidth") private var listWidth: Double = 320

    private var reader: ReaderController { model.reader }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                MenuColumn(model: model)
                    .frame(width: 220)
                Divider()
                middle
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            UsageBar(monitor: model.monitor, transcribing: model.library.transcribing != nil, listening: model.capture.isListening)
        }
        .toolbar {
            // The same items whatever is showing: a toolbar bridged into an AppKit window
            // loses items whose identity changes, so only labels, actions and enabling vary.
            ToolbarItem(placement: .navigation) {
                Toggle(isOn: $model.listening) {
                    Label(model.capture.isListening ? (model.capture.isSpeaking ? "Hearing you…" : "Listening") : "Voice Detection",
                          systemImage: model.capture.isListening ? "ear.fill" : "ear")
                }
                .toggleStyle(.button)
                .tint(model.capture.isSpeaking ? .red : .accentColor)
                .help("Record by itself whenever you speak; each stretch of speech becomes a recording (⌘⇧L). The menu bar icon pulses while it's on.")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                UpdateStatus(updater: model.updater)
                Toggle(isOn: wholeStream) { Label("Whole stream", systemImage: "doc.plaintext") }
                    .help("The whole stream as one continuous text, exactly what the reader reads (⌘⇧A). Select a passage and right-click to ask about it.")
                Button { model.pasteText() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .help("Add the clipboard's text to the stream as a note (⌘⇧V)")
                Button { model.importFiles() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Add audio files (m4a, mp3, wav…), transcribed here, or text files (.txt, .md) to the stream (⌘⇧I). Or drop them on the window.")
                Button { model.copyAll() } label: { Label("Copy All", systemImage: "doc.on.doc") }
                    .help("Copy the whole stream, in the list's order (⌘⇧C)")
                    .disabled(model.listed.isEmpty)
                Button {
                    if reader.running { reader.stopAfterCall() } else { model.showReader(.reading); reader.startReading() }
                } label: {
                    Label(reader.running ? (reader.stopping ? "Stopping…" : "Pause reading") : reader.startTitle,
                          systemImage: reader.running ? "pause.circle" : "eyeglasses")
                }
                .disabled(reader.running ? reader.stopping : (reader.blocker != nil || !reader.hasWork))
                .help(reader.running ? "Finish the call in progress, save, then pause. Read now carries on from the same place."
                      : (reader.blocker?.text ?? (reader.hasWork ? "Read what's new through every lens now, then answer the questions about your goals (it also does this by itself)" : "The reader has read everything you've said")))
            }
        }
        .overlay(alignment: .bottom) {
            if !model.library.pendingDeletes.isEmpty {
                UndoToast(count: model.library.pendingDeletes.count) { model.library.undoDelete() }
                    .padding(.bottom, 36)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.library.pendingDeletes.count)
        // Audio and text files (or loose text) dropped anywhere on the window join the list (and so
        // the stream). The stream's own box, deeper in, keeps the text dropped on it; the list
        // places what lands between its rows.
        .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { providers in model.takeDrop(providers) }
        .frame(minWidth: 960, minHeight: 560)
        .onAppear { reader.refreshStream(); reader.refreshFiles() }
        // A transcript finishing changes no count, so the reader is told about any change in status or text.
        .onChange(of: libraryFingerprint) { _, _ in reader.libraryChanged() }
    }

    /// The toolbar's Whole stream: on when the stream shows as one text (by choice, or because
    /// no item is chosen); off picks the first item.
    private var wholeStream: Binding<Bool> {
        Binding(get: { model.showingAll || model.selection.isEmpty },
                set: { on in
                    if on { model.showWholeStream() }
                    else { model.showingAll = false; if model.selection.isEmpty, let first = model.listed.first { model.selection = [first.id] } }
                })
    }

    /// Changes when a recording is added, removed, finishes or is edited.
    private var libraryFingerprint: Int {
        var h = Hasher()
        for r in model.library.recordings { h.combine(r.id); h.combine(r.status); h.combine(r.text.count) }
        return h.finalize()
    }

    /// The second column, for the sections that have a list to choose from.
    @ViewBuilder
    private var middle: some View {
        switch model.section {
        case .recordings:
            RecordingList(model: model).frame(width: listWidth)
            ColumnResizer(width: $listWidth, range: 240...520)
        case .reader(.notes):
            NotesFileList(model: model).frame(width: 260)
            Divider()
        case .settings:
            SettingsList(model: model).frame(width: 200)
            Divider()
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.section {
        case .recordings: recordings
        case .reader(.ask): ReaderAskView(model: model, go: { model.showReader($0) })
        case .reader(.forYou): ReaderForYouView(model: model, go: { model.showReader($0) })
        case .reader(.reading): ReaderReadingView(model: model, go: { model.showReader($0) })
        case .reader(.notes): NotesEditor(model: model)
        case .readerGuide: ReaderAboutView()
        case let .settings(tab): SettingsPage(model: model, tab: tab)
        case .setup: SetupView(model: model)
        }
    }

    /// One item's text when one is chosen, or the whole stream as one text.
    @ViewBuilder
    private var recordings: some View {
        let selected = model.selectedRecordings
        if model.library.recordings.isEmpty {
            EmptyState(hotkey: model.settings.settings.hotkey)
        } else if !model.showingAll, selected.count == 1, let r = selected.first {
            TranscriptView(model: model, recording: r)
                .id(r.id)
        } else if !model.showingAll, selected.count > 1 {
            MultiSelection(model: model, count: selected.count)
        } else {
            StreamTextView(model: model)
        }
    }
}

/// "Hold Fn to make your first recording", with the key drawn as a keycap.
struct EmptyState: View {
    let hotkey: Settings.Hotkey

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Text("Hold")
                Text(hotkey.glyph)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.tertiary, lineWidth: 0.5))
                Text("to make your first recording")
            }
            .font(.system(size: 15))
            Text("Double-tap it to record hands-free; tap once to stop. Or turn on Voice Detection and just talk.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Or drop audio files (an m4a from Voice Memos, say) or text files here, or paste text (⌘⇧V). Each becomes an item in the stream, and every item becomes text.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("The reader reads the stream as it grows, asks you about what it can't place (For you), and answers what you ask about it (Ask, ⌘2).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MultiSelection: View {
    let model: AppModel
    let count: Int

    var body: some View {
        VStack(spacing: 16) {
            Text("\(count) items selected").font(.title3)
            HStack(spacing: 12) {
                Button("Copy all") { model.copySelected() }
                Button("Delete", role: .destructive) { model.deleteSelected() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct UndoToast: View {
    let count: Int
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(count == 1 ? "Recording deleted" : "\(count) recordings deleted")
            Button("Undo", action: undo).keyboardShortcut("z", modifiers: .command)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }
}

/// Updates at the top right of the window: a quiet "Check for updates", an update to install, or
/// what went wrong with a report to copy.
struct UpdateStatus: View {
    let updater: Updater

    var body: some View {
        if Updater.canUpdate {
            switch updater.state {
            case .idle, .upToDate:
                Button { updater.check(userInitiated: true) } label: {
                    Label(updater.state == .upToDate ? "Up to date" : "Check for updates", systemImage: "arrow.triangle.2.circlepath")
                }
                .help(updater.state == .upToDate ? "\(updater.versionLine). Click to check again" : updater.versionLine)
            case .checking:
                ProgressView().controlSize(.small).help("Checking for updates…")
            case let .available(plan):
                Button { updater.confirmInstall() } label: { Label(plan.title + "…", systemImage: "arrow.down.circle.fill") }
                    .help(plan.title + ". Click to review it; nothing installs until you say so.")
            case let .installing(step):
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(step).font(.caption) }
            case let .failed(message):
                Menu {
                    Text(message)
                    Button("Try again") { updater.check(userInitiated: true) }
                    Button("Copy error report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Updater.report(message), forType: .string)
                    }
                } label: { Label("Update failed", systemImage: "exclamationmark.triangle") }
            }
        }
    }
}
