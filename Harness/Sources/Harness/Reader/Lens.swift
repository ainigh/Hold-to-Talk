import Foundation

/// One lens: one way of reading the stream, a chunk at a time, alongside every other lens.
/// `carry` means it keeps a notebook between chunks; `reads` lists lens ids whose current
/// notebooks it may see.
public struct Lens: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var on = true
    public var carry = false
    public var reads: [String] = []
    public var ignoreGoals = false
    public var title: String
    public var purpose: String = ""
    public var instructions: String = ""

    public init(id: String, on: Bool = true, carry: Bool = false, reads: [String] = [], ignoreGoals: Bool = false, title: String, purpose: String = "", instructions: String = "") {
        self.id = id; self.on = on; self.carry = carry; self.reads = reads; self.ignoreGoals = ignoreGoals
        self.title = title; self.purpose = purpose; self.instructions = instructions
    }

    // Old files may lack a field; every one has a default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
        carry = try c.decodeIfPresent(Bool.self, forKey: .carry) ?? false
        reads = try c.decodeIfPresent([String].self, forKey: .reads) ?? []
        ignoreGoals = try c.decodeIfPresent(Bool.self, forKey: .ignoreGoals) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        purpose = try c.decodeIfPresent(String.self, forKey: .purpose) ?? ""
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
    }

    /// The id of the lens whose entries are questions for the author, offered for answering by voice or by typing.
    public static let gapsId = "gaps"

    public static let questionsPurpose = "Questions about the author's goals (generated from them, plus any the author pinned), each answered from the notes with cited ids and refreshed as the stream grows. A first place to look, and a check on whether the notes can answer what the author cares about."

    /// A file-safe id from a title.
    public static func slug(_ title: String) -> String {
        var out = ""
        var dash = false
        for ch in title.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber { out.append(ch); dash = false }
            else if !dash, !out.isEmpty { out.append("-"); dash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "lens" : out
    }

    // The ledger deliberately ignores the goals so that things you didn't ask about stay findable.
    public static let defaults: [Lens] = [
        Lens(id: "ledger", carry: false, reads: [], ignoreGoals: true, title: "Ledger",
             purpose: "One line per sentence: what it is about, who or what it names, and what kind of sentence it is. The complete index; use it to check whether something is present at all.",
             instructions: """
             For EVERY sentence in the chunk, write exactly one entry with that sentence's single id. Do not skip any sentence and do not merge sentences. Do not summarize.
             Each entry: what the sentence is about in a few words; any person, place, project, thing or idea it names; and its kind, one of: statement, feeling, question, decision, rejection, plan, memory, aside.
             Example entry text: "the Kethra supplier missing deadlines; names: Kethra supplier; kind: statement"
             """),
        Lens(id: "people-and-things", carry: true, reads: [], title: "People and things",
             purpose: "A registry of every named person, place, project, thing and recurring idea, with aliases and the ids where each appears or something new is learned about it.",
             instructions: """
             Keep a registry of every person, place, project, thing, and recurring idea that is named or clearly referred to. Write an entry whenever something appears for the first time or something new is learned about it (a description, a relationship, a role, an alias like "that supplier" or "the app").
             Entry text: "<name> — <what was learned>" with the ids where it is shown.
             Notebook: a compact registry, one line per item: name — what it is — other ways it is referred to — ids where it appears. Resolve vague references ("that supplier", "the earlier idea") to registry names when the earlier text makes it clear; say "(unresolved)" when it does not.
             """),
        Lens(id: "threads", carry: true, reads: ["people-and-things"], title: "Threads and decisions",
             purpose: "What was decided, planned, or taken as current, and how each of those changed over the stream. History is kept with ids, not just the latest state.",
             instructions: """
             Track decisions, plans, positions and states of mind about anything, and how they change. A thread is one subject (the move, the logo colour, the hiring) and its sequence of states.
             Write an entry whenever a thread starts, changes, is reversed, or is dropped. Entry text: "<subject>: <old state> → <new state>" (or "starts as", "dropped") with the ids.
             Notebook: one line per live thread: subject — history as "state (id) → state (id) → ..." — current state. Keep the whole history, not only the latest value. Treat a musing ("maybe amber") as considered, not decided, unless the author commits.
             """),
        Lens(id: "feelings", carry: false, reads: ["people-and-things"], title: "Feelings",
             purpose: "Where the author expresses how they feel about something: the subject, the feeling, and the author's exact words, in stream order. Ambivalence is kept as ambivalence.",
             instructions: """
             Find every sentence where the author expresses or implies a feeling, mood, unease, excitement, doubt, relief, resentment, hope, dread, or similar, about anything.
             Entry text: "<subject> — <feeling in one or two words> — \\"<the author's exact phrase, quoted verbatim>\\"". Quote; do not paraphrase. If the feeling is mixed or contradictory, say so rather than picking one. Include feelings expressed in passing or as asides. Skip sentences with no feeling in them.
             """),
        Lens(id: "tensions", carry: true, reads: ["people-and-things", "threads"], title: "Tensions",
             purpose: "Places where later text disagrees with earlier text, where stated reasons conflict, or where the author argues with themselves. Each entry cites both sides.",
             instructions: """
             Look for contradictions and shifts: a later sentence that disagrees with an earlier one, a reason given for something that conflicts with another reason, a claim about a person that is later undercut, the author arguing both sides of something.
             Entry text: "<the two sides in one line each>" with the ids of BOTH sides. Only write an entry when you can cite both sides from the stream or from the notebook.
             Notebook: a short list of claims, positions and reasons worth watching for later contradiction, each with its id.
             """),
        Lens(id: "open-threads", carry: true, reads: ["threads"], title: "Open threads",
             purpose: "Things raised and never resolved: questions the author asked themselves, intentions never followed up, worries never settled. Resolved items are noted with the id that resolved them.",
             instructions: """
             Track things the author raises and leaves open: questions they ask themselves, things they mean to do or decide, worries they voice.
             Write an entry when something is opened ("open: <item>") and when something previously open is resolved or clearly abandoned ("resolved: <item> — <how>", citing the resolving ids).
             Notebook: the list of currently open items, each with the id where it was raised. Remove items when they are resolved.
             """),
        Lens(id: "against-the-goals", carry: true, reads: ["people-and-things", "threads"], title: "Against the goals",
             purpose: "Evidence that the author's stated goals or assumptions are wrong, unsupported, or already argued against by the author themselves. A deliberate counterweight to looking for what you expect to find.",
             instructions: """
             Read the author's goals and intent above as claims to be tested. Look for sentences that contradict them, that show the author once held the opposite view, that show an assumption behind a goal is unsupported, or that suggest a different question would be more useful than the one the author is asking.
             Entry text: "<which goal or assumption> — <what the stream shows instead>" with ids. Be specific and cite; do not invent disagreement where the text is silent.
             Notebook: for each goal, a one-line running verdict: supported / mixed / undercut, with the strongest ids either way.
             """),
        Lens(id: gapsId, carry: true, reads: ["people-and-things", "open-threads"], title: "Questions for you",
             purpose: "Questions the reader needed answered to understand the stream: who or what something is, what a vague reference points to, what happened next. The author answers them (by voice or by typing) and the answers join the stream, to be read like everything else.",
             instructions: """
             You are the reader who does not know what the author knows. Write a question wherever the stream assumes something you cannot find in the chunk or the notebooks: who a person is and how they relate to the author, what a project or place is, what a vague reference ("the thing with Mara", "the earlier plan") points to, what happened between two sentences, what the outcome of something was. Prefer questions whose answer would change how several sentences read. Ask for facts the author has and the text lacks, not for feelings or opinions. Lines that begin "Q:" followed by "A:" are the author's earlier answers; do not ask those again.
             Entry text: the question itself, one line, ending with a question mark, citing the ids that raised it. At most 3 per chunk; if the chunk raises nothing new, write [none].
             When a sentence in this chunk answers one of your earlier questions, write an entry "settled: <the earlier question, word for word>" citing the ids that answer it.
             Notebook: the open questions so far, one per line with ids, so that you do not ask the same thing twice; remove a question when a later sentence or an answer settles it.
             """),
    ]
}
