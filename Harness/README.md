# Harness

The app's behaviour as a pure Swift package with no UI import, so every push tests it on Linux.

```
swift build      # zero warnings
swift test       # 78 tests, well under a second
```

| Module | What it does | Spec section |
| --- | --- | --- |
| `Capture/HoldGesture` | Presses and releases with times in, `start`/`stop(keep:)` actions out: 250 ms before a hold counts, clips under 1.5 s discarded, a second tap within 350 ms locks, a locked recording stops at 2 h. | "Hold Fn to record" |
| `Capture/VoiceActivity` | Voice detection from loudness alone: a background level that follows the room, speech a few times louder than it; segments start after 300 ms, end after 2 s of silence, drop under 1.5 s, cut at 10 min. | "Voice-detection mode" |
| `Model/Recording` | One recording: `machineText` (never edited by hand) and `text` (yours); `replaceMachineText` keeps your edits through a re-transcribe. Status: recording, transcribing, final, failed. | "Data, storage and privacy" |
| `Text/TranscriptMerge` | Your text as word-level edits to the old machine text, re-applied onto the new one by aligning the two machine texts. A correction the new transcript already made is not doubled; an edit whose place vanished is kept at the nearest one. | "edits are stored as a diff" |
| `Text/TranscriptText` | Row titles (first 60 characters, on a word), Copy all (newest first, `yyyy-MM-dd HH:mm` line, blank-line separator, headers optional), whitespace cleanup and optional filler removal, the vocabulary prompt, paragraphs from segments (a pause over 2 s), `m:ss`. | "Review, copy, edit, delete" |
| `Storage/RecordingStore` | One JSON file per recording in `Recordings/`, audio in `Audio/`, models in `Models/`; atomic saves; recordings left "recording"/"transcribing" by a quit settle on load; orphaned audio found for recovery; Markdown export. | "Data, storage and privacy" |
| `Storage/WAVRepair` | Fixes the RIFF and data sizes of a WAV whose writer never closed it, so a crash mid-recording loses nothing. | "App crashes mid-recording" |
| `Storage/Settings` | The settings with the spec's defaults; `FnUsage` reads what macOS does with the Fn key. | "Settings", "Permissions" |
| `Model/DayGroups` | Today, Yesterday, then dates; text search. | "Main window" |
| `Model/Usage` | A usage sample (system and Holdnote CPU, memory, thermal state) and its words: the meters' labels, the menu's lines, the explanation. The app's `SystemMonitor` fills it from Mach. | — |
| `Update/Release` | Versions, GitHub releases and commits, and the update plan (download GitHub's build, or build here). From ainigh/Layered. | — |
| `Reader/Sentences` | The stream as numbered sentences (`s00001`…): splitting on sentence punctuation and line breaks, long sentences wrapped, ids normalised from what a model writes. | READER.md, "The idea" |
| `Reader/LensParse` | Lenient readers for the plain-line formats the model writes: one reply's sections per lens (`=== ledger ===`, `## Ledger`, `**Ledger**`…), lens entries and the NOTEBOOK section, question lists, the OPEN / READ / ANSWER action. | READER.md |
| `Reader/Lens`, `Reader/ReaderConfig` | The eight default lenses and the budgets (W, M, output cap, sentences at a time, lenses per call, rest between calls…), with their minimums. | READER.md, "The lenses", "Budgets" |
| `Reader/Reading` | Reading: a small chunk at a time through every lens at once, lenses grouped into calls by the window and the output cap, a lens left out of a reply read alone, notebooks carried (compressed, then cut, when over M), a lens that is behind catching up alone; then the questions about the goals, written once and refreshed as the stream grows; resumable through `progress.json`. | READER.md |
| `Reader/Asking` | One question answered with two tools, open a file page or read sentences by id, within the window, optionally about one recording's sentences; cited ids it never read are reported. | READER.md |
| `Reader/ReaderStream` | Adding text and Holdnote's transcripts to the stream (each recording once, once it settles; a corrected one again as a revision), which recording each sentence came from, the state and the estimate, the reader's questions (settled ones dropped) and your answers (spoken ones tied to their recording), pinned questions, corrections, the conversation. | READER.md, "Files written" |
| `Reader/ChatModel`, `Reader/NotesFolder`, `Reader/Tokens` | The model behind a `ChatModel` protocol (the app's `OllamaClient`; tests use a fake) with the prompt measured and refused over budget; plain files in the folder; the character-based token estimate, calibrated after every call. | READER.md, "Budgets" |

## Decisions where the spec was open, and where v0.1 stops short

- **Storage is JSON files, not SwiftData.** One file per recording in a folder you can read; a bad file is skipped, not fatal; testable on Linux. Same folder layout as the spec.
- **Edits are kept as text, merged on re-transcribe**, not stored as a diff. `TranscriptMerge` computes the diff when it is needed, so the file holds plain text you can read and a re-run never destroys your words.
- **The final pass is whisper.cpp (Metal), `large-v3-turbo` by default**, as in Layered, not WhisperKit; the same weights, the same accuracy, a package already known to build on this Mac. There is no live text yet: the spec's `SpeechAnalyzer` needs the macOS 26 SDK, which GitHub's runners don't have, so it is phase 2 behind a `Transcriber`-style swap.
- **Playback highlights the sentence**, not the word: whisper.cpp's segments carry the times; token-level timings are phase 2.
- **The HUD appears when recording starts (250 ms)**, not at 1.5 s: a press released before 1.5 s is discarded and the pill fades at once. Earlier feedback beats a silent key.
- **The event tap is listen-only**, so Fn is not swallowed from the frontmost app. With Fn set to Do Nothing, nothing else acts on it anyway.
- **A microphone change mid-recording stops the recording** and keeps what was recorded (the file's format is the device's), rather than carrying on seamlessly.
- **Audio stays WAV**; AAC transcoding after 24 h is phase 4. Auto-delete audio after N days is in.
- **The reader started as the Night Reader extension's engine** and now reads any time: a small chunk at a time through every lens at once rather than one full pass per lens overnight, so what you said is read within minutes and the questions for you arrive while you still remember. Ollama is behind a protocol, so reading and asking run end to end in the tests on a fake model. Transcripts join the stream once each, under a date line, so "at what point" can be answered in calendar time, and each sentence remembers its recording. The extension's folder picker became a folder in Application Support, its Chrome storage became UserDefaults and `chat.json`, and its keep-awake became `ProcessInfo.beginActivity`.
- **Voice detection is energy-based**, not Silero VAD: no extra model to download, and it runs on the audio thread for nothing. It can mistake loud steady noise for speech in a quiet room; a neural detector is a drop-in behind the same `VoiceActivity` interface if that turns out to matter. Segments are tagged with their listening session but listed by day like everything else.
- **Parakeet A/B, Spotlight exclusion toggle and folder encryption** are not in v0.1.
