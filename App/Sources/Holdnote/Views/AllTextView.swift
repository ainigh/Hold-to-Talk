import AppKit
import Harness
import SwiftUI

/// Every listed transcript as one continuous text, newest first with a date line above each
/// (as Settings → Storage has it): read it in one piece, select all and copy, or Copy All.
/// What's shown is exactly what Copy All puts on the clipboard.
struct AllTextView: View {
    let model: AppModel
    @State private var copied = false

    var body: some View {
        let text = model.allText
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.searchText.isEmpty ? "All recordings" : "Recordings matching “\(model.searchText)”")
                        .font(.system(size: 13, weight: .medium))
                    Text("\(model.listed.count) transcripts · \(text.split(whereSeparator: \.isWhitespace).count) words · newest first")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.library.copy(text)
                    copied = true
                    Task { try? await Task.sleep(for: .milliseconds(1200)); copied = false }
                } label: { Label(copied ? "Copied" : "Copy All", systemImage: copied ? "checkmark" : "doc.on.doc") }
                .help("Copy everything shown (⌘⇧C)")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            SelectableText(text: text)
        }
    }
}

/// A read-only NSTextView: proper select-all, copy and find across a long text.
struct SelectableText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        guard let view = scroll.documentView as? NSTextView else { return scroll }
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
        apply(text, to: view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
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
