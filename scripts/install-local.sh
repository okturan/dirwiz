#!/usr/bin/env bash
set -euo pipefail

# Build and install the current worktree for this Mac only. This deliberately writes under
# .build (never dist/) and disables notarization/network submission. Publishing remains the
# separate release workflow.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_DIST="$ROOT/.build/local-app"
BUILT_APP="$LOCAL_DIST/DirWiz.app"
INSTALLED_APP="/Applications/DirWiz.app"
BACKUP_APP="$LOCAL_DIST/previous-installed/DirWiz.app"
ENTITLEMENTS="$ROOT/DirWiz/DirWiz.entitlements"
PLIST="$BUILT_APP/Contents/Info.plist"

mkdir -p "$LOCAL_DIST"
DIRWIZ_DIST_DIR="$LOCAL_DIST" \
DIRWIZ_SKIP_NOTARIZATION=1 \
  "$ROOT/scripts/package-release.sh"

COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
# Only build inputs determine whether this artifact differs from the named commit. Repo-local
# notes/agent helpers do not enter the bundle, while an untracked Swift source absolutely does.
if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=all -- \
  Package.swift Sources DirWiz CLI scripts/package-release.sh)" ]]; then
  DIRTY="true"
else
  DIRTY="false"
fi

/usr/libexec/PlistBuddy -c "Delete :DirWizLocalSourceCommit" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :DirWizLocalSourceDirty" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :DirWizLocalBuildDate" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :DirWizLocalSourceCommit string $COMMIT" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :DirWizLocalSourceDirty bool $DIRTY" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :DirWizLocalBuildDate string $(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PLIST"

SIGN_IDENTITY="${DIRWIZ_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$({
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F '"' '/Developer ID Application|Apple Development|Mac Developer/ { print $2; exit }'
  } || true)"
fi

SIGN_ARGS=(--force --options runtime --entitlements "$ENTITLEMENTS")
if [[ -n "$SIGN_IDENTITY" ]]; then
  SIGN_ARGS+=(--timestamp --sign "$SIGN_IDENTITY")
else
  SIGN_ARGS+=(--timestamp=none --sign -)
fi
codesign "${SIGN_ARGS[@]}" "$BUILT_APP"
codesign --verify --strict --verbose=2 "$BUILT_APP"

# The package script also makes a zip; remove it from the local-only area so it cannot be
# mistaken for a release artifact.
find "$LOCAL_DIST" -maxdepth 1 -type f -name 'DirWiz-*-macos.zip' -delete

/usr/bin/osascript -e 'tell application id "com.dirwiz.DirWiz" to quit' 2>/dev/null || true

if [[ -e "$BACKUP_APP" ]]; then
  rm -rf "$BACKUP_APP"
fi
mkdir -p "$(dirname "$BACKUP_APP")"
if [[ -e "$INSTALLED_APP" ]]; then
  mv "$INSTALLED_APP" "$BACKUP_APP"
fi

if ! ditto "$BUILT_APP" "$INSTALLED_APP"; then
  if [[ -e "$BACKUP_APP" && ! -e "$INSTALLED_APP" ]]; then
    mv "$BACKUP_APP" "$INSTALLED_APP"
  fi
  exit 1
fi

BUILT_HASH="$(shasum -a 256 "$BUILT_APP/Contents/MacOS/DirWiz" | awk '{print $1}')"
INSTALLED_HASH="$(shasum -a 256 "$INSTALLED_APP/Contents/MacOS/DirWiz" | awk '{print $1}')"
if [[ "$BUILT_HASH" != "$INSTALLED_HASH" ]]; then
  echo "Installed binary does not match the local build" >&2
  exit 1
fi

open "$INSTALLED_APP"

echo "Installed local DirWiz.app from $COMMIT (tracked changes dirty: $DIRTY)"
echo "Binary SHA-256: $INSTALLED_HASH"
echo "Previous installed app: $BACKUP_APP"
echo "No artifact was written to dist/ or submitted to GitHub/Apple notarization."
