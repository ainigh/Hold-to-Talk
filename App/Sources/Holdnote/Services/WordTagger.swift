import Foundation
import Harness
import NaturalLanguage

/// Tags a text's words with Apple's NaturalLanguage: lemma and lexical class, so the inventory
/// counts "moved", "moving" and "move" as one verb and leaves out the closed classes
/// (prepositions, pronouns, determiners, conjunctions, particles, numbers). Pure; runs off the
/// main thread. Falls back to the harness's list-based tagger when the language is unknown to
/// the tagger.
enum WordTagger {
    static func tag(_ text: String) -> [WordInventory.Tagged] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .omitOther, .joinContractions]
        var out: [WordInventory.Tagged] = []
        var sawAClass = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: options) { tag, range in
            guard let tag else { return true }
            sawAClass = true
            let kind: WordInventory.Kind?
            switch tag {
            case .noun: kind = .noun
            case .verb: kind = .verb
            case .adjective: kind = .adjective
            case .adverb: kind = .adverb
            case .interjection, .otherWord: kind = .other
            default: kind = nil // preposition, pronoun, determiner, conjunction, particle, number, classifier, idiom
            }
            guard let kind else { return true }
            let surface = String(text[range])
            guard surface.count > 1 || surface.lowercased() == "i" else { return true }
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue ?? surface
            let key = lemma.lowercased()
            // The tagger calls a few closed-class words "other"; the list catches them.
            guard !WordInventory.closedClass.contains(key) else { return true }
            out.append(WordInventory.Tagged(lemma: key, kind: kind, surface: surface))
            return true
        }
        return sawAClass ? out : WordInventory.tag(text)
    }
}
