import AppKit
import Harness
import SwiftUI

/// The whole stream as one continuous text: every item in the list, in the list's order with a
/// date line above each, exactly what the reader reads and what Copy All puts on the clipboard.
/// Select any passage and right-click to ask the reader about it.
struct StreamTextView: View {
    let model: AppModel
    @State private var copied = false
    @AppStorage("streamAskPanel") private var showAsk = true
    /// Which panel sits beside the text: the conversation, or the words.
    @AppStorage("streamSidePanel") private var side = "ask"

    private var reader: ReaderController { model.reader }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 660
            if showAsk, wide {
                HStack(spacing: 0) {
                    stream
                    Divider()
                    panel.frame(width: min(360, max(280, geo.size.width * 0.36)))
                }
            } else if showAsk {
                VSplitView {
                    stream.frame(minHeight: 200)
                    panel.frame(minHeight: 160, idealHeight: 280)
                }
            } else {
                stream
            }
        }
        .onChange(of: model.askDraftRequests) { _, _ in if model.askDraftTarget == nil { showAsk = true; side = "ask" } }
    }

    @ViewBuilder
    private var panel: some View {
        if side == "words" { WordsPanel(model: model, items: model.listed) } else { AskPanel(model: model) }
    }

    private var stream: some View {
        let text = model.allText
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.searchText.isEmpty ? "ALL · the whole stream" : "Items matching “\(model.searchText)”")
                        .font(.system(size: 13, weight: .medium))
                    Text(meta(text)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if reader.unfedCount > 0, reader.folder != nil, model.searchText.isEmpty {
                    Button("Add \(reader.unfedCount) to the reader now") { _ = reader.feedTranscripts() }
                        .controlSize(.small)
                        .help("Items join the reader's stream by themselves a minute after they settle; this adds them at once")
                }
                Button {
                    model.library.copy(text)
                    copied = true
                    Task { try? await Task.sleep(for: .milliseconds(1200)); copied = false }
                } label: { Label(copied ? "Copied" : "Copy All", systemImage: copied ? "checkmark" : "doc.on.doc") }
                .help("Copy everything shown (⌘⇧C)")
                Picker("Beside", selection: Binding(get: { showAsk ? side : "none" }, set: { v in if v == "none" { showAsk = false } else { showAsk = true; side = v } })) {
                    Label("Ask", systemImage: "bubble.left.and.text.bubble.right").tag("ask")
                    Label("Words", systemImage: "textformat.abc").tag("words")
                    Label("Text only", systemImage: "rectangle").tag("none")
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                .help("Beside the text: the conversation about everything, the words that carry its meaning (nouns, verbs, adjectives, adverbs, counted), or nothing")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            if model.listed.isEmpty {
                Text(model.searchText.isEmpty ? "Nothing in the stream yet." : "Nothing matches.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SelectableText(text: text) { passage in model.askAbout(passage) }
            }
        }
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
