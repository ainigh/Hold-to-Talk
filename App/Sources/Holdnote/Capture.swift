import AVFoundation
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
    private let listener = Listener()
    /// Voice-detection mode is on: the mic is open and speech becomes recordings by itself.
    private(set) var isListening = false
    /// Speech is being heard in voice-detection mode.
    private(set) var isSpeaking = false
    /// The listening session (one id for all its segments) and when it began.
    private var session: (id: UUID, since: Date)?
    @ObservationIgnored private var listenTicker: Timer?
    @ObservationIgnored private var reminderTimer: Timer?
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
    /// Pause hotkey (the menu). Observable here; the monitor is told.
    var paused = false {
        didSet { monitor.paused = paused }
    }
    /// The event tap is running (Input Monitoring is allowed). Observable mirror of the monitor's state.
    private(set) var hotkeyRunning = false
    var onToggleWindow: (() -> Void)?

    init(library: Library, settings: SettingsStore) {
        self.library = library
        self.settings = settings
        monitor.hotkey = settings.settings.hotkey
        monitor.onEvent = { [weak self] event in self?.handle(event) }
        listener.onSegment = { [weak self] segment in self?.segmentHeard(segment) }
        listener.onError = { [weak self] message in
            self?.setListening(false)
            self?.hud.showFailure(message)
        }
        // Asleep, the mic is gone: what was recorded is kept and transcribed on wake.
        sleepObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupt(reason: nil) }
        })
    }

    /// Starts watching the hotkey. False until Input Monitoring is allowed.
    @discardableResult
    func start() -> Bool {
        monitor.hotkey = settings.settings.hotkey
        hotkeyRunning = monitor.start()
        return hotkeyRunning
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
        if isListening { listener.stop() }
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
        var relistenFailure: Error?
        if isListening {
            do { try listener.start(deviceUID: settings.settings.inputDeviceID) } catch { relistenFailure = error }
        }
        defer {
            if let relistenFailure {
                setListening(false)
                hud.showFailure("Voice Detection stopped: \(relistenFailure.localizedDescription)")
            }
        }
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

    // MARK: - Voice detection

    /// Turns listening on or off. Never on at launch: it is a choice each time.
    func setListening(_ on: Bool) {
        guard on != isListening else { return }
        if on {
            guard Recorder.isAllowed else {
                hud.showFailure("Microphone access is off: see Setup")
                return
            }
            do {
                try listener.start(deviceUID: settings.settings.inputDeviceID)
            } catch {
                hud.showFailure(error.localizedDescription)
                return
            }
            isListening = true
            session = (UUID(), Date())
            if settings.settings.sounds { Sounds.start() }
            listenTicker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let speaking = self.listener.isSpeaking
                    if speaking != self.isSpeaking { self.isSpeaking = speaking }
                }
            }
            // A mic left open and forgotten is the one thing that must not happen: a reminder every two hours.
            reminderTimer = Timer.scheduledTimer(withTimeInterval: 2 * 3600, repeats: true) { _ in
                Notifier.post(title: "Holdnote is still listening", body: "Voice detection has been on for a while. Turn it off from the menu bar when you're done.")
            }
        } else {
            listenTicker?.invalidate()
            listenTicker = nil
            reminderTimer?.invalidate()
            reminderTimer = nil
            listener.stop()
            isListening = false
            isSpeaking = false
            session = nil
            if settings.settings.sounds { Sounds.stop() }
        }
    }

    /// A segment of speech ended: written as a WAV, into the list, transcribed.
    private func segmentHeard(_ segment: Listener.Segment) {
        let id = segment.id
        let fileName = RecordingStore.audioFileName(for: id)
        let url = library.store.audioFolder.appendingPathComponent(fileName)
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: segment.format.sampleRate,
                AVNumberOfChannelsKey: segment.format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: segment.format.commonFormat, interleaved: segment.format.isInterleaved)
            for buffer in segment.buffers { try file.write(from: buffer) }
        } catch {
            hud.showFailure("Couldn't save a segment: \(error.localizedDescription)")
            return
        }
        var r = Recording(id: id, createdAt: segment.startedAt, audioFile: fileName, status: .transcribing, sessionID: session?.id)
        r.sourceDevice = "Voice detection"
        library.begin(r)
        library.finish(id, duration: segment.duration, device: "Voice detection", samples: segment.samples, appendTo: nil)
    }
}

enum Sounds {
    static func start() { NSSound(named: "Tink")?.play() }
    static func stop() { NSSound(named: "Pop")?.play() }
}
