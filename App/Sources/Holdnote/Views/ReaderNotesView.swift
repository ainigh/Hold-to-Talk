import Harness
import SwiftUI

/// Every file the reader wrote, in the window's second column when Notes is chosen.
struct NotesFileList: View {
    let model: AppModel

    private var reader: ReaderController { model.reader }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnHeader(title: "Notes") {
                Button { reader.refreshFiles() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Re-read the folder")
                Button { reader.showFolderInFinder() } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Show the folder in Finder").disabled(reader.folder == nil)
            }
            List(selection: Binding(get: { reader.currentFile }, set: { if let f = $0 { open(f) } })) {
                if reader.folder == nil {
                    Text("Choose a folder to see its files.").foregroundStyle(.secondary)
                } else if reader.files.isEmpty {
                    Text("The folder is empty. Record something, or paste text into the stream; the reader writes its notes here.").foregroundStyle(.secondary)
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
        .onAppear { reader.refreshFiles() }
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
        if reader.openFile(f) { return }
        confirm("Discard unsaved changes to \(reader.currentFile ?? "this file")?", detail: "What you typed since the last save is lost.", button: "Discard") { _ = reader.openFile(f, discarding: true) }
    }

    private func size(_ n: Int) -> String {
        n < 1024 ? "\(n) B" : n < 1_048_576 ? String(format: "%.1f KB", Double(n) / 1024) : String(format: "%.1f MB", Double(n) / 1_048_576)
    }
}

/// The note file chosen in the list, to read and edit. Answers are made from whatever is here.
struct NotesEditor: View {
    let model: AppModel
    @StateObject private var flash = FlashState()

    var body: some View {
        @Bindable var reader = model.reader
        VStack(spacing: 0) {
            HStack {
                Text(reader.currentFile ?? "Select a file").font(.system(size: 12)).foregroundStyle(reader.fileDirty ? .primary : .secondary)
                if reader.fileDirty { Text("· edited").font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                Flash(text: flash.text)
                Text("⌘S").font(.system(size: 11)).foregroundStyle(.tertiary)
                Button("Save") { if let msg = reader.saveFile() { flash.show(msg) } }
                    .disabled(!reader.fileDirty).keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            TextEditor(text: $reader.fileBody)
                .font(.system(size: 12, design: .monospaced))
                .disabled(reader.currentFile == nil)
        }
    }
}
