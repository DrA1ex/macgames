#!/bin/bash
# Package an already-built local fork. Publishing is a separate explicit step.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?Usage: package-fork-dmg.sh VERSION [APP_PATH]}"
APP="${2:-$ROOT/build/MacGames Local.app}"
[[ "$VERSION" =~ ^[a-zA-Z0-9._-]+$ ]] || { echo "Invalid version" >&2; exit 1; }
OUT="$ROOT/build/fork-release/$VERSION"
DMG="$OUT/MacGames-Fork-$VERSION.dmg"
[ ! -e "$DMG" ] || { echo "Image already exists: $DMG" >&2; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")" = com.dra1ex.macgames.local ] || {
  echo "This packages only the local DrA1ex fork." >&2; exit 1;
}
codesign --verify --deep --strict "$APP"
mkdir -p "$OUT"
STAGE="$(mktemp -d "$OUT/stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/MacGames.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me.txt" <<'TEXT'
MacGames Local — DrA1ex fork

Drag MacGames.app into Applications. Choose an installed Windows game's EXE
in the app and press Play. Compatible games share their Wine environment.
Steam/Battle.net clients are not started by this fork's local-EXE interface.

This is an experimental, locally signed build, not Apple-notarized.
AoE II selection-cache optimizations require the exact supported EXE build.
Source, build details and validation limits: https://github.com/DrA1ex/macgames
License: https://github.com/DrA1ex/macgames/blob/main/LICENSE
TEXT
cp "$ROOT/LICENSE" "$STAGE/LICENSE.txt"
hdiutil create -volname "MacGames Fork" -srcfolder "$STAGE" -format UDZO -imagekey zlib-level=9 "$DMG"
hdiutil verify "$DMG"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS)
printf '%s\n' "$DMG"
