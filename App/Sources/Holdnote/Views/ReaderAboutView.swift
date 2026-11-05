import SwiftUI

/// READER.md, shown in the window (Guide): what the reader does and why. Kept in step with the file by hand.
struct ReaderAboutView: View {
    var body: some View {
        ScrollView {
            MarkdownText(Self.text)
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static var blocks: [MarkdownText.Block] { MarkdownText.blocks(of: text) }
    static func inline(_ s: String) -> AttributedString { MarkdownText.inline(s) }

    static let text = #"""
# The Reader

Holdnote's reader reads what you say and write, as you go, through several lenses at once, and writes what it finds into plain files. It asks you about what it can't place, keeps answers to the questions you care about up to date, and answers anything else you ask, citing the sentences it relied on. Everything runs on this Mac through [Ollama](https://ollama.com).

## What it is for

You have a long, disorganised stream of your own thoughts, most of them spoken into Holdnote. You want to ask it things like: is X in there, what things are associated with Y, at what point did I start feeling a certain way about Z, where do I contradict myself, what did I leave open, which of the ways of looking at this are actually interesting. You do not need counts or arithmetic. You do not need perfect accuracy, because you will recognise a wrong answer when you see it next to the evidence, and you may ask for proof.

## The idea

The expensive reading is done in small pieces as you talk, in the background, in a form that makes questions cheap and hard to get wrong.

- The stream is something you grow by talking and by pasting. A transcript joins it by itself about a minute after it is final and you've stopped editing it, under its date. Each addition is split into numbered sentences (`s00001`, `s00002`, ...) that continue from the last one; earlier ids never change, so notes stay valid as the stream grows. Ids are positions and carry no meaning.
- The reader takes the stream a small chunk at a time (16 sentences by default) and reads each chunk through every lens at once: as many lenses share one call as the window and the output cap allow, and the rest go in the next call on the same chunk. Every line a lens writes cites the ids it came from.
- Each lens keeps a small notebook from chunk to chunk, and a lens can read the notebooks of others as they are now, so the registry of people and things lets the tensions lens resolve "that supplier" when it appears.
- It reads whenever there is something new, never while you record or transcribe (whisper and the model share the Mac). What you say becomes notes within minutes. A lens switched on later reads alone from the start until it reaches the others, then they read together.
- One lens asks *you* questions: who a name is, what happened next, what a vague reference points to. They wait under **For you**, and beside the recording they came from. Answer by voice (click Answer by voice, hold the hotkey, say it) or by typing; each answer joins the stream and is read like everything else. When the text answers one later, the lens marks it settled.
- Once everything is read, the reader writes questions from your goals and answers them from the notes; you can pin your own. Each answer is refreshed once you have said enough more. These are a first place to look, and a check on whether the notes can answer what you care about.
- To answer, the model has three moves: open a note file (one page at a time), read sentences by id, or find every sentence a word appears in (a page at a time; "plan" finds "plans" and "planning", not "airplane"), and a fourth when an embedding model is set (Settings → Reader): **similar**, the sentences nearest in meaning to a phrase, best first, a page at a time, for questions that name a feeling or a theme rather than a word. Every sentence is embedded once as it joins the stream (ids never change, so the store only grows) into `vectors.bin`; without the model nothing is offered and nothing else changes. It must have read, found or been shown the sentences it cites. There are no other tools. Every cited id leads back to your words and the recording they were said in. It is also given the forty words the stream uses most (word, kind, times), as context and as things worth finding.
- Every prompt says the text is a machine transcript of speech, typed text included, so a mis-heard word is read for what was meant and named as a likely error rather than built on.
- Corrections are a file. When you flag an answer, a line goes into `corrections.md`, which is read before every answer. You can also just edit any note file.

## Where it shows

The window has three things you use, named in its first column, and the rest under the hood.

- **Stream**: everything you add (recordings, dropped or imported audio, pasted or dropped text), each item text, under an **ALL** row. Choose ALL for the whole stream as one text, which is exactly what the reader reads, with the conversation about all of it beside it; select a passage and right-click to ask about it. Choose an item for its own text, with the Reader panel beside it: whether it is in the stream yet and read, the questions it raised for you, what each lens noticed in it, and a conversation about that item alone (its sentences are read first). An item edited after it joined can join again as a correction.
- **Goals**, a row above ALL in the stream: what you are trying to find out, and the questions kept answered about it.
- **Status**: Now (what is running: a recording, the transcriber, the reader, each with its stop), Reading (what the reader is doing now: the chunk in hand and which lenses have read it, what the model is writing as it writes it, the log, how far it has come) and Setup.
- **For you**: the reader's questions, under the item each came from.
- **Under the hood. Lenses**: the angles, editable. **Notes**: the files it writes, rendered. The **Guide** (this document) is at the bottom of the first column.
- **Words**, beside ALL and beside each item: the open-class words (names, nouns, verbs, adjectives, adverbs) counted by lemma, the closed classes left out. Not the reader's work: a plain pass with Apple's language tagger, there before any lens has read. The reader is handed the top of this list with every question.

## The lenses

| Lens | Carries a notebook | What it writes |
|---|---|---|
| Ledger | no | One line per sentence: topic, names, kind of sentence. Ignores your goals on purpose, so what you did not ask about stays findable. This is the replacement for grep: presence and absence questions are checked here. |
| People and things | yes | A registry of every named person, place, project, thing and recurring idea, with aliases and ids. |
| Threads and decisions | yes | Decisions, plans and positions, with their full history, not only the latest state. |
| Feelings | no | Where you express a feeling: subject, feeling, your exact words quoted. Ambivalence stays ambivalent. |
| Tensions | yes | Later text disagreeing with earlier text, conflicting reasons, you arguing with yourself. Both sides cited. |
| Open threads | yes | Questions raised and not answered, intentions never followed up, worries never settled. |
| Against the goals | yes | Evidence that your stated goals or assumptions are wrong or already argued against by you. A counterweight to finding what you expect to find. |
| Questions for you | yes | What the reader needed to know and the text did not say. Answered by voice or typing; answers join the stream. |

All lens instructions are editable (Lenses, in the first column) and the model sees them verbatim. Add lenses for whatever angle you want.

## Files written

The folder is `~/Library/Application Support/Holdnote/Reader/` unless you choose another (Settings → Reader; a folder in iCloud Drive works).

| File | Contents |
|---|---|
| `sentences.txt` | The numbered stream, one `id<TAB>text` per line; the source of truth for ids |
| `stream.txt` | The raw additions, in order, as a plain record |
| `additions.json` | When each addition was made, which ids it produced, and the recording it came from, so "at what point" can be answered in calendar time and every id leads back to a recording |
| `sources.json` | Which Holdnote recordings are in the stream already (each joins once, unless you add a correction) |
| `goals.md` | What you typed as your goals |
| `lenses/<lens>.md` | One file per lens: the entries, and the current notebook for lenses that carry one |
| `answers.md` | Your answers to the reader's questions (and the ones you skipped) |
| `questions.md` | The questions about your goals, with answers, evidence ids, files opened, and the point in the stream each answer is as of |
| `pinned.json` | The questions you pinned |
| `index.md` | A table of contents with one line on what each file is for |
| `corrections.md` | Your corrections, appended by the Flag button or by hand |
| `chat.json` | The conversation |
| `progress.json` | How far each lens has read, its notebook and entries, and the questions' answers; Clear progress on the Reading view starts over |
| `log.jsonl` | One line per model call: tokens, time, lenses, errors |
| `vectors.bin`, `vectors.json` | One vector per sentence for the similar move, append-only, with the embedding model's name and dimension; a store made by another model is not reused |

## Budgets

Everything the model sees counts against the prompt window W, including instructions, goals, notebooks, other lenses' notebooks and the sentences themselves. Each prompt is measured before it is sent and refused if it is over. Ollama's `num_ctx` is set to W plus the output cap plus a margin so Ollama never silently truncates. **Use the model's maximum** in Settings → Reader reads the model's trained context length and sets W from it; a larger W lets more lenses share one call.

Lenses share a call only while their instructions, notebooks and the chunk fit W and what they are expected to write fits the output cap. A reply that leaves a lens out, or is cut off by the output cap, sends that lens to read the same chunk on its own.

Tokens are estimated from characters because Ollama has no stable tokenizer endpoint; the ratio is calibrated after every call against the real prompt token count. A notebook that grows past its cap M gets one compression call; if still over, it is cut and the overflow is logged loudly.

A rest (default 20 seconds) is taken after every call while reading, so a larger model can run at a sustainable temperature. Questions you ask do not wait.

## Decisions made on your behalf

- A transcript joins the stream once it has been final and unedited for a minute (Settings → Reader sets how long, or turns joining by itself off; **Add to the reader now** on the whole-stream view does it at once). It joins in the order things happened (the list read from the bottom up), beginning with its date and time. Edit it after it joined and the Reader panel offers to add the corrected text; the earlier sentences keep their ids and the correction says what it replaces.
- A spoken answer to one of the reader's questions joins as that answer, not as a transcript of its own.
- Text also enters by pasting it as a note (⌘⇧V), or dropping a text file or loose text on the window; each is an item of the stream like a recording. A `stream.txt` already in the folder is numbered when reading first starts. Splitting is on sentence punctuation and line breaks. Ids are fixed-width (five digits) so they sort and grep cleanly.
- Reading starts by itself when there is something new, Ollama answers, and nothing is being recorded or transcribed. Text that joins while it reads is read in the same run. Stopping it by hand pauses it until you click Read now; a failure pauses it for ten minutes (or until Ollama answers again).
- The questions about your goals are written again when the goals change (or with New questions); answers to questions still asked are kept. Each answer is refreshed once the stream has grown by 60 sentences since (Settings → Reader). Your `corrections.md` and `answers.md` are never touched by the reader.
- Clear progress makes every lens read from the start again; use it after changing a lens's instructions. Changing W or M does not: positions are counted in sentences, and notebooks are compressed to a new M as they go.
- Lens output is one flat list of entries per lens, not a tree. If a file grows past what fits in one page, the model pages through it with an offset.
- The ledger validates itself: sentences with no ledger line are reported in the log.
- Entries citing ids that do not exist are dropped, and the drop is logged.
- Answers are in the second person and the model may not ask you questions back. If it cites an id it never read, the id is shown with a question mark.
- Progress is saved after every call, so quitting the app or a crash carries on where it stopped. Reading runs in the background: the window can be closed, and the menu bar icon shows glasses while it reads. A notification says when the reader has new questions for you while you are elsewhere.
- Thinking is off by default: thinking models (qwen3, deepseek-r1, gpt-oss) otherwise spend the output cap on hidden reasoning. Settings → Reader has a switch to let the model think.

## Setup

1. Install Ollama and pull a model, e.g. `ollama pull llama3.1:8b`. Start it (the menu bar app, or `ollama serve`). A native app needs no `OLLAMA_ORIGINS`. For finding by meaning, also `ollama pull nomic-embed-text`.
2. Open Status (⌘2). Getting started at the top of Now says what is still missing.
3. Add something to the stream: hold the hotkey and talk, drop an audio or text file on the window, or paste text. Write your goals (the Goals row above ALL) if you have some. Pick the model in Settings → Reader.
4. That's all: it reads by itself. Ask beside ALL or beside an item, answer its questions under For you or beside the item, click any sentence id to see your words and open the recording. Flag what is wrong.

## Known limits

- Small local models paraphrase feelings and sometimes cite ids they have not read; both are surfaced rather than hidden. A small model may also miss a lens's section when many share a call; that lens then reads alone, and Settings → Reader can put one lens in each call.
- A closed lid stops reading (the keep-awake prevents idle sleep, not a lid); it carries on when the Mac wakes.
- Asking shares the model with reading; an answer during reading waits its turn at Ollama.
"""#
}

/// Markdown, rendered the simple way: headings, paragraphs, bullet and numbered lists, tables,
/// and inline emphasis, code and links. Enough for the notes the reader writes and the guide.
struct MarkdownText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        let blocks = Self.blocks(of: text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, text):
                    Text(text).font(level == 1 ? .title2.weight(.semibold) : .system(size: level == 2 ? 15 : 13, weight: .semibold)).padding(.top, level == 1 ? 0 : 8)
                case let .paragraph(text):
                    Text(Self.inline(text)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                case let .list(items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 6) { Text("•"); Text(Self.inline(item)).fixedSize(horizontal: false, vertical: true) }.font(.system(size: 13))
                        }
                    }
                case let .table(rows):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(Array(row.enumerated()), id: \.offset) { k, cell in
                                    let width: CGFloat? = k == 0 ? 150 : (k == 1 && row.count == 3 ? 90 : nil)
                                    Text(Self.inline(cell)).font(.system(size: 12, weight: i == 0 ? .semibold : .regular))
                                        .frame(width: width, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if i == 0 { Divider() }
                        }
                    }
                case let .code(text):
                    Text(text).font(.system(size: 12, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Block { case heading(Int, String), paragraph(String), list([String]), table([[String]]), code(String) }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    static func blocks(of text: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = [], list: [String] = [], table: [[String]] = [], code: [String]? = nil
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] }
            if !list.isEmpty { out.append(.list(list)); list = [] }
            if !table.isEmpty { out.append(.table(table)); table = [] }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let open = code {
                if line.hasPrefix("```") { out.append(.code(open.joined(separator: "\n"))); code = nil } else { code = open + [raw] }
                continue
            }
            if line.hasPrefix("```") { flush(); code = []; continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                let level = line.prefix(while: { $0 == "#" }).count
                out.append(.heading(level, line.drop(while: { $0 == "#" || $0 == " " }).description))
            } else if line.hasPrefix("|") {
                if line.hasPrefix("|---") || line.hasPrefix("| ---") || line.hasPrefix("|:--") { continue }
                table.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) })
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || (line.first?.isNumber == true && line.contains(". ")) {
                if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] }
                list.append(line.hasPrefix("- ") || line.hasPrefix("* ") ? String(line.dropFirst(2)) : String(line.drop(while: { $0.isNumber || $0 == "." || $0 == " " })))
            } else {
                if !list.isEmpty { out.append(.list(list)); list = [] }
                para.append(line)
            }
        }
        if let code { out.append(.code(code.joined(separator: "\n"))) }
        flush()
        return out
    }
}
