#!/usr/bin/env bash
set -euo pipefail

# SwiftPM compiles AppIntent conformances but does not run Xcode's metadata extraction
# phase for a hand-built .app bundle. Shortcuts and Spotlight discover the generated
# Metadata.appintents resource, so packaging must create it before code signing.

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <DirWiz.app> <swift-build-bin-path>" >&2
  exit 64
fi

APP="$1"
BIN_PATH="$2"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${BIN_PATH%/Products/Release}"
OBJECTS_ROOT="$BUILD_ROOT/Intermediates.noindex/DirWiz.build/Release/DirWiz-p.build/Objects-normal"
OBJECTS="$OBJECTS_ROOT/arm64"
WORK_DIR="$ROOT/.build/app-intents-metadata"
CONST_VALUES_LIST="$WORK_DIR/DirWiz.SwiftConstValuesFileList"
STRINGS_DATA="$WORK_DIR/ExtractedAppShortcutsMetadata.stringsdata"
METADATA="$APP/Contents/Resources/Metadata.appintents"

SOURCE_FILE_LIST="$OBJECTS/DirWiz.SwiftFileList"
CONST_VALUES="$OBJECTS/DirWiz-primary.swiftconstvalues"
DEPENDENCY_FILE="$OBJECTS/DirWiz_dependency_info.dat"
APP_BINARY="$APP/Contents/MacOS/DirWiz"

for required in "$SOURCE_FILE_LIST" "$CONST_VALUES" "$DEPENDENCY_FILE" "$APP_BINARY"; do
  if [[ ! -f "$required" ]]; then
    echo "App Intents metadata input is missing: $required" >&2
    exit 1
  fi
done

TOOLCHAIN="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"
XCODE_BUILD="$(xcodebuild -version | awk '/Build version/ { print $3 }')"
if [[ -z "$XCODE_BUILD" ]]; then
  echo "Could not determine the Xcode build version for App Intents metadata" >&2
  exit 1
fi

mkdir -p "$WORK_DIR"
printf '%s\n' "$CONST_VALUES" > "$CONST_VALUES_LIST"
rm -rf "$METADATA"

xcrun appintentsmetadataprocessor \
  --toolchain-dir "$TOOLCHAIN" \
  --module-name DirWiz \
  --sdk-root "$SDK_ROOT" \
  --xcode-version "$XCODE_BUILD" \
  --platform-family macOS \
  --deployment-target 15.0 \
  --bundle-identifier com.dirwiz.DirWiz \
  --output "$APP/Contents/Resources" \
  --target-triple arm64-apple-macos15.0 \
  --binary-file "$APP_BINARY" \
  --dependency-file "$DEPENDENCY_FILE" \
  --stringsdata-file "$STRINGS_DATA" \
  --source-file-list "$SOURCE_FILE_LIST" \
  --swift-const-vals-list "$CONST_VALUES_LIST" \
  --force \
  --compile-time-extraction \
  --deployment-aware-processing \
  --validate-assistant-intents \
  --no-app-shortcuts-localization

for intent in GetFreeSpaceIntent LargestFilesIntent ScanVolumeIntent TakeCheckpointIntent; do
  identifier="$(plutil -extract "actions.$intent.identifier" raw \
    -o - "$METADATA/extract.actionsdata")"
  if [[ "$identifier" != "$intent" ]]; then
    echo "App Intents metadata is missing $intent" >&2
    exit 1
  fi
done

echo "App Intents metadata verified: 4 DirWiz actions"
