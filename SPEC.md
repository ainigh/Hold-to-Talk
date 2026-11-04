# Hold-to-Talk Mac Recorder & Transcriber — Spec

Nov 3, 2026 · @nigh

## Overview

A menu-bar-only macOS app that turns a held Fn key into a voice recorder and turns every recording into a near-perfect, editable, copyable transcript, fully on-device. Working name: **Holdnote**.

The app does three things, and a fourth that lives in its own window and its own spec (`READER.md`): the reader, which takes every transcript into a stream, reads it overnight through several lenses with a local model (Ollama), and answers questions about it in the morning, citing the sentences it relied on.

The recorder does three things and nothing else:

1. **Capture** — hold Fn to record, release to stop (or let voice-detection mode record for you).
2. **Transcribe** — a two-pass on-device pipeline: fast live text while you talk, then a slower, best-available model rewrites it for accuracy.
3. **Review** — a single window with a list of recordings on the left and the editable transcript on the right. Copy one, copy all, append notes, delete.

Guiding principles:

- **Accuracy over speed.** The final transcript is what matters; live text is a courtesy and is allowed to be wrong until the final pass lands.
- **Zero network.** Audio and text never leave the Mac. No account, no telemetry.
- **Invisible until needed.** No Dock icon, no windows on launch, one menu-bar glyph, one HUD while recording.
- **Native feel.** SwiftUI + AppKit, system materials, system motion curves. It should feel like Apple shipped it.

## Platform and constraints

Target is your machine: Apple Silicon M1, 64 GB unified memory, macOS 26. That memory budget is generous — the largest on-device speech models need under 4 GB — so the spec chooses accuracy freely and never trades it for RAM.

| Item | Decision | Why |
| --- | --- | --- |
| Minimum macOS | 26 (Tahoe) | Unlocks Apple's new `SpeechAnalyzer` API; see Transcription engine |
| Hardware | Apple Silicon only (M1+) | All models run on Neural Engine / GPU; no Intel path |
| Language | Swift 6, SwiftUI for views, AppKit for menu bar, HUD window and global key capture | Native look, lowest-latency key handling |
| Audio | `AVAudioEngine` input tap, 16 kHz mono float32 to the models, 48 kHz source kept on disk | Models want 16 kHz; keeping the original lets a better future model re-transcribe |
| Storage | SwiftData (SQLite) for metadata and text, audio files in `~/Library/Application Support/Holdnote/Audio/` | Simple, local, Time Machine-friendly |
| Distribution | Developer ID signed, notarized, not sandboxed | Global Fn capture needs Accessibility access, which App Store sandbox cannot grant |
| Network | None. No analytics, no update checks unless you add Sparkle later | Privacy is a feature |
| Model weights | Downloaded once on first launch (\~1.5 GB Whisper large-v3-turbo + Apple locale assets) | Only network the app ever touches, and only with your consent on the setup screen |

## Core user flows

### 1. Hold Fn to record

1. Press and hold **Fn**. After 250 ms of continuous hold, recording starts. A short, soft tick plays and a HUD pill fades in at the top-center of the active display.
2. Speak. The pill shows a live waveform, a running timer, and (if live transcription is on) the last line of provisional text.
3. Release Fn. Recording stops, the pill shows a brief “Transcribing…” state, then collapses to a checkmark and fades out. The recording appears at the top of the list, with provisional text immediately and the final high-accuracy text a few seconds later.

Rules that keep this from misfiring:

- A press shorter than 250 ms is ignored, so normal Fn use (Fn+arrows, emoji picker) is untouched.
- A press-and-release shorter than 1.5 s total records nothing and shows no UI; it is treated as accidental.
- **Lock mode:** press Fn twice quickly (double-tap, within 350 ms) to start a hands-free recording that keeps going until you tap Fn once. The pill shows a lock glyph so the state is unmistakable.
- Fn must be left as “Do nothing” in System Settings → Keyboard, otherwise macOS will also open the emoji picker or Dictation. The setup screen checks this and deep-links to the setting.
- The hotkey is configurable (Fn is the default; right-Option and a Fn-chord are the alternates), because some external keyboards do not send a usable Fn event.

### 2. Voice-detection mode (nice-to-have, v2)

A toggle in the menu. While on, the app listens continuously but records only when speech is detected.

- Detection runs a lightweight voice-activity detector (Silero VAD, \~2 MB, on-device) on the live mic stream; nothing is written to disk until speech starts.
- A segment starts after 300 ms of speech and ends after 2 s of silence. Segments shorter than 1.5 s are discarded.
- Each segment becomes its own recording, grouped in the list under a “Listening session” header with the session start time.
- The menu-bar glyph pulses slowly while listening and brightens during an active segment, so you always know the mic is live. Holding Fn still works and takes priority.
- Leaving the mode on is a conscious choice: it is never on at launch, and a Notification Center banner reminds you every 2 hours it has been listening.

### 3. Menu bar and main window

The menu-bar glyph (a small waveform) opens a dropdown with: **Open Holdnote**, **Voice detection** (toggle), **Microphone** (submenu of input devices), **Pause hotkey**, **Settings…**, **Quit**.

**Open Holdnote** (or ⌘⇧H from anywhere) shows the main window: a two-pane layout.

- **Left pane — recordings list.** Newest first, grouped by day (Today, Yesterday, then dates). Each row: first \~60 characters of the transcript as the title, duration, time, and a small status dot (grey = transcribing, none = done, amber = needs attention). A search field at the top filters by transcript text.
- **Right pane — transcript.** Selecting a row slides the transcript in. It is a plain, editable text view with the recording’s date, duration and a play button above it. Everything you type is saved as you type.

### 4. Review, copy, edit, delete

- **Copy** (button or ⌘C with the text view unfocused) copies the whole transcript as plain text.
- **Copy all** (toolbar button or ⌘⇧C) copies every transcript in the current list (search-filtered if a search is active), newest first, each preceded by a line with its date and time and separated by a blank line. A Settings option drops the date headers.
- **Edit / add more.** The text view is always editable. Type anywhere, or use the **Append** button at the bottom to jump to the end with a new paragraph. An append-by-voice shortcut — hold Fn while a recording is selected and a modifier (⌥) is held — records a new clip and appends its transcript to the selected recording rather than creating a new one.
- **Play back.** The play button scrubs audio; while playing, the word currently being spoken is highlighted (word timings come free from the models). Click a word to seek there.
- **Delete.** ⌫ or the trash button removes the selected recordings (multi-select supported). Deletion is immediate with a 10-second **Undo** toast; after that the audio file is gone. “Delete audio, keep text” is a secondary action for recordings you want to keep as notes only.
- **Re-transcribe** (context menu) runs the final pass again, e.g. after you add a term to the custom vocabulary.

## Transcription engine

Two passes, two engines, one editable result: Apple's `SpeechAnalyzer` gives live text while you speak; Whisper large-v3-turbo (via WhisperKit) re-transcribes the finished audio with your custom vocabulary and replaces the live text. Live is a courtesy; the Whisper pass is the source of truth.

### Why two engines

The best independent benchmark this year ([get-inscribe, July 2026](https://get-inscribe.com/blog/apple-speech-api-benchmark.html), summarized by [Rohit Raj](https://rohitraj.tech/notes/apple-speechanalyzer-vs-whisper-on-device-stt-2026)) puts Apple's new on-device API at 2.12% word error rate on clean English and 4.56% on noisy English, running 12–40× real time on an M2 Pro. That is roughly Whisper large-v3 accuracy at live speed, and it streams partial results natively. Its two gaps matter for you: it has **no custom-vocabulary API**, and it supports \~30 locales. WhisperKit fills both — it accepts a bias prompt of your names, products and jargon, covers 100+ languages, and a [separate real-world test](https://dicta.to/blog/speech-to-text-engine-comparison-mac-2026/) had it beating Apple on messy English. Running both costs nothing on a 64 GB M1 and gets you the best of each.

| Engine | Role | Model | Approx. size | Speed on M1 |
| --- | --- | --- | --- | --- |
| Apple SpeechAnalyzer (macOS 26 `Speech` framework) | Live text in the HUD, instant provisional transcript | Apple's bundled locale model | \~1 GB per locale, managed by macOS | 10×+ real time, streaming |
| WhisperKit | Final pass, custom vocabulary, non-English | `large-v3-turbo` (Core ML, Neural Engine + GPU) | \~1.6 GB | \~5–8× real time |
| Silero VAD (v2) | Voice-detection mode, trims leading/trailing silence | ONNX / Core ML | \~2 MB | negligible |

All three stay resident in memory after first use (warm models cut the first-transcript latency from \~4 s to under 1 s).

### Pipeline

1. Mic buffers (48 kHz) are written to a WAV file on disk and downsampled to 16 kHz mono in memory.
2. The 16 kHz stream feeds `SpeechAnalyzer` with `.volatileResults`; partial text goes to the HUD, finalized sentences go to the transcript as **provisional** text (rendered in a slightly lighter tone so you can see it is not final).
3. On stop, the WAV file is handed to WhisperKit with: language (auto or pinned in Settings), the custom-vocabulary prompt, word timestamps on, and a 30-second sliding window with 5-second overlap for long recordings.
4. Light post-processing on the Whisper output: merge overlaps, normalize numbers and currency the way you choose in Settings, strip filler words only if you enable it (default off, because “um” sometimes carries meaning).
5. The final text replaces the provisional text in one atomic update, keeping any edits you already typed (see Data: edits are stored as a diff against the machine transcript so a re-run never destroys your words).
6. Audio is kept at 48 kHz WAV for 24 hours, then transcoded to 64 kbps AAC in the background to save space. Settings lets you keep lossless forever.

### Accuracy levers you control

- **Custom vocabulary** (Settings → Vocabulary): a plain list of names, products and terms. Fed to Whisper as the prompt and used for a final spelling-correction pass. This is the single biggest accuracy lever for personal use.
- **Language**: auto-detect by default; pinning a language removes a class of errors on short clips.
- **Microphone choice**: a decent external or AirPods mic beats every model upgrade. The input-level meter in Settings shows clipping.
- **Re-transcribe**: after you add vocabulary, right-click any recording to run the final pass again.

### Engine swap is a one-line change

Transcription sits behind a `Transcriber` protocol with `stream(audio:) -> AsyncStream<Partial>` and `transcribe(file:) -> Transcript`. Parakeet TDT v3 (via FluidAudio) is a drop-in third implementation if a future benchmark shows it winning on your audio; it currently leads on disfluent, fast speech. The protocol means you can A/B engines on your own recordings in Settings → Advanced and pick the one that is actually best for your voice.

## UI/UX spec

The bar is “indistinguishable from an Apple app, with one signature moment”: the recording pill. Everything else is restraint — system fonts, system materials, system motion, no custom chrome.

### Menu bar

- Template (monochrome) waveform glyph, 18 pt, so it matches light/dark menu bars automatically.
- States: idle; recording (glyph becomes a red dot that breathes at 1 Hz); listening (glyph pulses opacity 60→100% over 3 s); transcribing (three-bar glyph animates like a tiny equalizer).
- Left-click opens the dropdown menu. ⌥-click opens the main window directly.

### Recording HUD (the signature)

- A floating pill, 240 × 44 pt, top-center of the display with the cursor, 24 pt below the menu bar. Non-activating panel (`NSPanel`, `.nonactivatingPanel`), ignores mouse, floats above full-screen apps.
- Material: `.hudWindow` vibrancy with a 1 px hairline border at 15% white. Corner radius 22 pt.
- Contents, left to right: red recording dot (8 pt, breathes), live waveform (24 bars, 2 pt wide, 1 pt gap, driven by RMS at 60 fps, eased with a 90 ms low-pass so it feels liquid, not jittery), monospaced timer `0:00`.
- When live text is on, the pill grows to 360 × 64 pt and shows the latest provisional line beneath the waveform in 13 pt, fading older words to 50% as new ones arrive.
- Entrance: scale 0.92→1.0 with opacity 0→1 over 180 ms, spring (response 0.3, damping 0.8). Exit: collapse to a 44 pt circle showing a checkmark, hold 400 ms, fade 150 ms.
- Lock mode shows a small padlock glyph to the left of the timer. Failure (mic unavailable, permission lost) turns the dot amber and the pill shows a one-line reason for 2.5 s.

### Main window

- Default 960 × 620 pt, resizable, remembers size and position. Unified toolbar, no title text, `.sidebar` material on the left pane.
- **Left pane** (min 280 pt): search field pinned at top, then the list. Rows are 56 pt: two lines of transcript preview in 13 pt, a 11 pt secondary line with time and duration. Selected row uses the accent tint. Day headers are sticky.
- **Right pane**: 16 pt body text (SF Pro, 1.45 line height, max 70 characters per line centered in the pane for readability). Header row above the text: date, duration, play/pause, and a progress slider that appears only while playing. Toolbar on the far right: Copy, Append, Re-transcribe, Delete.
- Pane transition when selecting a recording: text crossfades over 120 ms, no slide; the list selection highlight animates its position with a 200 ms spring. Speed over spectacle.
- Empty state: a single centered line, “Hold Fn to make your first recording,” with the Fn glyph drawn as a keycap.
- Provisional text is rendered at 70% opacity; when the final pass lands, each changed word fades to 100% over 300 ms, so you can see the upgrade happen without a jarring replacement.
- Copy feedback: the button briefly becomes “Copied” with a checkmark, 1.2 s, no toast.
- Multi-select with ⇧/⌘-click; the right pane shows “3 recordings selected · Copy all · Delete”.

### Keyboard

| Shortcut | Action |
| --- | --- |
| Fn (hold) | Record |
| Fn Fn | Lock recording on; Fn once to stop |
| ⌥ + Fn (hold) | Record and append to the selected recording |
| ⌘⇧H | Show / hide main window (global) |
| ⌘F | Focus search |
| ↑ / ↓ | Move selection |
| Space | Play / pause selected |
| ⌘C | Copy transcript (when text view is not focused) |
| ⌘⇧C | Copy all |
| ⌫ | Delete selected (with undo) |
| ⌘Z | Undo delete / undo text edit |
| Esc | Close window |

### Settings (single window, four tabs)

General (hotkey, launch at login, sounds, live text on/off), Audio (input device, level meter, keep lossless), Transcription (language, vocabulary list, filler-word removal, number formatting, engine A/B), Storage (location, auto-delete audio after N days, export all as Markdown).

## Data, storage and privacy

Everything lives in one folder you can back up, inspect or delete: `~/Library/Application Support/Holdnote/`.

| What | Where | Notes |
| --- | --- | --- |
| Database | `Holdnote.store` (SwiftData / SQLite) | One `Recording` row per clip |
| Audio | `Audio/<uuid>.wav` → `.m4a` after 24 h | \~5 MB/min WAV, \~0.5 MB/min AAC |
| Models | `Models/` | Whisper weights; Apple's assets are managed by macOS |
| Exports | Wherever you choose | Markdown, one file per recording or one combined file |

`Recording` fields: `id`, `createdAt`, `duration`, `audioURL`, `sourceDevice`, `language`, `machineText` (final Whisper output, never edited), `userEdits` (a diff against `machineText`), `displayText` (derived, cached), `words` (array of `{text, start, end}` for playback highlighting), `status` (recording / provisional / final / failed), `sessionID` (set for voice-detection segments).

Storing your edits as a diff rather than overwriting the text is what makes **Re-transcribe** safe: a better model can replace `machineText` and your added sentences and corrections are re-applied on top.

Privacy rules the app enforces, not just promises:

- No outbound connections after model download (verifiable with Little Snitch or `nettop`).
- The mic is opened only while Fn is held or voice-detection mode is on; the system orange mic indicator is your proof.
- Transcripts are excluded from Spotlight by default (toggle in Settings) so a search in Finder does not surface private notes.
- Deleted recordings are removed from disk, not moved to Trash, after the 10 s undo window.
- Optional: encrypt the folder with a passphrase (FileVault already covers disk-at-rest; this is for the shared-Mac case). v2.

## Permissions, setup and edge cases

First launch is a four-step sheet; the app is unusable until the first three are green, and it says so plainly rather than failing silently later.

1. **Microphone** — standard system prompt.
2. **Input Monitoring** — required to see the Fn key globally via a `CGEventTap` on `flagsChanged`. The sheet explains why and opens the exact pane in System Settings → Privacy & Security.
3. **Fn key behavior** — the app reads `com.apple.HIToolbox AppleFnUsageType`; if Fn is set to Dictation or Emoji, it shows a one-click “Open Keyboard settings” button and re-checks on return.
4. **Models** — downloads Whisper large-v3-turbo (\~1.6 GB) and asks macOS to install the Apple speech asset for your locale, with a progress bar. The hotkey works with live-only transcription while Whisper is still downloading.

Edge cases and the decided behavior:

| Situation | Behavior |
| --- | --- |
| Fn held while another app's text field is focused | Record normally; Holdnote never inserts text into other apps (that is a different product). Fn is swallowed so the frontmost app does not see it. |
| Fn held during screen lock or login window | Ignored. Event taps do not fire there. |
| Mic in use by another app (Zoom, FaceTime) | macOS allows shared input; record anyway. Show a one-line note in the HUD if the input level is zero for 2 s. |
| Default input device changes mid-recording (AirPods disconnect) | Keep recording on the new default without a gap; log the device switch on the recording. |
| Recording longer than 30 min | Fine. Whisper runs windowed; the list row shows an estimate (“\~45 s left”). Lock mode auto-stops at 2 h with a warning at 1 h 55. |
| Mac sleeps mid-recording | Recording stops and is saved and transcribed on wake. |
| App crashes mid-recording | WAV is written incrementally with a header fixup on launch; the partial clip is recovered and transcribed. |
| Whisper pass fails (corrupt audio, model missing) | Status turns amber; the provisional text stays; a Retry button appears. Never lose the audio. |
| Two Holdnote instances | Second launch activates the first and quits. |
| Disk nearly full (< 2 GB) | Refuse to start a new recording and say why in the HUD. |
| Input-monitoring permission revoked while running | Menu glyph shows a warning badge; the menu's first item becomes “Re-enable Fn hotkey…”. |
| External keyboard with no Fn event | Settings offers right-Option or ⌃⌥Space as the hotkey; the setup sheet detects a missing Fn within 10 s of asking you to press it. |

## Gaps closed

The brief left these open; each has a decision above and a one-line reason here. Change any of them.

| Gap in the brief | Decision | Reason |
| --- | --- | --- |
| Fn is already used by macOS (Dictation / Emoji) | Require Fn = “Do nothing” in System Settings; detect and deep-link | The app cannot override that system behavior; fighting it causes double-triggers |
| Capturing Fn at all needs special permission | Input Monitoring + `CGEventTap`; not sandboxed, so direct download instead of App Store | Sandboxed apps cannot see global key events |
| What counts as a “hold” | 250 ms to start, clips under 1.5 s discarded | Protects normal Fn+key use and kills accidental clips |
| Hands-free for long thoughts | Double-tap Fn to lock | Holding a key for 10 minutes is unpleasant |
| “Add more to the text” | Editable text view, Append button, and ⌥+Fn to append by voice | Covers typed and spoken additions |
| “Copy all” format | Newest first, date/time header line, blank-line separator, headers optional | Pasteable into notes or an LLM without cleanup |
| Live vs perfect | Live Apple text, then Whisper replaces it | Both, with the accurate one winning |
| Where accuracy actually comes from | Custom vocabulary list + re-transcribe | Names and jargon are what every model gets wrong |
| What happens to audio | Kept, transcoded to AAC after 24 h, auto-delete after N days optional | Re-transcription needs audio; disk is cheap but not infinite |
| Playback | Included, with word highlighting | Verifying a transcript without hearing it is guesswork |
| Search | Text search in the list | 200 recordings in, you will need it |
| Deleting by mistake | 10 s undo | Permanent delete with no undo is a trust problem |
| Voice-detection mode privacy | Never on at launch, pulsing glyph, 2-hourly reminder | An always-listening mic you forgot about is the one thing that must not happen |
| Naming recordings | Auto-title from first 60 characters, editable | Nobody names voice notes |
| Export | Markdown export, single or combined | Transcripts should outlive the app |
| Multiple mics | Device picker in menu, follows system default otherwise | AirPods vs built-in matters more than any model choice |
| Non-English | Auto-detect, pin in Settings; Whisper covers 100+ languages | Apple's API covers \~30 locales only |
| Speaker identification | Out of scope | Single-user voice notes; adding diarization doubles the pipeline for no gain here |
| Inserting text into other apps (dictation) | Out of scope for v1 | A different product with different UX; easy to add later via the same hotkey |

## Open questions for you

- [ ] Is this for you alone, or will it ship to others? (Decides whether the setup sheet needs polish, and whether an installer or Sparkle updates are worth it.)
- [ ] Which languages do you actually speak into it? If English only, Apple's API alone might be enough and Whisper becomes optional.
- [ ] Do you want filler words (“um”, “like”) removed by default? The spec defaults to keeping them.
- [ ] Should the app ever insert text into the frontmost app, like a dictation tool? The spec says no for v1.
- [ ] How long should audio be kept? The spec keeps it indefinitely unless you set auto-delete.
- [ ] Is a two-step Fn (hold vs double-tap lock) acceptable, or do you want a toggle-only mode?
- [ ] Any need to sync between Macs (iCloud Drive folder)? Not in the spec; easy to add because storage is one folder.

## Phased build plan

Four phases; the first one is already a useful app. Each phase ends with a thing you can use daily, so accuracy and feel get tested on real recordings early.

1. **Capture and final transcript (v0.1).** Menu bar app, Fn event tap, HUD pill with waveform, WAV recording, WhisperKit final pass, list + editable transcript, Copy, Copy all, Delete with undo, SwiftData storage. No live text yet. Exit test: a week of daily use, transcripts you would trust without checking.
2. **Live text and polish (v0.5).** `SpeechAnalyzer` streaming into the HUD and provisional transcript, word-timed playback with highlighting, search, custom vocabulary + Re-transcribe, Append and ⌥+Fn append-by-voice, lock mode, setup sheet with permission checks, keyboard shortcuts, Settings.
3. **Voice-detection mode (v0.8).** Silero VAD, session grouping, listening indicator and reminders, auto-stop safeguards.
4. **Finish (v1.0).** Markdown export, AAC transcoding and retention rules, Spotlight exclusion, crash recovery of partial WAVs, Parakeet as an A/B engine, notarized build.

Risks worth testing in the first two days, before anything else is built: that your keyboard emits a Fn `flagsChanged` event the tap can see (some third-party keyboards do not), and that Whisper large-v3-turbo on the M1 transcribes a 5-minute clip in under a minute (expected \~40 s; if it is much slower, switch the final pass to Parakeet).
