#!/usr/bin/env bash
# Builds a debug APK for local development.
# Run from the repository root:
#   support/scripts/compile_android_debug.sh

set -euo pipefail

cd app
fvm flutter build apk --debug
cd ..

echo
echo "APK: app/build/app/outputs/flutter-apk/app-debug.apk"