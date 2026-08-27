#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$SCRIPT_DIR/app"
FLUTTER_VERSION="$(sed -n 's/.*\"flutter\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p' "$SCRIPT_DIR/.fvmrc")"
FLUTTER_ROOT="$HOME/fvm/versions/$FLUTTER_VERSION"
BUILD_DIR="$APP_DIR/build/macos"
APP_PATH="$BUILD_DIR/Build/Products/Release/LocalRsync.app"
INSTALL_PATH="/Applications/LocalRsync.app"

if [[ -z "$FLUTTER_VERSION" || ! -x "$FLUTTER_ROOT/bin/flutter" ]]; then
    echo "Flutter $FLUTTER_VERSION not found at $FLUTTER_ROOT (run fvm install)." >&2
    exit 1
fi

cd "$APP_DIR"
fvm flutter pub get

cd macos
FLUTTER_ROOT="$FLUTTER_ROOT" xcodebuild \
    -workspace Runner.xcworkspace \
    -scheme Runner \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

if [[ ! -d "$APP_PATH" ]]; then
    echo "Release macOS app was not generated: $APP_PATH" >&2
    exit 1
fi

if pgrep -x "LocalRsync" >/dev/null 2>&1; then
    osascript -e 'tell application "LocalRsync" to quit' || true
    for _ in {1..10}; do
        pgrep -x "LocalRsync" >/dev/null 2>&1 || break
        sleep 1
    done
fi

SUDO=()
if [[ ! -w "$(dirname "$INSTALL_PATH")" ]]; then
    SUDO=(sudo)
fi

if [[ -e "$INSTALL_PATH" ]]; then
    "${SUDO[@]}" rm -rf "$INSTALL_PATH"
fi
"${SUDO[@]}" ditto "$APP_PATH" "$INSTALL_PATH"

echo "Installed: $INSTALL_PATH"
