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

    func testNightEndToEndWithAFakeModel() async throws {
        let f = try temp()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try ReaderStream.append("I want to move to Lisbon. Mara thinks it is a mistake. I feel torn about it.", to: f)
        var cfg = ReaderConfig()
        cfg.model = "fake"; cfg.coolOffSec = 0; cfg.questionCount = 2; cfg.morningSteps = 2; cfg.windowTokens = 4000
        let lenses = [Lens.defaults[0], Lens.defaults[1], Lens.defaults[7]]
        let model = FakeModel()
        model.answer = { req in
            if req.label.hasPrefix("ledger") { return "[s00001] the move; kind: plan\n[s00002] Mara; kind: statement\n[s00003] torn; kind: feeling" }
            if req.label.hasPrefix("people-and-things") { return "[s00002] Mara — doubts the move\nNOTEBOOK\nMara — person — s00002" }
            if req.label.hasPrefix("gaps") { return "[s00002] Who is Mara to you?\nNOTEBOOK\nWho is Mara? s00002" }
            if req.label == "qgen" { return "Why do you want to move?\nWhat does Mara think?" }
            if req.label.hasPrefix("morning s1") { return "OPEN lenses/ledger.md offset 0\nWHY: the index" }
            if req.label.hasPrefix("morning s2") { return "READ s00001 s00009\nWHY: cite" }
            return "ANSWER\nYou want to move (s00001).\nEVIDENCE: s00001, s00002"
        }
        let tokens = TokenEstimator()
        let logs = Lines()
        var ctl = Night.Control()
        ctl.log = { m in logs.add(m) }
        let done = try await Night.run(folder: f, config: cfg, lenses: lenses, goals: "Understand the move.", chat: MeasuredChat(model: model, tokens: tokens), control: ctl)
        XCTAssertTrue(done)
        let ledger = try XCTUnwrap(f.read("lenses/ledger.md"))
        XCTAssertTrue(ledger.contains("- [s00001] the move; kind: plan"))
        XCTAssertFalse(ledger.contains("not finished"))
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
        XCTAssertTrue(p.questionsDone)
        XCTAssertTrue(logs.all.contains { $0.contains("cited 1 ids it never read: s00002") })
        // The gaps lens asked a question; answering it joins the stream.
        let gaps = try XCTUnwrap(ReaderStream.gaps(in: f))
        XCTAssertEqual(gaps.open.map(\.question), ["Who is Mara to you?"])
        let added = try ReaderStream.answer(gaps.open[0], with: "My sister.", in: f)
        XCTAssertEqual(added.map(\.text), ["Q: Who is Mara to you?", "A: My sister."])
        XCTAssertEqual(ReaderStream.gaps(in: f)?.open.count, 0)
        XCTAssertEqual(ReaderStream.gaps(in: f)?.answered, 1)
        // A second night reads only what is new and regenerates the questions.
        let st = ReaderStream.state(in: f, config: cfg, lenses: lenses)
        XCTAssertEqual(st.count, 5); XCTAssertEqual(st.unread, 2); XCTAssertTrue(st.partial)
        let calls = model.calls.count
        let again = try await Night.run(folder: f, config: cfg, lenses: lenses, goals: "Understand the move.", chat: MeasuredChat(model: model, tokens: tokens), control: ctl)
        XCTAssertTrue(again)
        XCTAssertTrue(model.calls[calls...].contains { $0.user.contains("## Window 1 of 1 (sentences s00004–s00005)") })
        XCTAssertTrue(logs.all.contains { $0.contains("questions will be regenerated") })
        // Flags go to corrections.md; the chat survives a reload.
        try ReaderStream.flag(question: "q", answer: "a", note: "wrong", in: f)
        XCTAssertTrue(try XCTUnwrap(f.read("corrections.md")).contains("Correction: wrong"))
        var turn = ReaderStream.Turn(q: "What?"); turn.answer = "This."
        try ReaderStream.saveChat([turn], in: f)
        XCTAssertEqual(ReaderStream.loadChat(in: f).map(\.answer), ["This."])
    }

    func testNightStopsAndResumes() async throws {
        let f = try temp()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try ReaderStream.append((1...40).map { "Sentence number \($0) is here." }.joined(separator: " "), to: f)
        var cfg = ReaderConfig()
        cfg.model = "fake"; cfg.coolOffSec = 0; cfg.questionCount = 0; cfg.maxSentences = 10; cfg.windowTokens = 4000
        let model = FakeModel()
        model.answer = { _ in "[s00001] x" }
        let tokens = TokenEstimator()
        let counter = Counter()
        var ctl = Night.Control()
        ctl.stopped = { counter.value >= 2 }
        ctl.onTape = { _, _, _, state in if state == .done { counter.bump() } }
        let chat = MeasuredChat(model: model, tokens: tokens)
        let done = try await Night.run(folder: f, config: cfg, lenses: [Lens.defaults[0]], goals: "", chat: chat, control: ctl)
        XCTAssertFalse(done)
        XCTAssertEqual(ReaderProgress.load(f).lenses["ledger"]?.pos, 20)
        XCTAssertTrue(try XCTUnwrap(f.read("lenses/ledger.md")).contains("not finished"))
        XCTAssertTrue(ReaderStream.state(in: f, config: cfg, lenses: [Lens.defaults[0]]).partial)
        let plan = ReaderStream.plan(config: cfg, lenses: [Lens.defaults[0]], goals: "", unread: 20, averageChars: 28, tokens: tokens)
        XCTAssertEqual(plan.windows, 2)
        ctl.stopped = { false }
        let resumed = try await Night.run(folder: f, config: cfg, lenses: [Lens.defaults[0]], goals: "", chat: chat, control: ctl)
        XCTAssertTrue(resumed)
        XCTAssertEqual(ReaderProgress.load(f).lenses["ledger"]?.pos, 40)
        // A changed window size starts over.
        cfg.windowTokens = 5000
        XCTAssertEqual(ReaderStream.state(in: f, config: cfg, lenses: [Lens.defaults[0]]).unread, 40)
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

    func testConfigAndNotesFolder() throws {
        XCTAssertEqual(ReaderConfig.normalizeBase(" localhost:11434/api/ "), "http://localhost:11434")
        XCTAssertEqual(ReaderConfig.normalizeBase(""), "http://localhost:11434")
        var c = ReaderConfig(); c.windowTokens = 10; c.charsPerToken = 9
        XCTAssertEqual(c.clamped().windowTokens, 1000); XCTAssertEqual(c.clamped().charsPerToken, 5)
        let decoded = try JSONDecoder().decode(ReaderConfig.self, from: Data("{\"model\":\"m\"}".utf8))
        XCTAssertEqual(decoded.model, "m"); XCTAssertEqual(decoded.windowTokens, 6000)
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
        XCTAssertEqual(Morning.page(of: "a\nb\nc", offset: 1, budget: 1, tokens: t), "b\n[lines 1–1 of 3; to continue, OPEN the same file with offset 2]")
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
