import Foundation

/// Lenient readers for the plain-text formats the model is asked to write. A small local model
/// gets a line-oriented format right far more often than a JSON object; and when it strays
/// (markdown bullets, bold, numbering, a stray heading) these readers still find the content.
public enum LensParse {
    public struct Entry: Codable, Equatable, Sendable {
        public var ids: [String]
        public var text: String
        public init(ids: [String], text: String) { self.ids = ids; self.text = text }
    }

    public struct LensOutput: Equatable, Sendable {
        public var entries: [Entry]
        public var notebook: String
    }

    /// The morning model's one action per reply.
    public enum Action: Equatable, Sendable {
        case open(file: String, offset: Int, why: String)
        case read(ids: [String], why: String)
        /// The sentences a word appears in, from the `offset`th match on.
        case find(word: String, offset: Int, why: String)
        /// The sentences nearest in meaning to a phrase, from the `offset`th on.
        case similar(phrase: String, offset: Int, why: String)
        case answer(text: String, evidence: [String], why: String, implied: Bool)
        case none(why: String)
    }

    static func clean(_ s: String) -> String { s.replacingOccurrences(of: "\r", with: "") }

    /// Strips bullet markers, numbering and emphasis (**bold**, `code`) from a line.
    static func unmark(_ line: String) -> String {
        var l = Substring(line.drop(while: { $0 == " " || $0 == "\t" }))
        if let f = l.first, f == "-" || f == "*" || f == "•" { l = l.dropFirst() }
        else {
            let digits = l.prefix(while: { $0.isNumber && $0.isASCII })
            if !digits.isEmpty, let after = l.dropFirst(digits.count).first, after == "." || after == ")" { l = l.dropFirst(digits.count + 1) }
        }
        var s = String(l).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
        while let f = s.first, f == "*" || f == "_" { s.removeFirst() }
        while let e = s.last, e == "*" || e == "_" { s.removeLast() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Lens output: `[s00012, s00013] what was found` lines, then everything after a line that is
    /// just NOTEBOOK (any case, with or without # or :) is the notebook.
    public static func lens(_ text: String) -> LensOutput {
        var entries: [Entry] = []
        var notebook: [String]? = nil
        for raw in clean(text).components(separatedBy: "\n") {
            if notebook != nil { notebook?.append(raw); continue }
            let l = unmark(raw)
            let bare = l.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces)
            let noColon = bare.hasSuffix(":") || bare.hasSuffix("：") ? String(bare.dropLast()).trimmingCharacters(in: .whitespaces) : bare
            if noColon.lowercased() == "notebook" { notebook = []; continue }
            guard let (idPart, body) = splitEntry(l) else { continue }
            let ids = Sentences.idList(idPart)
            let t = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !ids.isEmpty, !t.isEmpty { entries.append(Entry(ids: ids, text: t)) }
        }
        return LensOutput(entries: entries, notebook: (notebook ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// One reply written for several lenses at once: the text under each `=== <lens id> ===`
    /// header, by lens id. Headers are found leniently (`## ledger`, `**Ledger**`, `=== Ledger ===`,
    /// the lens id or its title, any case). With one lens and no header, the whole reply is its
    /// section. Text before the first header is ignored.
    public static func sections(_ text: String, lenses: [(id: String, title: String)]) -> [String: String] {
        var names: [String: String] = [:]
        for l in lenses {
            names[l.id.lowercased()] = l.id
            names[l.title.lowercased()] = l.id
        }
        func header(_ raw: String) -> String? {
            var l = raw.trimmingCharacters(in: .whitespaces)
            // A header has a marker: === ledger ===, ## ledger, **ledger**, [ledger], LENS ledger.
            // A bare word is not one, so a notebook line that happens to read "Threads:" stays put.
            guard let f = l.first, "=#*[".contains(f) || l.lowercased().hasPrefix("lens") else { return nil }
            let edge = CharacterSet(charactersIn: "=#*_:[]- \t")
            l = l.trimmingCharacters(in: edge)
            // "=== ledger === Ledger": the part before the inner marker.
            if let r = l.range(of: "===") ?? l.range(of: "==") { l = String(l[..<r.lowerBound]).trimmingCharacters(in: edge) }
            var low = l.lowercased()
            if low.hasPrefix("lens") { low = String(low.dropFirst(4)).trimmingCharacters(in: edge) }
            if let id = names[low] { return id }
            // "ledger (keeps a notebook)" or "ledger — Ledger"
            for sep in [" (", " —", " –", " - ", ":"] {
                if let r = low.range(of: sep), let id = names[String(low[..<r.lowerBound]).trimmingCharacters(in: edge)] { return id }
            }
            return nil
        }
        var out: [String: [String]] = [:]
        var current: String?
        for raw in clean(text).components(separatedBy: "\n") {
            if let id = header(raw) { current = id; out[id] = out[id] ?? []; continue }
            if let current { out[current]?.append(raw) }
        }
        if out.isEmpty, lenses.count == 1 { return [lenses[0].id: clean(text)] }
        return out.mapValues { $0.joined(separator: "\n") }
    }

    /// `[ids] body`, `(ids) body`, or `s1, s2 - body`.
    static func splitEntry(_ l: String) -> (String, String)? {
        let separators: Set<Character> = [":", "-", "–", "—"]
        if let open = l.first, open == "[" || open == "(" {
            let close: Character = open == "[" ? "]" : ")"
            guard let end = l.firstIndex(of: close) else { return nil }
            let ids = String(l[l.index(after: l.startIndex)..<end])
            var rest = Substring(l[l.index(after: end)...]).drop(while: { $0 == " " })
            if let f = rest.first, separators.contains(f) { rest = rest.dropFirst().drop(while: { $0 == " " }) }
            return (ids, String(rest))
        }
        // Bare ids: s12, s13 — body
        guard let f = l.first, f == "s" || f == "S" else { return nil }
        var i = l.startIndex
        var sawDigit = false
        while i < l.endIndex {
            let c = l[i]
            if c == "s" || c == "S" || c == "," || c == ";" || c == "/" || c == "&" || c == "+" || c == " " { i = l.index(after: i); continue }
            if c.isNumber, c.isASCII { sawDigit = true; i = l.index(after: i); continue }
            break
        }
        guard sawDigit, i < l.endIndex, separators.contains(l[i]) || l[i] == "." else { return nil }
        let ids = String(l[..<i])
        let body = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        return (ids, body)
    }

    /// A list of questions, one per line; numbering and bullets are stripped, headings skipped.
    public static func questions(_ text: String, max: Int) -> [String] {
        var out: [String] = []
        for raw in clean(text).components(separatedBy: "\n") {
            let l = unmark(raw)
            if l.isEmpty || raw.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            let low = l.lowercased()
            if low.hasPrefix("here are") || low == "questions" || low == "questions:" || low == "question" { continue }
            if l.count < 8 { continue }
            out.append(l)
            if max > 0, out.count >= max { break }
        }
        return out
    }

    /// Morning action: OPEN <file> [offset <n>] / READ <ids> / FIND <word> [offset <n>] / SIMILAR
    /// <phrase> [offset <n>] / ANSWER (text, then EVIDENCE:). A reply with no action word but
    /// with text is taken as an answer.
    public static func action(_ text: String) -> Action {
        let lines = clean(text).components(separatedBy: "\n")
        let stripped = lines.map(unmark)
        var why = ""
        for l in stripped { if let w = valueAfter(l, keys: ["why"]) { why = w; break } }
        for (i, l) in stripped.enumerated() {
            let low = l.lowercased()
            guard let kind = ["open", "read", "find", "similar", "answer"].first(where: { low.hasPrefix($0) }) else { continue }
            var rest = Substring(l.dropFirst(kind.count))
            if let f = rest.first, f.isLetter || f.isNumber { continue } // "opened", "readiness"
            rest = rest.drop(while: { $0 == " " || $0 == ":" || $0 == "：" })
            let restString = String(rest).trimmingCharacters(in: .whitespaces)
            switch kind {
            case "open":
                var file = restString
                var offset = 0
                let words = restString.split(separator: " ").map(String.init)
                for (k, w) in words.enumerated() {
                    let lw = w.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":="))
                    if lw == "offset" || lw == "@" || (lw == "line" && k > 0 && words[k - 1].lowercased() == "at"), k + 1 < words.count, let n = Int(words[k + 1].trimmingCharacters(in: CharacterSet(charactersIn: ":=,."))) { offset = n }
                    else if lw.hasPrefix("offset"), let n = Int(lw.drop(while: { !$0.isNumber })) { offset = n }
                    else if lw.hasPrefix("@"), let n = Int(lw.dropFirst()) { offset = n }
                }
                file = words.first ?? ""
                file = file.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`,"))
                if file.lowercased() == "offset" { file = "" }
                return .open(file: file, offset: offset, why: why)
            case "read":
                return .read(ids: Sentences.idList(restString), why: why)
            case "find", "similar":
                let words = restString.split(separator: " ").map(String.init)
                var offset = 0
                var term: [String] = []
                var k = 0
                while k < words.count {
                    let lw = words[k].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":="))
                    if lw == "offset" || lw == "@", k + 1 < words.count, let n = Int(words[k + 1].trimmingCharacters(in: CharacterSet(charactersIn: ":=,."))) { offset = n; k += 2; continue }
                    if lw.hasPrefix("offset"), let n = Int(lw.drop(while: { !$0.isNumber })) { offset = n; k += 1; continue }
                    if lw.hasPrefix("@"), let n = Int(lw.dropFirst()) { offset = n; k += 1; continue }
                    term.append(words[k]); k += 1
                }
                let word = term.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\"'`,“”‘’<>"))
                return kind == "find" ? .find(word: word, offset: offset, why: why) : .similar(phrase: word, offset: offset, why: why)
            default:
                var body: [String] = []
                var evidence: [String]? = nil
                let after = [restString] + Array(lines[(i + 1)...])
                for raw in after {
                    let u = unmark(raw)
                    if let ev = valueAfter(u, keys: ["evidence", "cites", "cite", "sources", "source", "ids"]) {
                        evidence = (evidence ?? []) + Sentences.idList(ev); continue
                    }
                    if valueAfter(u, keys: ["why"]) != nil { continue }
                    body.append(raw)
                }
                let answer = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                let ev = evidence.map { Array(NSOrderedSet(array: $0)) as! [String] } ?? Sentences.idList(answer)
                return .answer(text: answer, evidence: ev, why: why, implied: false)
            }
        }
        let answer = clean(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.isEmpty { return .none(why: why) }
        return .answer(text: answer, evidence: Sentences.idList(answer), why: why, implied: true)
    }

    /// "KEY: value" (any case) → value.
    static func valueAfter(_ line: String, keys: [String]) -> String? {
        let low = line.lowercased()
        for k in keys where low.hasPrefix(k) {
            let rest = line.dropFirst(k.count).drop(while: { $0 == " " })
            guard let f = rest.first, f == ":" || f == "：" else { continue }
            return String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
