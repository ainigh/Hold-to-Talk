import Foundation
import Harness
import Observation

/// The word inventory of every item, made once per text off the main thread and kept until the
/// text changes, and added up for the stream (or whatever list is shown).
@MainActor
@Observable
final class WordsController {
    private struct Cached { var textHash: Int; var entries: [WordInventory.Entry] }
    @ObservationIgnored private var cache: [UUID: Cached] = [:]
    @ObservationIgnored private var pending: Set<UUID> = []
    /// The last list added up, so a redraw that asks for the same items costs nothing.
    @ObservationIgnored private var aggregate: (ids: [UUID], version: Int, result: (entries: [WordInventory.Entry], pending: Int))?
    /// Bumped when an inventory lands, so views that add them up recompute.
    private(set) var version = 0

    /// The inventory of one item, or nil while it is being made (then it lands and `version` moves).
    func inventory(of r: Recording) -> [WordInventory.Entry]? {
        if let c = cache[r.id], c.textHash == r.text.hashValue { return c.entries }
        request(r)
        return nil
    }

    /// The items' inventories added up; items not yet made are requested and counted once they land.
    func inventory(of items: [Recording]) -> (entries: [WordInventory.Entry], pending: Int) {
        let ids = items.map(\.id)
        if let a = aggregate, a.ids == ids, a.version == version, a.result.pending == 0, items.allSatisfy({ cache[$0.id]?.textHash == $0.text.hashValue || $0.text.isEmpty }) { return a.result }
        var made: [[WordInventory.Entry]] = []
        var waiting = 0
        for r in items where !r.text.isEmpty {
            if let inv = inventory(of: r) { made.append(inv) } else { waiting += 1 }
        }
        let result = (WordInventory.aggregate(made), waiting)
        aggregate = (ids, version, result)
        return result
    }

    private func request(_ r: Recording) {
        guard !r.text.isEmpty, !pending.contains(r.id) else { return }
        pending.insert(r.id)
        let id = r.id, text = r.text, hash = r.text.hashValue
        Task.detached(priority: .utility) {
            let tagged = WordTagger.tag(text)
            let entries = WordInventory.inventory(of: tagged, item: id.uuidString)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cache[id] = Cached(textHash: hash, entries: entries)
                self.pending.remove(id)
                self.version += 1
            }
        }
    }

    func forget(_ id: UUID) { cache[id] = nil }
}
