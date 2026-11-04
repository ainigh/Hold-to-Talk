import Foundation

/// One numbered sentence of the stream. Ids are opaque positions: s00001, s00002, ...
public struct Sentence: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

/// Turns the raw stream into numbered sentences, and reads them back.
public enum Sentences {
    public static let idWidth = 5
    /// A sentence longer than this is wrapped at a word boundary so no single sentence outgrows a window.
    static let maxSentenceChars = 1200

    public static func makeId(_ n: Int) -> String {
        let digits = String(n)
        return "s" + String(repeating: "0", count: max(0, idWidth - digits.count)) + digits
    }

    /// Normalises an id a model wrote ("s42", "S0042", " s00042 ") to the canonical width; nil if it is not an id.
    public static func normId(_ raw: String) -> String? {
        var s = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if let first = s.first, first == "s" || first == "S" { s = s.dropFirst() }
        guard !s.isEmpty, s.count <= 8, s.allSatisfy(\.isNumber), let n = Int(s) else { return nil }
        return makeId(n)
    }

    /// Every id-like token in a string, in order, without repeats.
    public static func idList(_ s: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var digits = ""
        var sawS = false
        func flush() {
            if !digits.isEmpty, digits.count <= 7, let n = Int(digits) {
                let id = makeId(n)
                if !seen.contains(id) { seen.insert(id); out.append(id) }
            }
            digits = ""; sawS = false
        }
        for ch in s {
            if ch.isNumber, ch.isASCII { digits.append(ch); continue }
            flush()
            sawS = ch == "s" || ch == "S"
        }
        flush()
        _ = sawS
        return out
    }

    static func wrapLong(_ s: String) -> [String] {
        guard s.count > maxSentenceChars else { return [s] }
        var out: [String] = []
        var rest = Substring(s)
        while rest.count > maxSentenceChars {
            let limit = rest.index(rest.startIndex, offsetBy: maxSentenceChars)
            var cut = rest[..<limit].lastIndex(of: " ") ?? limit
            if rest.distance(from: rest.startIndex, to: cut) < maxSentenceChars / 2 { cut = limit }
            out.append(rest[..<cut].trimmingCharacters(in: .whitespaces))
            rest = rest[cut...].drop(while: { $0 == " " })
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    /// Splits on sentence punctuation and line breaks; ids continue from `startIndex`.
    public static func split(_ text: String, startIndex: Int = 0) -> [Sentence] {
        var pieces: [String] = []
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for para in normalised.split(separator: "\n", omittingEmptySubsequences: true) {
            let p = para.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            for s in splitSentences(p) {
                let t = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !t.isEmpty { pieces.append(contentsOf: wrapLong(t)) }
            }
        }
        return pieces.enumerated().map { Sentence(id: makeId(startIndex + $0.offset + 1), text: $0.element) }
    }

    /// `(?<=[.!?…]["'”’)\]]?)\s+(?=\S)` by hand: a break after terminal punctuation (and an optional closing quote or bracket) followed by whitespace.
    static func splitSentences(_ p: String) -> [String] {
        let chars = Array(p)
        var out: [String] = []
        var current = ""
        var i = 0
        let terminal: Set<Character> = [".", "!", "?", "…"]
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]"]
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            if c.isWhitespace, i + 1 < chars.count, !chars[i + 1].isWhitespace {
                // Look back past the whitespace run.
                var j = i - 1
                while j >= 0, chars[j].isWhitespace { j -= 1 }
                if j >= 0 {
                    var k = j
                    if closers.contains(chars[k]) { k -= 1 }
                    if k >= 0, terminal.contains(chars[k]) {
                        out.append(current.trimmingCharacters(in: .whitespaces))
                        current = ""
                    }
                }
            }
            i += 1
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { out.append(last) }
        return out
    }

    /// Reads `sentences.txt`: one `id<TAB>text` per line.
    public static func parse(_ text: String) -> [Sentence] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let tab = line.firstIndex(of: "\t") else {
                let id = line.trimmingCharacters(in: .whitespaces)
                return isId(id) ? Sentence(id: id, text: "") : nil
            }
            let id = String(line[..<tab])
            return isId(id) ? Sentence(id: id, text: String(line[line.index(after: tab)...])) : nil
        }
    }

    static func isId(_ s: String) -> Bool { s.count > 1 && s.first == "s" && s.dropFirst().allSatisfy { $0.isNumber && $0.isASCII } }

    public static func format(_ sentences: [Sentence]) -> String {
        sentences.map { $0.id + "\t" + $0.text }.joined(separator: "\n") + "\n"
    }
}
