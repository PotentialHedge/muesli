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

# Optimise for size: most of the binary is FluidAudio, of which we use only the diarizer.
FLAGS=()
[ "$CONFIG" = release ] && FLAGS=(-Xswiftc -Osize)
swift build -c "$CONFIG" --product Muesli ${FLAGS[@]+"${FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${FLAGS[@]+"${FLAGS[@]}"} --show-bin-path)"
BIN="$BIN_DIR/Muesli"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Muesli"
# Drop local symbols (~half the file). Crash logs still symbolicate public/exported ones.
[ "$CONFIG" = release ] && strip -x "$APP/Contents/MacOS/Muesli"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Sparkle (updates). Muesli isn't sandboxed, so it doesn't need Sparkle's XPC services. The framework
# is re-signed with our identity: the hardened runtime only loads libraries signed by the same team.
# An ad-hoc signature has no team, so ad-hoc builds turn library validation off instead.
FW="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$FW"
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices"
for item in "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app" "$FW"; do
  codesign --force --options runtime --sign "$SIGN_IDENTITY" "$item"
done

ENTITLEMENTS=Resources/Muesli.entitlements
if [ "$SIGN_IDENTITY" = - ]; then
  ENTITLEMENTS="$(mktemp -t muesli-entitlements).plist"
  cp Resources/Muesli.entitlements "$ENTITLEMENTS"
  plutil -insert com\\.apple\\.security\\.cs\\.disable-library-validation -bool YES "$ENTITLEMENTS"
fi

codesign --force --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
