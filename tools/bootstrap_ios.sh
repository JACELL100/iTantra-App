#!/usr/bin/env bash
#
# Generates the Xcode project for the iOS host and drops the hand-written
# Swift sources and Info.plist into it.
#
# Why a script rather than a committed Runner.xcodeproj: an Xcode project file
# is a 700-line generated artifact keyed to a specific Xcode version, and a
# hand-edited one fails in ways that are miserable to debug. `flutter create`
# generates a correct project for whatever Xcode you have, and this script
# then installs the parts that are genuinely ours. Everything in ios/Runner
# here is real source; only the project scaffolding is generated.
#
# Run from the repository root:
#   bash tools/bootstrap_ios.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v flutter >/dev/null 2>&1; then
  echo "error: flutter is not on PATH" >&2
  exit 1
 fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "warning: iOS builds require macOS with Xcode; continuing so the" >&2
  echo "         project files can still be generated." >&2
fi

STASH="$(mktemp -d)"
trap 'rm -rf "$STASH"' EXIT

# Preserve our sources: `flutter create` will overwrite AppDelegate.swift and
# Info.plist with its templates.
if [[ -d ios/Runner ]]; then
  echo "==> stashing hand-written iOS sources"
  mkdir -p "$STASH/Runner"
  for file in \
    AppDelegate.swift \
    AudioCapturePlugin.swift \
    AudioPlaybackPlugin.swift \
    RfcommPlugin.swift \
    PlatformInfoPlugin.swift \
    Runner-Bridging-Header.h \
    Info.plist
  do
    [[ -f "ios/Runner/$file" ]] && cp "ios/Runner/$file" "$STASH/Runner/$file"
  done
  [[ -f ios/Podfile ]] && cp ios/Podfile "$STASH/Podfile"
fi

echo "==> generating the iOS project scaffolding"
flutter create --platforms=ios --project-name itantra --org org.itantra .

echo "==> restoring hand-written iOS sources"
for file in "$STASH"/Runner/*; do
  [[ -e "$file" ]] || continue
  cp "$file" "ios/Runner/$(basename "$file")"
done
[[ -f "$STASH/Podfile" ]] && cp "$STASH/Podfile" ios/Podfile

echo "==> flutter pub get"
flutter pub get

if command -v pod >/dev/null 2>&1; then
  echo "==> pod install"
  (cd ios && pod install)
else
  echo "note: CocoaPods not found; run 'cd ios && pod install' manually" >&2
fi

cat <<'DONE'

Done. Two manual steps remain in Xcode, because they cannot be scripted
reliably across Xcode versions:

  1. Open ios/Runner.xcworkspace. Under Runner > Build Settings, set
     "Objective-C Bridging Header" to Runner/Runner-Bridging-Header.h if it is
     not already set.
  2. Under Signing & Capabilities, select your team and add the
     "Background Modes" capability with Audio and Voice over IP checked.
     (Info.plist already declares UIBackgroundModes; Xcode wants the
     capability registered too.)

Then: flutter run --release -d <your-iphone>

Release, not debug: debug Dart is several times slower and the latency
numbers will be meaningless.
DONE
