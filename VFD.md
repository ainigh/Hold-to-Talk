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
| `stream.joins-reader` | `afterSettle(seconds)`, `manual` | `afterSettle(60)` | When an item joins the reader's copy of the stream | Settings → Reader. |

### Window

| Axis | Values | Default | What it decides | Why |
|---|---|---|---|---|
| `window.sections` | `[stream, ask, forYou]` main; `[reading, notes, guide]` under the hood; `[settings, setup]` | as listed | The first column's rows and their grouping | Three things you use; how it works below; the app's own below that. *Required.* |
| `window.sidebar-controls` | `[hotkey, voiceDetection, transcribing, reading, updates, quit]` | as listed | What the first column holds under the rows | State switches and what is running; settings live in Settings. |
| `window.list-width` | 240…520 | 320 | The second column's width for the stream | Draggable; remembered. |
| `window.reader-panel.shown` | `shown`, `hidden` | `shown` | Whether the reader's take on an item shows beside its text | The toggle on the item's header; remembered globally. |
| `window.reader-panel.placement` | `auto(660)`, `beside`, `below` | `auto(660)` | Beside the text when the pane is at least 660 pt wide, else below; panel width `min(340, max(280, 34%))` | |
| `window.voice-answer-row` | `whenArmed`, `never`° | `whenArmed` | The "Hold ⌥ to answer" row in the first column while a spoken answer is awaited | *Relation with the reader's questions.* |

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
| `transcribe.progress-view` | `tiles`, `barOnly` | `tiles` | What the transcribing pane shows for more than one chunk (one chunk is always a bar) | A tile per chunk with its own state is what makes "4 at once" visible. Tile grid 84–110 pt, bar 260 pt, board 640 pt. *`barOnly` not yet interpreted (seam).* |
| `transcribe.stop` | `abortAtNextStep` | that | Stop ends the run at whisper's next step, keeps the audio, marks it stopped for Retry | *Required; single value.* |

## 4. Contracts

- **Item.** Every value of every `item.*` axis renders for an item with audio and for one without, from the same row and header; nothing in the row or header may branch on origin except through `item.origin-mark`, and nothing may test for audio except through `Recording.hasAudio` (the file is there) and `Recording.hadAudio` (a length was recorded).
- **Stream.** The whole-stream text, Copy All and what the reader is fed are the same text in the same order for every value of `stream.order` and `stream.header-line`.
- **Transcribing.** For every `transcribe.at-once` and `transcribe.chunk-length`, the joined transcript covers the whole audio in order with times offset; progress is monotone; Stop leaves the audio and a Retry that works.
- **Design.** Text contrast ≥ 4.5:1; secondary text and non-text indicators (status dots, tile tints, marks) ≥ 3:1 on their background; every control at least macOS's small size (20 pt) with a visible focus ring, and a keyboard path for anything draggable; no horizontal scroll in any column at the minimum window size (960 × 560); reduced motion respected. Animations today: the undo toast, the chunk tiles' progress, the editor's fade while transcribing. *Stated, not yet checked (seam).*

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
- `transcribe.progress-view` is consulted only when the audio was cut into more than one chunk; the reporting is per-chunk always.

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
  joins-reader: afterSettle(60)
window:
  sections: [stream, ask, forYou | reading, notes, guide | settings, setup]
  sidebar-controls: [hotkey, voiceDetection, transcribing, reading, updates, quit]
  list-width: 320
  reader-panel: { shown: shown, placement: auto(660) }
  voice-answer-row: whenArmed
transcribe:
  chunk-length: 300
  chunk-min: 60
  split-threshold: 120
  at-once: automatic
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
- Timing and feedback constants not yet axes: the "Copied" badge (1.2 s), the undo window (10 s), the hotkey hold (250 ms), the accidental-recording cutoff (1.5 s).

## 10. Build log

- **Items made uniform (this spec's first entry).** Request: "make a text paste look identical to audio". Before: the row branched on `audioFile == nil` ("text only"), `sessionID` ("heard") and `sourceDevice` ("imported"); the header printed the device and a zero duration for text; Re-transcribe showed disabled for text. Move: a new group, Items, with `item.origin-mark` (shipped `silent`) and `item.measure` (shipped `durationOrWords`); playback and Re-transcribe keyed on audio present. Predicted cost: new axis. Actual: new axis plus modifying the row and header to read it (the first time an axis is introduced into code that had the decision inline). The shipped point moved on purpose: `origin-mark` was `word`, is `tooltip`.
- **First review.** One VFD review of this spec found: three different tests for "has audio" (now `hasAudio` / `hadAudio` on `Recording`, with the relation written); `reader-panel` fused (split into shown and placement); `at-once` hiding `automatic` and a bound (now in the set); `chunk-length` fusing three constants and depending on `at-once` (split, relation written); the edited mark bypassing the registry (now through it) and a second, reader-side edited mark (its own axis); the origin tooltip leaking past `origin-mark` (now a value of it). Declined for now, recorded as seams: a typed origin field, a copy registry, a type-scale axis, the `barOnly` interpreter, routing the reader marks and timestamps through the registry, and design-contract checks.
