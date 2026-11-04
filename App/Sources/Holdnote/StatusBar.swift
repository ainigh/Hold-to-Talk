import AppKit
import Harness
import Observation

/// The menu bar icon, made with AppKit's `NSStatusItem` (SwiftUI's `MenuBarExtra` ignored clicks
/// on some Macs). A click opens the menu; ⌥-click opens the window straight away. The glyph
/// says what the app is doing: a waveform at rest, a red dot while recording, a tiny equalizer
/// while transcribing, a warning when the hotkey can't be seen, an arrow when an update waits.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let model: AppModel
    private var blink: Timer?
    private var blinkOn = false

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.button?.toolTip = "Holdnote: hold \(model.settings.settings.hotkey.glyph) to record. Click for the menu, ⌥-click to open the window. ⌘⇧N opens the reader."
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refreshIcon()
    }

    /// Redrawn whenever what it shows changes.
    private func refreshIcon() {
        let (recording, transcribing, update, warning, listening, speaking, reading) = withObservationTracking {
            (model.capture.isRecording, model.library.transcribing != nil, model.updater.available != nil,
             !model.capture.hotkeyRunning || model.capture.paused, model.capture.isListening, model.capture.isSpeaking, model.reader.running)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshIcon() } }
        }
        let symbol: String
        if recording || speaking { symbol = "record.circle.fill" }
        else if listening { symbol = "ear.fill" }
        else if transcribing { symbol = "waveform.badge.magnifyingglass" }
        else if reading { symbol = "moon.fill" }
        else if update { symbol = "arrow.down.circle" }
        else if warning { symbol = "waveform.slash" }
        else { symbol = "waveform" }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Holdnote")
        let live = recording || speaking
        image?.isTemplate = !live
        item.button?.image = image
        item.button?.contentTintColor = live ? .systemRed : nil
        // Breathes at 1 Hz while recording; pulses slowly while listening, so an open mic is never a surprise.
        let pulse = live || listening
        if pulse, blink == nil {
            blink = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.blinkOn.toggle()
                    let speaking = self.model.capture.isRecording || self.model.capture.isSpeaking
                    self.item.button?.alphaValue = self.blinkOn ? (speaking ? 0.45 : 0.6) : 1
                }
            }
        } else if !pulse, let blink {
            blink.invalidate()
            self.blink = nil
            item.button?.alphaValue = 1
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.modifierFlags.contains(.option) == true, event?.type == .leftMouseUp {
            model.toggleWindow()
        } else {
            // The menu shows only while it is attached; detached again when it closes, so the
            // button keeps its own click handling.
            item.menu = menu
            item.button?.performClick(nil)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        item.menu = nil
        // Sampling is for eyes on it: the window's bar starts it again when it is open.
        if !model.isWindowVisible { model.monitor.stop() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !model.capture.hotkeyRunning {
            add("Re-enable the hotkey…", to: menu) { $0.showSetup() }
            menu.addItem(.separator())
        } else if !model.isSetUp {
            add("Finish setup…", to: menu) { $0.showSetup() }
            menu.addItem(.separator())
        }
        let listen = add(model.capture.isListening ? "Voice Detection: On" : "Voice Detection", to: menu) { $0.listening.toggle() }
        listen.state = model.capture.isListening ? .on : .off
        if model.capture.isListening { note(model.capture.isSpeaking ? "   Hearing speech…" : "   Listening; recordings start when you speak", in: menu) }
        menu.addItem(.separator())
        add("Open Holdnote", key: "h", to: menu) { $0.showWindow() }.keyEquivalentModifierMask = [.command, .shift]
        if model.capture.isRecording {
            add("Stop Recording", to: menu) { $0.capture.stopFromMenu() }
        }
        add("New Note from Clipboard", to: menu) { $0.pasteText() }
        add("Import Audio Files…", to: menu) { $0.importAudio() }
        menu.addItem(.separator())
        // The reader: open it, start or stop the night, and how far it is.
        add("Open the Reader", key: "n", to: menu) { $0.showReader() }.keyEquivalentModifierMask = [.command, .shift]
        let reader = model.reader
        if reader.running {
            note("Reading · \(reader.percent)%\(reader.status.isEmpty ? "" : " · " + reader.status)", in: menu)
            let stop = add(reader.stopping ? "Stopping…" : "Stop the Night After This Call", to: menu) { $0.reader.stopAfterCall() }
            stop.isEnabled = !reader.stopping
        } else {
            let start = add(reader.startTitle, to: menu) { $0.showReader(.night); $0.reader.startNight() }
            start.isEnabled = reader.blocker == nil
            if let g = reader.gaps, !g.open.isEmpty {
                add("\(g.open.count) question\(g.open.count == 1 ? "" : "s") for you…", to: menu) { $0.showReader(.stream) }
            } else if reader.hasNotes {
                add("Ask About the Stream…", to: menu) { $0.showReader(.morning) }
            }
        }
        menu.addItem(.separator())
        let mics = submenu("Microphone", in: menu)
        let chosen = model.settings.settings.inputDeviceID
        let system = add("System default", to: mics) { $0.setInputDevice(nil) }
        system.state = chosen == nil ? .on : .off
        for device in AudioDevices.inputs() {
            let i = add(device.name, to: mics) { $0.setInputDevice(device.uid) }
            i.state = chosen == device.uid ? .on : .off
        }
        let pause = add(model.capture.paused ? "Resume Hotkey" : "Pause Hotkey", to: menu) { $0.capture.paused.toggle() }
        pause.state = model.capture.paused ? .on : .off
        menu.addItem(.separator())
        // A fresh reading for the menu: the monitor runs while the window is open; else one is taken now
        // (its CPU figures need two readings, so the first menu after a while shows the last known).
        model.monitor.start()
        if let s = model.monitor.sample {
            note(UsageText.cpu(s), in: menu)
            note(UsageText.memory(s), in: menu)
            if s.thermal != .nominal { note(s.thermal.title, in: menu) }
            menu.addItem(.separator())
        }
        switch model.updater.state {
        case let .available(plan):
            add(plan.title + "…", to: menu) { $0.updater.confirmInstall() }
        case let .installing(step):
            note(step, in: menu)
        case .checking:
            note("Checking for updates…", in: menu)
        case let .failed(message):
            note(message, in: menu)
            add("Check for updates", to: menu) { $0.updater.check(userInitiated: true) }
        default:
            if Updater.canUpdate { add("Check for updates", to: menu) { $0.updater.check(userInitiated: true) } }
        }
        note(model.updater.versionLine, in: menu)
        add("Settings…", key: ",", to: menu) { $0.showSettings() }
        add("Quit Holdnote", key: "q", to: menu) { _ in NSApp.terminate(nil) }
    }

    // MARK: - Items

    /// A menu item that runs a closure.
    private final class ActionItem: NSMenuItem {
        var handler: (() -> Void)?
        @objc func run() { handler?() }
    }

    @discardableResult
    private func add(_ title: String, key: String = "", to menu: NSMenu, _ action: @escaping (AppModel) -> Void) -> NSMenuItem {
        let item = ActionItem(title: title, action: #selector(ActionItem.run), keyEquivalent: key)
        item.target = item
        item.handler = { [model] in action(model) }
        menu.addItem(item)
        return item
    }

    private func note(_ title: String, in menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func submenu(_ title: String, in menu: NSMenu) -> NSMenu {
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        menu.addItem(item)
        return sub
    }
}
