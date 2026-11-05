import Harness
import SwiftUI

/// Reading: what the reader is doing (the chunk in hand and which lenses have read it, what the
/// model is writing as it writes it, the log), how far it has come, and the lenses themselves.
struct ReaderReadingView: View {
    @Bindable var model: AppModel
    let go: (ReaderView) -> Void
    @State private var showPrompt = false
    @State private var showLog = false

    private var reader: ReaderController { model.reader }

    var body: some View {
        ReaderPage(title: "Reading", lede: "Whatever you record joins the stream a minute after it settles, and the reader reads it then: a small chunk at a time, through every lens at once (as many in one call as fit), each lens keeping its notebook from chunk to chunk. Then it answers the questions about your goals. It waits while you record or transcribe.") {
            runCard
            LensList(model: model)
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
                        Text(outcome).font(.system(size: 12)).foregroundStyle(outcome.hasPrefix("Up to date") ? Color.green : .primary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button(reader.startTitle) { reader.startReading() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(reader.running || reader.blocker != nil || !reader.hasWork)
                    Button(reader.stopping ? "Stopping…" : "Stop after this call") { reader.stopAfterCall() }
                        .disabled(!reader.running || reader.stopping)
                        .help("Finish the call in progress, save, then pause. Read now carries on from the same place.")
                    Button("Stop now") { reader.stopNow() }
                        .controlSize(.small)
                        .disabled(!reader.running)
                        .help("Cut the call in progress short; the chunk it was reading is read again.")
                }
            }
            HStack(spacing: 14) {
                Toggle("Read by itself when there's something new", isOn: Binding(get: { reader.config.autoRead }, set: { reader.config.autoRead = $0; if $0 { reader.resumeAuto() } }))
                    .font(.system(size: 12))
                Toggle("Keep the Mac awake while reading", isOn: Binding(get: { reader.config.keepAwake }, set: { reader.config.keepAwake = $0 }))
                    .font(.system(size: 12))
                Spacer()
                Button("Clear progress") {
                    confirm("Read everything again from the start?", detail: "Every lens forgets how far it has read and its notebook, so the next reading goes through the whole stream again. Note files are kept until they are rewritten.", button: "Clear progress") { reader.clearProgress() }
                }
                    .controlSize(.small)
                    .disabled(reader.running || reader.folder == nil)
                    .help("Every lens reads from the first sentence again (after changing a lens's instructions, say)")
            }
            if reader.config.autoRead, !reader.running, let until = reader.pausedUntil, until > Date() {
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary)
                    Text(until == .distantFuture ? "Paused: it won't read by itself until you click Read now." : "Paused after a problem until \(until.formatted(date: .omitted, time: .shortened)).")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Read by itself again") { reader.resumeAuto() }.buttonStyle(.link).font(.system(size: 12))
                }
            }
            progress
            if !reader.status.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(reader.status).font(.system(size: 12)).lineLimit(2)
                }
            }
            if let live = reader.live { liveView(live) }
            DisclosureGroup(isExpanded: $showLog) {
                ScrollView {
                    Text(reader.logText.isEmpty ? "Nothing yet." : reader.logText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
                .defaultScrollAnchor(.bottom)
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
    }

    /// How much of the stream every lens has read, the chunk in hand with a chip per lens, and the questions.
    @ViewBuilder
    private var progress: some View {
        let total = reader.running ? reader.totalCount : reader.stream.count
        let read = reader.running ? reader.readCount : reader.stream.count - reader.stream.unread
        if total > 0 {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Read by every lens").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(read.formatted()) of \(total.formatted()) sentences").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(min(read, total)), total: Double(total)).controlSize(.small)
                if reader.running, let c = reader.chunk {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Now: \(c.from)–\(c.to)").font(.system(size: 11, weight: .medium))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 4, alignment: .leading)], alignment: .leading, spacing: 4) {
                            ForEach(c.readers, id: \.self) { id in
                                let mark = reader.marks[id] ?? .waiting
                                HStack(spacing: 4) {
                                    Image(systemName: symbol(mark)).font(.system(size: 9)).foregroundStyle(color(mark))
                                    Text(reader.lenses.first { $0.id == id }?.title ?? id).font(.system(size: 11)).lineLimit(1)
                                }
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(color(mark).opacity(mark == .waiting ? 0.08 : 0.15)))
                            }
                        }
                    }
                }
                if let q = reader.questionInfo, q.total > 0 {
                    HStack {
                        Text(q.current.isEmpty ? "Questions about your goals" : "Answering: \(q.current)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text("\(q.done) of \(q.total) up to date").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func symbol(_ m: Reading.Mark) -> String {
        switch m {
        case .waiting: "circle"
        case .now: "circle.dotted"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private func color(_ m: Reading.Mark) -> Color {
        switch m {
        case .waiting: .secondary
        case .now: .accentColor
        case .done: .green
        case .failed: .orange
        }
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
            ScrollView {
                Text(live.output.isEmpty ? " " : live.output)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
            .defaultScrollAnchor(.bottom)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background))
        }
    }

    private var headline: String {
        if reader.running { return reader.runningAuto ? "Reading what's new" : "Reading" }
        guard reader.folder != nil else { return "Choose a folder to begin" }
        let s = reader.stream
        if s.count == 0 { return s.rawPresent ? "stream.txt is ready to be numbered and read" : (reader.unfedCount > 0 ? "\(reader.unfedCount) transcript\(reader.unfedCount == 1 ? "" : "s") about to join the stream" : "Nothing to read yet") }
        if s.unread == 0 {
            if s.questionsPending > 0 || s.questionsToWrite { return "Read · questions to answer" }
            return "Up to date"
        }
        let active = reader.lenses.filter(\.on).count
        return "\(s.unread.formatted()) unread sentence\(s.unread == 1 ? "" : "s") · \(active) lens\(active == 1 ? "" : "es")\(reader.plan.map { " · about \($0.durationText)" } ?? "")"
    }

    private var estimate: String {
        if reader.running || reader.folder == nil { return "" }
        let c = reader.config
        if reader.stream.count == 0 { return reader.unfedCount > 0 ? "They join a minute after they settle, or now with Read now." : "Record something, or paste text on the Stream view." }
        if reader.stream.unread == 0 {
            let p = reader.stream.questionsPending
            if p > 0 { return "\(p) question\(p == 1 ? "" : "s") about your goals to answer from what was read (up to \(c.askSteps + 1) calls each)." }
            return reader.stream.questionsToWrite ? "Next it writes \(c.questionCount) questions from your goals and answers them." : "Everything said so far has been read, and every question is answered. Record more, and it reads it."
        }
        guard let p = reader.plan else { return "" }
        let calls = p.callsPerChunk == 1 ? "every lens in one call" : "the lenses in \(p.callsPerChunk) calls"
        return "≈ \(p.perChunk.formatted()) sentences at a time, \(calls) (with notebooks half full), ≈ \(p.chunks.formatted()) chunk\(p.chunks == 1 ? "" : "s")\(p.questionCalls > 0 ? ", plus ≈ \(p.questionCalls.formatted()) calls for the questions" : ""), \(c.coolOffSec)s between calls. A rough plan; the log shows the real pace."
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
