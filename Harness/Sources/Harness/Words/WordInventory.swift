import Foundation

/// The words of a text that carry its meaning: every word that is not a closed-class word (a
/// preposition, pronoun, determiner, conjunction, auxiliary, particle, number), which leaves
/// the nouns, verbs, adjectives and adverbs, each counted and kept with the kind it was used
/// as. One pass per item; the stream's inventory is the items' added up. The tagging itself is
/// the caller's (the app uses Apple's NaturalLanguage, with lemmas); `WordInventory.tag` is a
/// plain fallback that knows the closed classes by list, so the harness can test the rest.
public enum WordInventory {
    /// A word as tagged: its lemma (lowercased), the kind it was used as, and the surface form.
    public struct Tagged: Equatable, Sendable {
        public var lemma: String
        public var kind: Kind
        public var surface: String
        public init(lemma: String, kind: Kind, surface: String) { self.lemma = lemma; self.kind = kind; self.surface = surface }
    }

    /// The open classes, and `other` for an open-class word whose kind the tagger could not tell.
    public enum Kind: String, Codable, CaseIterable, Sendable, Comparable {
        case noun, verb, adjective, adverb, other
        public static func < (a: Kind, b: Kind) -> Bool { a.order < b.order }
        private var order: Int { Kind.allCases.firstIndex(of: self) ?? 0 }
        public var title: String {
            switch self {
            case .noun: "Nouns"
            case .verb: "Verbs"
            case .adjective: "Adjectives"
            case .adverb: "Adverbs"
            case .other: "Other"
            }
        }
        public var single: String {
            switch self {
            case .noun: "noun"
            case .verb: "verb"
            case .adjective: "adjective"
            case .adverb: "adverb"
            case .other: "other"
            }
        }
    }

    /// One word of the inventory: how often, as what, and in which items.
    public struct Entry: Equatable, Sendable, Identifiable {
        public var lemma: String
        public var count: Int
        /// How often as each kind; the most frequent is `kind`.
        public var kinds: [Kind: Int]
        /// The items it appears in (whatever ids the caller passed), with its count in each.
        public var items: [String: Int]
        /// The forms it was written as ("went", "going" under "go"), with their counts, so a
        /// search for the word can use what is actually in the text.
        public var forms: [String: Int] = [:]
        public var id: String { lemma }
        /// The form written most often.
        public var commonForm: String { forms.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? lemma }
        public var kind: Kind { kinds.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? .other }
    }

    /// The inventory of one item: its tagged words counted by lemma.
    public static func inventory(of words: [Tagged], item: String) -> [Entry] {
        var by: [String: Entry] = [:]
        for w in words {
            let key = w.lemma.lowercased()
            guard !key.isEmpty else { continue }
            var e = by[key] ?? Entry(lemma: key, count: 0, kinds: [:], items: [:])
            e.count += 1
            e.kinds[w.kind, default: 0] += 1
            e.items[item, default: 0] += 1
            e.forms[w.surface.lowercased(), default: 0] += 1
            by[key] = e
        }
        return sorted(Array(by.values))
    }

    /// Several items' inventories added up.
    public static func aggregate(_ inventories: [[Entry]]) -> [Entry] {
        var by: [String: Entry] = [:]
        for inv in inventories {
            for e in inv {
                var t = by[e.lemma] ?? Entry(lemma: e.lemma, count: 0, kinds: [:], items: [:])
                t.count += e.count
                for (k, n) in e.kinds { t.kinds[k, default: 0] += n }
                for (i, n) in e.items { t.items[i, default: 0] += n }
                for (f, n) in e.forms { t.forms[f, default: 0] += n }
                by[e.lemma] = t
            }
        }
        return sorted(Array(by.values))
    }

    /// Most frequent first; ties alphabetical.
    public static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { $0.count != $1.count ? $0.count > $1.count : $0.lemma < $1.lemma }
    }

    // MARK: - The fallback tagger

    /// English closed-class words: what the inventory leaves out. Prepositions, pronouns,
    /// determiners, conjunctions, auxiliaries and modals, particles, numbers and a few
    /// discourse words. Not exhaustive; the app's tagger knows the classes properly.
    public static let closedClass: Set<String> = Set("""
    a an the this that these those my your his her its our their some any each every either neither no
    i me you he him she it we us they them myself yourself himself herself itself ourselves themselves
    who whom whose which what where when why how whoever whatever whichever
    of in on at to for with by from about as into like through after over between out against during
    without before under around among across behind beyond above below off up down near toward towards
    upon within along past since until unless than via per onto
    and or but nor so yet both either because although though while if then whether once
    be am is are was were been being have has had having do does did doing
    will would shall should can could may might must ought
    not no yes nope yeah okay ok oh um uh hmm mm well just also too very really quite rather
    there here now then
    one two three four five six seven eight nine ten hundred thousand million first second third
    's 'm 're 've 'll 'd n't
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// A plain tagging: words split on whitespace and punctuation, lowercased, the closed classes
    /// dropped, kind `other` throughout. The app replaces this with a real tagger.
    public static func tag(_ text: String) -> [Tagged] {
        var out: [Tagged] = []
        var word = ""
        func flush() {
            let w = word.lowercased()
            word = ""
            guard !w.isEmpty, w.count > 1 || w == "i", !closedClass.contains(w), w.first?.isNumber != true else { return }
            out.append(Tagged(lemma: w, kind: .other, surface: w))
        }
        for ch in text {
            if ch.isLetter || ch == "'" || ch == "’" || ch == "-" { word.append(ch == "’" ? "'" : ch) } else { flush() }
        }
        flush()
        return out
    }
}
