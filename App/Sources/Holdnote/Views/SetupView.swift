import AVFoundation
import AppKit
import Harness
import SwiftUI

/// First launch: four things the hotkey needs, each with a button that does it, re-checked
/// every second while it shows (in the window's last column). Says plainly what is missing instead of failing later.
struct SetupView: View {
    let model: AppModel
    @State private var micAllowed = Recorder.isAllowed
    @State private var inputAllowed = HotkeyMonitor.isAllowed
    @State private var fnUsage = Permissions.fnUsage()
    @State private var hasModel = false
    @State private var downloading: Double?
    @State private var downloadProblem: String?
    @State private var askedForInput = false

    private var hotkey: Settings.Hotkey { model.settings.settings.hotkey }
    private var fnFine: Bool { hotkey != .fn || fnUsage.isFine }
    private var allGreen: Bool { micAllowed && inputAllowed && fnFine && hasModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Holdnote").font(.title2.weight(.semibold))
                Text("Hold \(hotkey.title.lowercased()) anywhere to record; release to get the transcript. Four things first:")
                    .foregroundStyle(.secondary)
            }
            step(1, "Microphone", ok: micAllowed, detail: micAllowed ? "Allowed." : "To record what you say.") {
                if !micAllowed {
                    Button("Allow microphone") {
                        Task {
                            _ = await Recorder.permission()
                            refresh()
                            if !Recorder.isAllowed, AVCaptureDeviceStatus.denied { Permissions.openMicrophoneSettings() }
                        }
                    }
                }
            }
            step(2, "Input Monitoring", ok: inputAllowed,
                 detail: inputAllowed ? "Allowed: the app can see the hotkey in any app." : "To see the hotkey while you're in other apps. Nothing typed is recorded or kept.") {
                if !inputAllowed {
                    Button(askedForInput ? "Open Input Monitoring settings" : "Allow Input Monitoring") {
                        if askedForInput || !HotkeyMonitor.request() { Permissions.openInputMonitoringSettings() }
                        askedForInput = true
                    }
                }
            }
            if hotkey == .fn {
                step(3, "The Fn key does nothing else", ok: fnFine,
                     detail: fnFine ? "Set to Do Nothing." : "It's set to \"\(fnUsage.title)\", so macOS would also act on it. In System Settings → Keyboard, set \"Press 🌐 key to\" to Do Nothing. Or pick another key in Settings.") {
                    if !fnFine {
                        Button("Open Keyboard settings") { Permissions.openKeyboardSettings() }
                        Button("Use another key…") { model.showSettings(tab: .general) }
                    }
                }
            } else {
                step(3, "Hotkey", ok: true, detail: "\(hotkey.title). Change it in Settings → General.") { EmptyView() }
            }
            step(4, "Speech model", ok: hasModel,
                 detail: hasModel ? "\(model.settings.settings.model) is downloaded; everything runs on this Mac."
                                  : "Downloads \(model.settings.settings.model) from huggingface.co, once (\(Settings.models.first { $0.name == model.settings.settings.model }?.title ?? "")). The only time the app goes online besides its own updates.") {
                if let downloading {
                    ProgressView(value: downloading).frame(width: 200)
                } else if !hasModel {
                    Button("Download model") { download() }
                    Button("Choose another…") { model.showSettings(tab: .transcription) }
                }
                if let downloadProblem { Text(downloadProblem).font(.caption).foregroundStyle(.orange) }
            }
            Spacer(minLength: 0)
            HStack {
                if allGreen {
                    Label("Ready. Hold \(hotkey.glyph) to record.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("The hotkey won't work until these are green.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(allGreen ? "Done" : "Later") { model.closeSetup() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: 560, maxHeight: 520, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { refresh(); hasModel = model.library.transcriber.hasModel(model.settings.settings.model) }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                refresh()
            }
        }
    }

    private func refresh() {
        micAllowed = Recorder.isAllowed
        inputAllowed = HotkeyMonitor.isAllowed
        fnUsage = Permissions.fnUsage()
        hasModel = model.library.transcriber.hasModel(model.settings.settings.model)
        if inputAllowed, !model.capture.hotkeyRunning { model.capture.start() }
    }

    private func download() {
        let name = model.settings.settings.model
        let transcriber = model.library.transcriber
        downloading = 0
        downloadProblem = nil
        Task {
            do {
                try await transcriber.download(name) { p in Task { @MainActor in downloading = p ?? 0 } }
                downloading = nil
                hasModel = transcriber.hasModel(model.settings.settings.model)
            } catch {
                downloading = nil
                downloadProblem = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func step<Content: View>(_ n: Int, _ title: String, ok: Bool, detail: String, @ViewBuilder actions: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "\(n).circle")
                .font(.system(size: 20))
                .foregroundStyle(ok ? Color.green : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { actions() }.controlSize(.small).padding(.top, 2)
            }
        }
    }
}

/// Whether the microphone was refused before (then only System Settings can allow it).
enum AVCaptureDeviceStatus {
    static var denied: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .denied
    }
}
