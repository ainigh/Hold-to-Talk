import XCTest
@testable import Harness

/// A model that answers from a script: the next reply for every call, in order, or by matching the label.
final class FakeModel: ChatModel, @unchecked Sendable {
    var replies: [String] = []
    var answer: (ChatRequest) -> String = { _ in "" }
    var calls: [ChatRequest] = []
    private let lock = NSLock()
    init() {}
    private func take(_ request: ChatRequest) -> String {
        lock.lock(); defer { lock.unlock() }
        calls.append(request)
        return replies.isEmpty ? answer(request) : replies.removeFirst()
    }
    func chat(_ request: ChatRequest, config: ReaderConfig) async throws -> ChatReply {
        let text = take(request)
        request.onToken?(text, "")
        return ChatReply(text: text, promptTokens: (request.system.count + request.user.count) / 4, outTokens: text.count / 4, ms: 10)
    }
}

final class ReaderTests: XCTestCase {
    func temp() throws -> NotesFolder {
        try NotesFolder(root: FileManager.default.temporaryDirectory.appendingPathComponent("reader-test-\(UUID().uuidString)"))
    }

    func testIdsAndSplitting() {
        XCTAssertEqual(Sentences.makeId(42), "s00042")
        XCTAssertEqual(Sentences.normId(" S0042 "), "s00042")
        XCTAssertEqual(Sentences.normId("s42"), "s00042")
        XCTAssertNil(Sentences.normId("x42"))
        XCTAssertEqual(Sentences.idList("s00012, s13 and 7"), ["s00012", "s00013", "s00007"])
        let s = Sentences.split("First one. Second one!  Third?\n\nA \"quoted.\" Then more… and the end", startIndex: 2)
        XCTAssertEqual(s.map(\.id), ["s00003", "s00004", "s00005", "s00006", "s00007", "s00008"])
        XCTAssertEqual(s[0].text, "First one.")
        XCTAssertEqual(s[3].text, "A \"quoted.\"")
        XCTAssertEqual(s[5].text, "and the end")
        XCTAssertEqual(Sentences.split("e.g. nothing").count, 2)
        let long = String(repeating: "word ", count: 400)
        XCTAssertGreaterThan(Sentences.split(long).count, 1)
        let text = Sentences.format(s)
        XCTAssertEqual(Sentences.parse(text), s)
    }

    func testLensParsing() {
        let out = LensParse.lens("""
        Here are the entries:
        - [s00001] the move to Lisbon; names: Lisbon; kind: plan
        **[s00002, s00003]** - ambivalence about the move
        (s4) in parens
        s5, s6 — bare ids
        1. [s7]: numbered
        [none] nothing else
        ## NOTEBOOK:
        Lisbon — city — s00001
        more
        """)
        XCTAssertEqual(out.entries.map(\.ids), [["s00001"], ["s00002", "s00003"], ["s00004"], ["s00005", "s00006"], ["s00007"]])
        XCTAssertEqual(out.entries[1].text, "ambivalence about the move")
        XCTAssertEqual(out.notebook, "Lisbon — city — s00001\nmore")
        XCTAssertEqual(LensParse.questions("Here are the questions:\n1. What is Kethra?\n- short\n\nWhere did the plan go?", max: 5), ["What is Kethra?", "Where did the plan go?"])
    }

    func testActionParsing() {
        if case let .open(file, offset, why) = LensParse.action("OPEN lenses/ledger.md offset 40\nWHY: the index") {
            XCTAssertEqual(file, "lenses/ledger.md"); XCTAssertEqual(offset, 40); XCTAssertEqual(why, "the index")
        } else { XCTFail() }
        if case let .open(file, offset, _) = LensParse.action("**Open:** `questions.md` @12") {
            XCTAssertEqual(file, "questions.md"); XCTAssertEqual(offset, 12)
        } else { XCTFail() }
        if case let .read(ids, _) = LensParse.action("READ s00012 s00013, s14") { XCTAssertEqual(ids, ["s00012", "s00013", "s00014"]) } else { XCTFail() }
        if case let .answer(text, ev, _, implied) = LensParse.action("ANSWER\nYou kept circling back.\nMore here.\nEVIDENCE: s00001, s00002") {
            XCTAssertEqual(text, "You kept circling back.\nMore here."); XCTAssertEqual(ev, ["s00001", "s00002"]); XCTAssertFalse(implied)
        } else { XCTFail() }
        if case let .answer(text, ev, _, implied) = LensParse.action("You seem unsure (s00005).") {
            XCTAssertEqual(text, "You seem unsure (s00005)."); XCTAssertEqual(ev, ["s00005"]); XCTAssertTrue(implied)
        } else { XCTFail() }
        if case .none = LensParse.action("  \n") {} else { XCTFail() }
        // "opened" is not OPEN.
        if case .answer = LensParse.action("opened the file") {} else { XCTFail() }
    }

    func testStreamAppendAndFeed() throws {
        let f = try temp()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let a = try ReaderStream.append("One. Two.", to: f)
        XCTAssertEqual(a.map(\.id), ["s00001", "s00002"])
        let b = try ReaderStream.append("Three.", to: f)
        XCTAssertEqual(b.map(\.id), ["s00003"])
        XCTAssertEqual(ReaderStream.sentences(in: f).count, 3)
        XCTAssertEqual(ReaderStream.additions(in: f).count, 2)
        XCTAssertEqual(f.read("stream.txt"), "One. Two.\n\n\nThree.\n")
        let r1 = Recording(createdAt: Date(timeIntervalSince1970: 100), text: "Said this.", status: .final)
        let r2 = Recording(createdAt: Date(timeIntervalSince1970: 50), text: "", status: .final)
        let r3 = Recording(createdAt: Date(timeIntervalSince1970: 10), text: "Earlier.", status: .final)
        let fed = try ReaderStream.feed([r1, r2, r3], into: f, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(fed.recordings, 2)
        XCTAssertEqual(ReaderStream.sentences(in: f).map(\.text), ["One.", "Two.", "Three.", "1970-01-01 00:00.", "Earlier.", "1970-01-01 00:01.", "Said this."])
        XCTAssertEqual(ReaderStream.unfed([r1, r3], in: f), [])
        XCTAssertEqual(try ReaderStream.feed([r1, r3], into: f).sentences, 0)
        // An existing stream.txt is numbered on first append.
        let g = try temp()
        defer { try? FileManager.default.removeItem(at: g.root) }
        try g.write("stream.txt", "Old one. Old two.")
        XCTAssertEqual(try ReaderStream.append("New.", to: g).map(\.id), ["s00003"])
    }

    /// A reply for every lens a call names: its label is "<lens>+<lens>… <first id>".
    static func sections(_ req: ChatRequest, _ body: (String) -> String) -> String {
        let ids = req.label.split(separator: " ").first.map { $0.split(separator: "+").map(String.init) } ?? []
        return ids.map { "=== \($0) ===\n" + body($0) }.joined(separator: "\n")
    }

    func testReadingEndToEndWithAFakeModel() async throws {
        let f = try temp()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try ReaderStream.append("I want to move to Lisbon. Mara thinks it is a mistake. I feel torn about it.", to: f)
        var cfg = ReaderConfig()
        cfg.model = "fake"; cfg.coolOffSec = 0; cfg.questionCount = 2; cfg.askSteps = 2; cfg.windowTokens = 8000; cfg.questionRefresh = 2
        let lenses = [Lens.defaults[0], Lens.defaults[1], Lens.defaults[7]]
        let model = FakeModel()
        model.answer = { req in
            if req.label == "qgen" { return "Why do you want to move?\nWhat does Mara think?" }
            if req.label.hasPrefix("ask s1") { return "OPEN lenses/ledger.md offset 0\nWHY: the index" }
            if req.label.hasPrefix("ask s2") { return "READ s00001 s00009\nWHY: cite" }
            if req.label.hasPrefix("ask") { return "ANSWER\nYou want to move (s00001).\nEVIDENCE: s00001, s00002" }
            return Self.sections(req) { id in
                switch id {
                case "ledger": return "[s00001] the move; kind: plan\n[s00002] Mara; kind: statement\n[s00003] torn; kind: feeling\n[s00004] the answer; kind: statement\n[s00005] sister; kind: statement"
                case "people-and-things": return "[s00002] Mara — doubts the move\nNOTEBOOK\nMara — person — s00002"
                default: return "[s00002] Who is Mara to you?\nNOTEBOOK\nWho is Mara? s00002"
                }
            }
        }
        let tokens = TokenEstimator()
        let logs = Lines()
        let chunks = Lines()
        var ctl = Reading.Control()
        ctl.log = { m in logs.add(m) }
        ctl.onChunk = { a, b, n, readers in chunks.add("\(a)-\(b)/\(n) \(readers.joined(separator: ","))") }
        let done = try await Reading.run(folder: f, config: cfg, lenses: lenses, goals: "Understand the move.", chat: MeasuredChat(model: model, tokens: tokens), control: ctl)
        XCTAssertTrue(done)
        // Every lens read the chunk in one call.
        XCTAssertEqual(chunks.all, ["0-3/3 ledger,people-and-things,gaps"])
        XCTAssertEqual(model.calls.filter { $0.label.contains("+") }.count, 1)
        XCTAssertTrue(model.calls[0].system.contains("LENS gaps (Questions for you)"))
        let ledger = try XCTUnwrap(f.read("lenses/ledger.md"))
        XCTAssertTrue(ledger.contains("- [s00001] the move; kind: plan"))
        XCTAssertFalse(ledger.contains("not read the whole stream"))
        let people = try XCTUnwrap(f.read("lenses/people-and-things.md"))
        XCTAssertTrue(people.contains("## Notebook"))
        XCTAssertTrue(people.contains("Mara — person — s00002"))
        let questions = try XCTUnwrap(f.read("questions.md"))
        XCTAssertTrue(questions.contains("## Why do you want to move?"))
        XCTAssertTrue(questions.contains("Evidence: s00001, s00002"))
        XCTAssertTrue(questions.contains("Files opened: lenses/ledger.md"))
        XCTAssertTrue(try XCTUnwrap(f.read("index.md")).contains("questions.md"))
        XCTAssertEqual(f.read("goals.md"), "# Goals and intent\n\nUnderstand the move.\n")
        let p = ReaderProgress.load(f)
        XCTAssertEqual(p.lenses["ledger"]?.pos, 3)
        XCTAssertEqual(p.qa.map(\.asOf), [3, 3])
        XCTAssertTrue(logs.all.contains { $0.contains("cited 1 ids it never read: s00002") })
        var st = ReaderStream.state(in: f, config: cfg, lenses: lenses, goals: "Understand the move.")
        XCTAssertFalse(st.hasWork)
        // The gaps lens asked a question; answering it joins the stream.
        let gaps = try XCTUnwrap(ReaderStream.gaps(in: f))
        XCTAssertEqual(gaps.open.map(\.question), ["Who is Mara to you?"])
        let added = try ReaderStream.answer(gaps.open[0], with: "My sister.", in: f)
        XCTAssertEqual(added.map(\.text), ["Q: Who is Mara to you?", "A: My sister."])
        XCTAssertEqual(ReaderStream.gaps(in: f)?.open.count, 0)
        XCTAssertEqual(ReaderStream.gaps(in: f)?.answered, 1)
        // The next run reads only what is new, then refreshes the answers the growth made stale.
        st = ReaderStream.state(in: f, config: cfg, lenses: lenses, goals: "Understand the move.")
        XCTAssertEqual(st.count, 5); XCTAssertEqual(st.unread, 2); XCTAssertTrue(st.partial); XCTAssertEqual(st.questionsPending, 2)
        let calls = model.calls.count
        let again = try await Reading.run(folder: f, config: cfg, lenses: lenses, goals: "Understand the move.", chat: MeasuredChat(model: model, tokens: tokens), control: ctl)
        XCTAssertTrue(again)
        XCTAssertTrue(model.calls[calls...].contains { $0.user.contains("## The chunk: sentences s00004–s00005") })
        XCTAssertFalse(model.calls[calls...].contains { $0.label == "qgen" })
        XCTAssertEqual(ReaderProgress.load(f).qa.map(\.asOf), [5, 5])
        // A pinned question is answered too; changed goals write new questions.
        try ReaderStream.pin("Who is Mara?", in: f)
        XCTAssertEqual(ReaderStream.state(in: f, config: cfg, lenses: lenses, goals: "Understand the move.").questionsPending, 1)
        XCTAssertTrue(ReaderStream.state(in: f, config: cfg, lenses: lenses, goals: "Something else.").questionsToWrite)
        _ = try await Reading.run(folder: f, config: cfg, lenses: lenses, goals: "Understand the move.", chat: MeasuredChat(model: model, tokens: tokens), control: ctl)
        XCTAssertEqual(ReaderProgress.load(f).qa.count, 3)
        XCTAssertTrue(try XCTUnwrap(f.read("questions.md")).contains("## Who is Mara?"))
        // Flags go to corrections.md; the chat survives a reload.
        try ReaderStream.flag(question: "q", answer: "a", note: "wrong", in: f)
        XCTAssertTrue(try XCTUnwrap(f.read("corrections.md")).contains("Correction: wrong"))
        var turn = ReaderStream.Turn(q: "What?", about: "x", aboutLabel: "y"); turn.answer = "This."
        try ReaderStream.saveChat([turn], in: f)
        XCTAssertEqual(ReaderStream.loadChat(in: f).map(\.answer), ["This."])
        XCTAssertEqual(ReaderStream.loadChat(in: f).map(\.about), ["x"])
    }

    func testLensesSplitIntoCallsAndMissingSectionsReadAlone() async throws {
        let f = try temp()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try ReaderStream.append("One thing. Two things. Three things.", to: f)
        var cfg = ReaderConfig()
        cfg.model = "fake"; cfg.coolOffSec = 0; cfg.questionCount = 0; cfg.windowTokens = 8000
        let lenses = [Lens.defaults[0], Lens.defaults[1], Lens.defaults[3]]
        // One per call when asked.
        cfg.lensesPerCall = 1
        let one = FakeModel()
        one.answer = { req in Self.sections(req) { _ in "[s00001] x" } }
        _ = try await Reading.run(folder: f, config: cfg, lenses: lenses, goals: "", chat: MeasuredChat(model: one, tokens: TokenEstimator()), control: Reading.Control())
        XCTAssertEqual(one.calls.map { String($0.label.split(separator: " ")[0]) }, ["ledger", "people-and-things", "feelings"])
        // All at once, but the reply leaves one lens out: that one reads again on its own.
        let g = try temp()
        defer { try? FileManager.default.removeItem(at: g.root) }
        try ReaderStream.append("One thing. Two things. Three things.", to: g)
        cfg.lensesPerCall = 0
        let some = FakeModel()
        some.answer = { req in
            if req.label.hasPrefix("ledger+") { return "=== ledger ===\n[s00001] a\n**Feelings**\n[s00002] glad" }
            return "[s00003] alone"
        }
        let logs = Lines()
        var ctl = Reading.Control()
        ctl.log = { logs.add($0) }
        _ = try await Reading.run(folder: g, config: cfg, lenses: lenses, goals: "", chat: MeasuredChat(model: some, tokens: TokenEstimator()), control: ctl)
        XCTAssertEqual(some.calls.map { String($0.label.split(separator: " ")[0]) }, ["ledger+people-and-things+feelings", "people-and-things"])
        XCTAssertTrue(try XCTUnwrap(g.read("lenses/feelings.md")).contains("- [s00002] glad"))
        XCTAssertTrue(try XCTUnwrap(g.read("lenses/people-and-things.md")).contains("- [s00003] alone"))
        XCTAssertTrue(logs.all.contains { $0.contains("People and things was missing from the reply") })
        // The output cap splits the lenses too.
        var small = cfg; small.outputTokens = 400
        let sample = (1...16).map { Sentence(id: Sentences.makeId($0), text: "A sentence of an ordinary length for the stream.") }
        let groups = Reading.groups(lenses, all: lenses, chunk: sample, notebooks: [:], goals: "", config: small, tokens: TokenEstimator())
        XCTAssertGreaterThan(groups.count, 1)
        XCTAssertEqual(groups.flatMap { $0.map(\.id) }, lenses.map(\.id))
    }

    func testReadingStopsResumesAndCatchesUpANewLens() async throws {
        let f = try temp()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try ReaderStream.append((1...40).map { "Sentence number \($0) is here." }.joined(separator: " "), to: f)
        var cfg = ReaderConfig()
        cfg.model = "fake"; cfg.coolOffSec = 0; cfg.questionCount = 0; cfg.chunkSentences = 10; cfg.windowTokens = 4000
        let model = FakeModel()
        model.answer = { req in Self.sections(req) { _ in "[s00001] x" } }
        let tokens = TokenEstimator()
        let counter = Counter()
        var ctl = Reading.Control()
        ctl.stopped = { counter.value >= 2 }
        ctl.onRead = { _, _ in counter.bump() }
        let chat = MeasuredChat(model: model, tokens: tokens)
        let ledger = [Lens.defaults[0]]
        let done = try await Reading.run(folder: f, config: cfg, lenses: ledger, goals: "", chat: chat, control: ctl)
        XCTAssertFalse(done)
        XCTAssertEqual(ReaderProgress.load(f).lenses["ledger"]?.pos, 20)
        XCTAssertTrue(try XCTUnwrap(f.read("lenses/ledger.md")).contains("not read the whole stream"))
        XCTAssertTrue(ReaderStream.state(in: f, config: cfg, lenses: ledger).partial)
        let plan = ReaderStream.plan(config: cfg, lenses: ledger, goals: "", unread: 20, averageChars: 28, tokens: tokens)
        XCTAssertEqual(plan.chunks, 2); XCTAssertEqual(plan.callsPerChunk, 1)
        ctl.stopped = { false }
        // A lens switched on now reads alone until it reaches the ledger, then they read together.
        let both = [Lens.defaults[0], Lens.defaults[3]]
        let chunks = Lines()
        ctl.onChunk = { a, b, _, readers in chunks.add("\(a)-\(b) \(readers.joined(separator: ","))") }
        let resumed = try await Reading.run(folder: f, config: cfg, lenses: both, goals: "", chat: chat, control: ctl)
        XCTAssertTrue(resumed)
        XCTAssertEqual(chunks.all, ["0-10 feelings", "10-20 feelings", "20-30 ledger,feelings", "30-40 ledger,feelings"])
        XCTAssertEqual(ReaderProgress.load(f).lenses["ledger"]?.pos, 40)
        // Text added while reading is read in the same run.
        try ReaderStream.append("A first late one.", to: f)
        let once = Counter()
        let late = FakeModel()
        late.answer = { req in
            if once.value == 0 { once.bump(); _ = try? ReaderStream.append("A second late one.", to: f) }
            return Self.sections(req) { _ in "[s00041] late" }
        }
        let caught = try await Reading.run(folder: f, config: cfg, lenses: both, goals: "", chat: MeasuredChat(model: late, tokens: tokens), control: ctl)
        XCTAssertTrue(caught)
        XCTAssertEqual(ReaderProgress.load(f).lenses["feelings"]?.pos, 42)
        XCTAssertEqual(late.calls.count, 2)
    }

    func testPromptIsRefusedOverBudget() async throws {
        var cfg = ReaderConfig(); cfg.windowTokens = 1000
        let chat = MeasuredChat(model: FakeModel(), tokens: TokenEstimator())
        do {
            _ = try await chat.call(ChatRequest(system: String(repeating: "x", count: 5000), user: "", label: "big"), config: cfg, budget: 1000)
            XCTFail()
        } catch { XCTAssertTrue((error as? ReaderError)?.message.contains("exceeds budget") == true) }
        XCTAssertEqual(MeasuredChat.stripThinking("<think>hmm</think>\nanswer"), "answer")
        XCTAssertEqual(MeasuredChat.stripThinking("leak</think>answer"), "answer")
    }

    func testSectionsGapsAndWhereSentencesCameFrom() throws {
        let lenses = [(id: "ledger", title: "Ledger"), (id: "people-and-things", title: "People and things"), (id: "threads", title: "Threads and decisions")]
        let reply = """
        Sure, here you go.
        === ledger === Ledger
        [s00001] a
        ## People and things
        [s00002] b
        NOTEBOOK
        Threads: not a header
        **threads (keeps a notebook)**
        [none]
        """
        let sec = LensParse.sections(reply, lenses: lenses)
        XCTAssertEqual(sec["ledger"], "[s00001] a")
        XCTAssertEqual(LensParse.lens(sec["people-and-things"] ?? "").notebook, "Threads: not a header")
        XCTAssertEqual(sec["threads"], "[none]")
        XCTAssertEqual(LensParse.sections("[s00001] only", lenses: [lenses[0]])["ledger"], "[s00001] only")
        XCTAssertTrue(LensParse.sections("[s00001] only", lenses: lenses).isEmpty)

        // Gaps: settled ones and the notebook are not open questions.
        let f = try temp()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write("lenses/gaps.md", "# Q\n\n- [s00001] Who is Mara?\n- [s00002] What is Kethra?\n- [s00005] settled: who is Mara\n\n## Notebook\n\n- [s00009] Where is the flat?\n")
        XCTAssertEqual(ReaderStream.gaps(in: f)?.open.map(\.question), ["What is Kethra?"])

        // Transcripts: where they are in the stream, edits noticed, a revision joins again.
        let r = Recording(createdAt: Date(timeIntervalSince1970: 0), text: "Said this. And that.", status: .final)
        XCTAssertEqual(ReaderStream.standing(of: r, in: f), .waiting)
        try ReaderStream.append("Before.", to: f)
        try ReaderStream.feed([r], into: f, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(ReaderStream.standing(of: r, in: f), .inStream(ids: [2, 3, 4], edited: false))
        var edited = r; edited.text = "Said this. And the other."
        XCTAssertEqual(ReaderStream.standing(of: edited, in: f), .inStream(ids: [2, 3, 4], edited: true))
        let rev = try ReaderStream.revise(edited, in: f, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(rev[0].text.contains("replaces s00002–s00004"))
        XCTAssertEqual(ReaderStream.standing(of: edited, in: f), .inStream(ids: [2, 3, 4] + Array(5...(4 + rev.count)), edited: false))
        let spans = ReaderStream.spans(in: f)
        XCTAssertEqual(ReaderStream.span(of: 3, in: spans)?.source, r.id.uuidString)
        XCTAssertNil(ReaderStream.span(of: 1, in: spans)?.source)
        XCTAssertNil(ReaderStream.span(of: 99, in: spans))
        // An answer spoken in a recording keeps that recording from joining again.
        let spoken = Recording(text: "My sister.", status: .final)
        try ReaderStream.answer(ReaderStream.Gap(question: "Who?", ids: []), with: spoken.text, in: f, source: spoken.id.uuidString)
        XCTAssertEqual(ReaderStream.unfed([spoken], in: f), [])

        // Settling: a new transcript waits until it has been unchanged for a while; an old one is ready.
        var settle = ReaderStream.Settle()
        let now = Date(timeIntervalSince1970: 10_000)
        let fresh = Recording(createdAt: now, text: "New.", status: .final)
        let old = Recording(createdAt: Date(timeIntervalSince1970: 0), text: "Old.", status: .final)
        XCTAssertEqual(settle.ready([fresh, old], fed: [], now: now, seconds: 60).map(\.text), ["Old."])
        var changed = fresh; changed.text = "New, corrected."
        XCTAssertEqual(settle.ready([changed], fed: [], now: now.addingTimeInterval(50), seconds: 60), [])
        XCTAssertEqual(settle.ready([changed], fed: [], now: now.addingTimeInterval(100), seconds: 60), [])
        XCTAssertEqual(settle.ready([changed], fed: [], now: now.addingTimeInterval(111), seconds: 60).map(\.text), ["New, corrected."])
        XCTAssertEqual(settle.ready([changed], fed: [changed.id.uuidString], now: now.addingTimeInterval(200), seconds: 60), [])
    }

    func testConfigAndNotesFolder() throws {
        XCTAssertEqual(ReaderConfig.normalizeBase(" localhost:11434/api/ "), "http://localhost:11434")
        XCTAssertEqual(ReaderConfig.normalizeBase(""), "http://localhost:11434")
        var c = ReaderConfig(); c.windowTokens = 10; c.charsPerToken = 9
        XCTAssertEqual(c.clamped().windowTokens, 1000); XCTAssertEqual(c.clamped().charsPerToken, 5)
        let decoded = try JSONDecoder().decode(ReaderConfig.self, from: Data("{\"model\":\"m\"}".utf8))
        XCTAssertEqual(decoded.model, "m"); XCTAssertEqual(decoded.windowTokens, 6000)
        XCTAssertEqual(try JSONDecoder().decode(ReaderConfig.self, from: Data("{\"morningSteps\":3}".utf8)).askSteps, 3)
        XCTAssertEqual(try JSONDecoder().decode(Lens.self, from: Data("{\"id\":\"x\"}".utf8)).title, "x")
        XCTAssertEqual(Lens.slug("  New Lens!! 2 "), "new-lens-2")
        let f = try temp()
        defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertNil(f.url("../x"))
        try f.write("lenses/a.md", "a"); try f.append("lenses/a.md", "b"); try f.append("new.txt", "n")
        XCTAssertEqual(f.read("lenses/a.md"), "ab"); XCTAssertEqual(f.read("new.txt"), "n")
        XCTAssertEqual(f.list(), ["lenses/a.md", "new.txt"])
        let t = TokenEstimator()
        XCTAssertEqual(t.estimate("abcdefgh"), 3)
        XCTAssertEqual(t.clip("abcdefghij", 1).text, "abc")
        t.calibrate(chars: 1000, actualTokens: 500, estimatedTokens: 280)
        XCTAssertLessThan(t.charsPerToken, 3.6)
        XCTAssertEqual(Asking.page(of: "a\nb\nc", offset: 1, budget: 1, tokens: t), "b\n[lines 1–1 of 3; to continue, OPEN the same file with offset 2]")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
}
