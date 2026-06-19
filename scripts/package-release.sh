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
  --deep
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

codesign --verify --deep --strict --verbose=2 "$APP"
DITTONORSRC=1 COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$APP" "$ZIP"

echo "Built $APP"
echo "Built $ZIP"
echo "Signed with $SIGN_LABEL"
