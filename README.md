# Holdnote — Hold-to-Talk Mac Recorder & Transcriber

A menu-bar-only macOS app: hold **Fn** to record, release to get an editable, copyable transcript, made on this Mac by whisper.cpp. Nothing leaves the machine. `SPEC.md` is the source of truth.

```
Harness/   pure Swift package, no UI: the hold gesture, recordings and their folder store, transcript text, settings, the updater's logic
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

**Updates are a click.** The app checks for a new version when it starts and every six hours (or **Check for updates** in the menu bar menu and at the top right of the window). When there is one, a notification says so and the menu bar icon becomes a ⬇︎: click the notification, or the update in the menu, and it asks before doing anything: nothing installs until you choose **Install and Restart**. Then it downloads GitHub's build (or builds it on your Mac when GitHub hasn't yet), checks it, swaps it in and opens it again; if the new version won't open, the one you had comes back. It reaches GitHub through `gh`, signed in as above. What went wrong, if anything, is in `~/Library/Logs/Holdnote/update.log` (**Update failed** at the top right of the window › **Copy error report**). Running the install command again still works too.

GitHub Actions (`.github/workflows/build.yml`) tests the harness on Linux and builds the app on macOS on every push; a push to `main` also publishes the build as a release (`v0.1.<run number>`), which is what the installer and the updater download.

## First launch

A setup window asks for the four things the hotkey needs, each with a button, and re-checks until they are green:

1. **Microphone.**
2. **Input Monitoring** (System Settings → Privacy & Security), so the app can see the Fn key while you are in any other app. The tap is listen-only; nothing typed is kept.
3. **Fn set to "Do Nothing"** in System Settings → Keyboard ("Press 🌐 key to"), or macOS also opens the emoji picker or Dictation on every hold. Keyboards without a usable Fn can use the right Option key or ⌃⌥Space instead (Settings → General).
4. **The speech model**, downloaded once from huggingface.co with your consent (`large-v3-turbo`, 1.6 GB, by default; smaller ones in Settings → Transcription). The only time the app goes online besides its own updates.

## Using it

- **Hold Fn** (250 ms in, a tick and a pill at the top of the screen with a live waveform and timer); **release** to stop. A recording shorter than 1.5 s is treated as an accident and discarded.
- **Tap Fn twice** to record hands-free (a padlock in the pill); tap once to stop. Stops itself after two hours.
- **⌥ + hold Fn** with a recording selected in the window: the new clip's transcript is appended to it.
- **⌘⇧H** anywhere shows or hides the window; so does ⌥-clicking the menu bar icon. The icon's click opens the menu: Open, Microphone, Pause Hotkey, updates, Settings, Quit.
- **The window:** recordings on the left (newest first, by day, with search), the transcript on the right, editable; what you type is saved as you type. **Copy** copies one, **Copy All** (⌘⇧C) copies every listed transcript newest first with a date line above each (Settings → Storage turns the date lines off). **Append** adds a paragraph at the end. **Re-transcribe** runs the model again, keeping your edits on top of the new text (after adding names to Settings → Transcription → Vocabulary, say). **Delete** (⌫) waits ten seconds for Undo, then the audio is gone from disk; "Delete audio, keep text" in the row's menu keeps the note. **Play** follows along in the transcript; click in it to seek.
- Everything lives in `~/Library/Application Support/Holdnote/`: `Recordings/<id>.json`, `Audio/<id>.wav`, `Models/`. Export as Markdown from the Recording menu or Settings → Storage.

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
| The event tap, the recorder, whisper, playback, permissions, the updater | `App/Services/` |
| The hold → record → transcribe flow and the HUD pill | `App/Capture.swift`, `App/Views/HUD.swift` |
| The window, list, transcript, settings, setup | `App/Views/` |

See `Harness/README.md` for what the harness decided where the spec was open, and where v0.1 stops short of it.
