#!/bin/bash
# Build a separate local app using Command Line Tools and an installed MacGames runtime.
# No XcodeGen, Sparkle download, runtime modification or change to /Applications is needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="${1:-/Applications/MacGames.app}"
APP="$ROOT/build/MacGames Local.app"
SCRATCH="$ROOT/.build/local"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache"

VENDOR="$ROOT/Vendor"
if [ -f "$VENDOR/SHA256SUMS" ]; then
  (cd "$VENDOR" && shasum -a 256 --check --quiet SHA256SUMS)
  HELPERS="$VENDOR/Helpers"
  ENGINE="$VENDOR/Engine"
else
  [ -f "$SOURCE_APP/Contents/Resources/Runtime/VERSION" ] || {
    echo "Run scripts/fetch-runtime.sh first, or provide an installed MacGames.app." >&2; exit 1;
  }
  HELPERS="$SOURCE_APP/Contents/Helpers"
  ENGINE="$SOURCE_APP/Contents/Resources/Runtime/Engine"
fi
codesign --verify --strict "$ENGINE/bin/wine" "$ENGINE/bin/wineserver" "$HELPERS/x87sidecar"
swift build --disable-sandbox --package-path "$ROOT/Packages/MacGamesCore" --scratch-path "$SCRATCH" --product MacGamesBridge
swift build --disable-sandbox --package-path "$ROOT/Packages/MacGamesCore" --scratch-path "$SCRATCH" --product PerformanceRecorder
swift build --disable-sandbox --package-path "$ROOT/Packages/MacGamesCore" --scratch-path "$SCRATCH" --target MacGamesCore
BIN="$(swift build --disable-sandbox --package-path "$ROOT/Packages/MacGamesCore" --scratch-path "$SCRATCH" --show-bin-path)"
mkdir -p "$ROOT/build"
STAGE="$(mktemp -d "$ROOT/build/local-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
BUNDLE="$STAGE/MacGames Local.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Helpers"
swiftc -swift-version 6 -DLOCAL_BUILD -target arm64-apple-macos26.0 \
  -module-cache-path "$CLANG_MODULE_CACHE_PATH" -I "$BIN/Modules" \
  "$ROOT"/App/*.swift "$BIN"/MacGamesCore.build/*.swift.o -o "$BUNDLE/Contents/MacOS/MacGames"
mkdir -p "$BUNDLE/Contents/Resources/Runtime"
if [ -f "$VENDOR/SHA256SUMS" ]; then
  for folder in Engine Overlays Licenses Games WindowsHelpers; do
    ditto "$VENDOR/$folder" "$BUNDLE/Contents/Resources/Runtime/$folder"
  done
  cp "$ROOT/LICENSES/Sparkle-MIT.txt" "$BUNDLE/Contents/Resources/Runtime/Licenses/"
  cp "$VENDOR/dependency-links.json" "$BUNDLE/Contents/Resources/Runtime/"
  shasum -a 256 "$VENDOR/SHA256SUMS" | cut -c1-16 > "$BUNDLE/Contents/Resources/Runtime/VERSION"
else
  ditto "$SOURCE_APP/Contents/Resources/Runtime" "$BUNDLE/Contents/Resources/Runtime"
fi
for asset in AppIcon.icns Assets.car; do
  if [ -f "$SOURCE_APP/Contents/Resources/$asset" ]; then
    cp "$SOURCE_APP/Contents/Resources/$asset" "$BUNDLE/Contents/Resources/"
  fi
done
SIDECAR="${MACGAMES_AOE_SIDECAR:-}"
if [ -z "$SIDECAR" ]; then SIDECAR="$("$ROOT/scripts/prepare-aoe-runtime.sh")"; fi
codesign --verify --strict "$SIDECAR"
ditto "$SIDECAR" "$BUNDLE/Contents/Helpers/x87sidecar"
printf '2\n' > "$BUNDLE/Contents/Resources/Runtime/aoe-performance-v2"
if [ -f "$ROOT/build/aoe-runtime/sidecar-source-patched.tar.gz" ]; then
  mkdir -p "$BUNDLE/Contents/Resources/Runtime/Sources"
  cp "$ROOT/build/aoe-runtime/sidecar-source-patched.tar.gz" "$BUNDLE/Contents/Resources/Runtime/Sources/"
fi
ditto "$BIN/MacGamesBridge" "$BUNDLE/Contents/Helpers/MacGamesBridge"
ditto "$BIN/PerformanceRecorder" "$BUNDLE/Contents/Helpers/PerformanceRecorder"
xcrun clang -arch x86_64 -mmacosx-version-min=26.0 "$ROOT/Probe/rosetta-probe.c" -o "$BUNDLE/Contents/Helpers/RosettaProbe"
codesign --force --sign - "$BUNDLE/Contents/Helpers/RosettaProbe"
/usr/bin/python3 - "$BUNDLE/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({
        'CFBundleIdentifier': 'com.dra1ex.macgames.local',
        'CFBundleExecutable': 'MacGames', 'CFBundleName': 'MacGames Local',
        'CFBundleDisplayName': 'MacGames Local', 'CFBundleIconFile': 'AppIcon',
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
        'CFBundleShortVersionString': '0.1.1-local', 'LSMinimumSystemVersion': '26.0',
        'NSHighResolutionCapable': True,
        'NSMicrophoneUsageDescription': 'Allow microphone access for in-game voice chat.'
    }, f)
PY
# Sign only the newly built helper and outer bundle. Preserve the engine's original entitlements.
codesign --force --sign - "$BUNDLE/Contents/Helpers/MacGamesBridge"
codesign --force --sign - "$BUNDLE/Contents/Helpers/PerformanceRecorder"
codesign --force --sign - "$BUNDLE"
codesign --verify --strict "$BUNDLE"
# Refuse to overwrite an unrelated artifact at the fixed output path.
if [ -e "$APP" ]; then
  IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")"
  [[ "$IDENTIFIER" = com.tarikbc.macgames.local || "$IDENTIFIER" = com.dra1ex.macgames.local ]] || { echo "Unrelated app at $APP" >&2; exit 1; }
  rm -rf "$APP"
fi
mv "$BUNDLE" "$APP"
echo "Built: $APP"
