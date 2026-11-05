# Holdnote, as a VFD spec

A first, naive extraction of Holdnote's window in the terms of [Variability-First Development](https://github.com/ainigh/VFD-UNIVERSE): every decision the window makes, as an axis whose default is what ships today. Nothing here redesigns the app. The shipped configuration at the bottom *is* the app; widening a set adds a product without moving that point. `README.md` says what the app does, `SPEC.md` how it records and transcribes, `READER.md` how it reads. This file says what is decided, where, and what a change costs.

Scope so far: the **stream and its items**, the **window's shape**, and the **transcriber's pacing**. The reader's own axes (lenses, budgets, chunking of sentences) are configured in Settings → Reader and `READER.md` already names them; they are listed under known seams until extracted here.

## 1. Product

A menu-bar Mac app: hold a key and talk, drop a file, or paste text, and each becomes an item of one stream of text; a local model reads the stream through several lenses, asks what it cannot place, and answers questions about it with your words cited.

## 2. Groups

| Group | Responsibility | Why a group |
|---|---|---|
| Items | What one item of the stream is and how it is presented, whatever made it | The one place the app may ask "where did this come from"; keeping it one group is what makes a paste read like a recording |
| Stream | The list of items: order, search, the whole as one text | What the reader reads and Copy All copies must be the same thing |
| Window | The columns and what each shows | The mental model: three things you use, the rest under the hood |
| Transcribing | How audio becomes text, and how that is paced and shown | The only slow step in the app; the one the person watches |

## 3. Axes

Values marked ° are neutral (the axis behaves as if absent). *Required* axes have no neutral value. **Default** is what ships.

### Items

| Axis | Values | Default | What it decides | Why |
|---|---|---|---|---|
| `item.origin-mark` | `silent`°, `tooltip`, `word` | `tooltip` | Whether anything says where an item came from (heard, imported, pasted) | An item is text with a date; its origin is data, not a different kind of thing. `tooltip` keeps it out of sight but findable (hover the header). `word` is the app as it was before this spec. |
| `item.measure` | `durationOrWords`, `both`, `none`° | `durationOrWords` | What the row and header say about an item's size | Every item gets one measure in the same place: audio length when audio was recorded (`hadAudio`), else the word count. |
| `item.audio-actions` | `whenAudio` | `whenAudio` | Play, the playing-text view, Re-transcribe and Retry appear when the audio file is present (`hasAudio`) | Data-driven, not origin-driven: a recording whose audio was deleted shows none. *Required; single value.* |
| `item.title` | `firstLine60` | `firstLine60` | The row's title: the first non-empty line, cut to 60 characters | One rule for every item. *Required; single value so far.* |
| `item.edited-mark` | `word`, `silent`° | `word` | "edited" after the time when your text differs from the machine's | A plain fact about the item. |
| `item.reader-mark` | `icon`, `silent`° | `icon` | The reader's marks on a row: questions (with a count), edited after the reader took it, waiting, unread | The reader's view of the item, apart from the item's own marks. *Not yet routed through the registry (seam).* |
| `item.timestamp` | row: `time`, `dayTime`; header: `full` | row `time`, header `full` | How the item's date is written on each surface | *Relation with `stream.order`.* |
| `item.language-mark` | `header`, `both`, `silent`° | `header` | Where the language the transcriber found is shown | An asymmetry today: the header only. |

### Stream

| Axis | Values | Default | What it decides | Why |
|---|---|---|---|---|
| `stream.order` | `newestFirstByDay`, `custom` | `newestFirstByDay` | The list's order and sections; `custom` is your own drag order | Settings → General and the list header. The reader, Copy All and export follow it. |
| `stream.whole-view` | `onNoSelection`, `onlyOnDemand` | `onNoSelection` | When the right pane shows the whole stream as one text | Nothing selected means "all of it"; the toolbar toggle and ⌘⇧A force it. |
| `stream.header-line` | `dateTime`, `none`° | `dateTime` | The line above each item in the whole-stream text and Copy All | Settings → Storage → Copy all. |
| `stream.ask-from-selection` | `contextMenu`, `off`° | `contextMenu` | Right-click on a selected passage offers "Ask the reader about this…" | The stream is the input; asking should start from it. |
| `stream.all-row` | `top`, `none`° | `top` | A demarcated ALL row above the items, standing for the whole stream | Choosing it opens the columns for all of it, as choosing an item opens them for one. |
| `stream.goals-row` | `aboveAll`, `none`° | `aboveAll` | A demarcated Goals row above ALL, opening what you are trying to find out and the questions kept answered | Goals are read with every chunk, so they belong with the input, not with status. |
| `stream.side-panel` | `ask`, `words`, `none`° | `ask` | What sits beside the whole stream's text; remembered | |
| `words.classes` | `openOnly` | `openOnly` | Which words the inventory keeps: nouns, verbs, adjectives, adverbs (and words the tagger cannot class), never the closed classes | *Required; single value.* |
| `words.key` | `lemma`, `surface` | `lemma` | What counts as one word: the lemma ("move" for moved, moving) or the form as written. Every entry keeps the forms it was written as. | `surface` has no interpreter yet (seam). |
| `words.tagger` | `naturalLanguage`, `list` | `naturalLanguage` | Apple's tagger with lemmas, or the harness's closed-class list (kind `other` throughout) | `list` is reached only as the fallback (relation below); not a choice yet (seam). |
| `words.click` | `searchCommonForm`, `none`° | `searchCommonForm` | What a click on a word does: searches the stream for the form written most often | A search is a substring of the text, so it must use a form that is in the text, not the lemma. |
| `words.order` | `countThenAlpha` | `countThenAlpha` | Most frequent first, ties alphabetical | *Single value.* |
| `ask.scope` | `byNavigation` | `byNavigation` | What a question is about: everything when ALL is chosen, one item when an item is | One conversation, filtered by where you are; an item's questions read its sentences first. *Required; single value.* |
| `ask.placement` | `besidePane`, `ownView` | `besidePane` | Where the conversation sits: beside the text it is about (ALL or item), or as a view of its own | `ownView` was the app before this entry. |
| `stream.joins-reader` | `afterSettle(seconds)`, `manual` | `afterSettle(60)` | When an item joins the reader's copy of the stream | Settings → Reader. |

### Window

| Axis | Values | Default | What it decides | Why |
|---|---|---|---|---|
| `window.sections` | `[stream, status, forYou]` main; `[lenses, notes]` under the hood; `[settings]`; `guide` at the bottom | as listed | The first column's rows and their grouping | Three things you use; how it works below; the app's own below that; the guide out of the way. *Required.* |
| `status.pages` | `[now, reading, setup]` | that | Status's second column | What is running with its stops; the reading in detail; what the hotkey needs. *Required.* |
| `window.switches` | `toolbarLeading`, `sidebar` | `toolbarLeading` | Where the hotkey and voice-detection switches sit | Beside what is running, on one line. |
| `window.sidebar-controls` | `[setupWarning, guide, updates, quit]` | as listed | What the first column holds under the rows | The way to the guide and to updates; the switches and what is running are at the top (`window.switches`, `window.activity`). |
| `window.list-width` | 240…520 | 320 | The second column's width for the stream | Draggable; remembered. |
| `window.reader-panel.shown` | `shown`, `hidden` | `shown` | Whether the reader's take on an item shows beside its text | The toggle on the item's header; remembered globally. |
| `window.reader-panel.placement` | `auto(660)`, `beside`, `below` | `auto(660)` | Beside the text when the pane is at least 660 pt wide, else below; panel width `min(340, max(280, 34%))` | |
| `window.voice-answer-row` | `whenArmed`, `never`° | `whenArmed` | The "Hold ⌥ to answer" row in the first column while a spoken answer is awaited | *Relation with the reader's questions.* |
| `window.activity` | `topRight`, `sidebar`, `none`° | `topRight` | Where what is running shows, with its Stop or Pause | One place to look; the sidebar was the app before this entry. |
| `window.activity.items` | `oneByPriority[recording, transcribing, reading, listening]`, `all` | `oneByPriority` | Which running things the line shows when several run: the first of the list that applies, or all of them | A recording matters more than a transcription in progress; one line stays readable. |
| `window.footer.model` | `name`, `none`° | `name` | The footer names the speech model in use, with the last run (audio length, model, time, chunks, at once) on hover | Lets you judge a model or a worker count by what it did. |

### Transcribing

| Axis | Values | Default | What it decides | Why |
|---|---|---|---|---|
| `transcribe.chunk-length` | seconds | 300 | Chunks aim for this length | A two-hour file is 24 chunks; each is short enough to show progress and to balance the workers. |
| `transcribe.chunk-min` | seconds | 60 | No chunk shorter than this | Whisper works in 30 s windows; a cut costs context either side. |
| `transcribe.split-threshold` | seconds | 120 | Audio shorter than this is never split | |
| `transcribe.at-once` | `automatic`° (= 4), 1 (no splitting), 2, 3, 4, 6, 8; bound `maximumAtOnce` = 8 | `automatic` | How many chunks run at the same time on the one loaded model | One GPU: past a few, more share it more thinly and each costs a whisper state. Settings → Transcription → Speed, and the control on the transcribing pane. |
| `transcribe.cut` | `quietestNearEven(search ±8 s, frame 0.1 s)` | that | Where a cut lands | No word is split. *Single value so far.* |
| `transcribe.seam` | `dropRepeat`, `keepAll`° | `dropRepeat` | A segment that repeats the one before it (whisper hearing a cut twice) is dropped | |
| `transcribe.retry` | 0, 1, 2 | 1 | How many more tries a failed chunk gets before the whole is given up | |
| `transcribe.phase` | `[reading, cutting, transcribing]` | that | The phases the transcriber reports, shown as such at the top right and on Status | Reading a long file and cutting it are work of their own; a bar that sits still while they run reads as stuck. *Required.* |
| `transcribe.progress-view` | `tiles`, `barOnly` | `tiles` | What the transcribing pane shows for more than one chunk (one chunk is always a bar) | A tile per chunk with its own state is what makes "4 at once" visible. Tile grid 84–110 pt, bar 260 pt, board 640 pt. *`barOnly` not yet interpreted (seam).* |
| `transcribe.stop` | `abortAtNextStep` | that | Stop ends the run at whisper's next step, keeps the audio, marks it stopped for Retry | *Required; single value.* |

## 4. Contracts

- **Item.** Every value of every `item.*` axis renders for an item with audio and for one without, from the same row and header; nothing in the row or header may branch on origin except through `item.origin-mark`, and nothing may test for audio except through `Recording.hasAudio` (the file is there) and `Recording.hadAudio` (a length was recorded).
- **Stream.** The whole-stream text, Copy All and what the reader is fed are the same text in the same order for every value of `stream.order` and `stream.header-line`.
- **Transcribing.** For every `transcribe.at-once` and `transcribe.chunk-length`, the joined transcript covers the whole audio in order with times offset; progress is monotone; Stop leaves the audio and a Retry that works.
- **Design.** Text contrast ≥ 4.5:1; secondary text and non-text indicators (status dots, tile tints, marks) ≥ 3:1 on their background; every control at least macOS's small size (20 pt) with a visible focus ring, and a keyboard path for anything draggable; no horizontal scroll in any column at the minimum window size (960 × 560); reduced motion respected. Animations today: the undo toast, the chunk tiles' progress, the editor's fade while transcribing, the footer meters easing to a new value, the conversation scrolling to its newest turn. None yet gated on reduced motion. *Stated, not yet checked (seam).*

## 5. Relations

- `item.playback` and `item.retranscribe` depend on the item's data (audio present), never on `item.origin-mark`. *Why:* origin is presentation; audio is fact. *Consequence:* deleting audio removes both buttons whatever made the item.
- `transcribe.progress-view = tiles` needs the transcriber to report per-chunk state; `barOnly` needs only the fraction. *Consequence:* the reporting is always per-chunk; the view chooses.
- `stream.joins-reader` runs after an item's status is final and its text has settled; `item.edited-mark` is what tells you the reader may be behind. *Consequence:* a change to `stream.joins-reader` changes when the mark matters, not whether it shows.
- `transcribe.at-once` is read when a run starts. *Consequence:* changing it mid-run applies to the next run; the pane says so.
- `item.measure` keys on `hadAudio`, `item.audio-actions` on `hasAudio`. *Why:* a deleted file leaves the length true and the actions impossible. *Consequence:* after "Delete audio, keep text" the row still says 12:40 and the play button is gone; that is intended.
- `transcribe.at-once` raises the chunk count: there are at least as many chunks as workers, as long as each stays ≥ `chunk-min`. *Why:* a four-minute hold should use every worker. *Consequence:* ten minutes at 8 workers is eight 75 s chunks, not two of five minutes.
- `transcribe.at-once = automatic` resolves to 4 (`AudioSplit.automaticAtOnce`); any value above `maximumAtOnce` is clamped to it. *Consequence:* the "12 on an Ultra" probe touches the bound, not only the value set.
- `item.timestamp` on the row is `dayTime` when `stream.order = custom`. *Why:* your own order has no day sections to say the day. *Consequence:* changing the order changes the row's date format.
- `item.reader-mark = edited` depends on `stream.joins-reader`: it means edited after the reader took the item, which `item.edited-mark` does not. *Consequence:* a change to `stream.joins-reader` changes when the reader mark appears, never the item's own mark.
- `window.voice-answer-row` depends on the reader having armed a spoken answer.
- `stream.goals-row`, `stream.all-row` and items are exclusive in the selection: the last chosen wins. *Why:* each opens a different right pane. *Consequence:* a multiple selection never includes a special row.
- `words.key = lemma` needs `words.tagger = naturalLanguage`; with `list` the key is the surface form whatever `words.key` says. *Consequence:* the fallback counts "moved" and "moving" apart.
- `words.tagger = naturalLanguage` falls back to `list` for a text in which the tagger classes no word. *Consequence:* a text in a language the tagger does not know gets kind `other` throughout.
- `words.click = searchCommonForm` depends on `words.key`: the search is a substring of the text, so it uses the form written most often, never the lemma. *Consequence:* clicking "go" searches "went" when that is how it was said; the Words panel beside ALL then counts the matching items only.
- `window.switches = sidebar` would need `window.sidebar-controls` to include the two switches, and `toolbarLeading` needs it not to. *Consequence:* the two change together; `sidebar` has no interpreter today.
- `window.sections` does not list `reading` or `setup`: they are `status.pages`, and any request for them as a section resolves to Status on that page. *Consequence:* ⌘4 and the Setup button open Status; Done on Setup returns Status to Now.
- `transcribe.progress-view` is consulted only when the audio was cut into more than one chunk; the reporting is per-chunk always.
- `ask.scope = byNavigation` depends on `stream.all-row`: with no ALL row, "everything" has no place to be chosen and the conversation would need a view of its own (`ask.placement = ownView`). *Consequence:* the two change together.
- `window.activity`, `window.sidebar-controls`, `window.footer.model` and the menu bar glyph all read the running state; the shipped point says it at the top right (with the control), names the model in the footer, and changes the glyph. *Consequence:* a value of `window.activity` other than `topRight` must put the control back in the sidebar or nowhere; the footer and the glyph are not the place to look for the control.
- `stream.whole-view` follows the search: with a search active, ALL is the matching items only, Copy All copies that, and the reader is still fed everything. *Why:* the search is a lens on the list. *Consequence:* the Stream contract holds when no search is active; "Add N to the reader now" is offered only then.
- `ask.placement = besidePane` reuses `window.reader-panel.placement`'s rule (beside at ≥ 660 pt, else below). The ask panel is 280–360 pt, the reader panel 280–340 pt; the difference is not intended and is a seam to close with a shared side-panel vocabulary.

## 6. Scopes and overrides

Global values in Settings and in code. `window.reader-panel.shown` is a global remembered across launches (not per window). `transcribe.at-once` can be set from the transcribing pane, for the next run. No per-item overrides yet (see known seams).

## 7. Shipped configuration

```
items:
  origin-mark: tooltip
  measure: durationOrWords
  audio-actions: whenAudio
  title: firstLine60
  edited-mark: word
  reader-mark: icon
  timestamp: { row: time, header: full }
  language-mark: header
stream:
  order: newestFirstByDay
  whole-view: onNoSelection
  header-line: dateTime
  ask-from-selection: contextMenu
  all-row: top
  goals-row: aboveAll
  side-panel: ask
  joins-reader: afterSettle(60)
ask:
  scope: byNavigation
  placement: besidePane
window:
  sections: [stream, status, forYou | lenses, notes | settings | guide]
  sidebar-controls: [setupWarning, guide, updates, quit]
  switches: toolbarLeading
status:
  pages: [now, reading, setup]
words:
  classes: openOnly
  key: lemma
  tagger: naturalLanguage
  order: countThenAlpha
  activity: topRight
  footer.model: name
  list-width: 320
  reader-panel: { shown: shown, placement: auto(660) }
  voice-answer-row: whenArmed
transcribe:
  chunk-length: 300
  chunk-min: 60
  split-threshold: 120
  at-once: automatic
  phase: [reading, cutting, transcribing]
  cut: quietestNearEven(8)
  seam: dropRepeat
  retry: 1
  progress-view: tiles
  stop: abortAtNextStep
```

Where the sets live: `ItemPresentation.swift` (items), `AudioSplit.swift` and `WhisperTranscriber.Options` (transcribing), `Settings.swift` (what Settings holds), `MenuColumn.swift` (window sections). Not yet one place; see known seams.

## 8. Probes

| Request | Expected change | Cost |
|---|---|---|
| "Show a small icon for where each item came from" | `item.origin-mark` gains `icon`; one registry entry in `ItemPresentation` | value + registry entry |
| "Show words as well as duration" | `item.measure = both` | value |
| "Ten-minute chunks" | `transcribe.chunk-length = 600` | value |
| "Let me pick 12 at once on an Ultra" | `transcribe.at-once` expansion; `AudioSplit.maximumAtOnce` | axis expansion |
| "Pasted items should say 'note' in the row" | `item.origin-mark = word` globally, or a per-item override | value, or a new scope (seam) |
| "Hide the reader panel for text items only" | needs a per-item scope on `window.reader-panel` | new scope (seam) |
| "Put Notes among the main sections" | `window.sections` value | value |
| "Show the language in the row too" | `item.language-mark = both` | value |
| "Oldest first" | `stream.order` expansion | axis expansion |
| "The reader panel on the left" | `window.reader-panel.placement` expansion | axis expansion |
| "Larger type" or "compact rows" | no type-scale or density axis exists (sizes 16/13/11/10 and the 760 pt measure are fixed) | new axis |
| "In German" | copy is inline English with English plurals; no copy registry | surgery today; a copy registry makes it a registry entry |
| "Twelve at once on an Ultra" | `transcribe.at-once` bound `maximumAtOnce` | axis expansion |
| "Ask as a view of its own again" | `ask.placement = ownView` | value (the view exists in history; a registry entry to bring back) |
| "Which model made this transcript?" | `Recording.model` is stored; a value of `item.measure` or a tooltip | value |
| "Show the activity in the sidebar too" | `window.activity` expansion to `both` | axis expansion |
| "Show recording and transcribing at the same time" | `window.activity.items = all` | value |
| "Pause the transcriber instead of stopping it" | `transcribe.stop` has one value; a pause needs whisper-side work the spec does not estimate | new value, cost unknown |
| "The reader's progress as tiles, like the transcriber's" | the reader reports a percentage only; a per-chunk report and a `reader.progress-view` axis | new axis |
| "Remember the last run across launches" | `LastRun` persisted in Settings or the store | new scope |
| "Count proper nouns separately" | `words.classes` expansion and a second tagger scheme (names) | axis expansion plus a tagger change |
| "Show 'went' under 'go' when I click it" | done: entries keep their forms | value |
| "Words beside an item instead of under the reader's take" | a shared `sidePanel.kind` | new axis (seam above) |
| "Reading as a section of its own again" | the routing is code in `section`'s observer, not a value | modification today; a sections registry would make it a value |
| "Words as a lens the reader can read" | a registry entry: write the inventory into the notes folder as a file | registry entry |
| "Stop buttons in the sidebar too" | `window.activity` expansion | axis expansion |

## 9. Known seams

- The sets are defined in four files, not one; the About view is hand-written (`README.md`). Generating the tables above from the code is the next step.
- No per-item scope: every `item.*` axis is global.
- `item.title` and `transcribe.cut` have one value each and no neutral; probe for a second.
- The reader's axes (lenses, chunk sentences, lenses per call, budgets, auto-read, keep-awake) are configured in Settings → Reader and described in `READER.md`, not extracted here.
- `window.sections` is a fixed list in code; a value other than the shipped one needs a registry of sections.
- The design contract is stated, not checked by a test. Risks noted: small and mini controls in the first column and footers; borderless icon buttons with no frame; the column resizer is drag-only; the status dot and tile tints have no stated contrast floor.
- `item.reader-mark`, `item.timestamp` and `item.language-mark` are decided inline in `RecordingRow` and `TranscriptView`, not through `ItemPresentation`.
- `transcribe.progress-view = barOnly` has no interpreter.
- Origin is sniffed from `sourceDevice` strings ("Imported: …", "Pasted text", "Voice detection") rather than a typed field on `Recording`.
- Timing and feedback constants not yet axes: the "Copied" badge (1.2 s), the undo window (10 s), the hotkey hold (250 ms), the accidental-recording cutoff (1.5 s), the autosave debounce (0.6 s), the reader's pause after a failure (10 min), the activity line's bar (70 pt).
- Side panels (the reader's beside an item, the conversation beside ALL) each carry their own breakpoint and width numbers and remember shown-ness in AppStorage outside Settings (`transcriptReaderPanel`, `streamAskPanel`), which Start Over does not reset. A shared `window.side-panel` vocabulary and an `ask.shown` axis beside `window.reader-panel.shown` would close it.
- The transcriber's phases are worded in three places (the `Library.Phase` raw values, the activity line, the Status card); the last-run sentence in two. One registry entry per phase and one `LastRun` description would close it.
- The last run is remembered in memory only; a run before the last launch is gone.
- The ALL row's selection rule (ALL and items never mix; the last chosen wins) and the whole-stream header's meta list (items, words, reader progress, order) are fixed in code.
- The activity line is a plain text button without a frame or focus ring (a design-contract exception not yet declared); the Words panel's rows are plain buttons too (20 pt tall, no focus ring), its count bar is a faint tint, and the Beside picker is three glyphs with one tooltip.
- `stream.side-panel` is kept as two states in code (shown, and which) so "which" survives "hidden"; beside an item the choice does not exist (Words is a fixed block under the reader's take). A shared `sidePanel.shown` and `sidePanel.kind` vocabulary for ALL (`ask`, `words`) and item (`reader`, `words`) would close this and the earlier two-panels seam.
- `status.pages` has one value; each page's badge rule lives in `StatusList`, and the old rows for Reading and Setup in the sidebar's enum are dead.
- Words constants not yet axes: the page (60, then 200 more), the compact height (260 pt), the bar (60 pt), the one-letter rule (only "I" survives), and `other` being kept inside `openOnly` (interjections, and words the tagger could not class).

## 10. Build log

- **Items made uniform (this spec's first entry).** Request: "make a text paste look identical to audio". Before: the row branched on `audioFile == nil` ("text only"), `sessionID` ("heard") and `sourceDevice` ("imported"); the header printed the device and a zero duration for text; Re-transcribe showed disabled for text. Move: a new group, Items, with `item.origin-mark` (shipped `silent`) and `item.measure` (shipped `durationOrWords`); playback and Re-transcribe keyed on audio present. Predicted cost: new axis. Actual: new axis plus modifying the row and header to read it (the first time an axis is introduced into code that had the decision inline). The shipped point moved on purpose: `origin-mark` was `word`, is `tooltip`.
- **Status, ALL and the ask beside the text.** Requests: the model in the footer; cutting shown apart from transcribing; what is running at the top right with Stop; an ALL row; the conversation beside what it is about; the first column's Ask becomes Status. Moves: `window.activity`, `window.footer.model`, `transcribe.phase`, `stream.all-row`, `ask.scope`, `ask.placement`; `window.sections` and `sidebar-controls` values changed. Predicted: values and new axes. Actual: the same, plus modifying the Ask view into Status and a panel (the conversation had no registry; it does now, `AskPanel`). The shipped point moved on purpose in every one of these. The round's review found a compile error (a setting read before it was fetched), a last-run record for a deleted item, and a bar hidden while transcribing at 0%; all fixed. It also found the activity line's hidden priority rule (now `window.activity.items`), the search filtering ALL without a relation (written), and the two side panels' separate layout numbers (a seam).
- **Status in columns, Lenses on its own, Goals in the stream, switches at the top, Words.** Requests as listed. Moves: `status.pages`, `window.switches`, `stream.goals-row`, `stream.side-panel`, the `words.*` group; `window.sections` and `sidebar-controls` values changed; Reading and Setup route into Status. Predicted: values, new axes, and one new group (Words) with its own code (a pass in the harness, tested, and a tagger in the app). Actual: the same, plus modifying the Reading view (the lenses out of it) and the Status view (into a column with pages). The shipped point moved on purpose throughout. The round's review found nothing that would not compile; it found a click on a lemma searching for a form not in the text (entries now keep their forms; `words.click` written), a kind label cut wrong, the stream's inventory added up on every redraw (now cached), the word cache keyed on length (now on the text's hash, and cleared on delete), and Setup's Done leaving Status on Setup (now Now).
- **First review.** One VFD review of this spec found: three different tests for "has audio" (now `hasAudio` / `hadAudio` on `Recording`, with the relation written); `reader-panel` fused (split into shown and placement); `at-once` hiding `automatic` and a bound (now in the set); `chunk-length` fusing three constants and depending on `at-once` (split, relation written); the edited mark bypassing the registry (now through it) and a second, reader-side edited mark (its own axis); the origin tooltip leaking past `origin-mark` (now a value of it). Declined for now, recorded as seams: a typed origin field, a copy registry, a type-scale axis, the `barOnly` interpreter, routing the reader marks and timestamps through the registry, and design-contract checks.
