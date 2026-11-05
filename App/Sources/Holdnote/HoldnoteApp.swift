import AppKit
import Harness
import SwiftUI
import UniformTypeIdentifiers

@main
struct HoldnoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        // The icon is AppKit's (`StatusBarController`), and so is the one window
        // (`AppModel.showWindow`). This scene is never shown; it's here because an app needs one,
        // and it carries the app's menus and their shortcuts.
        MenuBarExtra("Holdnote", systemImage: "waveform", isInserted: .constant(false)) {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.showSettings() }.keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Recording") {
                Button(model.capture.isListening ? "Stop Voice Detection" : "Start Voice Detection") { model.listening.toggle() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Add the Clipboard to the Stream") { model.pasteText() }.keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Add Audio or Text Files to the Stream…") { model.importFiles() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Show the Whole Stream") { model.showWholeStream() }.keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Stop Transcribing") { model.library.cancelTranscription() }.disabled(model.library.transcribing == nil)
                Divider()
                Button("Copy All") { model.copyAll() }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Copy Transcript") { model.copySelected() }.keyboardShortcut("c", modifiers: [.command, .option])
                Button("Re-transcribe") { model.retranscribeSelected() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Find") { model.focusSearch() }.keyboardShortcut("f", modifiers: .command)
                Button("Play / Pause") { model.togglePlayback() }
                Divider()
                Button(model.capture.paused ? "Resume Hotkey" : "Pause Hotkey") { model.capture.paused.toggle() }
                Button("Stop Recording") { model.capture.stopFromMenu() }.keyboardShortcut(".", modifiers: .command)
                Divider()
                Menu("Export as Markdown") {
                    Button("One file…") { model.library.exportMarkdown(model.library.ordered, combined: true) }
                    Button("One file per recording…") { model.library.exportMarkdown(model.library.ordered, combined: false) }
                }
                Button("Show Holdnote folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.library.store.root]) }
                Button("Reset Everything…") { confirmResetEverything(model) }.disabled(model.capture.isRecording)
            }
            CommandMenu("Reader") {
                Button("Open the Reader") { model.showReader() }.keyboardShortcut("n", modifiers: [.command, .shift])
                ForEach(ReaderView.allCases) { v in
                    Button(v.title) { model.showReader(v) }
                }
                Divider()
                if model.reader.running {
                    Button("Stop Reading After This Call") { model.reader.stopAfterCall() }.disabled(model.reader.stopping)
                    Button("Stop Reading Now") { model.reader.stopNow() }
                } else {
                    Button("Read Now") { model.reader.startReading() }.disabled(model.reader.blocker != nil || !model.reader.hasWork)
                        .keyboardShortcut("r", modifiers: [.command, .option])
                }
                Toggle("Read by Itself", isOn: Binding(get: { model.reader.config.autoRead }, set: { model.reader.config.autoRead = $0; if $0 { model.reader.resumeAuto() } }))
                Button("Give the Reader What's New Now") { _ = model.reader.feedTranscripts() }
                Divider()
                Button("Show Reader Folder in Finder") { model.reader.showFolderInFinder() }
                Button("Reset the Reader…") { confirmResetReader(model) }
                Button("About the Reader") { model.showReaderAbout() }
            }
            CommandGroup(after: .toolbar) {
                Button("Stream") { model.show(.recordings) }.keyboardShortcut("1", modifiers: .command)
                Button("Ask") { model.showReader(.ask) }.keyboardShortcut("2", modifiers: .command)
                Button("For You") { model.showReader(.forYou) }.keyboardShortcut("3", modifiers: .command)
                Divider()
                Button("Reading") { model.showReader(.reading) }.keyboardShortcut("4", modifiers: .command)
                Button("Notes") { model.showReader(.notes) }.keyboardShortcut("5", modifiers: .command)
                Button("Guide") { model.showReaderAbout() }
                Divider()
                Button("Setup") { model.showSetup() }
            }
        }
    }
}

/// Asks first: the reader's notes, stream, goals and conversation go to the Trash.
@MainActor
func confirmResetReader(_ model: AppModel) {
    confirm("Reset the reader?",
            detail: "Its notes, the stream, your goals, the questions and the conversation go to the Trash in one dated folder; to undo, put its contents back in place. Your recordings stay and are read again from the oldest. Lenses and settings are kept.",
            button: "Reset the Reader") { model.resetReader() }
}

/// Asks first: every recording and the reader's notes go to the Trash.
@MainActor
func confirmResetEverything(_ model: AppModel) {
    confirm("Reset everything and start with no data?",
            detail: "Every recording and its audio, and all the reader's notes, goals and questions, go to the Trash in one dated folder; to undo, quit Holdnote and put its contents back in place. The speech model, permissions and settings stay, so you don't download or set up anything again.",
            button: "Reset Everything") { model.resetEverything() }
}

/// Starts what belongs to the running app (not to previews): the menu bar icon, the hotkey, the updater.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.start() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppModel.shared.willQuit() }
        return .terminateNow
    }
}

/// App-wide state: the library, the capture controller, the windows.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings = SettingsStore()
    let library: Library
    let capture: CaptureController
    let player = AudioPlayer()
    let updater = Updater()
    /// CPU and memory, the Mac's and Holdnote's share, for the window's bottom bar and the menu.
    let monitor = SystemMonitor()
    /// The reader: the stream, reading it, asking about it, its questions for you, the notes.
    let reader = ReaderController()
    /// What the window shows: the first column lists these; choosing one opens the columns it
    /// needs (the recordings list, the note files, the settings pages) and its page on the right.
    enum Section: Hashable {
        case recordings
        case reader(ReaderView)
        case readerGuide
        case settings(SettingsTab)
        case setup
    }
    var section: Section = .recordings {
        didSet {
            if case let .reader(v) = section { readerView = v }
            if case let .settings(t) = section { settingsTab = t }
        }
    }
    /// The reader view last shown, where "Open the Reader" goes.
    var readerView: ReaderView = .ask
    /// The settings page last shown.
    var settingsTab: SettingsTab = .general
    /// Set by the updater, which quits to swap the app.
    @ObservationIgnored var quittingForUpdate = false
    /// The window's selection (ids), shared with the menus and ⌥+hotkey.
    var selection: Set<UUID> = []
    var searchText = ""
    /// The right pane shows the whole stream as one continuous text (also when nothing is selected).
    var showingAll = false {
        didSet { if showingAll { section = .recordings } }
    }
    /// A passage picked in the stream to ask about: the Ask view takes it into its field.
    var askDraft = ""
    var askDraftRequests = 0
    /// Bumped to put the cursor in the search field.
    var searchRequests = 0
    @ObservationIgnored private var statusBar: StatusBarController?
    @ObservationIgnored private var window: NSWindow?

    init() {
        let store: RecordingStore
        do {
            store = try RecordingStore(root: RecordingStore.defaultRoot)
        } catch {
            // Without its folder nothing works; say so and stop rather than lose recordings silently.
            NSAlert(error: error).runModal()
            exit(1)
        }
        library = Library(store: store)
        capture = CaptureController(library: library, settings: settings)
        library.settings = { [settings] in settings.settings }
        // The list read from the bottom up: what happened first goes into the stream first.
        reader.recordings = { [library] in Array(library.ordered.reversed()) }
        reader.recording = { [library] id in library.recording(id) }
        // Whisper and the model share the Mac: reading waits while you record or transcribe.
        reader.isBusy = { [capture, library] in capture.isRecording || library.transcribing != nil }
        reader.isWindowKey = { [weak self] in self?.window?.isKeyWindow ?? false }
        // A spoken answer to one of the reader's questions: the next recording, once transcribed.
        library.onFinal = { [weak self] r in
            guard let self, self.reader.voiceAnswer != nil else { return }
            if self.reader.transcriptFinished(r), !(self.window?.isKeyWindow ?? false) {
                Notifier.post(title: "Answer saved", body: "Your spoken answer joined the reader's stream.", open: ReaderView.forYou.rawValue)
            }
        }
    }

    /// Once the app has launched.
    func start() {
        // A second copy opening activates the first and quits.
        if let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != getpid() }
            if let other = others.first {
                other.activate()
                NSApp.terminate(nil)
                return
            }
        }
        statusBar = StatusBarController(model: self)
        library.load()
        Notifier.shared.start(onInstall: { [weak self] in self?.updater.confirmInstall() },
                              onOpen: { [weak self] v in self?.showReader(ReaderView(rawValue: v)) })
        updater.start()
        capture.onToggleWindow = { [weak self] in self?.toggleWindow() }
        capture.selectedForAppend = { [weak self] in
            guard let self, self.selection.count == 1, let id = self.selection.first, self.library.recording(id)?.status == .final else { return nil }
            return id
        }
        capture.start()
        reader.start()
        if !isSetUp { showSetup() }
        // Closing the window puts the app back in the menu bar only (no Dock icon).
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let closing = note.object as? NSWindow, closing === self.window else { return }
                _ = NSApp.setActivationPolicy(.accessory)
                // The usage bar's sampling is for eyes on it.
                self.monitor.stop()
            }
        }
    }

    /// Voice detection, on or off (the toolbar, the menus, the menu bar).
    var listening: Bool {
        get { capture.isListening }
        set { capture.setListening(newValue) }
    }

    func willQuit() {
        capture.setListening(false)
        library.saveNow()
        library.commitDeletes()
        capture.interrupt(reason: nil)
        // Reading saves after every call; cutting the call short loses only that chunk.
        reader.stopNow()
    }

    /// Everything the hotkey needs is in place.
    var isSetUp: Bool {
        Recorder.isAllowed && HotkeyMonitor.isAllowed && (settings.settings.hotkey != .fn || Permissions.fnUsage().isFine)
            && library.transcriber.hasModel(settings.settings.model)
    }

    // MARK: - Windows

    /// Opens the window (or brings it back) in front of other apps. A menu bar-only app can't come
    /// to the front, so while a window is open the app is a regular one, with a Dock icon.
    func showWindow() {
        let window = self.window ?? makeWindow()
        monitor.start()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    var isWindowVisible: Bool { window?.isVisible ?? false }

    /// ⌘⇧H and a click on the menu bar icon: the window closes when it is open in front, else it
    /// opens (or comes to the front).
    ///
    /// "In front" is what the person sees, not whether macOS made Holdnote the active app (since
    /// macOS 14 an activation request can be declined): a window any part of which is on screen
    /// closes; one fully covered by other windows comes forward instead.
    func toggleWindow() {
        if let window, window.isVisible, !window.isMiniaturized, NSApp.isActive || window.occlusionState.contains(.visible) {
            window.close()
        } else {
            if let window, window.isMiniaturized { window.deminiaturize(nil) }
            showWindow()
        }
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: MainWindow(model: self).frame(minWidth: 960, minHeight: 560))
        hosting.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.title = "Holdnote"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1240, height: 760))
        window.center()
        window.setFrameAutosaveName("Holdnote.main")
        // A frame saved by an older, smaller window is grown to what the sidebar and the reader need.
        let least = NSSize(width: 960, height: 560)
        window.contentMinSize = least
        let now = window.contentRect(forFrameRect: window.frame).size
        if now.width < least.width || now.height < least.height {
            window.setContentSize(NSSize(width: max(now.width, least.width), height: max(now.height, least.height)))
        }
        self.window = window
        return window
    }

    /// The window, on `section`.
    func show(_ section: Section) {
        self.section = section
        showWindow()
    }

    /// Settings, in the window, on the page asked for (or the one last shown).
    func showSettings(tab: SettingsTab? = nil) {
        show(.settings(tab ?? settingsTab))
    }

    /// The window, on the reader view asked for (or the one it was last on).
    func showReader(_ view: ReaderView? = nil) {
        show(.reader(view ?? readerView))
    }

    /// The whole stream as one text, in the Stream section.
    func showWholeStream() {
        selection = []
        showingAll = true
        showWindow()
    }

    /// Ask, with a passage of the stream quoted in the field, to finish the question after it.
    func askAbout(_ passage: String) {
        var excerpt = passage.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        if excerpt.count > 600 { excerpt = String(excerpt.prefix(600)).trimmingCharacters(in: .whitespaces) + "…" }
        askDraft = "About this passage: “\(excerpt)”\n\n"
        askDraftRequests += 1
        showReader(.ask)
    }

    /// Ask, about one item in the stream, by its first words.
    func askAbout(_ r: Recording) {
        askDraft = "About my \(r.audioFile != nil ? "recording" : "note") of \(r.createdAt.formatted(date: .abbreviated, time: .shortened)) (“\(r.title)”): "
        askDraftRequests += 1
        showReader(.ask)
    }

    /// A recording in the list, selected and shown (from a sentence id, a question, the stream).
    func openRecording(_ id: UUID) {
        guard library.recording(id) != nil else { NSSound.beep(); return }
        showingAll = false
        if !listed.contains(where: { $0.id == id }) { searchText = "" }
        show(.recordings)
        selection = [id]
    }

    // MARK: - Starting over

    /// The reader from nothing: its notes, stream, goals and conversation go to the Trash.
    /// Recordings stay, and join the stream again (oldest first) as if new.
    func resetReader() {
        reader.whenIdle { [weak self] in
            guard let self else { return }
            switch self.reader.reset() {
            case let .success(url): self.tell("The reader starts over", StartOver.whereItWent(url))
            case let .failure(error): self.tell("Could not reset the reader", error.localizedDescription)
            }
        }
    }

    /// Holdnote from nothing, to try it as a new user would: every recording and its audio, and
    /// the reader's notes, go to the Trash. The speech model, permissions and settings stay.
    func resetEverything() {
        guard !capture.isRecording else { tell("Stop the recording first", "A recording is in progress."); return }
        capture.setListening(false)
        player.stop()
        reader.disarmVoiceAnswer()
        reader.whenIdle { [weak self] in
            guard let self else { return }
            var lines: [String] = []
            do { lines.append("Recordings: " + StartOver.whereItWent(try self.library.reset())) }
            catch { lines.append("Recordings could not be moved: \(error.localizedDescription)") }
            switch self.reader.reset() {
            case let .success(url): lines.append("Reader notes: " + StartOver.whereItWent(url))
            case let .failure(error): lines.append("Reader notes could not be moved: \(error.localizedDescription)")
            }
            self.selection = []
            self.searchText = ""
            self.showingAll = false
            self.show(.recordings)
            self.tell("Holdnote starts over", lines.joined(separator: "\n\n"))
        }
    }

    private func tell(_ title: String, _ detail: String) {
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            NSApp.activate()
            alert.runModal()
        }
    }

    /// What the reader does and why.
    func showReaderAbout() {
        show(.readerGuide)
    }

    func showSetup() {
        show(.setup)
    }

    /// Setup is done (or put off): back to the recordings.
    func closeSetup() {
        section = .recordings
    }

    // MARK: - Actions from the menus

    /// The recordings the window lists now, in the list's order (search applied).
    var listed: [Recording] { DayGroup.filter(library.ordered, query: searchText) }

    var selectedRecordings: [Recording] { library.ordered.filter { selection.contains($0.id) } }

    func copyAll() {
        library.copyAll(listed)
    }

    func copySelected() {
        let selected = selectedRecordings
        guard !selected.isEmpty else { return }
        if selected.count == 1 { library.copy(selected[0].text) } else { library.copyAll(selected) }
    }

    func retranscribeSelected() {
        for id in selection { library.retranscribe(id) }
    }

    func deleteSelected() {
        guard !selection.isEmpty else { return }
        if let playing = player.playing, selection.contains(playing) { player.stop() }
        library.delete(selection)
        selection = []
    }

    /// The clipboard's text as a new note, selected.
    func pasteText() {
        guard let text = NSPasteboard.general.string(forType: .string), let r = library.addText(text) else {
            NSSound.beep()
            return
        }
        showingAll = false
        show(.recordings)
        selection = [r.id]
    }

    /// Files from elsewhere join the list: audio (m4a, mp3, wav…) is transcribed, text (.txt, .md)
    /// becomes a note. The ones given (dropped), or the ones chosen in a panel. With `before`
    /// (dropped between two rows of your own order), they go just above that row; nil there with
    /// `atEnd` puts them at the bottom. The last one is selected.
    func importFiles(_ urls: [URL]? = nil, before target: UUID? = nil, atEnd: Bool = false) {
        let chosen: [URL]
        if let urls {
            chosen = urls
        } else {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.audio, .plainText]
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.prompt = "Import"
            panel.message = "Audio is transcribed on this Mac; text files become notes. Each joins the list."
            NSApp.activate()
            guard panel.runModal() == .OK else { return }
            chosen = panel.urls
        }
        var problems: [String] = []
        var added: [Recording] = []
        for url in chosen {
            do {
                switch Self.kind(of: url) {
                case .audio: added.append(try library.importAudio(url))
                case .text: added.append(try library.importText(url))
                case nil: problems.append("\(url.lastPathComponent) is neither audio nor plain text.")
                }
            } catch { problems.append(error.localizedDescription) }
        }
        if !added.isEmpty {
            if settings.settings.listOrder == .custom, target != nil || atEnd {
                library.move(added.map(\.id), before: target)
            }
            showingAll = false
            show(.recordings)
            selection = [added[added.count - 1].id]
        }
        if !problems.isEmpty {
            let alert = NSAlert()
            alert.messageText = problems.count == 1 ? "Could not add the file" : "Could not add \(problems.count) files"
            alert.informativeText = problems.joined(separator: "\n")
            alert.runModal()
        }
    }

    enum FileKind { case audio, text }

    static func kind(of url: URL) -> FileKind? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .audio) { return .audio }
        if let type, type.conforms(to: .plainText) { return .text }
        if ["txt", "text", "md", "markdown"].contains(url.pathExtension.lowercased()) { return .text }
        return nil
    }

    /// Something dragged in: files are imported (audio and text), loose text becomes a note.
    /// Says whether it was taken. `before`/`atEnd` place it in your own order (see `importFiles`).
    func takeDrop(_ providers: [NSItemProvider], before target: UUID? = nil, atEnd: Bool = false) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        let texts = providers.filter { !$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) && $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }
        guard !files.isEmpty || !texts.isEmpty else { return false }
        let collected = Collected()
        let group = DispatchGroup()
        for p in files {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { collected.add(url: url) }
                else if let url = item as? URL { collected.add(url: url) }
                group.leave()
            }
        }
        for p in texts {
            group.enter()
            _ = p.loadObject(ofClass: String.self) { text, _ in
                if let text { collected.add(text: text) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let (urls, texts) = collected.taken
                // Files the order of the drag; loose text as notes after them.
                if !urls.isEmpty { self.importFiles(urls.sorted { $0.lastPathComponent < $1.lastPathComponent }, before: target, atEnd: atEnd) }
                for t in texts {
                    guard let r = self.library.addText(t) else { continue }
                    if self.settings.settings.listOrder == .custom, target != nil || atEnd { self.library.move([r.id], before: target) }
                    self.show(.recordings)
                    self.selection = [r.id]
                }
            }
        }
        return true
    }

    /// What a drop's providers handed over, from their own threads.
    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        private var texts: [String] = []
        func add(url: URL) { lock.lock(); urls.append(url); lock.unlock() }
        func add(text: String) { lock.lock(); texts.append(text); lock.unlock() }
        var taken: ([URL], [String]) { lock.lock(); defer { lock.unlock() }; return (urls, texts) }
    }

    /// Every listed transcript as one text, exactly what Copy All copies.
    var allText: String { TranscriptText.copyAll(listed, headers: settings.settings.copyAllHeaders, keepOrder: true) }

    func focusSearch() {
        show(.recordings)
        searchRequests += 1
    }

    func togglePlayback() {
        guard selection.count == 1, let id = selection.first, let r = library.recording(id), let url = library.store.audioURL(for: r) else { return }
        player.toggle(url, id: id)
    }

    func setInputDevice(_ uid: String?) {
        settings.settings.inputDeviceID = uid
    }
}
