#!/usr/bin/env bash
# Local Wine smoke test for the loader pipeline. No game and no Steam needed.
#
# Proves: zig builds a working version.dll proxy, Mewjector loads a mod DLL from
# mods/, and the MJ_* API (log, type ids, name registry) answers.
#
#   ./tools/smoke/run_smoke.sh
#
# Requires wine64 (e.g. `nix shell nixpkgs#wine64`).
set -euo pipefail
cd "$(dirname "$0")/../.."

ZIG="${ZIG:-zig}"
TARGET="-target x86_64-windows-gnu"
CFLAGS="-O2 -fms-extensions -Wall -Wno-microsoft-anon-tag"
UP="vendor/upstream"
RUN=".scratch/smoke"
PREFIX="$PWD/.scratch/wineprefix"   # kept between runs: Wine's first-run init is slow

MINGW_INCLUDES="$($ZIG cc $TARGET -E -v -x c /dev/null 2>&1 \
  | sed -n '/search starts here:/,/End of search list/p' \
  | grep -E '^ ' | sed 's/^ *//' | sed 's/^/-I/')"

./vendor/sync.sh

rm -rf "$RUN"
mkdir -p "$RUN/mods"

echo "==> building loader + smoke mod"
# Official loader: KERNEL32-only and known to load under Proton.
cp "$UP/mewjector/release/version.dll" "$RUN/version.dll"
cp "$UP/mewjector/release/chainloader.ini" "$RUN/chainloader.ini"
# CRT-free mod, same rules as src/spike_mod.c.
$ZIG cc $TARGET $CFLAGS -shared -nostdlib \
  $MINGW_INCLUDES -lkernel32 -Wl,--entry,DllMain \
  -o "$RUN/mods/SmokeMod.dll" tools/smoke/hello_mod.c -I"$UP/mewjector"
$ZIG cc $TARGET -O2 -o "$RUN/wintest.exe" tools/smoke/wintest.c -lversion

echo "==> running under Wine"
(
  cd "$RUN"
  export WINEPREFIX="$PREFIX" WINEDEBUG=-all
  # - version=n,b: Wine prefers its builtin version.dll, so force native ours,
  #   falling back to builtin. The ',b' matters: 'version=n' alone makes 32-bit
  #   Wine processes try to load our 64-bit DLL and die, which breaks Proton's
  #   Steam bits and takes the game down with it.
  # - mscoree/mshtml disabled: without this, Wine's first run tries to install
  #   mono/gecko and hangs on a dialog there is no display for.
  export WINEDLLOVERRIDES="version=n,b;mscoree,mshtml="
  # Wine's prefix services (wineboot/winedevice/winedbg) can outlive the app,
  # which hangs a naive `wine app.exe`. Bound it, then stop the server; the
  # log file is the real test output.
  timeout 240 wine wintest.exe >/dev/null 2>&1 || true
  timeout 30 wineserver -k >/dev/null 2>&1 || true
)

log="$RUN/mod_logs/chainloader.log"
if [ ! -f "$log" ]; then
  echo "FAIL: no chainloader.log produced; proxy did not run" >&2
  exit 1
fi

echo "==> chainloader.log"
cat "$log"

if grep -q "SmokeMod: Mewjector API resolved" "$log"; then
  echo
  echo "PASS: loader pipeline works under Wine"
else
  echo
  echo "FAIL: mod did not report the Mewjector API" >&2
  exit 1
fi
