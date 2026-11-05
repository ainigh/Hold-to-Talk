import Foundation

/// Starting over without losing anything for good: what is reset goes to the Trash in one dated
/// folder; moving what is in that folder back where it was undoes it.
enum StartOver {
    /// Gathers the `items` that exist into one folder named `name` and the time, inside `parent`,
    /// then moves that folder to the Trash. Returns where it ended up: in the Trash, or left in
    /// `parent` when the Trash refused it (a folder on another volume, say). Nil when there was nothing.
    static func trash(_ items: [URL], named name: String, in parent: URL) throws -> URL? {
        let fm = FileManager.default
        let present = items.filter { fm.fileExists(atPath: $0.path) }
        guard !present.isEmpty else { return nil }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let bundle = parent.appendingPathComponent("\(name) \(stamp.string(from: Date()))")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        for u in present { try fm.moveItem(at: u, to: bundle.appendingPathComponent(u.lastPathComponent)) }
        var result: NSURL?
        do {
            try fm.trashItem(at: bundle, resultingItemURL: &result)
            return (result as URL?) ?? bundle
        } catch {
            return bundle
        }
    }

    /// Says where a reset put things, for the alert afterwards.
    static func whereItWent(_ url: URL?) -> String {
        guard let url else { return "There was nothing to move." }
        return url.path.contains("/.Trash/") ? "It is in the Trash as “\(url.lastPathComponent)”." : "It was moved to \(url.path) (the Trash refused it)."
    }
}
