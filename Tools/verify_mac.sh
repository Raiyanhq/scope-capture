#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Run this verification on a Mac with Xcode installed." >&2
  exit 1
fi
xcodebuild -version
swift test
xcodebuild -project SCOPECapture.xcodeproj -scheme 'SCOPE Capture' \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .verification/DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project SCOPECapture.xcodeproj -scheme 'SCOPE Capture' \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath .verification/DerivedData CODE_SIGNING_ALLOWED=NO build
echo "Core tests and unsigned Debug/Release builds passed. Real-device and distribution checks remain required."
