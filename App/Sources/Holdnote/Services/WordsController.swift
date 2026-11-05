import Foundation
import Harness
import Observation

/// The word inventory of every item, made once per text off the main thread and kept until the
/// text changes, and added up for the stream (or whatever list is shown).
@MainActor
@Observable
final class WordsController {
    private struct Cached { var textCount: Int; var entries: [WordInventory.Entry] }
    @ObservationIgnored private var cache: [UUID: Cached] = [:]
    @ObservationIgnored private var pending: Set<UUID> = []
    /// Bumped when an inventory lands, so views that add them up recompute.
    private(set) var version = 0

    /// The inventory of one item, or nil while it is being made (then it lands and `version` moves).
    func inventory(of r: Recording) -> [WordInventory.Entry]? {
        if let c = cache[r.id], c.textCount == r.text.count { return c.entries }
        request(r)
        return nil
    }

    /// The items' inventories added up; items not yet made are requested and counted once they land.
    func inventory(of items: [Recording]) -> (entries: [WordInventory.Entry], pending: Int) {
        var made: [[WordInventory.Entry]] = []
        var waiting = 0
        for r in items where !r.text.isEmpty {
            if let inv = inventory(of: r) { made.append(inv) } else { waiting += 1 }
        }
        return (WordInventory.aggregate(made), waiting)
    }

    private func request(_ r: Recording) {
        guard !r.text.isEmpty, !pending.contains(r.id) else { return }
        pending.insert(r.id)
        let id = r.id, text = r.text
        Task.detached(priority: .utility) {
            let tagged = WordTagger.tag(text)
            let entries = WordInventory.inventory(of: tagged, item: id.uuidString)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cache[id] = Cached(textCount: text.count, entries: entries)
                self.pending.remove(id)
                self.version += 1
            }
        }
    }

    func forget(_ id: UUID) { cache[id] = nil }
}
