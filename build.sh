#!/usr/bin/env bash
# Build the Windows artifacts into dist/.
#
#   ./build.sh                    # dist/version.dll (official) + BreedingSpike.dll
#   ./build.sh --patched          # everything, with version.dll built from source + our patch
#   ./build.sh mod                # only our mod DLL
#   ./build.sh loader             # only the official version.dll + chainloader.ini
#   ./build.sh loader --patched   # build version.dll from source + our patch
#   ./build.sh loader --from-source   # build Mewjector from source with zig (NOT Proton-safe)
#   MEWUI_MODE=1 ./build.sh mod  # compile the mod with MewUI mode N (0-2, default 0)
#
# Two hard-won rules live here:
#
#  1. Every shipped DLL imports only KERNEL32.dll. The official Mewjector
#     release is built that way; our patched loader and our mod get there with
#     -nostdlib plus src/crt_shim.c, src/crt_format.c and (for the loader)
#     src/loader_crt.c. A zig/mingw build that links the dynamic UCRT imports
#     api-ms-win-crt-* and the game crashes at launch under Proton.
#  2. Our mod DLL must be KERNEL32-only too. zig's default CRT pulls in
#     api-ms-win-crt-*, so we link with -nostdlib, our own entry point, and
#     kernel32 only. Our own sources avoid the C runtime (formatting goes
#     through Mewjector's MJ_Log). Vendored MewUI does use it, so
#     src/crt_shim.c supplies the few functions it calls over KERNEL32 only.
#     MewUI, its shim, and compiler-rt are linked only in MewUI modes (1, 2);
#     mode 0 is the lean, pre-MewUI DLL again.
#
# MewUI uses MSVC __try/__except, which GCC/mingw cannot compile, so zig stays.
set -euo pipefail
cd "$(dirname "$0")"

ZIG="${ZIG:-zig}"
TARGET="-target x86_64-windows-gnu"
CFLAGS="-O2 -fms-extensions -Wall -Wno-microsoft-anon-tag"

# MewUI integration mode compiled into the mod: 0 (off), 1 (bootstrap only),
# 2 (full). Defaults to 0 so an unset environment always builds the safe DLL.
MEWUI_MODE="${MEWUI_MODE:-0}"

# zig's mingw include paths, so -nostdlib can still find <windows.h>.
MINGW_INCLUDES="$($ZIG cc $TARGET -E -v -x c /dev/null 2>&1 \
  | sed -n '/search starts here:/,/End of search list/p' \
  | grep -E '^ ' | sed 's/^ *//' | sed 's/^/-I/')"

./vendor/sync.sh

UP="vendor/upstream"
OUT="dist"
mkdir -p "$OUT"

build_loader() {
  local mode="${1:-}"
  if [ "$mode" = "--patched" ]; then
    echo "==> version.dll (Mewjector, patched: EnableEPFallback + Logging, KERNEL32-only)"
    local work="$OUT/.mewjector-patched"
    local shim="$OUT/.loader-obj"
    rm -rf "$work" "$shim"
    mkdir -p "$work" "$shim"
    cp -r "$UP/mewjector" "$work/mewjector"
    patch -p1 -d "$work/mewjector" < "$PWD/patches/mewjector-epfallback-and-logging.patch"
    # Same CRT-free recipe as the mod (rule 1): -nostdlib, our shim sources,
    # KERNEL32 only. compiler-rt supplies the SEH handler and stack probe.
    $ZIG cc $TARGET $CFLAGS -ffreestanding -fno-builtin -c \
      $MINGW_INCLUDES -Isrc \
      -o "$shim/crt_shim.o" src/crt_shim.c
    $ZIG cc $TARGET $CFLAGS -ffreestanding -fno-builtin -c \
      $MINGW_INCLUDES -Isrc \
      -o "$shim/crt_format.o" src/crt_format.c
    $ZIG cc $TARGET $CFLAGS -ffreestanding -fno-builtin -c \
      $MINGW_INCLUDES -Isrc \
      -o "$shim/loader_crt.o" src/loader_crt.c
    $ZIG cc $TARGET $CFLAGS -shared -nostdlib \
      $MINGW_INCLUDES -Isrc -lkernel32 -lcompiler_rt \
      -Wl,--entry,DllMain \
      -o "$OUT/version.dll" \
      "$shim/loader_crt.o" "$shim/crt_shim.o" "$shim/crt_format.o" \
      "$work/mewjector/version.c" "$work/mewjector/version.def"
    cp "$work/mewjector/chainloader.ini" "$OUT/chainloader.ini"
    return
  fi

  if [ "$mode" = "--from-source" ]; then
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
  echo "==> BreedingSpike.dll (CRT-free, KERNEL32-only, MewUI mode $MEWUI_MODE)"
  # Every mode links our own sources, KERNEL32, and the Mewjector header. Mode 0
  # is the pre-MewUI DLL: no mew_ui_api.o, no shim, no compiler-rt.
  local sources=(src/spike_mod.c src/bridge_client.c src/shortcut_watcher.c src/mem_read.c src/save_diag.c)
  local objects=()
  local include_dirs=(-I"$UP/mewjector" -Isrc)
  local libs=(-lkernel32)

  if [ "$MEWUI_MODE" != 0 ]; then
    # The shim replaces the handful of CRT functions MewUI needs. It is
    # compiled separately with -ffreestanding -fno-builtin so the compiler
    # cannot lower a hand-written mem*/str* loop into a call to itself.
    # src/crt_format.c is the formatting half, split out to stay inside the
    # file-size budget.
    local shim_dir="$OUT/.obj"
    mkdir -p "$shim_dir"
    $ZIG cc $TARGET $CFLAGS -ffreestanding -fno-builtin -c \
      $MINGW_INCLUDES -Isrc \
      -o "$shim_dir/crt_shim.o" src/crt_shim.c
    $ZIG cc $TARGET $CFLAGS -ffreestanding -fno-builtin -c \
      $MINGW_INCLUDES -Isrc \
      -o "$shim_dir/crt_format.o" src/crt_format.c
    # MewUI's typed-text function has a frame over 4 KB, so the compiler emits
    # a ___chkstk_ms stack probe. -nostdlib also drops zig's compiler-rt, so
    # pull it back in explicitly; it is static and adds no DLL imports.
    objects=("$shim_dir/crt_shim.o" "$shim_dir/crt_format.o")
    sources+=("$UP/mewui/src/native/mew_ui_api.c")
    include_dirs+=(-I"$UP/mewui" -I"$UP/mewui/src/native")
    libs+=(-lcompiler_rt)
  fi

  $ZIG cc $TARGET $CFLAGS -DMEWUI_MODE="$MEWUI_MODE" -shared -nostdlib \
    $MINGW_INCLUDES "${libs[@]}" \
    -Wl,--entry,DllMain \
    -o "$OUT/BreedingSpike.dll" \
    "${objects[@]}" "${sources[@]}" "${include_dirs[@]}"
}

what="${1:-all}"
shift || true
case "$what" in
  all)    build_loader "$@"; build_mod ;;
  mod)    build_mod ;;
  loader) build_loader "$@" ;;
  # Shorthand for the common release build: the patched loader plus the mod.
  --patched) build_loader --patched; build_mod ;;
  *) echo "usage: $0 [all|mod|loader|--patched] [--patched|--from-source]" >&2; exit 2 ;;
esac

echo
echo "Artifacts in $OUT:"
ls -la "$OUT"
