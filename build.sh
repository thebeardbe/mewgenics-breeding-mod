#!/usr/bin/env bash
# Build the Windows artifacts into dist/.
#
#   ./build.sh                    # dist/version.dll (official) + BreedingSpike.dll
#   ./build.sh mod                # only our mod DLL
#   ./build.sh loader             # only the official version.dll + chainloader.ini
#   ./build.sh loader --from-source   # build Mewjector from source with zig (NOT Proton-safe)
#
# Two hard-won rules live here:
#
#  1. The shipped loader is the official Mewjector release. It imports only
#     KERNEL32.dll. A zig/mingw build of the same source imports api-ms-win-crt-*
#     and the game crashes at launch under Proton.
#  2. Our mod DLL must be KERNEL32-only too. zig's default CRT pulls in
#     api-ms-win-crt-*, so we link with -nostdlib, our own entry point, and
#     kernel32 only. That is why the mod source must not use the C runtime
#     (no stdio, no string.h). Formatting goes through Mewjector's MJ_Log.
#
# MewUI uses MSVC __try/__except, which GCC/mingw cannot compile, so zig stays.
set -euo pipefail
cd "$(dirname "$0")"

ZIG="${ZIG:-zig}"
TARGET="-target x86_64-windows-gnu"
CFLAGS="-O2 -fms-extensions -Wall -Wno-microsoft-anon-tag"

# zig's mingw include paths, so -nostdlib can still find <windows.h>.
MINGW_INCLUDES="$($ZIG cc $TARGET -E -v -x c /dev/null 2>&1 \
  | sed -n '/search starts here:/,/End of search list/p' \
  | grep -E '^ ' | sed 's/^ *//' | sed 's/^/-I/')"

./vendor/sync.sh

UP="vendor/upstream"
OUT="dist"
mkdir -p "$OUT"

build_loader() {
  if [ "${1:-}" = "--from-source" ]; then
    echo "==> version.dll (Mewjector, built from source with zig)"
    echo "    WARNING: imports api-ms-win-crt-*; crashes the game under Proton."
    $ZIG cc $TARGET $CFLAGS -shared \
      -o "$OUT/version.dll" \
      "$UP/mewjector/version.c" "$UP/mewjector/version.def"
  else
    echo "==> version.dll (official Mewjector release, KERNEL32-only)"
    cp "$UP/mewjector/release/version.dll" "$OUT/version.dll"
  fi
  cp "$UP/mewjector/release/chainloader.ini" "$OUT/chainloader.ini"
}

build_mod() {
  echo "==> BreedingSpike.dll (CRT-free, KERNEL32-only)"
  $ZIG cc $TARGET $CFLAGS -shared -nostdlib \
    $MINGW_INCLUDES -lkernel32 \
    -Wl,--entry,DllMain \
    -o "$OUT/BreedingSpike.dll" \
    src/spike_mod.c \
    -I"$UP/mewjector" -I"$UP/mewui"
}

what="${1:-all}"
shift || true
case "$what" in
  all)    build_loader "$@"; build_mod ;;
  mod)    build_mod ;;
  loader) build_loader "$@" ;;
  *) echo "usage: $0 [all|mod|loader] [--from-source]" >&2; exit 2 ;;
esac

echo
echo "Artifacts in $OUT:"
ls -la "$OUT"
