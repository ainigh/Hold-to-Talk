# Holdnote — Hold-to-Talk Mac Recorder & Transcriber

A menu-bar-only macOS app: hold **Fn** to record, release to get an editable, copyable transcript, made on this Mac by whisper.cpp. Nothing leaves the machine. `SPEC.md` is the source of truth for recording and transcribing; `READER.md` for the reader; `VFD.md` names every decision the window makes as an axis, with what a change costs, which reads everything you say as you go, through a local model and several lenses at once, asks you about what it can't place, and answers questions about it, citing your words.

```
Harness/   pure Swift package, no UI: the hold gesture, recordings and their folder store, transcript text, settings, the updater's logic, the reader's engine (sentences, lenses, reading in chunks, asking)
App/       the SwiftUI + AppKit menu bar app, a thin projection of the harness
scripts/   build-app.sh: builds, signs and zips Holdnote.app (CI and the updater run it); smoke-test.sh opens it and checks
```

## Install (and update)

**The first time only:** the installer comes through `gh` (GitHub's command line tool), signed in to an account that can see this repository. With [Homebrew](https://brew.sh), paste this in Terminal (a browser window opens to sign in):

```bash
brew install gh && gh auth login --web --git-protocol https -h github.com
```

Then paste this. It keeps your recordings and settings.

```bash
gh api -H "Accept: application/vnd.github.raw" repos/ainigh/Hold-to-Talk/contents/install.sh | bash
```

It downloads the latest build GitHub made into `~/Applications` and opens it. If the new app quits as soon as it opens, or anything fails on the way, the app you had is put back. With no build published yet, it builds the app on your Mac (needs Apple's command line tools: `xcode-select --install`). Needs macOS 14 (Sonoma) or newer on Apple silicon.

**Updates are a click.** The app checks for a new version when it starts and every six hours (or **Check for updates** at the bottom of the window's first column and at the top right of the window). When there is one, a notification says so and the menu bar icon becomes a ⬇︎: click the notification, or the update in the window, and it asks before doing anything: nothing installs until you choose **Install and Restart**. Then it downloads GitHub's build (or builds it on your Mac when GitHub hasn't yet), checks it, swaps it in and opens it again; if the new version won't open, the one you had comes back. It reaches GitHub through `gh`, signed in as above. What went wrong, if anything, is in `~/Library/Logs/Holdnote/update.log` (**Update failed** at the top right of the window › **Copy error report**). Running the install command again still works too.

GitHub Actions (`.github/workflows/build.yml`) tests the harness on Linux and builds the app on macOS on every push; a push to `main` also publishes the build as a release (`v0.1.<run number>`), which is what the installer and the updater download.

## First launch

The window opens on **Setup**, which asks for the four things the hotkey needs, each with a button, and re-checks until they are green:

1. **Microphone.**
2. **Input Monitoring** (System Settings → Privacy & Security), so the app can see the Fn key while you are in any other app. The tap is listen-only; nothing typed is kept.
3. **Fn set to "Do Nothing"** in System Settings → Keyboard ("Press 🌐 key to"), or macOS also opens the emoji picker or Dictation on every hold. Keyboards without a usable Fn can use the right Option key or ⌃⌥Space instead (Settings → General).
4. **The speech model**, downloaded once from huggingface.co with your consent (`large-v3-turbo`, 1.6 GB, by default; smaller ones in Settings → Transcription). The only time the app goes online besides its own updates.

## Using it

- **Hold Fn** (250 ms in, a tick and a pill at the top of the screen with a live waveform and timer); **release** to stop. A recording shorter than 1.5 s is treated as an accident and discarded.
- **Tap Fn twice** to record hands-free (a padlock in the pill); tap once to stop. Stops itself after two hours.
- **Voice Detection** (the first toolbar button, ⌘⇧L, or the switch at the bottom of the window's first column): the mic stays open and each stretch of speech becomes its own recording, no key needed. Speech counts after 300 ms, a 2 s pause ends the segment, and segments under 1.5 s are dropped. Nothing is written until speech starts. The menu bar icon pulses while it's on and turns red while you're heard; it is never on at launch, and a notification reminds you every two hours. Holding Fn still works and takes priority.
- **⌥ + hold Fn** with a recording selected in the window: the new clip's transcript is appended to it.
- **A click on the menu bar icon**, or **⌘⇧H** anywhere, shows or hides the window. A right-click on the icon offers only Show/Hide and Quit; everything else is in the window.
- **The window is three things, in columns.** The first column names them: **Stream** (everything you add, each item text, with your goals and the conversation about it), **Status** (what is running, with its stop; the reading in detail; Setup) and **For you** (what the reader needs you to tell it). Under the hood sit **Lenses** (the angles the reader reads through, editable) and **Notes** (the files it writes); then **Settings**. At the bottom of the column: the **Guide**, updates, Quit. **The top of the window** has the hotkey and Voice Detection switches on the left and, in the middle, what is running: a recording, the transcriber (reading the file, cutting it into chunks, then chunks done and running) or the reader, each with its Stop or Pause. The footer names the speech model in use and, on hover, how the last transcription went.
- **The stream is the real input.** Its items (recordings, dropped or imported audio, pasted or dropped text) are listed in the second column under two rows that are not items: **Goals** (what you are trying to find out, which every lens reads, and the questions the reader keeps answered about it) and **ALL**; search at the top. Choose **ALL** (or nothing, or ⌘⇧A) for everything as one continuous text in the list's order with a date line above each, exactly what the reader reads and Copy All copies, with the conversation about all of it beside it. Choose an item for its text, editable, with what the reader made of it beside it and a conversation about that item alone. So what you ask about follows where you are: ALL, or one item. Beside ALL, **Words** instead of Ask shows every word that carries meaning in the stream (nouns, verbs, adjectives, adverbs; the closed classes such as prepositions and pronouns left out), counted by lemma so "moved" and "moving" are one verb, filtered by kind; click a word to search the stream for it. Beside an item the same choice exists: the reader's take, Words, or text only. Names (people, places, organisations) are counted apart from other nouns. Select any passage of the whole stream and right-click: **Ask the reader about this…** puts it in the field. A mark on a row says the reader has questions about it (with how many) or that you edited it after the reader took it.
- **Your own order.** The list is newest first in day sections, or, from the button at the top of the list (or Settings → General), in your own order: drag recordings and notes up and down to say what came from what, or use Move to Top / Move to Bottom in a row's menu (the whole selection moves together). The top is the latest. Copy All, the whole stream, export and the reader's stream all follow that order; a new recording lands on top, and an older file added later lands among its own time. The order is `order.json` in the Holdnote folder.
- **Drop audio and text files** on the window, or **Import** (⌘⇧I, the toolbar, or + at the top of the list): an m4a from Voice Memos, an mp3, a wav, anything this Mac can play joins the list as a recording and is transcribed like one (the file is kept as it is in `Audio/`); a .txt or .md file, or text dragged from another app, becomes a note. Each is dated by its file, so it sits among its own time. In your own order, files dropped between two rows land there.
- **Long audio is transcribed in chunks, a few at once, and you watch them.** Anything over two minutes (a long hold, a voice-detection monologue, an imported file) is cut at quiet moments into chunks of about five minutes (a two-hour file makes 24), each transcribed on its own; four run at a time on the one loaded model, each taking the next chunk as it finishes, so the GPU stays busy to the end. While it runs, the transcript pane shows every chunk as a tile with its own progress (waiting, running, done), how many run at once, and the control for that number; the first column shows the same in one line. The text is joined back in order with the times intact, and words whisper heard twice at a cut are dropped. Imported files are decoded a block at a time, so a two-hour file doesn't need to fit in memory as recorded. Settings → Transcription → Speed (or the control on the pane) sets how many run at once, or turns splitting off.
- **Paste text as a note** (⌘⇧V, the Paste toolbar button, or ⌘V with the list focused): it joins the list like a recording, titled by its first words, marked "text only", and goes into Copy All with the rest.
- **Stop** a transcription that is taking too long (the button under its progress, the row's menu, or the Recording menu): the audio is kept, marked stopped, and **Retry** runs it again.
- **The bar at the bottom of the window** shows what the Mac is spending and Holdnote's share of it: CPU in use across every app with Holdnote's part in the accent colour, memory in use of what's installed with Holdnote's footprint (mostly the loaded speech model), and a warning when the Mac is running hot. Hover it for the explanation.
- **Start over** (Settings → Storage, or the Recording and Reader menus): **Reset the Reader…** sends the reader's notes, stream, goals and questions to the Trash and reads your recordings again from the oldest; **Reset Everything…** sends every recording and its audio there too, to try Holdnote with no data. Both keep the speech model, permissions and settings, and nothing is deleted: it waits in the Trash in one dated folder.
- Everything lives in `~/Library/Application Support/Holdnote/`: `Recordings/<id>.json`, `Audio/<id>.wav`, `Models/`. Export as Markdown from the Recording menu or Settings → Storage.

## The reader

What you say becomes something you can ask about, as you go. A minute after a transcript is final (and you've stopped editing it) it joins the reader's stream, and when nothing is being recorded or transcribed the reader reads what's new: a small chunk at a time, through every lens at once. It lives in the same window as the recordings (**⌘⇧N** jumps there):

- **The Reader panel, beside every transcript** (the Reader button at the top right of the transcript shows or hides it): whether the recording is in the stream and read; the questions it raised for you, to answer right there; what each lens noticed in it (people and things, threads, feelings, tensions, open threads…); and questions about that recording alone. Edit a transcript after the reader took it, and the panel offers to add the correction.
- **Ask** sits beside the text, for ALL or for one item: your questions and the reader's answers, newest at the bottom, the field under them. Every answer cites sentence ids; click one to see your exact words and open the recording (a `?` marks an id it cited without reading). **Keep answered** pins a question so its answer is refreshed as you say more. **Goals**, above ALL in the stream, holds what you are trying to find out and the questions the reader writes from it, answers from the notes and keeps up to date. **Status** (⌘2) shows what is running (Now, with every stop button), the reading in detail, and Setup. **Flag** a wrong answer and it goes into `corrections.md`, which is read before every later answer. The model has three moves: open a note file a page at a time, read sentences by id, or **find** every sentence a word appears in, a page at a time. It is also given the forty words the stream uses most, as context and as things worth finding, and is told throughout that the text is a machine transcript (even when it was typed), so a mis-heard word is read for what was meant.
- **For you.** What the reader could not work out from your words alone, under the recording each question came from. **Answer by voice** (then hold the hotkey and say it: the next recording is the answer) or type; each answer joins the stream. A notification says when it has new questions while you're elsewhere.
- **Reading.** What it is doing (the chunk in hand and a chip per lens, what the model is writing as it writes it, the log), how far it has read, **Read now**, **Stop**, and the lenses (ledger, people and things, threads, feelings, tensions, open threads, against the goals, questions for you), editable; the model sees the instructions verbatim. The menu bar icon shows glasses while it reads; the window can be closed.
- **Everything you add is the stream.** A transcript or note joins the reader's copy of it by itself a minute after it settles (the whole-stream view says how many are still to join, with a button to add them now); your answers to its questions join too.
- **Notes.** Every file the reader wrote, in the folder (`~/Library/Application Support/Holdnote/Reader/`, or one you choose, iCloud Drive included). Markdown files read as pages, with Edit for the raw text; the rest show as they are.

It needs [Ollama](https://ollama.com) running on this Mac with a model pulled (`ollama pull llama3.1:8b`); Settings → Reader picks the model, how many sentences it reads at a time and how many lenses share a call, the budgets, and whether it reads by itself. `READER.md` has the whole design, from the lenses to the files and the budgets.

## Build and test

Harness (Linux or macOS, Swift 6.1):

```bash
cd Harness && swift build && swift test
```

App (macOS 14, Xcode 16 or newer):

```bash
cd App && make app        # builds Holdnote.app into App/build/ (scripts/build-app.sh, this Mac's chip)
open build/Holdnote.app
```

Or open `App/Package.swift` in Xcode.

## Where things live

| Behaviour | Where |
| --- | --- |
| When a held key starts and stops a recording (250 ms hold, 1.5 s minimum, double-tap lock, 2 h limit) | `Harness/Capture/HoldGesture` |
| A recording, its machine text and your text, re-applying edits onto a new transcript | `Harness/Model/Recording`, `Harness/Text/TranscriptMerge` |
| Titles, Copy all, cleanup, vocabulary prompt, paragraphs from segments, durations | `Harness/Text/TranscriptText` |
| The folder store, Markdown export, crash-recovery of WAV headers | `Harness/Storage/` |
| Settings and what the Fn key is set to | `Harness/Storage/Settings` |
| Day groups and search | `Harness/Model/DayGroups` |
| What the updater compares (versions, releases, commits, the update plan) | `Harness/Update/` |
| The stream's sentences and ids (and which recording each came from), the lenses, reading in chunks with every lens at once (notebooks, the questions about your goals), asking with two tools, the reader's files and progress | `Harness/Reader/` |
| Ollama over HTTP, the reader's state, feeding transcripts as they settle and reading when there's something new | `App/Services/OllamaClient`, `App/Services/ReaderController` |
| The reader's views: Status, For you, Reading, Notes; the ask panel beside the stream and the Reader panel beside an item | `App/Views/Reader*`, `App/Views/RecordingReaderPanel` |
| The event tap, the recorder, whisper, playback, permissions, the updater | `App/Services/` |
| The hold → record → transcribe flow and the HUD pill | `App/Capture.swift`, `App/Views/HUD.swift` |
| The window, list, transcript, settings, setup | `App/Views/` |

See `Harness/README.md` for what the harness decided where the spec was open, and where v0.1 stops short of it.
