#!/usr/bin/env bash
# End-to-end check of the dictation → paste path without a microphone:
# plays a fixture into Apen as if it were the mic, lets Apen paste into a new TextEdit document,
# then reads the document back and checks the clipboard was restored.
#
# Needs a Debug build running (make run) with Accessibility allowed for Apen, and lets this terminal
# control TextEdit (macOS asks once).
set -euo pipefail

cd "$(dirname "$0")/.."
FIXTURE="${1:-$PWD/Fixtures/generated/acronyms.wav}"
EXPECT="${2:-RLS policy}"
SENTINEL="apen-e2e-sentinel-$RANDOM"

[[ -f "$FIXTURE" ]] || { echo "missing fixture $FIXTURE (run make fixtures)"; exit 1; }
APP="${APEN_APP:-$PWD/build/DerivedData/Build/Products/Debug/Apen.app}"
pgrep -f "$APP/Contents/MacOS/Apen" >/dev/null || { echo "The Debug build isn't running (make run)"; exit 1; }

printf '%s' "$SENTINEL" | pbcopy
osascript -e 'tell application "TextEdit" to activate' -e 'tell application "TextEdit" to make new document' >/dev/null
sleep 1

# Send the URL to the Debug build explicitly; the Release app in /Applications ignores debug commands.
open -g -a "$APP" "apen://debug/dictate?file=${FIXTURE}&speed=4"

text=""
for _ in $(seq 1 60); do
  sleep 0.5
  text="$(osascript -e 'tell application "TextEdit" to get text of document 1' 2>/dev/null || true)"
  [[ -n "$text" ]] && break
done
sleep 2
clipboard="$(pbpaste)"

echo "Pasted: $text"
status=0
if [[ "$text" == *"$EXPECT"* ]]; then echo "✔ paste contains \"$EXPECT\""; else echo "✘ expected \"$EXPECT\""; status=1; fi
if [[ "$clipboard" == "$SENTINEL" ]]; then echo "✔ clipboard restored"; else echo "✘ clipboard not restored: $clipboard"; status=1; fi

osascript -e 'tell application "TextEdit" to close document 1 saving no' >/dev/null 2>&1 || true
exit $status
