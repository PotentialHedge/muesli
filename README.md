# Muesli

Local, private meeting notes for macOS. See [DESIGN.md](DESIGN.md).

Status: menu bar app, meeting detection, and dual-track recording (mic = you, system audio = everyone else). No transcription yet.

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
build/Muesli.app/Contents/MacOS/Muesli record --seconds 10    # test recording
```

Run CLI commands with `open -n build/Muesli.app --args <command>` if you want Muesli's own
privacy permissions rather than your terminal's.

Each rebuild changes the ad-hoc signature, so macOS asks for permissions again. Set
`MUESLI_SIGN_IDENTITY` to a stable (even self-signed) code-signing identity to avoid that.
