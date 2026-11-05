import Harness
import SwiftUI

/// Lenses: the angles the reader reads every chunk through, each with its instructions (the
/// model sees them verbatim), its order, whether it carries a notebook and reads others'.
struct LensesView: View {
    @Bindable var model: AppModel

    var body: some View {
        ReaderPage(title: "Lenses", lede: "Every chunk of the stream is read through every lens that is on, in this order; as many share one call as fit. Add a lens for any angle you want; the reader writes one file per lens into the notes.") {
            LensList(model: model)
        }
    }
}

/// The lenses, each a disclosure with its instructions (the model sees them verbatim).
struct LensList: View {
    @Bindable var model: AppModel
    @State private var open: Set<String> = []

    private var reader: ReaderController { model.reader }

    var body: some View {
        ReaderBlock(title: "Lenses", lede: "Every chunk is read through every lens that is on, in this order; as many share one call as fit. Click a lens to edit its instructions (the model sees them verbatim). A lens can read the notebooks of others.") {
            HStack {
                Spacer()
                Button("Add a lens") { let id = reader.addLens(); open.insert(id) }.controlSize(.small)
                Button("Restore defaults") {
                    confirm("Replace all lenses with the defaults?", detail: "Your edits to lens instructions will be lost.", button: "Restore defaults") { reader.resetLenses() }
                }
                .controlSize(.small)
            }
            ForEach(Array(reader.lenses.enumerated()), id: \.element.id) { idx, lens in
                LensRow(model: model, lens: lens, index: idx, isOpen: open.contains(lens.id)) { on in
                    if on { open.insert(lens.id) } else { open.remove(lens.id) }
                }
            }
        }
    }
}

struct LensRow: View {
    let model: AppModel
    let lens: Lens
    let index: Int
    let isOpen: Bool
    let setOpen: (Bool) -> Void

    private var reader: ReaderController { model.reader }

    private func binding<T>(_ keyPath: WritableKeyPath<Lens, T>) -> Binding<T> {
        Binding(get: { reader.lenses.first { $0.id == lens.id }?[keyPath: keyPath] ?? lens[keyPath: keyPath] },
                set: { v in if let i = reader.lenses.firstIndex(where: { $0.id == lens.id }) { reader.lenses[i][keyPath: keyPath] = v } })
    }

    var body: some View {
        let problems = reader.readsProblems(of: lens)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: binding(\.on)).labelsHidden().toggleStyle(.switch).controlSize(.mini).help("Run this lens")
                Button { setOpen(!isOpen) } label: {
                    HStack(spacing: 8) {
                        Text(lens.title.isEmpty ? "Untitled lens" : lens.title).font(.system(size: 13, weight: .medium)).foregroundStyle(lens.on ? .primary : .secondary)
                        if lens.carry { Badge("notebook", .green) }
                        if !lens.reads.isEmpty { Badge("reads \(lens.reads.count)") }
                        if lens.ignoreGoals { Badge("ignores goals") }
                        if !problems.isEmpty { Badge("check reads", .orange) }
                        if let n = reader.entries[lens.id]?.count, n > 0 { Text("\(n.formatted()) entries").font(.system(size: 10)).foregroundStyle(.secondary) }
                        Spacer()
                        Image(systemName: "chevron.down").rotationEffect(.degrees(isOpen ? 0 : -90)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { reader.move(lens.id, by: -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).disabled(index == 0).help("Move up")
                Button { reader.move(lens.id, by: 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless).disabled(index == reader.lenses.count - 1).help("Move down")
                Button {
                    if lens.instructions.trimmingCharacters(in: .whitespaces).isEmpty { reader.removeLens(lens.id) }
                    else { confirm("Remove the lens “\(lens.title)”?", detail: "Its notes file stays in the folder.", button: "Remove") { reader.removeLens(lens.id) } }
                } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove this lens")
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        TextField("Name", text: Binding(get: { lens.title }, set: { reader.rename(lens.id, to: $0) })).frame(maxWidth: 220)
                        TextField("Reads the notebooks of (lens ids, comma separated)", text: Binding(
                            get: { reader.lenses.first { $0.id == lens.id }?.reads.joined(separator: ", ") ?? "" },
                            set: { v in if let i = reader.lenses.firstIndex(where: { $0.id == lens.id }) { reader.lenses[i].reads = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } }))
                        Toggle("carries a notebook", isOn: binding(\.carry)).font(.system(size: 12))
                    }
                    if !problems.isEmpty { Text(problems.joined(separator: "; ") + ". Ids are shown at the bottom of each lens.").font(.system(size: 11)).foregroundStyle(.orange) }
                    TextField("What this file is for (shown to the model when it answers questions)", text: binding(\.purpose))
                    Text("Instructions (the model sees these verbatim)").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextEditor(text: binding(\.instructions))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 110, maxHeight: 220)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.background))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    Text("id: \(lens.id)  ·  file: lenses/\(lens.id).md").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.leading, 4)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(lens.on ? 0.4 : 0.2)))
    }
}
