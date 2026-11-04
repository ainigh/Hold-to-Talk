import Foundation

/// Text the window shows and copies.
public enum TranscriptText {
    /// A row's title: the first 60 characters of the first non-empty line, or what the status
    /// says while there is no text yet.
    public static func title(_ text: String, status: Recording.Status = .final, limit: Int = 60) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        if line.isEmpty {
            switch status {
            case .recording: return "Recording…"
            case .transcribing: return "Transcribing…"
            case .failed: return "Transcription failed"
            case .final: return "Empty recording"
            }
        }
        guard line.count > limit else { return line }
        let cut = line.prefix(limit)
        // Back to the last space so a word isn't cut in two (unless that loses most of it).
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    /// Copy all: every recording's text, newest first, each under a line with its date and time,
    /// separated by a blank line. `headers: false` drops the date lines.
    public static func copyAll(_ recordings: [Recording], headers: Bool = true, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let sorted = recordings.sorted { $0.createdAt > $1.createdAt }
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return sorted.map { r in
            let body = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return headers ? "\(formatter.string(from: r.createdAt))\n\(body)" : body
        }.joined(separator: "\n\n")
    }

    /// Light cleanup of a machine transcript: one space between words, paragraphs kept, and
    /// filler words out when asked (off by default: "um" sometimes carries meaning).
    public static func clean(_ text: String, removeFillers: Bool = false) -> String {
        var lines = text.components(separatedBy: "\n").map { line in
            line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
        if removeFillers {
            lines = lines.map(stripFillers)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let fillers: Set<String> = ["um", "uh", "umm", "uhh", "erm", "hmm", "mm", "mhm"]

    static func stripFillers(_ line: String) -> String {
        let words = line.split(separator: " ").filter { word in
            let bare = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
            return !fillers.contains(bare)
        }
        return words.joined(separator: " ")
    }

    /// The transcriber's bias prompt from the vocabulary list: one line of the terms, so names
    /// and jargon are spelt the way you write them.
    public static func vocabularyPrompt(_ vocabulary: [String]) -> String {
        let terms = vocabulary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return "" }
        return terms.joined(separator: ", ") + "."
    }

    /// Joins the transcriber's segments into paragraphs: a pause of more than `gap` seconds
    /// between two segments starts a new paragraph.
    public static func join(_ segments: [Recording.Segment], paragraphGap gap: TimeInterval = 2) -> String {
        var out = ""
        var previousEnd: TimeInterval?
        for s in segments {
            let text = s.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if out.isEmpty {
                out = text
            } else if let previousEnd, s.start - previousEnd > gap {
                out += "\n\n" + text
            } else {
                out += " " + text
            }
            previousEnd = s.end
        }
        return out
    }

    /// `m:ss` (or `h:mm:ss`) for the list and the HUD.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
