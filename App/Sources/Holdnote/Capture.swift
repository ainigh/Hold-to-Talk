import AppKit
import Foundation
import Harness
import Observation

/// Hold the hotkey: record. Joins the hotkey monitor, the hold gesture, the recorder, the HUD
/// and the library.
@MainActor
@Observable
final class CaptureController {
    let monitor = HotkeyMonitor()
    let hud = HUDController()
    private let library: Library
    private let settings: SettingsStore
    private var gesture = HoldGesture()
    private var recorder: Recorder?
    private var current: (id: UUID, appendTo: UUID?)?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []
    /// The window's selection when exactly one recording is selected: ⌥+hotkey appends to it.
    @ObservationIgnored var selectedForAppend: () -> UUID? = { nil }
    private(set) var isRecording = false
    /// Pause hotkey (the menu).
    var paused: Bool {
        get { monitor.paused }
        set { monitor.paused = newValue }
    }
    var onToggleWindow: (() -> Void)?

    init(library: Library, settings: SettingsStore) {
        self.library = library
        self.settings = settings
        monitor.hotkey = settings.settings.hotkey
        monitor.onEvent = { [weak self] event in self?.handle(event) }
        // Asleep, the mic is gone: what was recorded is kept and transcribed on wake.
        sleepObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupt(reason: nil) }
        })
    }

    /// Starts watching the hotkey. False until Input Monitoring is allowed.
    @discardableResult
    func start() -> Bool {
        monitor.hotkey = settings.settings.hotkey
        return monitor.start()
    }

    func hotkeyChanged() {
        monitor.hotkey = settings.settings.hotkey
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func handle(_ event: HotkeyMonitor.Event) {
        switch event {
        case let .pressed(modifiers):
            pendingAppend = modifiers.contains(.maskAlternate) ? selectedForAppend() : nil
            act(gesture.pressed(at: now))
            startTicking()
        case .released:
            act(gesture.released(at: now))
            if !gesture.isRecording { stopTicking() }
        case .toggleWindow:
            onToggleWindow?()
        }
    }

    /// Set at the press (⌥ held): the recording that starts appends to this one.
    @ObservationIgnored private var pendingAppend: UUID?

    private func startTicking() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.act(self.gesture.tick(at: self.now))
                if self.isRecording { self.hud.update(level: self.recorder?.level ?? 0, seconds: self.recorder?.seconds ?? 0, silentFor: self.recorder?.secondsOfSilence ?? 0) }
                if case .idle = self.gesture.state, !self.isRecording { self.stopTicking() }
            }
        }
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func act(_ actions: [HoldGesture.Action]) {
        for action in actions {
            switch action {
            case let .start(locked): startRecording(locked: locked)
            case let .stop(keep): stopRecording(keep: keep)
            }
        }
    }

    private func startRecording(locked: Bool) {
        guard !isRecording else { return }
        guard Recorder.isAllowed else {
            hud.showFailure("Microphone access is off: see Setup")
            gesture.reset()
            return
        }
        if let free = Permissions.freeSpace(at: library.store.root), free < Permissions.minimumFreeSpace {
            hud.showFailure("Disk nearly full: free some space to record")
            gesture.reset()
            return
        }
        let id = UUID()
        let fileName = RecordingStore.audioFileName(for: id)
        let recorder = Recorder(url: library.store.audioFolder.appendingPathComponent(fileName))
        do {
            try recorder.start(deviceUID: settings.settings.inputDeviceID)
        } catch {
            hud.showFailure(error.localizedDescription)
            gesture.reset()
            return
        }
        self.recorder = recorder
        recorder.onInterruption = { [weak self] in self?.interrupt(reason: "The microphone changed; recording stopped") }
        current = (id, pendingAppend)
        isRecording = true
        library.begin(Recording(id: id, audioFile: fileName, status: .recording))
        if settings.settings.sounds { Sounds.start() }
        hud.show(locked: locked, appending: pendingAppend != nil)
        startTicking()
    }

    private func stopRecording(keep: Bool) {
        guard isRecording, let recorder, let current else { return }
        recorder.stop()
        isRecording = false
        self.recorder = nil
        self.current = nil
        if keep {
            if settings.settings.sounds { Sounds.stop() }
            library.finish(current.id, duration: recorder.seconds, device: recorder.deviceName, samples: recorder.allSamples(), appendTo: current.appendTo)
            hud.finish()
        } else {
            library.discard(current.id)
            hud.hide()
        }
    }

    /// Recording stopped from outside the gesture (sleep, the device went away): kept.
    func interrupt(reason: String?) {
        guard isRecording else { return }
        gesture.reset()
        monitor.forgetPress()
        stopRecording(keep: true)
        if let reason { hud.showFailure(reason) }
    }

    /// Stop a locked recording from the menu.
    func stopFromMenu() {
        interrupt(reason: nil)
    }
}

enum Sounds {
    static func start() { NSSound(named: "Tink")?.play() }
    static func stop() { NSSound(named: "Pop")?.play() }
}
