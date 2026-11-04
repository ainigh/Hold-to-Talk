import AppKit
import Harness
import SwiftUI

/// The one window: the sidebar on the left holds the reader's four views (Stream, Night, Morning,
/// Notes) and then the recordings; the right pane shows whichever is chosen, the transcript of the
/// selected recording by default.
struct MainWindow: View {
    @Bindable var model: AppModel

    private var reader: ReaderController { model.reader }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                Sidebar(model: model)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 320)
            } detail: {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search transcripts")
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
                    Toggle(isOn: $model.showingAll) { Label("All Text", systemImage: "doc.plaintext") }
                        .help("Every transcript in the list as one continuous text (⌘⇧A). Select all and copy, or Copy All.")
                    Button { model.pasteText() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                        .help("The clipboard's text as a new note (⌘⇧V)")
                    Button { model.copyAll() } label: { Label("Copy All", systemImage: "doc.on.doc") }
                        .help("Copy every transcript in the list, newest first (⌘⇧C)")
                        .disabled(model.listed.isEmpty)
                    Button {
                        if reader.running { reader.stopAfterCall() } else { model.showReader(.night); reader.startNight() }
                    } label: {
                        Label(reader.running ? (reader.stopping ? "Stopping…" : "Stop after this call") : reader.startTitle,
                              systemImage: reader.running ? "stop.circle" : "moon.fill")
                    }
                    .disabled(reader.running ? reader.stopping : reader.blocker != nil)
                    .help(reader.running ? "Finish the call in progress, save progress, then stop. Resume later from the same place."
                          : (reader.blocker?.text ?? "The reader: read everything unread through every lens, then answer the overnight questions"))
                    Button { model.showSettings() } label: { Label("Settings", systemImage: "gearshape") }
                        .help("Settings (⌘,)")
                }
            }
            Divider()
            UsageBar(monitor: model.monitor, transcribing: model.library.transcribing != nil, listening: model.capture.isListening)
        }
        .overlay(alignment: .bottom) {
            if !model.library.pendingDeletes.isEmpty {
                UndoToast(count: model.library.pendingDeletes.count) { model.library.undoDelete() }
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.library.pendingDeletes.count)
        .frame(minWidth: 860, minHeight: 520)
        .onAppear { reader.refreshStream(); reader.refreshFiles() }
        .onChange(of: model.library.recordings.count) { _, _ in reader.libraryChanged() }
        // Typing in the search field is about the recordings.
        .onChange(of: model.searchText) { _, new in if !new.isEmpty, model.pane != .recordings { model.pane = .recordings } }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.pane {
        case .reader(.stream): ReaderStreamView(model: model, go: { model.showReader($0) })
        case .reader(.night): ReaderNightView(model: model, go: { model.showReader($0) })
        case .reader(.morning): ReaderMorningView(model: model)
        case .reader(.notes): ReaderNotesView(model: model)
        case .recordings: recordings
        }
    }

    @ViewBuilder
    private var recordings: some View {
        let selected = model.selectedRecordings
        if model.showingAll, !model.listed.isEmpty {
            AllTextView(model: model)
        } else if model.library.recordings.isEmpty {
            EmptyState(hotkey: model.settings.settings.hotkey)
        } else if selected.count == 1, let r = selected.first {
            TranscriptView(model: model, recording: r)
                .id(r.id)
        } else if selected.count > 1 {
            MultiSelection(model: model, count: selected.count)
        } else {
            Text("Select a recording")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MultiSelection: View {
    let model: AppModel
    let count: Int

    var body: some View {
        VStack(spacing: 16) {
            Text("\(count) recordings selected").font(.title3)
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
