import AppKit
import Harness
import SwiftUI

/// The window's first column: everything Holdnote has, one row each. Choosing a row opens the
/// columns it needs to the right. Under the rows, what the menu bar menu used to hold: voice
/// detection, the hotkey, the microphone, a recording in progress, the night's progress, updates,
/// and Quit.
struct MenuColumn: View {
    @Bindable var model: AppModel

    private var reader: ReaderController { model.reader }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                Section("Holdnote") {
                    row("Recordings", symbol: "waveform", meta: model.library.recordings.isEmpty ? "" : model.library.recordings.count.formatted())
                        .tag(Item.recordings)
                }
                Section("Reader") {
                    ForEach(ReaderView.allCases) { v in
                        row(v.title, symbol: v.symbol, meta: meta(v), attention: attention(v)).tag(Item.reader(v))
                    }
                    row("Guide", symbol: "book", meta: "").tag(Item.readerGuide)
                }
                Section("App") {
                    row("Settings", symbol: "gearshape", meta: "").tag(Item.settings)
                    row("Setup", symbol: model.capture.hotkeyRunning ? "checklist" : "exclamationmark.triangle",
                        meta: model.capture.hotkeyRunning ? "" : "hotkey off", attention: !model.capture.hotkeyRunning).tag(Item.setup)
                }
            }
            .listStyle(.sidebar)
            Divider()
            controls
        }
    }

    /// The rows stand for sections; settings is one row whatever page it is on.
    enum Item: Hashable { case recordings, reader(ReaderView), readerGuide, settings, setup }

    private var selection: Binding<Item?> {
        Binding(
            get: {
                switch model.section {
                case .recordings: .recordings
                case let .reader(v): .reader(v)
                case .readerGuide: .readerGuide
                case .settings: .settings
                case .setup: .setup
                }
            },
            set: { item in
                switch item {
                case .recordings: model.section = .recordings
                case let .reader(v): model.section = .reader(v)
                case .readerGuide: model.section = .readerGuide
                case .settings: model.section = .settings(model.settingsTab)
                case .setup: model.section = .setup
                case nil: break
                }
            })
    }

    private func row(_ title: String, symbol: String, meta: String, attention: Bool = false) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(meta).font(.system(size: 11)).foregroundStyle(attention ? Color.accentColor : .secondary)
        }
    }

    // MARK: - What the menu bar menu held

    private var controls: some View {
        VStack(alignment: .leading, spacing: 9) {
            if model.capture.isRecording {
                Button { model.capture.stopFromMenu() } label: {
                    Label("Recording · Stop", systemImage: "stop.circle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Stop the recording in progress (⌘.)")
            }
            Toggle(isOn: $model.listening) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Voice Detection").font(.system(size: 12))
                    if model.capture.isListening {
                        Text(model.capture.isSpeaking ? "Hearing speech…" : "Listening; recordings start when you speak")
                            .font(.system(size: 10)).foregroundStyle(model.capture.isSpeaking ? Color.red : .secondary)
                    }
                }
            }
            .toggleStyle(.switch).controlSize(.mini)
            .help("Record by itself whenever you speak (⌘⇧L)")
            Toggle(isOn: Binding(get: { !model.capture.paused }, set: { model.capture.paused = !$0 })) {
                Text("Hotkey (\(model.settings.settings.hotkey.glyph))").font(.system(size: 12))
            }
            .toggleStyle(.switch).controlSize(.mini)
            .help(model.capture.paused ? "The hotkey is paused; turn on to record with it again" : "Hold the key to record; turn off to pause it")
            MicrophonePicker(model: model)
            if reader.running {
                Button { model.showReader(.night) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "moon.fill").foregroundStyle(Color.accentColor)
                            Text(reader.status.isEmpty ? "Reading" : reader.status).font(.system(size: 11)).lineLimit(2)
                        }
                        ProgressView(value: Double(min(100, max(0, reader.percent))), total: 100).controlSize(.small)
                    }
                }
                .buttonStyle(.plain)
                .help("Open the Night view")
            }
            if isReaderSection { readerLines }
            Divider()
            HStack(spacing: 6) {
                UpdateStatus(updater: model.updater).buttonStyle(.borderless).controlSize(.small).labelStyle(.iconOnly)
                Text(model.updater.versionLine).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless)
                    .help("Quit Holdnote (⌘Q)")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isReaderSection: Bool {
        switch model.section {
        case .reader, .readerGuide: true
        default: false
        }
    }

    /// The notes folder and the Ollama connection, while a reader view shows.
    private var readerLines: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { reader.chooseFolder() } label: {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Folder").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(reader.folder.map { $0.name + "/" } ?? "Choose a folder").font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    }
                } icon: { Image(systemName: "folder") }
            }
            .buttonStyle(.plain)
            .help(reader.folder.map { "Notes are written into \($0.root.path). Click to choose another folder." } ?? "Choose the folder the notes are written into")
            Button { model.showSettings(tab: .reader); reader.refreshModels() } label: {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ollama").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(ollamaLine).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    }
                } icon: { Circle().fill(ollamaColor).frame(width: 8, height: 8) }
            }
            .buttonStyle(.plain)
            .help(ollamaDetail)
        }
    }

    private var ollamaLine: String {
        switch reader.ollama {
        case .checking: "checking…"
        case .ok: reader.config.model.isEmpty ? "no model" : reader.config.model
        case .bad: "not connected"
        }
    }
    private var ollamaDetail: String {
        switch reader.ollama {
        case .checking: "Checking Ollama…"
        case let .ok(d), let .bad(d): d
        }
    }
    private var ollamaColor: Color {
        switch reader.ollama {
        case .checking: .secondary
        case .ok: .green
        case .bad: .orange
        }
    }

    private func meta(_ v: ReaderView) -> String {
        switch v {
        case .stream:
            if let g = reader.gaps, !g.open.isEmpty { return "\(g.open.count) question\(g.open.count == 1 ? "" : "s")" }
            return reader.stream.count > 0 ? reader.stream.count.formatted() : ""
        case .night:
            if reader.running { return "\(reader.percent)%" }
            if reader.stream.unread > 0 { return "\(reader.stream.unread.formatted()) unread" }
            return reader.notesCount > 0 ? "\(reader.notesCount) note\(reader.notesCount == 1 ? "" : "s")" : ""
        case .notes: return reader.files.isEmpty ? "" : reader.files.count.formatted()
        }
    }

    private func attention(_ v: ReaderView) -> Bool {
        switch v {
        case .stream: (reader.gaps?.open.isEmpty == false) || (reader.folder != nil && reader.stream.count == 0 && !reader.stream.rawPresent)
        case .night: !reader.running && reader.stream.unread > 0 && reader.ollamaOK
        default: false
        }
    }
}

/// The microphone, as the menu bar menu offered it. The device list is read when the column
/// appears and each time the picker is opened, not on every redraw (it asks Core Audio).
struct MicrophonePicker: View {
    let model: AppModel
    @State private var devices: [AudioDevices.Device] = []

    var body: some View {
        Picker(selection: Binding(get: { model.settings.settings.inputDeviceID }, set: { model.setInputDevice($0) })) {
            Text("System default").tag(String?.none)
            ForEach(devices) { Text($0.name).tag(String?.some($0.uid)) }
        } label: {
            Image(systemName: "mic")
        }
        .pickerStyle(.menu).controlSize(.small)
        .help("Microphone")
        .onAppear { devices = AudioDevices.inputs() }
        .onHover { if $0 { devices = AudioDevices.inputs() } }
    }
}

/// A column's title bar, with its own buttons on the right.
struct ColumnHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                trailing()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
        }
    }
}

/// Settings' pages, in the second column when Settings is chosen.
struct SettingsList: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(title: "Settings") { EmptyView() }
            List(selection: Binding(get: { model.settingsTab }, set: { if let t = $0 { model.section = .settings(t) } })) {
                ForEach(SettingsTab.allCases) { t in Label(t.title, systemImage: t.symbol).tag(t) }
            }
            .listStyle(.sidebar)
        }
    }
}

/// The line between two columns: drag it to make the one on its left wider or narrower.
struct ColumnResizer: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard inside != hovering else { return }
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in
                            let s = start ?? width
                            start = s
                            width = min(range.upperBound, max(range.lowerBound, s + v.translation.width))
                        }
                        .onEnded { _ in start = nil })
            }
    }
}
