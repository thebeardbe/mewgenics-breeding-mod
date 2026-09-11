#!/usr/bin/env bash
# Build the Windows artifacts into dist/.
#
#   ./build.sh              # version.dll (Mewjector) + BreedingSpike.dll (our mod)
#   ./build.sh mod          # only our mod DLL
#   ./build.sh loader       # only version.dll
#
# Toolchain: zig cc cross-compiling to x86_64-windows-gnu, with -fms-extensions
# so MSVC __try/__except compiles. GCC/mingw cannot build Mewjector or MewUI
# (they use SEH), which is why zig is the pinned toolchain.
set -euo pipefail
cd "$(dirname "$0")"

ZIG="${ZIG:-zig}"
TARGET="-target x86_64-windows-gnu"
CFLAGS="-O2 -fms-extensions -Wall"

./vendor/sync.sh

UP="vendor/upstream"
OUT="dist"
mkdir -p "$OUT"

build_loader() {
  echo "==> version.dll (Mewjector)"
  $ZIG cc $TARGET $CFLAGS -shared \
    -o "$OUT/version.dll" \
    "$UP/mewjector/version.c" "$UP/mewjector/version.def"
  cp "$UP/mewjector/chainloader.ini" "$OUT/chainloader.ini"
}

build_mod() {
  echo "==> BreedingSpike.dll"
  $ZIG cc $TARGET $CFLAGS -shared \
    -o "$OUT/BreedingSpike.dll" \
    src/spike_mod.c \
    -I"$UP/mewjector" -I"$UP/mewui"
}

what="${1:-all}"
case "$what" in
  all)    build_loader; build_mod ;;
  mod)    build_mod ;;
  loader) build_loader ;;
  *) echo "usage: $0 [all|mod|loader]" >&2; exit 2 ;;
esac

echo
echo "Artifacts in $OUT:"
ls -la "$OUT"
