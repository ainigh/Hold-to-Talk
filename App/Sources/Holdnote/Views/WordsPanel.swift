import Harness
import SwiftUI

/// The words that carry the meaning of an item, or of the whole stream: every noun, verb,
/// adjective and adverb (the closed classes left out), counted by lemma, most frequent first.
/// Pick a kind to see only those; click a word to search the stream for it.
struct WordsPanel: View {
    let model: AppModel
    /// The items to count: one, or the whole list.
    let items: [Recording]
    var compact = false
    @State private var kind: WordInventory.Kind? = nil
    @State private var limit = 60

    private var words: WordsController { model.words }

    var body: some View {
        // Reading `version` ties this view to inventories landing.
        let _ = words.version
        let all = words.inventory(of: items)
        let shown = all.entries.filter { kind == nil || $0.kind == kind }
        VStack(spacing: 0) {
            if !compact {
                HStack {
                    Label(items.count == 1 ? "Words in this item" : "Words in the stream", systemImage: "textformat.abc")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(summary(all.entries, pending: all.pending)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Divider()
            }
            Picker("Kind", selection: $kind) {
                Text("All").tag(WordInventory.Kind?.none)
                ForEach(WordInventory.Kind.allCases.filter { k in all.entries.contains { $0.kind == k } }, id: \.self) { k in
                    Text(k.title).tag(WordInventory.Kind?.some(k))
                }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            .padding(.horizontal, compact ? 0 : 14).padding(.vertical, 8)
            if shown.isEmpty {
                Text(all.pending > 0 ? "Counting…" : "No words yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, compact ? 0 : 14).padding(.bottom, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(shown.prefix(limit)) { e in row(e, in: all.entries) }
                        if shown.count > limit {
                            Button("\(shown.count - limit) more") { limit += 200 }.buttonStyle(.link).font(.system(size: 11)).padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, compact ? 0 : 14).padding(.bottom, 10)
                }
                .frame(maxHeight: compact ? 260 : .infinity)
            }
        }
        .background(compact ? Color.clear : Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func row(_ e: WordInventory.Entry, in all: [WordInventory.Entry]) -> some View {
        let most = all.first?.count ?? 1
        return Button {
            // The form written most often, so the search finds it ("went", not "go").
            model.searchText = e.commonForm
            model.show(.recordings)
        } label: {
            HStack(spacing: 8) {
                Text(e.lemma).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 4)
                if kind == nil { Text(e.kind.single).font(.system(size: 10)).foregroundStyle(.tertiary) }
                Text("\(e.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .frame(minHeight: 20)
            .background(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.18))
                    .frame(width: max(2, 60 * CGFloat(e.count) / CGFloat(most)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(e.lemma): \(e.count) time\(e.count == 1 ? "" : "s") as \(kinds(e)), in \(e.items.count) item\(e.items.count == 1 ? "" : "s")\(e.forms.count > 1 ? ", written as \(e.forms.keys.sorted().joined(separator: ", "))" : ""). Click to search the stream for “\(e.commonForm)”.")
    }

    private func kinds(_ e: WordInventory.Entry) -> String {
        e.kinds.sorted { $0.value > $1.value }.map { "\($0.key.single) \($0.value)" }.joined(separator: ", ")
    }

    private func summary(_ entries: [WordInventory.Entry], pending: Int) -> String {
        let total = entries.reduce(0) { $0 + $1.count }
        var s = "\(entries.count.formatted()) words · \(total.formatted()) uses"
        if pending > 0 { s += " · counting \(pending)…" }
        return s
    }
}
