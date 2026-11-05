import Harness
import SwiftUI

/// What stands between you and the reader's first answers, in the order to fix it.
struct GettingStarted: View {
    let model: AppModel
    let go: (ReaderView) -> Void

    private var reader: ReaderController { model.reader }

    struct Step: Identifiable {
        var id: String
        var ok: Bool
        var text: String
        var action: String
        var go: () -> Void
    }

    private var steps: [Step] {
        [
            Step(id: "ollama", ok: reader.ollamaOK, text: "Start Ollama and pull a model (ollama pull llama3.1:8b).", action: "Check", go: { model.showSettings(tab: .reader); reader.refreshModels() }),
            Step(id: "folder", ok: reader.folder != nil, text: "Choose a folder for the notes. The default is inside Holdnote's own folder.", action: "Choose", go: { reader.chooseFolder() }),
            Step(id: "goals", ok: !reader.goals.trimmingCharacters(in: .whitespaces).isEmpty, text: "Write what you are trying to find out (below).", action: "", go: {}),
            Step(id: "stream", ok: reader.stream.count > 0 || reader.stream.rawPresent || reader.unfedCount > 0, text: "Add something to the stream: hold \(model.settings.settings.hotkey.glyph) and talk, drop an audio or text file on the window, or paste text (⌘⇧V).", action: "Open the stream", go: { model.show(.recordings) }),
            Step(id: "read", ok: reader.hasNotes, text: reader.config.autoRead ? "That's all: it reads by itself, whenever you're not recording." : "Read: it runs in the background, and the window can be closed.", action: reader.config.autoRead ? "" : "Read now", go: { reader.startReading() }),
        ]
    }

    var body: some View {
        let steps = self.steps
        if !steps.allSatisfy(\.ok) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Getting started").font(.system(size: 13, weight: .semibold))
                ForEach(steps) { s in
                    HStack(spacing: 8) {
                        Image(systemName: s.ok ? "checkmark.circle.fill" : "circle").foregroundStyle(s.ok ? Color.green : Color.secondary)
                        Text(s.text).font(.system(size: 12)).foregroundStyle(s.ok ? .secondary : .primary).strikethrough(s.ok, color: .secondary)
                        if !s.ok, !s.action.isEmpty { Button(s.action, action: s.go).buttonStyle(.link).font(.system(size: 12)) }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        }
    }
}
