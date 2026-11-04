import AppKit
import Harness
import SwiftUI
import UniformTypeIdentifiers

@main
struct HoldnoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        // The icon and its menu are AppKit's (`StatusBarController`), and so are the windows
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
                Button("New Note from Clipboard") { model.pasteText() }.keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Import Audio Files…") { model.importAudio() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button(model.showingAll ? "Show One Recording" : "Show All Text") { model.showingAll.toggle(); model.showWindow() }.keyboardShortcut("a", modifiers: [.command, .shift])
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
                    Button("One file…") { model.library.exportMarkdown(model.library.recordings, combined: true) }
                    Button("One file per recording…") { model.library.exportMarkdown(model.library.recordings, combined: false) }
                }
                Button("Show Holdnote folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.library.store.root]) }
            }
            CommandMenu("Reader") {
                Button("Open the Reader") { model.showReader() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Stream") { model.showReader(.stream) }
                Button("Night") { model.showReader(.night) }
                Button("Notes") { model.showReader(.notes) }
                Divider()
                if model.reader.running {
                    Button("Stop the Night After This Call") { model.reader.stopAfterCall() }.disabled(model.reader.stopping)
                    Button("Stop the Night Now") { model.reader.stopNow() }
                } else {
                    Button(model.reader.startTitle) { model.showReader(.night); model.reader.startNight() }.disabled(model.reader.blocker != nil)
                }
                Button("Add Transcripts to the Stream") { _ = model.reader.feedTranscripts() }.disabled(model.reader.running)
                Divider()
                Button("Show Reader Folder in Finder") { model.reader.showFolderInFinder() }
                Button("About the Reader…") { model.showReaderAbout() }
            }
            CommandGroup(after: .toolbar) {
                Button("Setup…") { model.showSetup() }
            }
        }
    }
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
    /// The reader: the stream, the night (reading and asking), the notes.
    let reader = ReaderController()
    /// What the window's right pane shows: the selected recording, or one of the reader's views.
    enum Pane: Hashable { case recordings, reader(ReaderView) }
    var pane: Pane = .recordings {
        didSet { if case let .reader(v) = pane { readerView = v } }
    }
    /// The reader view last shown, where "Open the Reader" goes.
    var readerView: ReaderView = .stream
    /// Which settings tab is showing.
    var settingsTab: SettingsTab = .general
    /// Set by the updater, which quits to swap the app.
    @ObservationIgnored var quittingForUpdate = false
    /// The window's selection (ids), shared with the menus and ⌥+hotkey.
    var selection: Set<UUID> = []
    var searchText = ""
    /// The right pane shows every listed transcript as one continuous text.
    var showingAll = false {
        didSet { if showingAll { pane = .recordings } }
    }
    /// Bumped to put the cursor in the search field.
    var searchRequests = 0
    @ObservationIgnored private var statusBar: StatusBarController?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var setupWindow: NSWindow?
    @ObservationIgnored private var aboutWindow: NSWindow?

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
        reader.recordings = { [library] in library.recordings }
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
        Notifier.shared.start { [weak self] in self?.updater.confirmInstall() }
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
                guard let self, let closing = note.object as? NSWindow else { return }
                let open = [self.window, self.settingsWindow, self.setupWindow, self.aboutWindow].compactMap { $0 }.filter { $0 !== closing && $0.isVisible }
                if open.isEmpty { _ = NSApp.setActivationPolicy(.accessory) }
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
        // The night saves after every window; cutting the call short loses only that window.
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
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    var isWindowVisible: Bool { window?.isVisible ?? false }

    /// ⌘⇧H and the menu bar icon: the window closes when it is open in front, else it opens.
    func toggleWindow() {
        if let window, window.isVisible, !window.isMiniaturized, NSApp.isActive {
            window.performClose(nil)
        } else {
            if let window, window.isMiniaturized { window.deminiaturize(nil) }
            showWindow()
        }
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: MainWindow(model: self).frame(minWidth: 860, minHeight: 520))
        hosting.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.title = "Holdnote"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1080, height: 700))
        window.center()
        window.setFrameAutosaveName("Holdnote.main")
        // A frame saved by an older, smaller window is grown to what the sidebar and the reader need.
        let least = NSSize(width: 860, height: 520)
        window.contentMinSize = least
        let now = window.contentRect(forFrameRect: window.frame).size
        if now.width < least.width || now.height < least.height {
            window.setContentSize(NSSize(width: max(now.width, least.width), height: max(now.height, least.height)))
        }
        self.window = window
        return window
    }

    func showSettings(tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        let window = settingsWindow ?? {
            let hosting = NSHostingController(rootView: SettingsView(model: self))
            let w = NSWindow(contentViewController: hosting)
            w.identifier = NSUserInterfaceItemIdentifier("settings")
            w.title = "Holdnote Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 560, height: 560))
            w.center()
            settingsWindow = w
            return w
        }()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// The window, on the reader view asked for (or the one it was last on).
    func showReader(_ view: ReaderView? = nil) {
        if let view { readerView = view }
        pane = .reader(readerView)
        showWindow()
    }

    /// What the reader does and why, from the extension's spec.
    func showReaderAbout() {
        let window = aboutWindow ?? {
            let hosting = NSHostingController(rootView: ReaderAboutView())
            let w = NSWindow(contentViewController: hosting)
            w.identifier = NSUserInterfaceItemIdentifier("reader-about")
            w.title = "About the Reader"
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 680, height: 640))
            w.center()
            aboutWindow = w
            return w
        }()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func showSetup() {
        let window = setupWindow ?? {
            let hosting = NSHostingController(rootView: SetupView(model: self))
            let w = NSWindow(contentViewController: hosting)
            w.identifier = NSUserInterfaceItemIdentifier("setup")
            w.title = "Set up Holdnote"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 520, height: 460))
            w.center()
            setupWindow = w
            return w
        }()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func closeSetup() {
        setupWindow?.performClose(nil)
    }

    // MARK: - Actions from the menus

    /// The recordings the window lists now (search applied).
    var listed: [Recording] { DayGroup.filter(library.recordings, query: searchText) }

    var selectedRecordings: [Recording] { library.recordings.filter { selection.contains($0.id) } }

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
        pane = .recordings
        selection = [r.id]
        showWindow()
    }

    /// Audio files from elsewhere (m4a, mp3, wav…) join the list and are transcribed: the ones
    /// given (dropped on the window), or the ones chosen in a panel. The last one is selected.
    func importAudio(_ urls: [URL]? = nil) {
        let chosen: [URL]
        if let urls {
            chosen = urls
        } else {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.audio]
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.prompt = "Import"
            panel.message = "Each file joins the list as a recording and is transcribed on this Mac."
            NSApp.activate()
            guard panel.runModal() == .OK else { return }
            chosen = panel.urls
        }
        var problems: [String] = []
        var last: Recording?
        for url in chosen {
            do { last = try library.importAudio(url) } catch { problems.append(error.localizedDescription) }
        }
        if let last {
            showingAll = false
            pane = .recordings
            selection = [last.id]
            showWindow()
        }
        if !problems.isEmpty {
            let alert = NSAlert()
            alert.messageText = problems.count == 1 ? "Could not import the file" : "Could not import \(problems.count) files"
            alert.informativeText = problems.joined(separator: "\n")
            alert.runModal()
        }
    }

    /// File URLs dragged in: the audio files among them are imported. Says whether any were.
    func importDropped(_ providers: [NSItemProvider]) -> Bool {
        let audio = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !audio.isEmpty else { return false }
        for p in audio {
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil),
                      let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audio) else { return }
                Task { @MainActor in AppModel.shared.importAudio([url]) }
            }
        }
        return true
    }

    /// Every listed transcript as one text, exactly what Copy All copies.
    var allText: String { TranscriptText.copyAll(listed, headers: settings.settings.copyAllHeaders) }

    func focusSearch() {
        pane = .recordings
        showWindow()
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
