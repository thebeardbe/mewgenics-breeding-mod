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
UP="vendor/upstream"
RUN=".scratch/smoke"
PREFIX="$PWD/.scratch/wineprefix"   # kept between runs: Wine's first-run init is slow

./vendor/sync.sh

rm -rf "$RUN"
mkdir -p "$RUN/mods"

echo "==> building loader + smoke mod"
$ZIG cc $TARGET -O2 -fms-extensions -shared \
  -o "$RUN/version.dll" "$UP/mewjector/version.c" "$UP/mewjector/version.def"
cp "$UP/mewjector/chainloader.ini" "$RUN/chainloader.ini"
$ZIG cc $TARGET -O2 -fms-extensions -shared \
  -o "$RUN/mods/SmokeMod.dll" tools/smoke/hello_mod.c -I"$UP/mewjector"
$ZIG cc $TARGET -O2 -o "$RUN/wintest.exe" tools/smoke/wintest.c -lversion

echo "==> running under Wine"
(
  cd "$RUN"
  export WINEPREFIX="$PREFIX" WINEDEBUG=-all
  # - version=n: Wine prefers its builtin version.dll, so force ours. This is
  #   the same override Proton needs in the Steam launch options.
  # - mscoree/mshtml disabled: without this, Wine's first run tries to install
  #   mono/gecko and hangs on a dialog there is no display for.
  export WINEDLLOVERRIDES="version=n;mscoree,mshtml="
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
