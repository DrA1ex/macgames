#!/bin/bash
set -euo pipefail
SOURCE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?Usage: build.sh OUTPUT_DIRECTORY}"
CC="${CC:-x86_64-w64-mingw32-gcc}"
mkdir -p "$OUT"
"$CC" -O2 -shared "$SOURCE/cache.c" -lbcrypt -o "$OUT/cache.dll"
"$CC" -O2 -municode "$SOURCE/loader.c" -lbcrypt -o "$OUT/loader.exe"
