# Utter

Local dictation for macOS, a free replacement for Superwhisper. Press **⌥Space**, talk, and press it again. Your words
are transcribed on this Mac and pasted into whatever window is selected. Nothing is sent to a server.

- **Menu bar app** with your recent transcripts (one-click Copy), a microphone picker, and the dictation mode.
- **Long dictations**: text is transcribed while you talk, so it's ready about a second after you stop, even after
  ten minutes.
- **Files**: drop an audio or video file on *Transcribe File…*.
- **Open-weight models, on device**: NVIDIA Parakeet Unified EN for speech (Neural Engine). Optionally Qwen3-4B for
  cleanup (GPU).
- **Memory only while working**: models load when you start talking and are released as soon as the text is
  delivered. The cleanup model runs in a helper process that exits afterwards.
- **History**: every transcript is saved locally and searchable.
- **Personal dictionary**: "when I say *RLS*, write *row-level security*". Tolerates `R.L.S.` / `rls` / aliases, and
  can bias the speech model toward your jargon.
- **Modes** for the optional cleanup: Coding (prompts for AI coding tools), General, Writing, Message, Email, Notes,
  Raw. Apps switch modes automatically (Cursor/VS Code/Terminal/Claude → Coding, Slack → Message, Mail → Email…).

## Setup

Requirements: Apple Silicon, macOS 26, Xcode 27.

```bash
make bootstrap   # installs XcodeGen if needed, creates Config/Local.xcconfig, generates the project
make models      # one-time: downloads Parakeet (~600 MB) + vocabulary model (~100 MB)
make install     # Release build into /Applications and launches it
```

Set `DEVELOPMENT_TEAM` in `Config/Local.xcconfig` to your Apple Development team so macOS keeps Utter's
permissions across rebuilds. Without it, builds are ad-hoc signed and you re-grant Accessibility after every
rebuild.

On first launch, the welcome window walks through the rest:

1. **Microphone**: asked the first time you dictate.
2. **Accessibility**: lets Utter press ⌘V for you (System Settings › Privacy & Security › Accessibility).
3. **Models**: the speech model, and optionally the 2.5 GB cleanup model.
4. **Shortcut**: change it in Settings › General. Quit Superwhisper, which also uses ⌥Space.

## Using it

| Action | How |
| --- | --- |
| Dictate | Tap ⌥Space, talk, tap ⌥Space. Or hold ⌥Space while talking and release |
| Cancel | Esc while recording (while processing, Esc skips the paste; the text is still saved) |
| Skip cleanup | Press ⌥Space while "Cleaning up" shows, to paste the uncleaned text now |
| Copy an old transcript | Menu bar › Recent › copy icon, or History (⇧⌘C) |
| Switch microphone | Menu bar › microphone menu (affects Utter only) |
| Pick a mode | Menu bar › Mode, or Settings › Modes to assign apps and add per-mode instructions |
| Transcribe a file | Menu bar › Transcribe File…, drag a file in, or Finder › Open With › Utter |

## Where things live

| What | Where |
| --- | --- |
| History and dictionary | `~/Library/Application Support/Utter/utter.sqlite` |
| Recordings (kept only on failure, or if you choose) | `~/Library/Application Support/Utter/Recordings/` |
| Cleanup model | `~/Library/Application Support/Utter/Models/` |
| Speech models | `~/Library/Application Support/FluidAudio/Models/` |

## Development

```bash
make test          # unit tests (dictionary, triggers, text, cleanup prompt/guard, stores)
make fixtures      # speech fixtures generated with `say`
make integration   # model-backed tests: accuracy, long-form, latency, boosting, cleanup, memory
make run           # Debug build + launch
./scripts/e2e-paste.sh   # plays a fixture as the mic, checks the paste into TextEdit and the clipboard restore
cd Packages/UtterKit && swift run utter transcribe <file> --memory   # headless transcription + memory report
```

Measured on an M3 Max:

- A 5.2-minute recording transcribes with 0% WER on the `say` fixture, and the final text arrives 0.09 s after
  the audio ends.
- Warm model load takes 0.15–0.4 s. The first load compiles for the Neural Engine (~20 s, done during setup).
- Cleanup takes 0.2–1 s for a typical prompt. The helper starts in 0.35 s warm.
- Memory:
  - Idle: about 42–53 MB for Utter.
  - While dictating: about 60 MB for Utter, plus about 665 MB for the cleanup helper when cleanup is on.
  - After the paste: back to idle, and the helper has exited.

See [AGENTS.md](AGENTS.md) for architecture and conventions. Third-party licenses are in
[LICENSES/THIRD_PARTY.md](LICENSES/THIRD_PARTY.md).
