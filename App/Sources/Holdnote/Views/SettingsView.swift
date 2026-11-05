import AppKit
import Harness
import SwiftUI

/// Settings' pages, listed in the window's second column when Settings is chosen.
enum SettingsTab: String, Hashable, CaseIterable, Identifiable {
    case general, audio, transcription, storage, reader
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .audio: "Audio"
        case .transcription: "Transcription"
        case .storage: "Storage"
        case .reader: "Reader"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .audio: "mic"
        case .transcription: "text.quote"
        case .storage: "internaldrive"
        case .reader: "eyeglasses"
        }
    }
}

/// One settings page, in the window's last column.
struct SettingsPage: View {
    @Bindable var model: AppModel
    let tab: SettingsTab

    var body: some View {
        @Bindable var store = model.settings
        Group {
            switch tab {
            case .general: GeneralSettings(model: model, settings: $store.settings)
            case .audio: AudioSettings(settings: $store.settings)
            case .transcription: TranscriptionSettings(model: model, settings: $store.settings)
            case .storage: StorageSettings(model: model, settings: $store.settings)
            case .reader: ReaderSettings(model: model)
            }
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct GeneralSettings: View {
    let model: AppModel
    @Binding var settings: Settings
    @State private var launchAtLogin = Permissions.launchesAtLogin
    @State private var loginProblem: String?
    @State private var revertingLogin = false

    var body: some View {
        Form {
            Picker("Record while holding", selection: $settings.hotkey) {
                ForEach(Settings.Hotkey.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .onChange(of: settings.hotkey) { _, _ in model.capture.hotkeyChanged() }
            Text(hotkeyNote).font(.caption).foregroundStyle(.secondary)
            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    // Putting the toggle back after a failure fires this again: that one is skipped.
                    if revertingLogin { revertingLogin = false; return }
                    do { try Permissions.setLaunchAtLogin(on); loginProblem = nil } catch {
                        loginProblem = error.localizedDescription
                        revertingLogin = true
                        launchAtLogin = !on
                    }
                }
                .disabled(!Updater.canUpdate)
            if let loginProblem { Text(loginProblem).font(.caption).foregroundStyle(.orange) }
            Toggle("Sounds when recording starts and stops", isOn: $settings.sounds)
            Section("The list") {
                Picker("Order", selection: Binding(get: { settings.listOrder }, set: { new in
                    if new == .custom { model.library.adoptOrderIfEmpty() }
                    settings.listOrder = new
                })) {
                    Text("Newest first, by day").tag(Settings.ListOrder.newestFirst)
                    Text("My own order").tag(Settings.ListOrder.custom)
                }
                Text("In your own order, drag recordings and notes up and down to say what came from what; the top is the latest. Copy All, All Text, export and the reader's stream follow it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Shortcuts") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Hold the key · record")
                        Text("Tap it twice · record hands-free, tap once to stop")
                        Text("⌥ + hold · add to the selected recording")
                        Text("⌘⇧H, or a click on the menu bar icon · show or hide the window")
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
    @State private var hasModel = false
    @State private var downloading: Double?
    @State private var downloadProblem: String?

    var body: some View {
        Form {
            Section("Model") {
                Picker("Model", selection: $settings.model) {
                    ForEach(Settings.models, id: \.name) { Text($0.title).tag($0.name) }
                }
                HStack {
                    if hasModel {
                        Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Delete model") {
                            model.library.transcriber.unload()
                            try? FileManager.default.removeItem(at: model.library.transcriber.modelURL(settings.model))
                            hasModel = false
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
            Section("Speed") {
                Picker("Long audio", selection: $settings.parallelParts) {
                    Text("Split automatically (up to 4 parts)").tag(0)
                    Text("Don't split").tag(1)
                    ForEach([2, 3, 4, 6, 8], id: \.self) { Text("\($0) parts at once").tag($0) }
                }
                Text("Audio over two minutes is cut at quiet moments into parts of at least a minute, transcribed at the same time on the one loaded model, and joined back in order. More parts share the GPU more thinly; try 2–4 on an M1, more on a Max or Ultra. Short clips are never split.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .onAppear {
            vocabulary = settings.vocabulary.joined(separator: "\n")
            hasModel = model.library.transcriber.hasModel(settings.model)
        }
        .onChange(of: settings.model) { _, m in hasModel = model.library.transcriber.hasModel(m) }
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
                hasModel = true
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
                    Button("Export all as one Markdown file…") { model.library.exportMarkdown(model.library.ordered, combined: true) }
                    Button("One file each…") { model.library.exportMarkdown(model.library.ordered, combined: false) }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }
}

/// The reader: Ollama, the model, and the budgets every prompt is measured against. Saved as you change them.
struct ReaderSettings: View {
    let model: AppModel
    @State private var base = ""
    @State private var moreBudgets = false

    private var reader: ReaderController { model.reader }

    var body: some View {
        @Bindable var reader = model.reader
        Form {
            Section("Ollama") {
                HStack {
                    TextField("Address", text: $base)
                        .onSubmit { apply() }
                    Button("Check again") { apply() }
                }
                Picker("Model", selection: $reader.config.model) {
                    if reader.models.isEmpty { Text(reader.config.model.isEmpty ? "no models" : reader.config.model).tag(reader.config.model) }
                    ForEach(reader.models, id: \.self) { Text($0).tag($0) }
                }
                Text(ollamaDetail).font(.caption).foregroundStyle(reader.ollamaOK ? Color.secondary : Color.orange)
                Toggle("Let the model think before it answers", isOn: $reader.config.think)
                Text("Off by default: thinking models (qwen3, deepseek-r1, gpt-oss) otherwise spend the output cap on hidden reasoning and take far longer per call. Turn on only if you want it and the output cap is generous.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("When it reads") {
                Toggle("Transcripts join the stream by themselves", isOn: $reader.config.feedTranscripts)
                if reader.config.feedTranscripts {
                    Stepper("…once unchanged for \(reader.config.settleSeconds) s", value: $reader.config.settleSeconds, in: 0...3600, step: 15)
                    Text("Long enough to fix a word or two before the reader takes it. An edit made later can still be added as a correction, from the transcript's Reader panel.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Read by itself when there's something new", isOn: Binding(get: { reader.config.autoRead }, set: { reader.config.autoRead = $0; if $0 { reader.resumeAuto() } }))
                Text("Never while you record or transcribe: whisper and the model share the Mac. Off, it reads only when you click Read now.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Keep the Mac awake while reading", isOn: $reader.config.keepAwake)
            }
            Section("Pace and budgets") {
                Stepper("Prompt window W: \(reader.config.windowTokens.formatted()) tokens", value: $reader.config.windowTokens, in: 1000...200_000, step: 500)
                HStack {
                    Button("Use the model's maximum") { reader.useModelMaximum() }.disabled(reader.config.model.isEmpty)
                        .help("Read the model's trained context length from Ollama and set W from it")
                }
                if !reader.contextNote.isEmpty { Text(reader.contextNote).font(.caption).foregroundStyle(.secondary) }
                Stepper("Sentences at a time: \(reader.config.chunkSentences == 0 ? "as many as fit" : reader.config.chunkSentences.formatted())", value: $reader.config.chunkSentences, in: 0...400, step: 4)
                Stepper("Lenses per call: \(reader.config.lensesPerCall == 0 ? "as many as fit" : reader.config.lensesPerCall.formatted())", value: $reader.config.lensesPerCall, in: 0...20)
                Text("Every lens reads each chunk. With “as many as fit”, they share one call while the window and the output cap allow, and the rest go in the next call on the same chunk. One per call is slower but easiest for a small model.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Rest between calls: \(reader.config.coolOffSec) s", value: $reader.config.coolOffSec, in: 0...3600, step: 5)
                Stepper("Notebook cap M: \(reader.config.notebookTokens.formatted()) tokens", value: $reader.config.notebookTokens, in: 100...20_000, step: 100)
                Stepper("Output cap: \(reader.config.outputTokens.formatted()) tokens", value: $reader.config.outputTokens, in: 200...32_000, step: 100)
                DisclosureGroup("Questions and more budgets", isExpanded: $moreBudgets) {
                    Stepper("Questions about your goals: \(reader.config.questionCount)", value: $reader.config.questionCount, in: 0...100)
                    Stepper("Answer again after \(reader.config.questionRefresh.formatted()) new sentences", value: $reader.config.questionRefresh, in: 1...5000, step: 10)
                    Stepper("Steps per answer: \(reader.config.askSteps)", value: $reader.config.askSteps, in: 1...40)
                    Stepper("Other lenses' notebooks cap: \(reader.config.digestTokens.formatted()) tokens", value: $reader.config.digestTokens, in: 0...20_000, step: 100)
                    Stepper("File page size: \(reader.config.pageTokens.formatted()) tokens", value: $reader.config.pageTokens, in: 200...20_000, step: 100)
                    Stepper("Chars per token (estimate): \(String(format: "%.2f", reader.config.charsPerToken))", value: $reader.config.charsPerToken, in: 2...5, step: 0.1)
                }
                Text("num_ctx is set automatically to W + output cap + 512 (\(reader.config.numCtx.formatted()) now) so Ollama never truncates a prompt. Every prompt is measured before it is sent and refused if it is over W. Chars per token is recalibrated after every call.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("The notes") {
                LabeledContent("Notes folder") {
                    HStack {
                        Text(reader.folder?.root.path ?? "none").font(.caption).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { reader.chooseFolder() }.disabled(reader.running)
                        Button("Default") { reader.useDefaultFolder() }.disabled(reader.running || reader.folder?.root.path == ReaderController.defaultFolder.path)
                    }
                }
                Text("Plain text files you can read, edit and back up. Choose a folder in iCloud Drive to read the same notes from another Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .onAppear { base = reader.config.base }
    }

    private var ollamaDetail: String {
        switch reader.ollama {
        case .checking: "Checking…"
        case let .ok(d), let .bad(d): d
        }
    }

    private func apply() {
        let b = ReaderConfig.normalizeBase(base)
        base = b
        if b != reader.config.base { reader.config.base = b }
        reader.refreshModels()
    }
}
