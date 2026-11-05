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
        guard !model.isEmpty else { state = .off; store = nil; task?.cancel(); task = nil; return }
        if folder.root.path != folderPath || store?.model != model {
            folderPath = folder.root.path
            store = VectorStore.load(from: folder, model: model)
            indexed = store?.count ?? 0
        }
        queued = (folder, sentences, base, model)
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.drain()
            self?.task = nil
        }
    }

    private func drain() async {
        while let job = queued {
            queued = nil
            if state == .off || state == .checking || { if case .unavailable = state { return true }; return false }() { state = .checking }
            let client = OllamaClient(base: job.base)
            // The model is proven once per folder-and-model by embedding one word.
            if store == nil || !(state == .idle || state == .indexing) {
                do {
                    let probe = try await client.embed(model: job.model, texts: ["hello"])
                    guard let dim = probe.first?.count, dim > 0 else { state = .unavailable("the model returned no vector"); return }
                    if store == nil || store?.dim != dim { store = VectorStore(model: job.model, dim: dim) }
                } catch {
                    state = .unavailable((error as? ReaderError)?.message ?? error.localizedDescription)
                    return
                }
            }
            guard var s = store else { return }
            let missing = s.missing(in: job.sentences)
            let byN = Dictionary(job.sentences.compactMap { sent in Sentences.number(sent.id).map { ($0, sent.text) } }, uniquingKeysWith: { a, _ in a })
            state = missing.isEmpty ? .idle : .indexing
            var k = 0
            while k < missing.count, !Task.isCancelled {
                let batch = Array(missing[k..<min(k + 32, missing.count)])
                do {
                    let vectors = try await client.embed(model: job.model, texts: batch.map { byN[$0] ?? "" })
                    guard vectors.count == batch.count else { state = .unavailable("the model returned \(vectors.count) vectors for \(batch.count) sentences"); return }
                    try s.append(zip(batch, vectors).map { ($0, $1) }, to: job.folder)
                    store = s
                    indexed = s.count
                } catch {
                    state = .unavailable((error as? ReaderError)?.message ?? error.localizedDescription)
                    return
                }
                k += 32
            }
            state = .idle
        }
    }

    /// The SIMILAR move: the phrase embedded, ranked against the store, paged.
    func similar(_ phrase: String, offset: Int, base: String, model: String, sentences byId: [String: String], budget: Int, tokens: TokenEstimator) async throws -> (text: String, ids: [String]) {
        guard let store, store.count > 0 else { throw ReaderError("nothing is indexed yet") }
        let q = try await OllamaClient(base: base).embed(model: model, texts: [phrase])
        guard let v = q.first else { throw ReaderError("the embedding model returned nothing") }
        let hits = store.search(v, top: 60)
        return Asking.similarPage(phrase, hits: hits, sentences: byId, offset: offset, budget: budget, tokens: tokens)
    }

    /// The folder was reset or changed: forget the store (it is reloaded on the next schedule).
    func reset() { store = nil; folderPath = ""; indexed = 0; state = .off; task?.cancel(); task = nil; queued = nil }
}
