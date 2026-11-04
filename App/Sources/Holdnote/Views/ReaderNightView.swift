import Harness
import SwiftUI

/// Read overnight: the run card (what will happen, Start, Stop, progress, what the model is
/// writing as it writes it, the log) and the lenses.
struct ReaderNightView: View {
    @Bindable var model: AppModel
    let go: (ReaderWindow.ReaderView) -> Void
    @State private var showPrompt = false
    @State private var showLog = false
    @State private var confirmClear = false
    @State private var confirmReset = false

    private var reader: ReaderController { model.reader }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Read overnight").font(.title2.weight(.semibold))
                    Text("Each lens is one full pass over everything unread, one window at a time, writing notes that cite sentence ids. The night runs in the background with the window closed, and can be stopped and resumed.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                runCard
                LensList(model: model, confirmReset: $confirmReset)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .confirmationDialog("Delete progress.json so the next run reads the whole stream again from the start? Note files are kept until overwritten.", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear progress", role: .destructive) { reader.clearProgress() }
        }
        .confirmationDialog("Replace all lenses with the defaults? Your edits to lens instructions will be lost.", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Restore defaults", role: .destructive) { reader.resetLenses() }
        }
    }

    private var runCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline).font(.system(size: 17, weight: .semibold))
                    Text(estimate).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !reader.config.model.isEmpty {
                        HStack(spacing: 4) {
                            Text("\(reader.config.model) · \(reader.config.coolOffSec)s between calls · thinking \(reader.config.think ? "on" : "off") ·").font(.system(size: 11)).foregroundStyle(.secondary)
                            Button("Settings") { model.showSettings(tab: .reader) }.buttonStyle(.link).font(.system(size: 11))
                        }
                    }
                    if let b = reader.blocker, !reader.running {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                            Text(b.text).font(.system(size: 12))
                            Button(blockerAction(b.step)) { goFix(b.step) }.buttonStyle(.link).font(.system(size: 12))
                        }
                    }
                    if let outcome = reader.lastOutcome, !reader.running {
                        Text(outcome).font(.system(size: 12)).foregroundStyle(outcome.hasPrefix("The night is done") ? Color.green : .primary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button(reader.startTitle) { reader.startNight() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(reader.running || reader.blocker != nil)
                    Button(reader.stopping ? "Stopping…" : "Stop after this call") { reader.stopAfterCall() }
                        .disabled(!reader.running || reader.stopping)
                        .help("Finish the call in progress, save progress, then stop. Resume later from the same place.")
                    Button("Stop now") { reader.stopNow() }
                        .controlSize(.small)
                        .disabled(!reader.running)
                        .help("Cut the call in progress short; the window it was reading is read again on resume.")
                }
            }
            HStack {
                Toggle("Keep the Mac awake while reading", isOn: Binding(get: { reader.config.keepAwake }, set: { reader.config.keepAwake = $0 }))
                    .font(.system(size: 12))
                Spacer()
                Button("Clear progress") { confirmClear = true }
                    .controlSize(.small)
                    .disabled(reader.running || reader.folder == nil)
                    .help("Forget what has been read so the next night starts from the first sentence")
            }
            if !reader.status.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(reader.status).font(.system(size: 12))
                }
            }
            if let live = reader.live { liveView(live) }
            if !reader.tape.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(reader.tape) { row in
                        HStack(spacing: 8) {
                            Text(row.title).font(.system(size: 11)).frame(width: 130, alignment: .leading).lineLimit(1)
                            HStack(spacing: 1) {
                                ForEach(Array(row.cells.enumerated()), id: \.offset) { _, c in
                                    Rectangle().fill(cellColor(c)).frame(height: 8)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            Text(row.finished ? "done" : "\(row.percent)%").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
            DisclosureGroup(isExpanded: $showLog) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(reader.logText.isEmpty ? "Nothing yet." : reader.logText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("end")
                    }
                    .frame(height: 180)
                    .onChange(of: reader.log.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
            } label: {
                HStack {
                    Text("Log").font(.system(size: 12, weight: .medium))
                    Text("· \(reader.log.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") { model.library.copy(reader.logText) }.buttonStyle(.link).font(.system(size: 11))
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
        .onChange(of: reader.running) { _, on in if on { showLog = true } }
    }

    private func liveView(_ live: ReaderController.LiveCall) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(live.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                TimelineView(.periodic(from: live.started, by: 0.5)) { ctx in
                    let secs = ctx.date.timeIntervalSince(live.started)
                    let chars = live.output.count + live.thinking.count
                    Text("\(reader.running ? String(format: "%.1fs · ", secs) : "")≈ \(Int(Double(chars) / reader.tokens.charsPerToken).formatted()) tokens\(live.note.isEmpty ? "" : " · " + live.note)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Toggle("Prompt", isOn: $showPrompt).toggleStyle(.button).controlSize(.small).help("Show the prompt this call was sent")
            }
            if showPrompt {
                ScrollView {
                    Text("── system (≈ \(reader.tokens.estimate(live.system).formatted()) tokens) ──\n\(live.system)\n\n── user (≈ \(reader.tokens.estimate(live.user).formatted()) tokens) ──\n\(live.user)")
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background))
            }
            if !live.thinking.isEmpty {
                ScrollView { Text(live.thinking).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 80).padding(6).background(RoundedRectangle(cornerRadius: 6).fill(.background))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(live.output.isEmpty ? " " : live.output)
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .id("out")
                }
                .frame(height: 160)
                .onChange(of: live.output.count) { _, _ in proxy.scrollTo("out", anchor: .bottom) }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background))
        }
    }

    private func cellColor(_ c: Night.TapeState) -> Color {
        switch c {
        case .initial: Color.secondary.opacity(0.2)
        case .now: Color.accentColor.opacity(0.6)
        case .done: Color.accentColor
        case .bad: Color.orange
        }
    }

    private var headline: String {
        if reader.running { return "Reading" }
        guard reader.folder != nil else { return "Choose a folder to begin" }
        let s = reader.stream
        if s.count == 0 { return s.rawPresent ? "stream.txt is ready to be numbered and read" : (reader.unfedCount > 0 ? "\(reader.unfedCount) transcripts ready to join the stream" : "Nothing to read yet") }
        if s.unread == 0 { return "Everything has been read" }
        let active = reader.lenses.filter(\.on).count
        return "\(s.unread.formatted()) unread sentence\(s.unread == 1 ? "" : "s") · \(active) lens\(active == 1 ? "" : "es")\(reader.plan.map { " · about \($0.durationText)" } ?? "")"
    }

    private var estimate: String {
        if reader.running || reader.folder == nil { return "" }
        let c = reader.config
        if reader.stream.count == 0 { return reader.unfedCount > 0 ? "They are added when the night starts." : "" }
        if reader.stream.unread == 0 {
            return "The next night only runs the question pass\(c.questionCount > 0 ? " (≈ \(c.questionCount) × up to \(c.morningSteps + 1) calls)" : ""). Record or paste more to give it something to read."
        }
        guard let p = reader.plan else { return "" }
        return "≈ \(p.perWindow.formatted()) sentences per window, ≈ \(p.windows.formatted()) windows in all\(p.questionCalls > 0 ? ", plus ≈ \(p.questionCalls.formatted()) calls for the question pass" : ""), at \(c.coolOffSec)s cool-off. A rough plan; the log shows the real pace."
    }

    private func blockerAction(_ step: String) -> String {
        switch step {
        case "folder": "Choose a folder"
        case "stream": "Add some text"
        case "ollama": "Check Ollama"
        default: "Lenses"
        }
    }

    private func goFix(_ step: String) {
        switch step {
        case "folder": reader.chooseFolder()
        case "stream": go(.stream)
        case "ollama": model.showSettings(tab: .reader); reader.refreshModels()
        default: break
        }
    }
}

/// The lenses, each a disclosure with its instructions (the model sees them verbatim).
struct LensList: View {
    @Bindable var model: AppModel
    @Binding var confirmReset: Bool
    @State private var open: Set<String> = []

    private var reader: ReaderController { model.reader }

    var body: some View {
        ReaderBlock(title: "Lenses", lede: "Click a lens to edit its instructions; the model sees them verbatim. Lenses run in this order, and a later lens can read the notebook of an earlier one.") {
            HStack {
                Spacer()
                Button("Add a lens") { let id = reader.addLens(); open.insert(id) }.controlSize(.small)
                Button("Restore defaults") { confirmReset = true }.controlSize(.small)
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
    @State private var confirmDelete = false

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
                        if lens.carry { badge("notebook", .green) }
                        if !lens.reads.isEmpty { badge("reads \(lens.reads.count)", .secondary) }
                        if lens.ignoreGoals { badge("ignores goals", .secondary) }
                        if !problems.isEmpty { badge("check reads", .orange) }
                        Spacer()
                        Image(systemName: "chevron.down").rotationEffect(.degrees(isOpen ? 0 : -90)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { reader.move(lens.id, by: -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).disabled(index == 0).help("Move up")
                Button { reader.move(lens.id, by: 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless).disabled(index == reader.lenses.count - 1).help("Move down")
                Button { if lens.instructions.trimmingCharacters(in: .whitespaces).isEmpty { reader.removeLens(lens.id) } else { confirmDelete = true } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove this lens")
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
                    TextField("What this file is for (shown to the morning model)", text: binding(\.purpose))
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
        .confirmationDialog("Remove the lens “\(lens.title)”? Its notes file stays in the folder.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { reader.removeLens(lens.id) }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10)).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15))).foregroundStyle(color == .secondary ? Color.secondary : color)
    }
}
