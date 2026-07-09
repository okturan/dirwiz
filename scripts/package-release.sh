#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="DirWiz"
PRODUCT_NAME="DirWiz"
PLIST="$ROOT/DirWiz/Info.plist"
ENTITLEMENTS="$ROOT/DirWiz/DirWiz.entitlements"
ICON="$ROOT/DirWiz/Resources/DirWiz.icns"
DIST_DIR="${DIRWIZ_DIST_DIR:-"$ROOT/dist"}"
APP="$DIST_DIR/$APP_NAME.app"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
ZIP="$DIST_DIR/$APP_NAME-$VERSION-macos.zip"

swift build -c release --product "$PRODUCT_NAME"

rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/release/$PRODUCT_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$PLIST" "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/DirWiz.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod +x "$APP/Contents/MacOS/$APP_NAME"
xattr -cr "$APP" 2>/dev/null || true

SIGN_IDENTITY="${DIRWIZ_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F '"' '/Developer ID Application|Apple Development|Mac Developer/ { print $2; exit }' \
      || true
  )"
fi

SIGN_LABEL="$SIGN_IDENTITY"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
  SIGN_LABEL="ad hoc"
fi

SIGN_ARGS=(
  --force
  --options runtime
  --entitlements "$ENTITLEMENTS"
  --sign "$SIGN_IDENTITY"
)

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  SIGN_ARGS+=(--timestamp=none)
else
  SIGN_ARGS+=(--timestamp)
fi

codesign "${SIGN_ARGS[@]}" "$APP"
xattr -cr "$APP" 2>/dev/null || true

codesign --verify --strict --verbose=2 "$APP"
DITTONORSRC=1 COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$APP" "$ZIP"

echo "Built $APP"
echo "Built $ZIP"
echo "Signed with $SIGN_LABEL"

# Notarization: gated on a real (non-ad-hoc) Developer ID signature AND App Store
# Connect API-key credentials. Without both, the ad-hoc build above is the final
# artifact (unchanged prior behavior). Credentials come from three vars, which may
# be exported or placed in a git-ignored scripts/notary.env:
#   DIRWIZ_NOTARY_KEY     path to the AuthKey_XXXX.p8 (keep it outside the repo)
#   DIRWIZ_NOTARY_KEY_ID  the 10-char Key ID
#   DIRWIZ_NOTARY_ISSUER  the Issuer ID (UUID)
# API-key auth needs no app-specific password and no keychain profile, so the whole
# build→notarize→staple runs headless (locally or in CI).
if [[ -f "$ROOT/scripts/notary.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/scripts/notary.env"
fi
NOTARY_KEY="${DIRWIZ_NOTARY_KEY:-}"
NOTARY_KEY_ID="${DIRWIZ_NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${DIRWIZ_NOTARY_ISSUER:-}"

if [[ "$SIGN_IDENTITY" != "-" && -n "$NOTARY_KEY" && -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER" ]]; then
  if [[ ! -f "$NOTARY_KEY" ]]; then
    echo "Notarization key not found at: $NOTARY_KEY" >&2
    exit 1
  fi
  echo "Submitting $ZIP for notarization (key id: $NOTARY_KEY_ID)..."
  # --wait blocks until Apple returns Accepted/Invalid; a non-Accepted result is a
  # non-zero exit, which aborts the script (set -e). On failure, inspect with:
  #   xcrun notarytool log <submission-id> --key "$NOTARY_KEY" \
  #     --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
  xcrun notarytool submit "$ZIP" \
    --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait

  # Staple the ticket onto the .app (not the zip — stapler can't staple an archive),
  # then rebuild the zip from the stapled app so the ticket travels with the download
  # and the app passes Gatekeeper offline on other Macs.
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  DITTONORSRC=1 COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$APP" "$ZIP"

  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=4 "$APP" || true
  echo "Notarized and stapled: $APP"
  echo "Distributable (ticket embedded): $ZIP"
else
  echo "Skipped notarization (ad-hoc build). To enable: install a Developer ID Application"
  echo "certificate and set DIRWIZ_NOTARY_KEY / _KEY_ID / _ISSUER (or scripts/notary.env)."
fi
