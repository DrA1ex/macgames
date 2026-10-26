#!/bin/bash
# Xcode build phase: copies the vendored runtime and the helpers into MacGames.app.
set -euo pipefail

VENDOR="$SRCROOT/Vendor"
if [ ! -f "$VENDOR/SHA256SUMS" ]; then
  echo "error: Vendor/ is missing. Run scripts/fetch-runtime.sh first." >&2
  exit 1
fi
APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
RT="$APP/Contents/Resources/Runtime"
HELPERS="$APP/Contents/Helpers"
mkdir -p "$RT" "$HELPERS"

# Byte-for-byte copies: the engine's signatures and entitlements must stay valid.
rsync -a --delete "$VENDOR/Engine/" "$RT/Engine/"
rsync -a --delete "$VENDOR/Overlays/" "$RT/Overlays/"
rsync -a --delete "$VENDOR/Licenses/" "$RT/Licenses/"
# Licenses of parts linked into the app itself, such as Sparkle.
cp "$SRCROOT/LICENSES/Sparkle-MIT.txt" "$RT/Licenses/"
rsync -a --delete "$VENDOR/Games/" "$RT/Games/"
# Runtime 4 still holds the retired Overwatch pipeline helper; Overwatch now uses Recall's tool from its pack.
rsync -a --delete --delete-excluded --exclude prepare-pipelines.exe --exclude DXMT-LICENSE.txt "$VENDOR/WindowsHelpers/" "$RT/WindowsHelpers/"
cp "$VENDOR/dependency-links.json" "$RT/dependency-links.json"
shasum -a 256 "$VENDOR/SHA256SUMS" | cut -c1-16 > "$RT/VERSION"

AOE2_OVERLAY="$(python3 "$SRCROOT/scripts/prepare-aoe2-runtime.py")"
ditto "$AOE2_OVERLAY" "$RT/Overlays/aoe2-selection"
mkdir -p "$RT/Sources"
cp "$SRCROOT/build/aoe2-runtime/wine-aoe2-source-patched.tar.gz" "$RT/Sources/"
SIDECAR="$("$SRCROOT/scripts/prepare-aoe-runtime.sh")"
ditto "$SIDECAR" "$HELPERS/x87sidecar"
printf '2\n' > "$RT/aoe-performance-v2"
cp "$SRCROOT/build/aoe-runtime/aoe2-selection-jump" "$RT/"
mkdir -p "$RT/Sources"
cp "$SRCROOT/build/aoe-runtime/sidecar-source-patched.tar.gz" "$RT/Sources/"
ditto "$BUILT_PRODUCTS_DIR/MacGamesBridge" "$HELPERS/MacGamesBridge"
ditto "$BUILT_PRODUCTS_DIR/RosettaProbe" "$HELPERS/RosettaProbe"
