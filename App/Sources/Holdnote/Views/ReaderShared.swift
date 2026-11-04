import AppKit
import Harness
import SwiftUI

/// The reader's four views, in the order you use them, as they appear in the window's sidebar
/// under the recordings: Stream, Night, Morning, Notes.
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
