#!/bin/bash
# Opens the built app, waits, and checks it is still running; then prints what its main thread is
# doing. A main thread that is busy rather than waiting for events is a menu bar icon that ignores
# clicks, so the sample says where it's stuck. GitHub Actions runs it after every build.
#
#   scripts/smoke-test.sh            (after scripts/build-app.sh)
set -uo pipefail
cd "$(dirname "$0")/../App"

BIN=build/Holdnote.app/Contents/MacOS/Holdnote
[[ -x "$BIN" ]] || { echo "no $BIN: run scripts/build-app.sh first" >&2; exit 1; }
# Opened the way a person opens it (Launch Services, as the Finder and install.sh do), not run
# from the shell: an app started either way can behave differently.
open -n --stdout build/smoke.log --stderr build/smoke.log build/Holdnote.app
sleep 15
pid="$(pgrep -nf "$PWD/$BIN" || true)"
if [[ -z "$pid" ]]; then
  echo "❌ the app quit within 15 seconds of opening. Its output:"
  cat build/smoke.log
  exit 1
fi

if ! kill -0 "$pid" 2>/dev/null; then
  echo "❌ the app quit within 15 seconds of opening. Its output:"
  cat build/smoke.log
  exit 1
fi
echo "✅ still running after 15 seconds"

sample "$pid" 3 -file build/sample.txt >/dev/null 2>&1 || true
echo "--- the main thread over 3 seconds (idle is mostly mach_msg in the run loop) ---"
sed -n '/com.apple.main-thread/,/^ *[0-9][0-9]* Thread_/p' build/sample.txt | head -200
# Click the menu bar icon the way a person would: each click shows or hides the window (needs the
# runner's accessibility permission; without it this only says so). Two clicks must give two
# different window counts, one open and one closed, whatever state the app started in.
echo "--- clicking the menu bar icon twice ---"
perl -e 'alarm 40; exec @ARGV' osascript <<'OSA' 2>&1 | tee build/click.log || true
tell application "System Events"
  tell process "Holdnote"
    log ("windows at start: " & (count of windows))
    set extras to menu bar 2
    log ("menu bar items: " & (count of menu bar items of extras))
    click menu bar item 1 of extras
    delay 3
    log ("windows after click one: " & (count of windows))
    click menu bar item 1 of extras
    delay 3
    log ("windows after click two: " & (count of windows))
  end tell
end tell
OSA

# Still answering after the window came and went?
sleep 3
echo "--- after the clicks: CPU and the main thread ---"
ps -o %cpu=,stat= -p "$pid" || true
sample "$pid" 3 -file build/sample-window.txt >/dev/null 2>&1 || true
sed -n '/com.apple.main-thread/,/^ *[0-9][0-9]* Thread_/p' build/sample-window.txt | head -120

echo "--- the app's output ---"
head -100 build/smoke.log
alive=yes
kill -0 "$pid" 2>/dev/null || alive=no
kill "$pid" 2>/dev/null || true
one="$(sed -n 's/.*windows after click one: \([0-9]*\).*/\1/p' build/click.log)"
two="$(sed -n 's/.*windows after click two: \([0-9]*\).*/\1/p' build/click.log)"
if [[ -n "$one" && -n "$two" && "$one" == "$two" ]]; then
  echo "❌ clicking the menu bar icon didn't show or hide the window (windows: $one, then $two)"
  exit 1
fi
if [[ "$alive" == no ]]; then
  echo "❌ the app quit after the menu bar icon was clicked"
  exit 1
fi
