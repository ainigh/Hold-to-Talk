import AppKit
import Harness
import SwiftUI

/// The reader's views. Ask (a conversation about the stream) and For you (what it needs you to
/// tell it) sit beside the Stream in the window's first column; Reading (what it is doing, and
/// the lenses) and Notes (the files it writes) are under the hood, below.
enum ReaderView: String, CaseIterable, Identifiable {
    case ask, forYou, reading, notes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ask: "Ask"
        case .forYou: "For you"
        case .reading: "Reading"
        case .notes: "Notes"
        }
    }
    var symbol: String {
        switch self {
        case .ask: "bubble.left.and.text.bubble.right"
        case .forYou: "questionmark.bubble"
        case .reading: "eyeglasses"
        case .notes: "doc.text"
        }
    }
    /// The two you use; the other two show how it works.
    var isMain: Bool { self == .ask || self == .forYou }
}

/// Asks before something is lost, with AppKit's own alert. SwiftUI's confirmationDialog, hosted
/// in this window, took the toolbar's items with it when the view that held it appeared. The
/// alert opens on the next turn of the run loop, never in the middle of a SwiftUI update.
@MainActor
func confirm(_ message: String, detail: String = "", button: String, then action: @escaping @MainActor () -> Void) {
    Task { @MainActor in
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: button).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { action() }
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

/// A sentence id as a small button: click to see the author's exact words under it, and the
/// recording they were said in, to open (and play).
struct SentenceIds: View {
    let ids: [String]
    let unread: [String]
    let model: AppModel
    @State private var open: Set<String> = []

    init(ids: [String], unread: [String] = [], model: AppModel) {
        self.ids = ids; self.unread = unread; self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if ids.isEmpty {
                Text("no sentence ids cited").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                // An adaptive grid wraps the ids like text with SwiftUI's own layout.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 4, alignment: .leading)], alignment: .leading, spacing: 4) {
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
                    SentenceQuote(id: id, model: model)
                }
            }
        }
    }
}

/// One sentence in your words, and the recording it came from (a click opens it).
struct SentenceQuote: View {
    let id: String
    let model: AppModel

    var body: some View {
        let origin = model.reader.origin(of: id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Text(model.reader.sentence(id) ?? "(not found in sentences.txt)").font(.system(size: 12)).textSelection(.enabled)
            }
            if let origin {
                Button { model.openRecording(origin.id) } label: {
                    Label("From your recording of \(origin.createdAt.formatted(date: .abbreviated, time: .shortened))", systemImage: origin.audioFile != nil ? "waveform" : "doc.text")
                        .font(.system(size: 11))
                }
                .buttonStyle(.link)
                .help("Open the recording\(origin.audioFile != nil ? "; Space plays it" : "")")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    }
}

/// A small coloured label.
struct Badge: View {
    let text: String
    var color: Color = .secondary

    init(_ text: String, _ color: Color = .secondary) { self.text = text; self.color = color }

    var body: some View {
        Text(text).font(.system(size: 10)).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15))).foregroundStyle(color == .secondary ? Color.secondary : color)
    }
}

/// A rounded panel, the reader's cards.
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }
}

/// The reader's page: a title, a line under it, and its sections, in a column of readable width.
struct ReaderPage<Content: View>: View {
    let title: String
    let lede: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.weight(.semibold))
                    if !lede.isEmpty {
                        Text(lede).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                content()
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
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
