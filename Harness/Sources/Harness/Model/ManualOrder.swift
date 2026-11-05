import Foundation

/// The list in the order you put it in, not the order things were recorded: what came from what,
/// what answers what. The order is a list of ids, top first, kept beside the recordings
/// (`order.json`). As everywhere in the list, the top is the latest: the story reads upwards, and
/// Copy All, export and the reader's stream follow the same order.
public enum ManualOrder {
    /// `recordings` in `order`. One the order doesn't know yet (new, imported, recovered) goes where
    /// its date puts it: above the first known recording older than it, so a new recording lands
    /// on top and an old file imported later lands among its own time.
    public static func apply(_ order: [UUID], to recordings: [Recording]) -> [Recording] {
        let byId = Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<UUID>()
        var result: [Recording] = []
        for id in order where !seen.contains(id) {
            if let r = byId[id] { result.append(r); seen.insert(id) }
        }
        let unknown = recordings.filter { !seen.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
        // Oldest first, so each later (newer) one lands above it when they share a neighbour.
        for r in unknown.reversed() {
            let at = result.firstIndex { $0.createdAt < r.createdAt } ?? result.count
            result.insert(r, at: at)
        }
        return result
    }

    /// The order with `ids` taken out and put back, in their present order, just above `target`
    /// (or at the bottom when `target` is nil or one of the moved ids).
    public static func move(_ ids: [UUID], in order: [UUID], before target: UUID?) -> [UUID] {
        let moving = Set(ids)
        let kept = order.filter { !moving.contains($0) }
        let moved = order.filter { moving.contains($0) } + ids.filter { !order.contains($0) }
        guard let target, !moving.contains(target), let at = kept.firstIndex(of: target) else { return kept + moved }
        var result = kept
        result.insert(contentsOf: moved, at: at)
        return result
    }

    /// The order after a drag in a list showing `shown` (the whole list, or what a search left):
    /// the rows at `offsets` dropped at `destination`, as SwiftUI's `onMove` reports it.
    public static func move(offsets: IndexSet, to destination: Int, shown: [UUID], in order: [UUID]) -> [UUID] {
        let ids = offsets.sorted().compactMap { shown.indices.contains($0) ? shown[$0] : nil }
        // The first row at or after the drop point that isn't itself moving.
        let target = shown.indices.contains(destination) ? shown[destination...].first { !ids.contains($0) } : nil
        if target == nil, let lastShown = shown.last(where: { !ids.contains($0) }), let after = order.firstIndex(of: lastShown) {
            // Dropped below the last row shown: just below it, not at the very end of everything hidden.
            let rest = order[(after + 1)...].first { !ids.contains($0) }
            return move(ids, in: order, before: rest)
        }
        return move(ids, in: order, before: target)
    }
}
