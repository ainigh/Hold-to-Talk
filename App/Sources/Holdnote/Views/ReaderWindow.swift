import AppKit
import Harness
import SwiftUI

/// The reader's window: the four views in the order you use them down the left (Stream, Night,
/// Morning, Notes), with the folder and the Ollama connection under them, and one view at a time
/// on the right. What the Chrome extension's runner was, as a Mac window.
struct ReaderWindow: View {
    @Bindable var model: AppModel

    enum ReaderView: String, CaseIterable, Identifiable {
        case stream, night, morning, notes
        var id: String { rawValue }
        var title: String {
            switch self {
            case .stream: "Stream"
            case .night: "Night"
            case .morning: "Morning"
            case .notes: "Notes"
            }
        }
        var symbol: String {
            switch self {
            case .stream: "text.alignleft"
            case .night: "moon.stars"
            case .morning: "sun.horizon"
            case .notes: "doc.text"
            }
        }
    }

    private var reader: ReaderController { model.reader }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                switch model.readerView {
                case .stream: ReaderStreamView(model: model, go: { model.readerView = $0 })
                case .night: ReaderNightView(model: model, go: { model.readerView = $0 })
                case .morning: ReaderMorningView(model: model)
                case .notes: ReaderNotesView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            // The same two items whatever the night is doing: a toolbar bridged into an AppKit window
            // loses its items when their identity changes, so only the label and action change.
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if reader.running { reader.stopAfterCall() } else { model.readerView = .night; reader.startNight() }
                } label: {
                    Label(reader.running ? (reader.stopping ? "Stopping…" : "Stop after this call") : reader.startTitle,
                          systemImage: reader.running ? "stop.circle" : "moon.fill")
                }
                .disabled(reader.running ? reader.stopping : reader.blocker != nil)
                .help(reader.running ? "Finish the call in progress, save progress, then stop. Resume later from the same place."
                      : (reader.blocker?.text ?? "Read everything unread through every lens, then answer the overnight questions"))
                Button { model.showSettings(tab: .reader) } label: { Label("Settings", systemImage: "gearshape") }
                    .help("The model and the budgets (Settings → Reader)")
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear { reader.refreshStream(); reader.refreshFiles() }
        .onChange(of: model.library.recordings.count) { _, _ in reader.libraryChanged() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.readerView) {
                ForEach(ReaderView.allCases) { v in
                    HStack {
                        Label(v.title, systemImage: v.symbol)
                        Spacer()
                        Text(meta(v)).font(.system(size: 11)).foregroundStyle(attention(v) ? Color.accentColor : .secondary)
                    }
                    .tag(v)
                }
            }
            .listStyle(.sidebar)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                if reader.running {
                    Button { model.readerView = .night } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "moon.fill").foregroundStyle(Color.accentColor)
                                Text(reader.status.isEmpty ? "Reading" : reader.status).font(.system(size: 11)).lineLimit(2)
                            }
                            ProgressView(value: Double(reader.percent), total: 100).controlSize(.small)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Open the Night view")
                }
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
                    } icon: {
                        Circle().fill(ollamaColor).frame(width: 8, height: 8)
                    }
                }
                .buttonStyle(.plain)
                .help(ollamaDetail)
            }
            .padding(12)
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
            return reader.stream.unread > 0 ? "\(reader.stream.unread.formatted()) unread" : ""
        case .morning: return reader.notesCount > 0 ? "\(reader.notesCount) note\(reader.notesCount == 1 ? "" : "s")" : ""
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

// MARK: - Shared pieces

/// A section heading with a one-line explanation under it.
struct ReaderBlock<Content: View>: View {
    let title: String
    let lede: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold))
            if !lede.isEmpty { Text(lede).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            content()
        }
        .padding(.bottom, 8)
    }
}

/// A sentence id as a small button: click to see the author's exact words under it.
struct SentenceIds: View {
    let ids: [String]
    let unread: [String]
    let lookup: (String) -> String?
    @State private var open: Set<String> = []

    init(ids: [String], unread: [String] = [], lookup: @escaping (String) -> String?) {
        self.ids = ids; self.unread = unread; self.lookup = lookup
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if ids.isEmpty {
                Text("no sentence ids cited").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                FlowRow(spacing: 4) {
                    ForEach(ids, id: \.self) { id in
                        let isUnread = unread.contains(id)
                        Button {
                            if open.contains(id) { open.remove(id) } else { open.insert(id) }
                        } label: {
                            Text(id + (isUnread ? " ?" : ""))
                                .font(.system(size: 11, design: .monospaced))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(open.contains(id) ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12)))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isUnread ? Color.orange.opacity(0.6) : .clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help(isUnread ? "Cited but never read during this answer. Click to see the sentence." : "Click to see the sentence")
                    }
                }
                ForEach(ids.filter { open.contains($0) }, id: \.self) { id in
                    HStack(alignment: .top, spacing: 8) {
                        Text(id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Text(lookup(id) ?? "(not found in sentences.txt)").font(.system(size: 12)).textSelection(.enabled)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                }
            }
        }
    }
}

/// Lays its children out in rows, wrapping like text. Always answers with a finite size: an
/// unbounded or missing width proposal gets one row, never an infinite frame (which SwiftUI
/// answers by drawing nothing at all).
struct FlowRow: Layout {
    var spacing: CGFloat = 4

    private func rows(_ subviews: Subviews, width: CGFloat?) -> (size: CGSize, frames: [CGRect]) {
        let limit = width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if let limit, x > 0, x + size.width > limit { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: limit ?? widest, height: y + rowHeight), frames)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(subviews, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = rows(subviews, width: bounds.width)
        for (s, f) in zip(subviews, laid.frames) {
            s.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }
}

/// A short message that fades after a moment (the extension's toast).
struct Flash: View {
    let text: String?
    var body: some View {
        if let text {
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).transition(.opacity)
        }
    }
}

final class FlashState: ObservableObject {
    @Published var text: String?
    private var generation = 0
    func show(_ t: String, seconds: Double = 3.5) {
        text = t
        generation += 1
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if let self, self.generation == g { self.text = nil }
        }
    }
}
