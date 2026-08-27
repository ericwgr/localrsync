#!/usr/bin/env bash
# Builds a debug version of the macOS app for local development.
# Run from the repository root:
#   support/scripts/compile_macos_debug.sh
#
# The Xcode project is configured with the release signing identity
# "Developer ID Application: Tien Do Nam (3W7H4PYMCV)", which is usually not
# available on a developer machine, so `fvm flutter build macos` fails with
# "No signing certificate found". Signing is therefore disabled here via
# CODE_SIGNING_ALLOWED=NO. The resulting app cannot be distributed, but
# runs fine locally. To build a signed app, drop the two CODE_SIGNING_*
# settings and provide your own team in Xcode.

set -euo pipefail

# The Flutter build steps embedded in the Xcode project (cargokit, flutter assemble)
# need FLUTTER_ROOT; resolve the version pinned in .fvmrc via fvm's install layout.
FLUTTER_VERSION=$(python3 -c 'import json; print(json.load(open(".fvmrc"))["flutter"])')
FLUTTER_ROOT="$HOME/fvm/versions/$FLUTTER_VERSION"
if [ ! -x "$FLUTTER_ROOT/bin/flutter" ]; then
  echo "Flutter $FLUTTER_VERSION not found at $FLUTTER_ROOT (fvm install)." >&2
  exit 1
fi

cd app
fvm flutter pub get

cd macos
FLUTTER_ROOT="$FLUTTER_ROOT" \
xcodebuild \
  -workspace Runner.xcworkspace \
  -scheme Runner \
  -configuration Debug \
  -derivedDataPath ../build/macos \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build | tail -n 20

cd ../..

echo
echo "App: app/build/macos/Build/Products/Debug/LocalRsync.app"