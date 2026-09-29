#!/usr/bin/env bash
# Generates speech fixtures with macOS `say` (no network) plus the expected text for each.
# Output: Fixtures/generated/<name>.wav (16 kHz mono) and <name>.txt; m4a/mp4 copies of `short`.
set -euo pipefail

cd "$(dirname "$0")"
OUT=generated
VOICE="${VOICE:-Samantha}"
mkdir -p "$OUT"

make_fixture() {
  local name="$1" text="$2"
  printf '%s\n' "$text" > "$OUT/$name.txt"
  say -v "$VOICE" -o "$OUT/$name.aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$OUT/$name.aiff" "$OUT/$name.wav"
  rm -f "$OUT/$name.aiff"
}

make_fixture short "The quick brown fox jumps over the lazy dog near the riverbank."
make_fixture acronyms "Please check the RLS policy for BPC before the PR merges tonight."
make_fixture instruction "Write me a Python function that reverses a string and make it handle Unicode correctly."
make_fixture ramble "Um so I was thinking that uh we should probably like refactor the login flow because you know it keeps timing out on slow networks."

# Five seconds of silence.
python3 - "$OUT/silence.wav" <<'PY'
import struct, sys, wave
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(struct.pack("<h", 0) * 16000 * 5)
PY
: > "$OUT/silence.txt"

# About six minutes of long-form speech: twelve paragraphs, each with a distinctive keyword.
KEYWORDS=(giraffe lighthouse saxophone volcano pineapple glacier harmonica telescope cinnamon avalanche marathon origami)
: > "$OUT/long.txt"
: > "$OUT/long-keywords.txt"
for keyword in "${KEYWORDS[@]}"; do
  paragraph="This paragraph is about the ${keyword}. When we plan the next release we should remember the ${keyword}, because the team agreed that every long dictation must keep its details in order, from the first sentence to the last one. The ${keyword} is the reminder that nothing in the middle of a long recording can be dropped, repeated or reordered while the model transcribes it in the background. After that we can move on and talk about the next topic, which will come right after a short pause."
  printf '%s\n' "$paragraph" >> "$OUT/long.txt"
  printf '%s\n' "$keyword" >> "$OUT/long-keywords.txt"
done
say -v "$VOICE" -o "$OUT/long.aiff" -f "$OUT/long.txt"
afconvert -f WAVE -d LEI16@16000 -c 1 "$OUT/long.aiff" "$OUT/long.wav"
rm -f "$OUT/long.aiff"

# Container variants for the file decoder.
afconvert -f m4af -d aac "$OUT/short.wav" "$OUT/short.m4a"
if command -v ffmpeg >/dev/null; then
  ffmpeg -loglevel error -y -f lavfi -i color=c=black:s=320x240:d=5 -i "$OUT/short.wav" \
    -shortest -c:v libx264 -pix_fmt yuv420p -c:a aac "$OUT/short.mp4"
fi

echo "Fixtures written to $(pwd)/$OUT"
