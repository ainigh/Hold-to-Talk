import AppKit
import Harness
import SwiftUI

/// ALL, the whole stream as one text (KINDS.md): every item in the list, in the list's order with
/// a date line above each, exactly what the reader reads and what Copy All puts on the
/// clipboard. The same chrome as any text: Copy first in the footer, and beside it its
/// questions for you, the conversation, or its words. Select any passage and right-click to
/// ask the reader about it.
struct StreamTextView: View {
    let model: AppModel
    @AppStorage(SidePanel.key) private var side = SidePanel.reader.rawValue

    private var reader: ReaderController { model.reader }

    var body: some View {
        let text = model.allText
        TextFrame(offered: [.forYou, .ask, .words]) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.searchText.isEmpty ? "ALL · the whole stream" : "Items matching “\(model.searchText)”")
                    .font(.system(size: 13, weight: .medium))
                Text(meta(text)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        } content: {
            if model.listed.isEmpty {
                Text(model.searchText.isEmpty ? "Nothing in the stream yet." : "Nothing matches.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SelectableText(text: text) { passage in model.askAbout(passage) }
            }
        } footer: {
            CopyButton(text: text, title: "Copy All", help: "Copy everything shown (⌘⇧C)") { model.library.copy($0) }
            if reader.unfedCount > 0, reader.folder != nil, model.searchText.isEmpty {
                Button { _ = reader.feedTranscripts() } label: { Label("Add \(reader.unfedCount) to the reader now", systemImage: "eyeglasses") }
                    .help("Items join the reader's stream by themselves a minute after they settle; this adds them at once")
            }
            Spacer()
        } side: { panel in
            switch panel {
            case .forYou: OpenQuestionsPanel(model: model)
            case .words: WordsPanel(model: model, items: model.listed)
            default: AskPanel(model: model)
            }
        }
        // "Ask the reader about this…": the conversation beside the text, the passage in its field.
        .onChange(of: model.askDraftRequests) { _, _ in if model.askDraftTarget == nil { side = SidePanel.ask.rawValue } }
    }

    private func meta(_ text: String) -> String {
        var parts = ["\(model.listed.count) item\(model.listed.count == 1 ? "" : "s")", "\(text.split(whereSeparator: \.isWhitespace).count.formatted()) words"]
        if model.searchText.isEmpty {
            let s = reader.stream
            if s.count > 0 { parts.append(s.unread > 0 ? "reader: \((s.count - s.unread).formatted()) of \(s.count.formatted()) sentences read" : "reader: all \(s.count.formatted()) sentences read") }
            else if reader.unfedCount == 0 { parts.append("the reader has nothing yet") }
        }
        parts.append(model.settings.settings.listOrder == .custom ? "in your order" : "newest first")
        return parts.joined(separator: " · ")
    }
}

/// A read-only NSTextView: proper select-all, copy and find across a long text, and a menu
/// item to ask the reader about the selection.
struct SelectableText: NSViewRepresentable {
    let text: String
    var onAsk: ((String) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let view = AskableTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = false
        view.usesFindBar = true
        view.textContainerInset = NSSize(width: 20, height: 16)
        view.font = NSFont.systemFont(ofSize: 16)
        view.textColor = .labelColor
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        view.defaultParagraphStyle = style
        view.typingAttributes = [.font: NSFont.systemFont(ofSize: 16), .paragraphStyle: style, .foregroundColor: NSColor.labelColor]
        view.onAsk = onAsk
        scroll.documentView = view
        apply(text, to: view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? AskableTextView else { return }
        view.onAsk = onAsk
        guard view.string != text else { return }
        apply(text, to: view)
    }

    private func apply(_ text: String, to view: NSTextView) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        let body = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16), .paragraphStyle: style, .foregroundColor: NSColor.labelColor])
        // The date lines, a touch quieter, so the text reads as one piece with markers.
        let lines = text.components(separatedBy: "\n")
        var offset = 0
        for line in lines {
            let length = (line as NSString).length
            if Self.isHeader(line) {
                body.addAttributes([.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor],
                                   range: NSRange(location: offset, length: length))
            }
            offset += length + 1
        }
        view.textStorage?.setAttributedString(body)
    }

    /// "2026-11-04 09:30" as `TranscriptText.copyAll` writes it.
    static func isHeader(_ line: String) -> Bool {
        line.count == 16 && line.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#, options: .regularExpression) != nil
    }
}

/// A text view whose right-click menu offers to ask the reader about the selected passage.
final class AskableTextView: NSTextView {
    var onAsk: ((String) -> Void)?

    private var selectedPassage: String {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage, range.location + range.length <= storage.length else { return "" }
        return (storage.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard onAsk != nil, !selectedPassage.isEmpty else { return menu }
        let item = NSMenuItem(title: "Ask the reader about this…", action: #selector(askAboutSelection(_:)), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func askAboutSelection(_ sender: Any?) {
        let passage = selectedPassage
        guard !passage.isEmpty else { return }
        onAsk?(passage)
    }
}
