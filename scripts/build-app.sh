#!/usr/bin/env bash
# Builds build/Muesli.app from the Swift package.
#
#   CONFIG=debug scripts/build-app.sh
#   MUESLI_SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#
# Default signing is ad-hoc ("-"). macOS ties privacy permissions to the signature, and an
# ad-hoc signature changes on every build, so you'll be re-prompted for mic / system audio
# access after each rebuild. Signing with a stable identity (even a self-signed one) avoids that.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${MUESLI_SIGN_IDENTITY:--}"
APP="build/Muesli.app"

swift build -c "$CONFIG" --product Muesli
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Muesli"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Muesli"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --options runtime \
  --entitlements Resources/Muesli.entitlements \
  --sign "$SIGN_IDENTITY" "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
