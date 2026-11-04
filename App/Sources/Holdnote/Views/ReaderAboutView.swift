import SwiftUI

/// READER.md, shown in a window: what the reader does and why. Kept in step with the file by hand.
struct ReaderAboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(Self.blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case let .heading(level, text):
                        Text(text).font(level == 1 ? .title2.weight(.semibold) : .system(size: 15, weight: .semibold)).padding(.top, level == 1 ? 0 : 8)
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
                    }
                }
            }
            .textSelection(.enabled)
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 400)
    }

    enum Block { case heading(Int, String), paragraph(String), list([String]), table([[String]]) }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    static var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = [], list: [String] = [], table: [[String]] = []
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] }
            if !list.isEmpty { out.append(.list(list)); list = [] }
            if !table.isEmpty { out.append(.table(table)); table = [] }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                let level = line.prefix(while: { $0 == "#" }).count
                out.append(.heading(level, line.drop(while: { $0 == "#" || $0 == " " }).description))
            } else if line.hasPrefix("|") {
                if line.hasPrefix("|---") || line.hasPrefix("| ---") { continue }
                table.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) })
            } else if line.hasPrefix("- ") || (line.first?.isNumber == true && line.contains(". ")) {
                if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] }
                list.append(line.hasPrefix("- ") ? String(line.dropFirst(2)) : String(line.drop(while: { $0.isNumber || $0 == "." || $0 == " " })))
            } else {
                if !list.isEmpty { out.append(.list(list)); list = [] }
                para.append(line)
            }
        }
        flush()
        return out
    }

    static let text = #"""
# The Reader

Holdnote's reader reads what you said and wrote, overnight, through several lenses, and writes what it finds into plain files. In the morning you ask questions and a local model answers from those files, citing the sentences it relied on. Everything runs on this Mac through [Ollama](https://ollama.com). It is the Night Reader Chrome extension, built into the app, so recording a thought and asking about it weeks later is one flow.

## What it is for

You have a long, disorganised stream of your own thoughts, most of them spoken into Holdnote. You want to ask it things like: is X in there, what things are associated with Y, at what point did I start feeling a certain way about Z, where do I contradict myself, what did I leave open, which of the ways of looking at this are actually interesting. You do not need counts or arithmetic. You do not need perfect accuracy, because you will recognise a wrong answer when you see it next to the evidence, and you may ask for proof.

## The idea

Compute overnight is nearly free; your attention in the morning is not. So the expensive work is done while you sleep, in a form that makes morning questions cheap and hard to get wrong.

- The stream is something you grow by talking (every transcript joins it when a night starts, oldest first, under its date) and by pasting. Each addition is split into numbered sentences (`s00001`, `s00002`, ...) that continue from the last one; earlier ids never change, so notes written on earlier nights stay valid. Ids are positions and carry no meaning.
- Each lens remembers how far it has read. The next night reads only what is new, carrying its notebook forward, so a night after a day of notes is a few calls, not a re-read.
- Each lens is one full pass over the stream, window by window, with a small notebook carried between windows. Every line a lens writes cites the ids it came from.
- Lenses run in order and later ones can see the final notebook of earlier ones. The registry of people and things built by the second pass lets the fourth pass resolve "that supplier" when it appears.
- One lens asks *you* questions: what a name refers to, what happened next, what a vague reference points to. You answer on the Stream view (type, or hold the hotkey and say it, then take the transcript); each answer joins the stream and is read the next night.
- A final pass reads your goals and the notes, generates questions you would want answered, and answers them. This is a cache for the morning and a check on whether the notes can answer what you care about.
- In the morning the model has exactly two moves: open a note file (one page at a time), or read sentences by id. It must read the sentences it cites. There are no other tools.
- Corrections are a file. When you flag an answer, a line goes into `corrections.md`, which the morning model reads before every answer. You can also just edit any note file.

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
| Questions for you | yes | What the reader needed to know and the text did not say. Answered on the Stream view; answers join the stream. |

All lens instructions are editable (Night view) and the model sees them verbatim. Add lenses for whatever angle you want.

## Files written

The folder is `~/Library/Application Support/Holdnote/Reader/` unless you choose another (Settings → Reader; a folder in iCloud Drive works).

| File | Contents |
|---|---|
| `sentences.txt` | The numbered stream, one `id<TAB>text` per line; the source of truth for ids |
| `stream.txt` | The raw additions, in order, as a plain record |
| `additions.json` | When each addition was made and which ids it produced, so "at what point" can be answered in calendar time too |
| `sources.json` | Which Holdnote recordings are in the stream already (each joins once) |
| `goals.md` | What you typed as your goals |
| `lenses/<lens>.md` | One file per lens: the entries, and the final notebook for lenses that carry one |
| `answers.md` | Your answers to the reader's questions (and the ones you skipped) |
| `questions.md` | The overnight questions with answers, evidence ids and files opened |
| `index.md` | A table of contents with one line on what each file is for |
| `corrections.md` | Your corrections, appended by the Flag button or by hand |
| `chat.json` | The morning conversation |
| `progress.json` | Resume state; Clear progress on the Night view starts over |
| `log.jsonl` | One line per model call: tokens, time, entries, overflows, errors |

## Budgets

Everything the model sees counts against the prompt window W, including instructions, goals, notebook, prior-lens digest and the sentences themselves. Each prompt is measured before it is sent and refused if it is over. Ollama's `num_ctx` is set to W plus the output cap plus a margin so Ollama never silently truncates. **Use the model's maximum** in Settings → Reader reads the model's trained context length and sets W from it.

Tokens are estimated from characters because Ollama has no stable tokenizer endpoint; the ratio is calibrated after every call against the real prompt token count. A notebook that grows past its cap M gets one compression call; if still over, it is cut and the overflow is logged loudly.

A cool-off interval (default 60 seconds) is waited after every model call during the night, so a larger model can run at a sustainable temperature. Morning questions do not wait.

Cost per night is roughly (number of lenses) × (new tokens ÷ window tokens) model calls, plus the question pass, each followed by the cool-off. On an M1 with a 27B model, a 6k-token window and a one-minute cool-off, that is about 40 calls an hour: a 100k-token first stream through eight lenses is a night and a bit; a day's worth of new notes afterwards is minutes.

## Decisions made on your behalf

- Transcripts join the stream when a night starts (Settings → Reader turns that off; **Add them now** on the Stream view does it by hand), oldest first, each beginning with its date and time. A transcript joins once; later edits to it in Holdnote do not change the stream, so correct it before the night if it matters, or paste the correction.
- Text also enters by pasting into the stream box, or dropping a text file on it. A `stream.txt` already in the folder is numbered on first addition. Splitting is on sentence punctuation and line breaks. Ids are fixed-width (five digits) so they sort and grep cleanly.
- When the stream grows, the overnight questions are regenerated and re-answered; the previous `questions.md` is overwritten. Your `corrections.md` and `answers.md` are never touched by the night.
- Clear progress makes every lens read from the start again; use it after changing a lens's instructions or the window size (a changed window or notebook size does it by itself).
- Lens output is one flat list of entries per lens, not a tree. If a file grows past what fits in one page, the morning model pages through it with an offset.
- The ledger pass validates itself: sentences with no ledger line are reported in the log.
- Entries citing ids that do not exist are dropped, and the drop is logged.
- The morning model answers in the second person and may not ask you questions back. If it cites an id it never read, the id is shown with a question mark.
- Progress is saved after every window, so quitting the app or a crash resumes where it stopped. The night runs in the background: the reader window can be closed, and the menu bar icon shows a moon while it reads.
- The night can start by itself at a time of day (Settings → Reader), when there is something new to read and Ollama answers. The Mac has to be awake at that moment; once a night runs it keeps the Mac awake until it is done.
- Thinking is off by default: thinking models (qwen3, deepseek-r1, gpt-oss) otherwise spend the output cap on hidden reasoning. Settings → Reader has a switch to let the model think.

## Setup

1. Install Ollama and pull a model, e.g. `ollama pull llama3.1:8b`. Start it (the menu bar app, or `ollama serve`). A native app needs no `OLLAMA_ORIGINS`.
2. Open the reader (⌘⇧N, or the menu bar menu). The checklist on Stream says what is still missing before a first night.
3. Write your goals. Record something, or paste text. Pick the model in Settings → Reader and set the cool-off. Start the night; the window can be closed.
4. In the morning, ask on the Night view, under the run card. Click any sentence id to see your words. Flag what is wrong. Answer the reader's questions on Stream.

## Known limits

- Small local models paraphrase feelings and sometimes cite ids they have not read; both are surfaced rather than hidden.
- A closed lid still stops the night (the keep-awake prevents idle sleep, not a lid); it resumes on the next Start.
- The morning shares the model with a running night; an answer during the night waits its turn at Ollama.
"""#
}
