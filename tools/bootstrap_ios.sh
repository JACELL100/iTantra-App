#!/usr/bin/env bash
#
# Prepares and checks the committed iOS host for a build on macOS.
#
# This script used to *generate* `Runner.xcodeproj` with `flutter create`,
# because an Xcode project file is a generated artifact. That was the wrong
# trade for this repository: `flutter create .` regenerates every platform
# directory it knows about, so running it would have silently reverted the
# Android host - the manifest that documents the INTERNET permission and the
# capture/playback/Bluetooth channels - back to the Flutter template. The
# project is committed instead, and this script does the two things that
# actually are needed on a Mac.
#
#   1. **Verify the Swift sources are really compiled.** It is easy and
#      invisible to have a `.swift` file sitting in `ios/Runner/` that the
#      project never compiles: the build succeeds, the app launches, and the
#      platform channel is simply missing at runtime. That is the exact failure
#      this check exists to catch, and it is why it is a hard error rather than
#      a warning.
#   2. **Run `pod install`**, which is a genuine per-machine step because it
#      resolves the Flutter and plugin pods for the Podfile in this checkout.
#
# Run from the repository root:
#   bash tools/bootstrap_ios.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: iOS builds require macOS with Xcode." >&2
  exit 1
fi

for tool in flutter xcodebuild pod; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool is not on PATH" >&2
    exit 1
  fi
done

PROJECT='ios/Runner.xcodeproj/project.pbxproj'
if [[ ! -f "$PROJECT" ]]; then
  echo "error: $PROJECT is missing from the checkout" >&2
  exit 1
fi

echo "==> checking that every Swift source is in the Runner target"

# The app's compile phase, not the test target's.
SOURCES="$(awk '/Begin PBXSourcesBuildPhase/,/End PBXSourcesBuildPhase/' "$PROJECT")"

SWIFT_FILES=(
  AppDelegate.swift
  AudioCapturePlugin.swift
  AudioPlaybackPlugin.swift
  PlatformInfoPlugin.swift
  RfcommPlugin.swift
)

missing=0
for file in "${SWIFT_FILES[@]}"; do
  if [[ ! -f "ios/Runner/$file" ]]; then
    echo "  error: ios/Runner/$file does not exist" >&2
    missing=1
    continue
  fi
  if ! grep -q "$file in Sources" <<<"$SOURCES"; then
    echo "  error: $file exists but is not in the Sources build phase," >&2
    echo "         so its platform channels would be missing at runtime" >&2
    missing=1
    continue
  fi
  echo "  ok: $file"
done

if [[ "$missing" -ne 0 ]]; then
  echo "" >&2
  echo "Fix: open ios/Runner.xcworkspace in Xcode, then add the file to the" >&2
  echo "Runner target via File > Add Files to Runner." >&2
  exit 1
fi

if ! grep -q 'SWIFT_OBJC_BRIDGING_HEADER = "Runner/Runner-Bridging-Header.h"' "$PROJECT"; then
  echo "  error: the Objective-C bridging header is not set in the project" >&2
  echo "         (needed for GeneratedPluginRegistrant.m to be visible to Swift)" >&2
  exit 1
fi
echo "  ok: bridging header is configured"

echo "==> flutter pub get"
flutter pub get

echo "==> pod install"
(cd ios && pod install)

cat <<'DONE'

Done. What remains cannot be scripted, because it is per-developer state:

  1. Open ios/Runner.xcworkspace (not .xcodeproj - the workspace carries the
     pods).
  2. Signing & Capabilities: select your team. Info.plist already declares the
     Background Modes, and the project already sets the bridging header, so the
     only capability Xcode wants registered explicitly is "Background Modes"
     with Audio checked.
  3. Because this build has never been run on a device, start with
     `flutter run --profile -d <iphone>` and watch the log for platform
     exceptions on the audio_capture and audio_playback channels first.

Then: flutter run --release -d <your-iphone>

Release, not debug: debug Dart is several times slower and the latency numbers
would be meaningless.
DONE
