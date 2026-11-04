import Foundation

/// Keeps your edits when the machine's transcript is replaced (Re-transcribe, a better model).
///
/// Your text is a list of changes to the old machine text (words deleted, inserted, replaced);
/// each change is placed in the new machine text at the words that correspond to the old ones,
/// found by aligning the two machine texts word by word. A change whose place no longer exists
/// (the new transcript heard those words differently) is kept anyway, at the nearest place, so
/// nothing you typed is lost.
public enum TranscriptMerge {
    /// `edits` is your text, made from `old`; returns it made from `new` instead.
    public static func reapply(edits: String, from old: String, onto new: String) -> String {
        if old == new { return edits }
        if edits == old { return new }
        let oldWords = tokens(old), userWords = tokens(edits), newWords = tokens(new)
        // Where each old word went in the new text (nil: not there any more).
        let mapping = align(oldWords.map(\.key), newWords.map(\.key))
        // The user's text as operations on the old words.
        let ops = diff(oldWords.map(\.key), userWords.map(\.key))

        var out: [Token] = []
        var newIndex = 0
        // Emits the new words up to (not including) `limit`.
        func catchUp(to limit: Int) {
            while newIndex < limit, newIndex < newWords.count {
                out.append(newWords[newIndex])
                newIndex += 1
            }
        }
        // The new position of old word `i`, or of the next old word that is still there.
        func place(_ i: Int) -> Int {
            var j = i
            while j < mapping.count {
                if let p = mapping[j] { return p }
                j += 1
            }
            return newWords.count
        }
        for op in ops {
            switch op {
            case let .keep(oldI, _):
                if let p = mapping[oldI], p >= newIndex { catchUp(to: p + 1) }
            case let .delete(oldI):
                if let p = mapping[oldI] {
                    // Emit everything before it, then skip it.
                    if p >= newIndex {
                        catchUp(to: p)
                        newIndex = p + 1
                    }
                }
            case let .insert(before: oldI, userI):
                let p = place(oldI)
                // Your correction may be what the new transcript heard this time ("wrld" fixed to
                // "world", and now it says "world"): then the new word stands, not a second copy.
                if let same = (newIndex..<min(p, newWords.count)).first(where: { newWords[$0].key == userWords[userI].key }) {
                    catchUp(to: same + 1)
                } else {
                    catchUp(to: p)
                    out.append(userWords[userI])
                }
            }
        }
        catchUp(to: newWords.count)
        return render(out)
    }

    // MARK: - Tokens

    struct Token: Equatable {
        /// The word with its punctuation, as written.
        let text: String
        /// What it is compared by: lowercased, no punctuation.
        let key: String
        /// The whitespace before it ("" for the first; "\n\n" keeps a paragraph).
        let gap: String
    }

    static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var gap = ""
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            let key = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            result.append(Token(text: word, key: key.isEmpty ? word : key, gap: gap))
            word = ""
            gap = ""
        }
        for ch in text {
            if ch.isWhitespace {
                if !word.isEmpty { flush() }
                gap.append(ch)
            } else {
                word.append(ch)
            }
        }
        flush()
        return result
    }

    static func render(_ tokens: [Token]) -> String {
        var out = ""
        for (i, t) in tokens.enumerated() {
            if i > 0 {
                // A paragraph break on either side of the join is kept; else one space.
                out += t.gap.contains("\n\n") ? "\n\n" : (t.gap.contains("\n") ? "\n" : " ")
            }
            out += t.text
        }
        return out
    }

    // MARK: - Diff

    enum Op: Equatable {
        case keep(Int, Int)
        case delete(Int)
        /// A user word that goes before old word `before` (`before == old.count`: at the end).
        case insert(before: Int, Int)
    }

    /// The edit script from `a` to `b`, by longest common subsequence.
    static func diff(_ a: [String], _ b: [String]) -> [Op] {
        let pairs = lcs(a, b)
        var ops: [Op] = []
        var i = 0, j = 0
        for (ai, bj) in pairs {
            while i < ai { ops.append(.delete(i)); i += 1 }
            while j < bj { ops.append(.insert(before: ai, j)); j += 1 }
            ops.append(.keep(ai, bj))
            i = ai + 1
            j = bj + 1
        }
        while i < a.count { ops.append(.delete(i)); i += 1 }
        while j < b.count { ops.append(.insert(before: a.count, j)); j += 1 }
        return ops
    }

    /// For each word of `a`, its index in `b` when the alignment keeps it.
    static func align(_ a: [String], _ b: [String]) -> [Int?] {
        var mapping = [Int?](repeating: nil, count: a.count)
        for (ai, bj) in lcs(a, b) { mapping[ai] = bj }
        return mapping
    }

    /// The matched pairs of a longest common subsequence, in order. Quadratic in memory on
    /// the two lengths; transcripts of some thousand words are fine.
    static func lcs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        // Trim what both share at the ends: the common case is a small change in a long text.
        var head = 0
        while head < n, head < m, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < n - head, tail < m - head, a[n - 1 - tail] == b[m - 1 - tail] { tail += 1 }
        let an = n - head - tail, bm = m - head - tail
        var pairs = (0..<head).map { ($0, $0) }
        if an > 0, bm > 0 {
            var table = [Int32](repeating: 0, count: (an + 1) * (bm + 1))
            let w = bm + 1
            for i in stride(from: an - 1, through: 0, by: -1) {
                for j in stride(from: bm - 1, through: 0, by: -1) {
                    table[i * w + j] = a[head + i] == b[head + j]
                        ? table[(i + 1) * w + j + 1] + 1
                        : max(table[(i + 1) * w + j], table[i * w + j + 1])
                }
            }
            var i = 0, j = 0
            while i < an, j < bm {
                if a[head + i] == b[head + j] {
                    pairs.append((head + i, head + j))
                    i += 1
                    j += 1
                } else if table[(i + 1) * w + j] >= table[i * w + j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
        }
        pairs += (0..<tail).map { (n - tail + $0, m - tail + $0) }
        return pairs
    }
}
