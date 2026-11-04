import AppKit
import Foundation
import Harness
import Observation

/// The recordings: loaded from the store at launch, saved on every change, transcribed one at
/// a time in the background. Deleting waits ten seconds for Undo before the files go.
@MainActor
@Observable
final class Library {
    let store: RecordingStore
    let transcriber: WhisperTranscriber
    private(set) var recordings: [Recording] = []
    /// What the transcriber is doing, for the list's status dots and the menu bar glyph.
    private(set) var transcribing: UUID?
    private(set) var transcribingProgress: Double = 0
    /// Recordings deleted and still undoable, newest deletion last.
    private(set) var pendingDeletes: [Recording] = []
    @ObservationIgnored private var deleteTimer: Timer?
    @ObservationIgnored private var queue: [(id: UUID, appendTo: UUID?)] = []
    @ObservationIgnored private var samplesInMemory: [UUID: [Float]] = [:]
    @ObservationIgnored private var saveTimers: [UUID: Timer] = [:]
    @ObservationIgnored var settings: () -> Settings = { Settings() }
    /// Something went wrong loading (said in the window, once).
    private(set) var loadProblems: [String] = []

    init(store: RecordingStore) {
        self.store = store
        transcriber = WhisperTranscriber(modelsFolder: store.modelsFolder)
    }

    func load() {
        var problems: [String] = []
        recordings = store.loadAll { url, error in problems.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        loadProblems = problems
        recover()
        applyRetention()
    }

    /// Audio left by a crash mid-recording becomes a recording again, with its header fixed
    /// and its transcript queued.
    private func recover() {
        for url in store.orphanedAudio(knownTo: recordings) {
            _ = try? WAVRepair.repair(url)
            guard let duration = AudioDecoder.duration(url), duration >= 1 else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            var r = Recording(createdAt: created, duration: duration, audioFile: url.lastPathComponent, status: .transcribing)
            r.failure = nil
            recordings.insert(r, at: 0)
            recordings.sort { $0.createdAt > $1.createdAt }
            try? store.save(r)
            enqueue(r.id)
        }
        // Transcripts that never finished (the app quit) are run again.
        for r in recordings where r.status == .failed && r.text.isEmpty && r.audioFile != nil {
            retranscribe(r.id)
        }
    }

    /// Audio older than the setting is deleted; the text stays.
    func applyRetention() {
        let days = settings().deleteAudioAfterDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        for i in recordings.indices where recordings[i].audioFile != nil && recordings[i].createdAt < cutoff && recordings[i].status == .final {
            try? store.deleteAudio(of: &recordings[i])
        }
    }

    func recording(_ id: UUID) -> Recording? { recordings.first { $0.id == id } }

    private func index(_ id: UUID) -> Int? { recordings.firstIndex { $0.id == id } }

    // MARK: - New recordings

    /// A recording that has just started: in the list from its first second.
    func begin(_ recording: Recording) {
        recordings.insert(recording, at: 0)
        try? store.save(recording)
    }

    /// The recording stopped: its audio is on disk, its samples are here; transcribe it. With
    /// `appendTo`, the transcript goes onto that recording and this clip is let go.
    func finish(_ id: UUID, duration: TimeInterval, device: String?, samples: [Float], appendTo: UUID?) {
        guard let i = index(id) else { return }
        recordings[i].duration = duration
        recordings[i].sourceDevice = device
        recordings[i].status = .transcribing
        try? store.save(recordings[i])
        samplesInMemory[id] = samples
        enqueue(id, appendTo: appendTo)
    }

    /// Pasted text becomes a note in the list: no audio, final from the start, titled by its
    /// first words like any recording. Returns it (nil for blank text).
    @discardableResult
    func addText(_ text: String) -> Recording? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let r = Recording(sourceDevice: "Pasted text", machineText: body, text: body, status: .final)
        recordings.insert(r, at: 0)
        try? store.save(r)
        return r
    }

    /// The recording was an accident: gone without a trace.
    func discard(_ id: UUID) {
        guard let i = index(id) else { return }
        let r = recordings.remove(at: i)
        store.delete(r)
    }

    // MARK: - Transcribing

    func retranscribe(_ id: UUID) {
        guard let i = index(id), recordings[i].audioFile != nil else { return }
        recordings[i].status = .transcribing
        recordings[i].failure = nil
        try? store.save(recordings[i])
        enqueue(id)
    }

    private func enqueue(_ id: UUID, appendTo: UUID? = nil) {
        queue.append((id, appendTo))
        runQueue()
    }

    private func runQueue() {
        guard transcribing == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        guard let r = recording(job.id) else { runQueue(); return }
        transcribing = job.id
        transcribingProgress = 0
        let samples = samplesInMemory.removeValue(forKey: job.id)
        let audioURL = store.audioURL(for: r)
        let s = settings()
        let options = WhisperTranscriber.Options(language: s.language, prompt: TranscriptText.vocabularyPrompt(s.vocabulary))
        let transcriber = transcriber
        let model = s.model
        let removeFillers = s.removeFillers
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Swift.Result<WhisperTranscriber.Result, Error>
            do {
                let audio: [Float]
                if let samples, !samples.isEmpty {
                    audio = samples
                } else if let audioURL {
                    audio = try AudioDecoder.pcm16k(audioURL)
                } else {
                    throw WhisperTranscriber.Problem("The audio was deleted; there's nothing to transcribe.")
                }
                outcome = .success(try transcriber.transcribe(audio, model: model, options: options) { p in
                    Task { @MainActor [weak self] in self?.transcribingProgress = p }
                })
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { [weak self] in
                self?.finished(job.id, appendTo: job.appendTo, outcome: outcome, removeFillers: removeFillers)
            }
        }
    }

    private func finished(_ id: UUID, appendTo: UUID?, outcome: Swift.Result<WhisperTranscriber.Result, Error>, removeFillers: Bool) {
        transcribing = nil
        defer { runQueue() }
        guard let i = index(id) else { return }
        switch outcome {
        case let .success(result):
            let text = TranscriptText.clean(TranscriptText.join(result.segments), removeFillers: removeFillers)
            if let appendTo, let target = index(appendTo) {
                // Spoken onto another recording: its text grows; this clip has done its job.
                let addition = text.isEmpty ? "" : "\n\n" + text
                recordings[target].text = recordings[target].text.trimmingCharacters(in: .whitespacesAndNewlines) + addition
                recordings[target].machineText += addition
                try? store.save(recordings[target])
                let clip = recordings.remove(at: i)
                store.delete(clip)
                return
            }
            recordings[i].replaceMachineText(text, segments: result.segments, language: result.language, model: result.model)
            try? store.save(recordings[i])
        case let .failure(error):
            recordings[i].status = .failed
            recordings[i].failure = error.localizedDescription
            try? store.save(recordings[i])
        }
    }

    // MARK: - Editing

    /// What you type is saved as you type (a moment after you stop).
    func setText(_ text: String, of id: UUID) {
        guard let i = index(id), recordings[i].text != text else { return }
        recordings[i].text = text
        saveTimers[id]?.invalidate()
        saveTimers[id] = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let r = self.recording(id) else { return }
                try? self.store.save(r)
                self.saveTimers[id] = nil
            }
        }
    }

    func saveNow() {
        for (id, timer) in saveTimers {
            timer.invalidate()
            if let r = recording(id) { try? store.save(r) }
        }
        saveTimers = [:]
    }

    // MARK: - Deleting

    /// Removes the recordings from the list now and from disk in ten seconds, unless undone.
    func delete(_ ids: Set<UUID>) {
        let removed = recordings.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        recordings.removeAll { ids.contains($0.id) }
        pendingDeletes += removed
        deleteTimer?.invalidate()
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.commitDeletes() }
        }
    }

    func undoDelete() {
        deleteTimer?.invalidate()
        deleteTimer = nil
        recordings += pendingDeletes
        recordings.sort { $0.createdAt > $1.createdAt }
        pendingDeletes = []
    }

    func commitDeletes() {
        deleteTimer?.invalidate()
        deleteTimer = nil
        for r in pendingDeletes { store.delete(r) }
        pendingDeletes = []
    }

    /// Keeps the text, removes the audio.
    func deleteAudio(_ id: UUID) {
        guard let i = index(id) else { return }
        try? store.deleteAudio(of: &recordings[i])
    }

    // MARK: - Copying and export

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyAll(_ list: [Recording]) {
        copy(TranscriptText.copyAll(list, headers: settings().copyAllHeaders))
    }

    /// Markdown of the recordings (all, or a selection) into a file or a folder of files.
    func exportMarkdown(_ list: [Recording], combined: Bool) {
        let sorted = list.sorted { $0.createdAt > $1.createdAt }
        if combined {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Holdnote export.md"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let text = sorted.map { RecordingStore.markdown($0) }.joined(separator: "\n")
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { NSAlert(error: error).runModal() }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Export here"
            panel.message = "One Markdown file per recording goes into this folder."
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm"
            for r in sorted {
                let url = folder.appendingPathComponent("\(formatter.string(from: r.createdAt)) \(r.id.uuidString.prefix(4)).md")
                try? RecordingStore.markdown(r).write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
