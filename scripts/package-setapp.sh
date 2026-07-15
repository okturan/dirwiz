#!/usr/bin/env bash
set -euo pipefail

# Builds the Setapp-format submission archive on top of the regular release
# build. Reuses package-release.sh for build/sign/notarize so that logic
# lives in exactly one place.
#
# NOT a submission by itself: the Setapp Framework and the per-app public key
# (both account-gated, obtained after registering the app with Setapp) are
# not integrated. This script only produces a format-correct archive.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="DirWiz"
PLIST="$ROOT/DirWiz/Info.plist"
ICON="$ROOT/DirWiz/Resources/DirWiz.icns"
DIST_DIR="${DIRWIZ_DIST_DIR:-"$ROOT/dist"}"
APP="$DIST_DIR/$APP_NAME.app"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
SETAPP_ZIP="$DIST_DIR/$APP_NAME-Setapp-$VERSION.zip"

STAGE_DIR="$DIST_DIR/setapp-stage"
ICONSET_DIR="$DIST_DIR/setapp-stage.iconset"
VERIFY_DIR="$DIST_DIR/setapp-verify"

"$ROOT/scripts/package-release.sh"

if [[ ! -d "$APP" ]]; then
  echo "Expected release build at $APP but it does not exist" >&2
  exit 1
fi

rm -rf "$STAGE_DIR" "$ICONSET_DIR" "$VERIFY_DIR" "$SETAPP_ZIP"
mkdir -p "$STAGE_DIR"

# Stage a copy of the signed .app (ditto preserves the code signature; cp -R
# of a bundle can silently drop resource-fork/xattr state on some setups).
ditto "$APP" "$STAGE_DIR/$APP_NAME.app"

# Extract AppIcon.png (1024x1024) from the .icns. iconutil's iconset always
# names the 1024px representation icon_512x512@2x.png (512pt @2x = 1024px).
iconutil --convert iconset --output "$ICONSET_DIR" "$ICON"
SOURCE_ICON="$ICONSET_DIR/icon_512x512@2x.png"
if [[ ! -f "$SOURCE_ICON" ]]; then
  echo "No 1024x1024 representation found in $ICON (expected icon_512x512@2x.png)" >&2
  echo "This is an artwork gap, not a packaging bug -- do not upscale a smaller icon." >&2
  exit 1
fi

ICON_W="$(sips -g pixelWidth "$SOURCE_ICON" | awk '/pixelWidth/ { print $2 }')"
ICON_H="$(sips -g pixelHeight "$SOURCE_ICON" | awk '/pixelHeight/ { print $2 }')"
if [[ "$ICON_W" != "1024" || "$ICON_H" != "1024" ]]; then
  echo "Extracted icon is ${ICON_W}x${ICON_H}, expected 1024x1024" >&2
  exit 1
fi

cp "$SOURCE_ICON" "$STAGE_DIR/AppIcon.png"
rm -rf "$ICONSET_DIR"

# Zip the CONTENTS of the staging directory (no --keepParent) so the archive
# root is exactly DirWiz.app + AppIcon.png, per the Setapp package-format spec.
(
  cd "$STAGE_DIR"
  DITTONORSRC=1 COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --noqtn --noacl . "$SETAPP_ZIP"
)

# --- Self-verification: round-trip the archive and check every requirement ---
mkdir -p "$VERIFY_DIR"
/usr/bin/ditto -x -k "$SETAPP_ZIP" "$VERIFY_DIR"

if [[ ! -d "$VERIFY_DIR/$APP_NAME.app" ]]; then
  echo "Self-check FAILED: $APP_NAME.app not found at archive root after round-trip" >&2
  exit 1
fi
if [[ ! -f "$VERIFY_DIR/AppIcon.png" ]]; then
  echo "Self-check FAILED: AppIcon.png not found at archive root after round-trip" >&2
  exit 1
fi
MACOSX_HITS="$(find "$VERIFY_DIR" -depth -iname "__MACOSX")"
if [[ -n "$MACOSX_HITS" ]]; then
  echo "Self-check FAILED: __MACOSX cruft present after round-trip: $MACOSX_HITS" >&2
  exit 1
fi
echo "Self-check: DirWiz.app + AppIcon.png present, no __MACOSX -- OK"

# codesign --verify is the packaging-correctness check: it fails if the
# ditto round-trip corrupted the signature, regardless of notarization
# state. This is a hard gate.
if ! codesign --verify --deep --strict --verbose=2 "$VERIFY_DIR/$APP_NAME.app"; then
  echo "Self-check FAILED: codesign --verify rejected the extracted app (packaging corrupted the signature)" >&2
  exit 1
fi
echo "Self-check: codesign --verify -- OK"

# spctl --assess is Gatekeeper's notarization-ticket check, not a packaging
# check: it can only pass on a notarized build (real Developer ID signature
# alone is not enough), so it is advisory here rather than fatal -- a build
# lacking notarization credentials (e.g. no scripts/notary.env) will always
# fail it, by design, with no packaging bug involved. package-release.sh
# treats this the same way (`spctl --assess ... || true` after notarizing).
if spctl --assess --type execute --verbose=4 "$VERIFY_DIR/$APP_NAME.app" 2>&1; then
  echo "Self-check: spctl --assess -- OK (notarized)"
else
  echo "Self-check: spctl --assess -- NOT accepted (expected unless the build was notarized; see package-release.sh notarization gating)"
fi

VERIFY_ARCHS="$(lipo -archs "$VERIFY_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME")"
if [[ "$VERIFY_ARCHS" != *arm64* || "$VERIFY_ARCHS" != *x86_64* ]]; then
  echo "Self-check FAILED: extracted binary is not universal (archs: $VERIFY_ARCHS)" >&2
  exit 1
fi
echo "Self-check: lipo -archs reports $VERIFY_ARCHS -- OK"

VERIFY_ICON_W="$(sips -g pixelWidth "$VERIFY_DIR/AppIcon.png" | awk '/pixelWidth/ { print $2 }')"
VERIFY_ICON_H="$(sips -g pixelHeight "$VERIFY_DIR/AppIcon.png" | awk '/pixelHeight/ { print $2 }')"
if [[ "$VERIFY_ICON_W" != "1024" || "$VERIFY_ICON_H" != "1024" ]]; then
  echo "Self-check FAILED: extracted AppIcon.png is ${VERIFY_ICON_W}x${VERIFY_ICON_H}, expected 1024x1024" >&2
  exit 1
fi
echo "Self-check: AppIcon.png is 1024x1024 -- OK"

ZIP_BYTES="$(stat -f%z "$SETAPP_ZIP")"
ONE_GB=$((1024 * 1024 * 1024))
if (( ZIP_BYTES >= ONE_GB )); then
  echo "Self-check FAILED: archive is $ZIP_BYTES bytes, over the 1 GB Setapp cap" >&2
  exit 1
fi
echo "Self-check: archive size $ZIP_BYTES bytes (< 1 GB cap) -- OK"

rm -rf "$STAGE_DIR" "$VERIFY_DIR"

echo ""
echo "Built Setapp package: $SETAPP_ZIP"
echo ""
echo "*** NOT yet submittable ***"
echo "The Setapp Framework and per-app public key are not integrated (both require"
echo "a Setapp developer account: register the app, download the public key, then"
echo "integrate the framework -- see .claude/skills/setapp-submission/references/"
echo "framework-integration.md). This archive is format-ready only."
