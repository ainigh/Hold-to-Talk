import Harness
import SwiftUI

/// Everything the night wrote, as plain text in the folder. Edit and save; the morning reads whatever is here.
struct ReaderNotesView: View {
    let model: AppModel
    @State private var confirmDiscard: String?
    @StateObject private var flash = FlashState()

    private var reader: ReaderController { model.reader }

    var body: some View {
        @Bindable var reader = model.reader
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Notes").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { reader.refreshFiles() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Re-read the folder")
                    Button { reader.showFolderInFinder() } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Show the folder in Finder").disabled(reader.folder == nil)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                List(selection: Binding(get: { reader.currentFile }, set: { if let f = $0 { open(f) } })) {
                    if reader.folder == nil {
                        Text("Choose a folder to see its files.").foregroundStyle(.secondary)
                    } else if reader.files.isEmpty {
                        Text("The folder is empty. Add text and run a night.").foregroundStyle(.secondary)
                    }
                    ForEach(groups) { g in
                        Section(g.id) {
                            ForEach(g.files) { f in
                                HStack {
                                    Text(f.shortName).lineLimit(1)
                                    Spacer()
                                    Text(size(f.size)).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                .tag(f.name)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            VStack(spacing: 0) {
                HStack {
                    Text(reader.currentFile ?? "Select a file").font(.system(size: 12)).foregroundStyle(reader.fileDirty ? .primary : .secondary)
                    if reader.fileDirty { Text("· edited").font(.system(size: 11)).foregroundStyle(.secondary) }
                    Spacer()
                    Flash(text: flash.text)
                    Text("⌘S").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Button("Save") { save() }.disabled(!reader.fileDirty).keyboardShortcut("s", modifiers: .command)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
                TextEditor(text: $reader.fileBody)
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(reader.currentFile == nil)
            }
            .frame(minWidth: 360)
        }
        .onAppear { reader.refreshFiles() }
        .confirmationDialog("Discard unsaved changes to \(reader.currentFile ?? "")?", isPresented: Binding(get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } }), titleVisibility: .visible) {
            Button("Discard", role: .destructive) { if let f = confirmDiscard { reader.openFile(f, discarding: true) }; confirmDiscard = nil }
        }
    }

    struct Group: Identifiable {
        var id: String
        var files: [ReaderController.NoteFile]
    }

    private var groups: [Group] {
        var out: [Group] = []
        for f in reader.files {
            if let i = out.firstIndex(where: { $0.id == f.group }) { out[i].files.append(f) } else { out.append(Group(id: f.group, files: [f])) }
        }
        return out
    }

    private func open(_ f: String) {
        if !reader.openFile(f) { confirmDiscard = f }
    }

    private func save() {
        if let msg = reader.saveFile() { flash.show(msg) }
    }

    private func size(_ n: Int) -> String {
        n < 1024 ? "\(n) B" : n < 1_048_576 ? String(format: "%.1f KB", Double(n) / 1024) : String(format: "%.1f MB", Double(n) / 1_048_576)
    }
}
