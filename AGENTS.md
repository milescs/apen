# Utter — agent guide

Utter is a personal, fully local macOS menu-bar dictation app (a Superwhisper replacement). Speech is transcribed
on-device by NVIDIA Parakeet Unified EN (via FluidAudio, Core ML / Neural Engine); an optional cleanup pass uses
Qwen3-4B-Instruct-2507 through llama.cpp. English only.

## Hard rules

- **Local only.** No cloud APIs, telemetry or network calls at runtime. The only network access is the explicit
  model downloads (`SpeechModel.download`, `BoostModel.download`, `CleanupModel.download`). Tests use local models
  and `say`-generated fixtures only.
- **Free, open-weight models only.** Don't add or reuse proprietary model files (e.g. anything from Superwhisper's
  folders). Keep the attributions in `LICENSES/` and the About window accurate.
- **Models occupy memory only while working.** Speech and cleanup models load at the start of a recording or file job
  and are released when it ends (`SpeechModelHost`, `ModelLifecycle`). Don't add long-lived model references.
- **Never lose a dictation.** Audio is written to `~/Library/Application Support/Utter/Recordings/` while recording and
  deleted only after the transcript is saved (unless the user keeps recordings).
- **Privacy.** Don't log transcripts. `EngineLogging.quiet()` keeps FluidAudio's debug text out of the system log.

## Layout

| Path | What |
| --- | --- |
| `project.yml` | XcodeGen spec (the `.xcodeproj` is generated and gitignored) |
| `App/` | App target: SwiftUI + AppKit glue (menu bar, HUD, hotkeys, paste, windows) |
| `Packages/UtterKit/Sources/UtterCore` | Pure logic + GRDB stores (dictionary matcher, trigger state machine, text utilities, cleanup prompt/guard) |
| `Packages/UtterKit/Sources/UtterEngines` | FluidAudio + llama.cpp: audio capture/decoding, live transcription, model management, cleanup runtime |
| `Packages/UtterKit/Sources/utter-cli` | `utter` CLI: model downloads, headless transcription, memory measurements |
| `Fixtures/` | `make-fixtures.sh` (speech fixtures via `say`); `Fixtures/real/` holds personal recordings (gitignored) |

## Commands

| Task | Command |
| --- | --- |
| First setup | `make bootstrap && make models` |
| Unit tests | `make test` |
| Model-backed tests | `make integration` |
| Build + run (Debug) | `make run` |
| Install to /Applications | `make install` |
| Transcribe a file headlessly | `cd Packages/UtterKit && swift run utter transcribe <file> --memory` |
| Reset permissions | `make reset-tcc` |

## Conventions

- Swift 6 language mode with complete strict concurrency; zero warnings.
- Audio tap and Core Audio listener closures must be created in nonisolated code and capture no main-actor state
  (a main-actor closure on the audio thread traps at runtime).
- All Core ML calls go through `CoreMLGate` (concurrent FluidAudio managers can crash).
- FluidAudio's README/API docs are stale; read the source at the pinned tag in `.build/checkouts/FluidAudio`.
- Behavior changes ship with tests next to the code (`Tests/UtterCoreTests`, `Tests/UtterEnginesTests`).
