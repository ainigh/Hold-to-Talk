import AppKit
import Harness
import SwiftUI

/// The window's first column. Three things you use: the Stream (everything you add, each item
/// text), Ask (a conversation about it) and For you (what the reader needs you to tell it).
/// Under the hood, how the reading works: Reading, Notes, the Guide. Then Settings and Setup.
/// At the bottom, the recording switches and updates; what is running shows at the top right.
struct MenuColumn: View {
    @Bindable var model: AppModel

    private var reader: ReaderController { model.reader }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                Section {
                    row("Stream", symbol: "text.alignleft", meta: model.library.recordings.isEmpty ? "" : model.library.recordings.count.formatted())
                        .tag(Item.recordings)
                    ForEach(ReaderView.allCases.filter(\.isMain)) { v in
                        row(v.title, symbol: v.symbol, meta: meta(v), attention: attention(v)).tag(Item.reader(v))
                    }
                }
                if let gap = reader.voiceAnswer {
                    Section {
                        Button { model.showReader(.forYou) } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Hold \(model.settings.settings.hotkey.glyph) to answer").font(.system(size: 12, weight: .medium))
                                    Text(gap.question).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                                }
                            } icon: { Image(systemName: "mic.fill").foregroundStyle(.red) }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("Under the hood") {
                    ForEach(ReaderView.allCases.filter { !$0.isMain }) { v in
                        row(v.title, symbol: v.symbol, meta: meta(v), attention: attention(v)).tag(Item.reader(v))
                    }
                    row("Guide", symbol: "book", meta: "").tag(Item.readerGuide)
                }
                Section {
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

    // MARK: - Recording, reading, updates

    private var controls: some View {
        VStack(alignment: .leading, spacing: 9) {
            if model.capture.isRecording {
                Button { model.capture.stopFromMenu() } label: {
                    Label("Recording · Stop", systemImage: "stop.circle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Stop the recording in progress (⌘.)")
            }
            Toggle(isOn: Binding(get: { !model.capture.paused }, set: { model.capture.paused = !$0 })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hold \(model.settings.settings.hotkey.glyph) to talk").font(.system(size: 12))
                    if model.capture.paused { Text("Paused").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
            }
            .toggleStyle(.switch).controlSize(.mini)
            .help(model.capture.paused ? "The hotkey is paused; turn on to record with it again" : "Hold the key anywhere to record; turn off to pause it")
            Toggle(isOn: $model.listening) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Voice detection").font(.system(size: 12))
                    if model.capture.isListening {
                        Text(model.capture.isSpeaking ? "Hearing speech…" : "Recording starts when you speak")
                            .font(.system(size: 10)).foregroundStyle(model.capture.isSpeaking ? Color.red : .secondary)
                    }
                }
            }
            .toggleStyle(.switch).controlSize(.mini)
            .help("Record by itself whenever you speak (⌘⇧L)")
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

    private func meta(_ v: ReaderView) -> String {
        switch v {
        case .status:
            if reader.running { return "\(reader.percent)%" }
            if model.library.transcribing != nil { return "transcribing" }
            let n = reader.questions.count
            return n == 0 ? "" : "\(reader.questions.filter { reader.answers[$0] != nil }.count)/\(n)"
        case .forYou:
            let n = reader.gaps?.open.count ?? 0
            return n > 0 ? n.formatted() : ""
        case .reading:
            if reader.running { return "\(reader.percent)%" }
            if reader.stream.unread > 0 { return "\(reader.stream.unread.formatted()) unread" }
            if let b = reader.blocker, b.step == "ollama" || b.step == "folder" { return "not ready" }
            return ""
        case .notes: return reader.files.isEmpty ? "" : reader.files.count.formatted()
        }
    }

    private func attention(_ v: ReaderView) -> Bool {
        switch v {
        case .forYou: (reader.gaps?.open.isEmpty == false) || reader.voiceAnswer != nil
        case .status: reader.blocker.map { $0.step == "ollama" || $0.step == "folder" } ?? false
        case .reading: (!reader.running && reader.stream.unread > 0 && reader.ollamaOK && !reader.config.autoRead) || (reader.blocker.map { $0.step == "ollama" || $0.step == "folder" } ?? false)
        default: false
        }
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
