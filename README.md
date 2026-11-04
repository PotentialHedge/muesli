# Muesli

Local, private meeting notes for macOS. See [DESIGN.md](DESIGN.md).

Status: menu bar app, meeting detection, dual-track recording (mic = you, system audio = everyone
else), live on-device transcription, and speaker identification at the end of each meeting.
Each meeting becomes a folder with `transcript.md` and `transcript.json`; audio is deleted
afterwards unless you turn on "Keep Audio After Transcribing".

On first use, macOS downloads the speech model for your language, and Muesli downloads ~34 MB of
speaker-diarization models from Hugging Face. After that nothing leaves your Mac.

## Build & run

Requires macOS 26+ and Xcode.

```sh
scripts/build-app.sh          # → build/Muesli.app (ad-hoc signed)
open build/Muesli.app         # menu bar app
swift test                    # unit tests
```

The binary is also a CLI:

```sh
build/Muesli.app/Contents/MacOS/Muesli mic-users              # who's using the mic, and which meeting app it maps to
build/Muesli.app/Contents/MacOS/Muesli record --seconds 10    # test recording, then transcribe
build/Muesli.app/Contents/MacOS/Muesli transcribe "<meeting folder>" [--language de-DE] [--no-diarize] [--delete-audio]
build/Muesli.app/Contents/MacOS/Muesli languages              # transcription languages on this Mac
```

`transcribe` re-runs the final pass on a folder that still has its `audio/` (e.g. one recorded
with audio retention on, or one whose transcription failed).

Run CLI commands with `open -n build/Muesli.app --args <command>` if you want Muesli's own
privacy permissions rather than your terminal's.

Each rebuild changes the ad-hoc signature, so macOS asks for permissions again. Set
`MUESLI_SIGN_IDENTITY` to a stable (even self-signed) code-signing identity to avoid that.
