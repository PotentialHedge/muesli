#!/usr/bin/env bash
# Builds a release and publishes it as a GitHub release that Sparkle picks up.
#
#   scripts/release.sh 0.2.0
#
# Code-signs with TINYMUESLI_SIGN_IDENTITY, by default the self-signed "Muesli Self-Signed" certificate
# from this Mac's keychain. macOS ties privacy permissions to that certificate, so releases must
# keep using it (an ad-hoc release would lose every user's permissions).
#
# Bumps the version in Resources/Info.plist (commit that afterwards), builds, zips the app, signs
# the zip with the Sparkle EdDSA key from this Mac's keychain, and uploads the zip and appcast.xml
# to a release tagged v<version>. The app's SUFeedURL points at the latest release's appcast.xml.
#
# The key's public half is SUPublicEDKey in Info.plist. Without the private half (made once with
# .build/artifacts/sparkle/Sparkle/bin/generate_keys; back it up with its -x option) no update
# can be published that existing copies will install.
#
# DRY_RUN=1 builds and writes build/release/ without creating the release.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version, e.g. 0.2.0>}"
REPO="PotentialHedge/tinymuesli"
TAG="v$VERSION"
PLIST=Resources/Info.plist
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
OUT=build/release
export TINYMUESLI_SIGN_IDENTITY="${TINYMUESLI_SIGN_IDENTITY:-Muesli Self-Signed}"

# Sparkle compares CFBundleVersion, so it must grow with every release.
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"

[ -x "$SPARKLE_BIN/generate_appcast" ] || swift package resolve
scripts/build-app.sh

rm -rf "$OUT"
mkdir -p "$OUT"
ZIP="$OUT/tinyMuesli-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent build/tinyMuesli.app "$ZIP"
# Signs the zip with the keychain key and writes $OUT/appcast.xml with one item, for this version.
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" "$OUT"

echo "tinyMuesli $VERSION (build $BUILD): $ZIP, $OUT/appcast.xml"
if [ "${DRY_RUN:-0}" = 1 ]; then
  echo "DRY_RUN: no release created"
  exit 0
fi
gh release create "$TAG" --repo "$REPO" --title "tinyMuesli $VERSION" --generate-notes "$ZIP" "$OUT/appcast.xml"
