import AppKit
import Harness
import Observation

/// The menu bar icon, made with AppKit's `NSStatusItem` (SwiftUI's `MenuBarExtra` ignored clicks
/// on some Macs). A click shows or hides the window, which holds everything the old menu did; a
/// right-click (or ⌃-click) offers only Show/Hide and Quit, so the app can always be quit from
/// here. The glyph says what the app is doing: a waveform at rest, a red dot while recording, a
/// tiny equalizer while transcribing, a warning when the hotkey can't be seen, an arrow when an
/// update waits.
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
        item.button?.toolTip = "Holdnote: hold \(model.settings.settings.hotkey.glyph) to record. Click to show or hide the window; right-click to quit."
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
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if secondary {
            // The menu shows only while it is attached; detached again when it closes, so the
            // button keeps its own click handling.
            item.menu = menu
            item.button?.performClick(nil)
        } else {
            model.toggleWindow()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        item.menu = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(model.isWindowVisible ? "Hide Holdnote" : "Show Holdnote", key: "h", to: menu) { $0.toggleWindow() }.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
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
}
