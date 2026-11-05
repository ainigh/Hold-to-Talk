import Foundation
import Harness
import Observation

/// Keeps the stream's sentences embedded for the SIMILAR move: whenever sentences join the
/// stream, the ones without a vector are sent to Ollama's embedding model in batches and
/// appended to the folder's store. Nothing is re-embedded (ids never change). Without the
/// model, or with the setting empty, nothing runs and SIMILAR is simply not offered.
@MainActor
@Observable
final class EmbeddingIndexer {
    enum State: Equatable { case off, checking, unavailable(String), idle, indexing }
    private(set) var state: State = .off
    /// How many of the stream's sentences have a vector, and how many there are.
    private(set) var indexed = 0
    private(set) var total = 0

    @ObservationIgnored private var store: VectorStore?
    @ObservationIgnored private var folderPath = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var queued: (folder: NotesFolder, sentences: [Sentence], base: String, model: String)?
    /// Bumped by `reset()` and by a model or folder change; a drain from an earlier generation
    /// stops writing as soon as it notices.
    @ObservationIgnored private var generation = 0
    static let batch = 32
    /// How many nearest sentences a SIMILAR ranks; the page budget then cuts the page.
    static let top = 60

    /// SIMILAR can be offered: the model answered and there is a store with something in it.
    var available: Bool {
        switch state { case .idle, .indexing: return (store?.count ?? 0) > 0; default: return false }
    }

    var line: String {
        switch state {
        case .off: return "Off: no embedding model set (Settings → Reader)."
        case .checking: return "Checking the embedding model…"
        case let .unavailable(why): return "Not available: \(why)"
        case .idle, .indexing:
            let n = store?.count ?? 0
            let head = state == .indexing ? "Indexing" : "Indexed"
            return "\(head) \(min(n, total).formatted()) of \(total.formatted()) sentences for SIMILAR (\(store?.model ?? ""))"
        }
    }

    /// Called whenever the stream may have grown or the folder or model changed. Loads the
    /// store for this folder and model, then embeds what is missing in the background.
    func schedule(folder: NotesFolder, sentences: [Sentence], base: String, model: String) {
        total = sentences.count
        guard !model.isEmpty else { reset(); state = .off; return }
        if folder.root.path != folderPath || storeModel != model {
            generation += 1
            task?.cancel(); task = nil
            folderPath = folder.root.path
            storeModel = model
            store = VectorStore.load(from: folder, model: model)
            indexed = store?.count ?? 0
            state = .checking
        }
        queued = (folder, sentences, base, model)
        guard task == nil else { return }
        let mine = generation
        task = Task { [weak self] in
            await self?.drain(generation: mine)
            if let self, self.generation == mine { self.task = nil }
        }
    }

    /// The model the store (or the attempt at one) is for, kept apart from `store`, which is
    /// nil until the model has answered.
    @ObservationIgnored private var storeModel = ""

    private func drain(generation mine: Int) async {
        func stale() -> Bool { Task.isCancelled || generation != mine }
        func fail(_ error: Error) {
            guard !stale() else { return }
            if (error as? ReaderError)?.cancelled == true || error is CancellationError { return }
            state = .unavailable((error as? ReaderError)?.message ?? error.localizedDescription)
        }
        while let job = queued, !stale() {
            queued = nil
            let client = OllamaClient(base: job.base)
            // The model is proven once per folder-and-model by embedding one word.
            if store == nil {
                state = .checking
                do {
                    let probe = try await client.embed(model: job.model, texts: ["hello"])
                    guard !stale() else { return }
                    guard let dim = probe.first?.count, dim > 0 else { state = .unavailable("the model returned no vector"); return }
                    store = VectorStore(model: job.model, dim: dim)
                } catch { fail(error); return }
            }
            guard let current = store else { return }
            let missing = current.missing(in: job.sentences)
            let byN = Dictionary(job.sentences.compactMap { sent in Sentences.number(sent.id).map { ($0, sent.text) } }, uniquingKeysWith: { a, _ in a })
            state = missing.isEmpty ? .idle : .indexing
            var k = 0
            while k < missing.count, !stale() {
                let batch = Array(missing[k..<min(k + Self.batch, missing.count)])
                do {
                    let vectors = try await client.embed(model: job.model, texts: batch.map { byN[$0] ?? "" })
                    guard !stale() else { return }
                    guard vectors.count == batch.count else { state = .unavailable("the model returned \(vectors.count) vectors for \(batch.count) sentences"); return }
                    // Taken out of `store` while it grows, so the buffer is not copied each batch.
                    guard var s = store else { return }
                    store = nil
                    try s.append(zip(batch, vectors).map { ($0, $1) }, to: job.folder)
                    store = s
                    indexed = s.count
                } catch { fail(error); return }
                k += Self.batch
            }
            if !stale() { state = .idle }
        }
    }

    /// The SIMILAR move: the phrase embedded, ranked against the store, paged.
    func similar(_ phrase: String, offset: Int, base: String, model: String, sentences byId: [String: String], budget: Int, tokens: TokenEstimator) async throws -> (text: String, ids: [String]) {
        guard let store, store.count > 0 else { throw ReaderError("nothing is indexed yet") }
        let q = try await OllamaClient(base: base).embed(model: model, texts: [phrase])
        guard let v = q.first else { throw ReaderError("the embedding model returned nothing") }
        let hits = store.search(v, top: Self.top)
        return Asking.similarPage(phrase, hits: hits, sentences: byId, offset: offset, budget: budget, tokens: tokens)
    }

    /// The folder was reset or changed: forget the store (it is reloaded on the next schedule).
    func reset() { generation += 1; task?.cancel(); task = nil; queued = nil; store = nil; storeModel = ""; folderPath = ""; indexed = 0; state = .off }

    /// Something went wrong, as against off, checking or idle.
    var isUnavailable: Bool { if case .unavailable = state { return true }; return false }
}
