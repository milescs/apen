#!/usr/bin/env bash
# End-to-end check of the dictation → paste path without a microphone:
# plays a fixture into Utter as if it were the mic, lets Utter paste into a new TextEdit document,
# then reads the document back and checks the clipboard was restored.
#
# Needs a Debug build running (make run) with Accessibility allowed for Utter, and lets this terminal
# control TextEdit (macOS asks once).
set -euo pipefail

cd "$(dirname "$0")/.."
FIXTURE="${1:-$PWD/Fixtures/generated/acronyms.wav}"
EXPECT="${2:-RLS policy}"
SENTINEL="utter-e2e-sentinel-$RANDOM"

[[ -f "$FIXTURE" ]] || { echo "missing fixture $FIXTURE (run make fixtures)"; exit 1; }
pgrep -x Utter >/dev/null || { echo "Utter isn't running (make run)"; exit 1; }

printf '%s' "$SENTINEL" | pbcopy
osascript -e 'tell application "TextEdit" to activate' -e 'tell application "TextEdit" to make new document' >/dev/null
sleep 1

open -g "utter://debug/dictate?file=${FIXTURE}&speed=4"

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
