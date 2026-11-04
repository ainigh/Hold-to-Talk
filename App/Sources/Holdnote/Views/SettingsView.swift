import AppKit
import Harness
import SwiftUI

/// One window, four tabs: General, Audio, Transcription, Storage.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        @Bindable var store = model.settings
        TabView {
            GeneralSettings(model: model, settings: $store.settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            AudioSettings(settings: $store.settings)
                .tabItem { Label("Audio", systemImage: "mic") }
            TranscriptionSettings(model: model, settings: $store.settings)
                .tabItem { Label("Transcription", systemImage: "text.quote") }
            StorageSettings(model: model, settings: $store.settings)
                .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(width: 520)
        .padding(.bottom, 12)
    }
}

struct GeneralSettings: View {
    let model: AppModel
    @Binding var settings: Settings
    @State private var launchAtLogin = Permissions.launchesAtLogin
    @State private var loginProblem: String?

    var body: some View {
        Form {
            Picker("Record while holding", selection: $settings.hotkey) {
                ForEach(Settings.Hotkey.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .onChange(of: settings.hotkey) { _, _ in model.capture.hotkeyChanged() }
            Text(hotkeyNote).font(.caption).foregroundStyle(.secondary)
            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do { try Permissions.setLaunchAtLogin(on); loginProblem = nil } catch { loginProblem = error.localizedDescription; launchAtLogin = !on }
                }
                .disabled(!Updater.canUpdate)
            if let loginProblem { Text(loginProblem).font(.caption).foregroundStyle(.orange) }
            Toggle("Sounds when recording starts and stops", isOn: $settings.sounds)
            Section {
                LabeledContent("Shortcuts") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Hold the key · record")
                        Text("Tap it twice · record hands-free, tap once to stop")
                        Text("⌥ + hold · add to the selected recording")
                        Text("⌘⇧H · show or hide the window")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var hotkeyNote: String {
        switch settings.hotkey {
        case .fn: "Fn must be set to \"Do Nothing\" in System Settings → Keyboard, or macOS also opens the emoji picker or Dictation."
        case .rightOption: "For keyboards whose Fn key sends no event. The right Option key still works with other keys for a short press."
        case .controlOptionSpace: "Works on any keyboard."
        }
    }
}

struct AudioSettings: View {
    @Binding var settings: Settings
    @State private var devices = AudioDevices.inputs()

    var body: some View {
        Form {
            Picker("Microphone", selection: $settings.inputDeviceID) {
                Text("System default").tag(String?.none)
                ForEach(devices) { Text($0.name).tag(String?.some($0.uid)) }
            }
            Button("Refresh list") { devices = AudioDevices.inputs() }
            Text("A decent external mic or AirPods beat every model upgrade. The audio is recorded in the microphone's own format as WAV; the transcriber reads a 16 kHz copy.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }
}

struct TranscriptionSettings: View {
    let model: AppModel
    @Binding var settings: Settings
    @State private var vocabulary = ""
    @State private var downloading: Double?
    @State private var downloadProblem: String?

    var body: some View {
        Form {
            Section("Model") {
                Picker("Model", selection: $settings.model) {
                    ForEach(Settings.models, id: \.name) { Text($0.title).tag($0.name) }
                }
                HStack {
                    if model.library.transcriber.hasModel(settings.model) {
                        Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Delete model") {
                            model.library.transcriber.unload()
                            try? FileManager.default.removeItem(at: model.library.transcriber.modelURL(settings.model))
                            settings = settings  // redraw
                        }
                    } else if let downloading {
                        ProgressView(value: downloading).frame(width: 160)
                        Text("\(Int(downloading * 100))%").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Not downloaded", systemImage: "arrow.down.circle")
                        Spacer()
                        Button("Download") { download() }
                    }
                }
                if let downloadProblem { Text(downloadProblem).font(.caption).foregroundStyle(.orange) }
                Text("Models come from huggingface.co once and stay in the Holdnote folder. Nothing else ever goes online.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Language") {
                Picker("Language", selection: $settings.language) {
                    ForEach(Settings.languages, id: \.code) { Text($0.title).tag($0.code) }
                }
                Text("Pinning a language removes a class of errors on short clips.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Vocabulary") {
                TextEditor(text: $vocabulary)
                    .font(.system(size: 13))
                    .frame(minHeight: 90)
                    .onChange(of: vocabulary) { _, new in
                        settings.vocabulary = new.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                Text("Names, products and jargon, one per line. The transcriber is told these before it listens; right-click a recording → Re-transcribe to apply them to older ones.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Text") {
                Toggle("Remove filler words (um, uh)", isOn: $settings.removeFillers)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .onAppear { vocabulary = settings.vocabulary.joined(separator: "\n") }
    }

    private func download() {
        let name = settings.model
        downloading = 0
        downloadProblem = nil
        let transcriber = model.library.transcriber
        Task {
            do {
                try await transcriber.download(name) { p in
                    Task { @MainActor in downloading = p ?? 0 }
                }
                downloading = nil
            } catch {
                downloading = nil
                downloadProblem = error.localizedDescription
            }
        }
    }
}

struct StorageSettings: View {
    let model: AppModel
    @Binding var settings: Settings

    var body: some View {
        Form {
            Section("Where") {
                LabeledContent("Folder") {
                    HStack {
                        Text(model.library.store.root.path).font(.caption).lineLimit(1).truncationMode(.middle)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.library.store.root]) }
                    }
                }
                Text("One file per recording and its audio, in a folder you can back up, look into or delete. Spotlight doesn't index it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Audio") {
                Picker("Delete audio after", selection: $settings.deleteAudioAfterDays) {
                    Text("Never").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("A year").tag(365)
                }
                .onChange(of: settings.deleteAudioAfterDays) { _, _ in model.library.applyRetention() }
                Text("The text stays. Keeping the audio is what lets a better model transcribe it again later (about 5 MB a minute).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Copy all") {
                Toggle("Put the date and time above each transcript", isOn: $settings.copyAllHeaders)
            }
            Section("Export") {
                HStack {
                    Button("Export all as one Markdown file…") { model.library.exportMarkdown(model.library.recordings, combined: true) }
                    Button("One file each…") { model.library.exportMarkdown(model.library.recordings, combined: false) }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }
}
