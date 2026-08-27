#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$SCRIPT_DIR/app"
APK_PATH="$APP_DIR/build/app/outputs/flutter-apk/app-release.apk"
DEST_DIR="/Users/i/BaiduSyncdisk"

cd "$APP_DIR"
fvm flutter build apk --release --target-platform android-arm64

if [[ ! -f "$APK_PATH" ]]; then
    echo "Release APK was not generated: $APK_PATH" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
ARCHIVE_PATH="$DEST_DIR/app-release_${TIMESTAMP}.zip"
zip -j -q "$ARCHIVE_PATH" "$APK_PATH"

echo "APK: $APK_PATH"
echo "Archive: $ARCHIVE_PATH"
