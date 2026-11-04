# Muesli — Design

Muesli takes notes in meetings, so you remember them. It does that one job, fully on your Mac, and stays out of the way.

## Principles

- **The filesystem is the API.** Muesli writes well-structured plain files. Everything else (summaries, chat, integrations) happens outside it: in your agent, through MCP, hooks, or the CLI.
- **100% local, privacy first.** No network access except optional model downloads. Free and open source.
- **Small.** Native binary (a few MB), no bundled runtime.
- **Minimal UI.** A menu bar status icon and a list of meetings.

## Decisions

| Area | Decision |
|---|---|
| Platform | macOS 26+ only (for now) |
| Language / shell | Swift, SwiftUI `MenuBarExtra`; one binary that also runs as the CLI and MCP server |
| System audio | Core Audio process taps (no Screen Recording permission) |
| Mic | Separate track, voice processing on (echo cancellation) |
| Transcription | Apple `SpeechAnalyzer` / `SpeechTranscriber`: on-device, OS-managed models, nothing to download. Behind a `Transcriber` protocol so Parakeet/Whisper can be added later |
| Languages | English + major European languages for v1; check `SpeechTranscriber.supportedLocales` at runtime. Chinese possible later |
| Speaker ID | Mic vs system channel gives Me / Others; diarization on the system track gives Speaker 1..n; local voice-print DB to remember names |
| Meeting detection | Per-process mic usage (Core Audio). No calendar access |
| Start behaviour | Notification with one-click "Record"; per-app "always record" setting |
| Stop behaviour | Mic released for ~20 s → end, run the final pass |
| Audio retention | Optional, **off by default** (transcript only) |
| Pipeline | Chunked live transcription written incrementally → final diarization + cleanup pass at end |
| Extensibility | MCP server (stdio), `on-meeting-end` hook executables, CLI. No in-process plugins |
| Distribution | Notarized DMG + Sparkle updates; Homebrew cask |
| Permissions | Microphone, System Audio Recording, Notifications. Nothing else |

## File layout

```
~/Meetings/                      # configurable
  2026/11/
    2026-11-04 1030 Zoom/
      transcript.md              # YAML frontmatter + speaker-labelled text
      transcript.json            # segments, timings, speaker ids, confidence
      notes.md                   # optional scratchpad
      audio.m4a                  # only if retention is enabled
```

Any search index is a derived cache that can be rebuilt from these files.

## Open questions

- Diarization model: FluidAudio (CoreML) is the likely choice. It needs a small model download (tens of MB). Confirm size and quality.
- Browser-based meetings (Google Meet): the browser using the mic is an ambiguous signal; v1 only shows a prompt.

## Build order

1. Menu bar app + per-process mic detection + notification prompt
2. Dual-track capture (tap + mic with echo cancellation) to disk
3. Live transcription → `transcript.md`
4. Final pass: diarization, `transcript.json`
5. CLI + MCP server + hooks
6. Signing, notarization, Sparkle, Homebrew cask
