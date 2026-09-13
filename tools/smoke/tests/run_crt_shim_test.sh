#!/usr/bin/env bash
# Wine smoke test for the hand-written CRT shim (src/crt_shim.c,
# src/crt_format.c) that lets vendored MewUI build without a Windows CRT.
#
# Builds a Mewjector mod that links the shim with the exact flags build.sh uses
# and drives every function the shim replaces. Mewjector formats the log line,
# so a shim bug cannot corrupt the pass/fail verdict. Also asserts the built
# DLL imports only KERNEL32.dll.
#
#   ./tools/smoke/tests/run_crt_shim_test.sh
#
# Requires zig, binutils (objdump) and wine64 (e.g. `nix shell nixpkgs#wine64`).
set -euo pipefail
cd "$(dirname "$0")/../../.."

ZIG="${ZIG:-zig}"
TARGET="-target x86_64-windows-gnu"
CFLAGS="-O2 -fms-extensions -Wall -Wno-microsoft-anon-tag"
UP="vendor/upstream"
RUN=".scratch/crt_shim_smoke"
PREFIX="$PWD/.scratch/wineprefix"

MINGW_INCLUDES="$($ZIG cc $TARGET -E -v -x c /dev/null 2>&1 \
  | sed -n '/search starts here:/,/End of search list/p' \
  | grep -E '^ ' | sed 's/^ *//' | sed 's/^/-I/')"

./vendor/sync.sh

rm -rf "$RUN"
mkdir -p "$RUN/mods"

echo "==> building CRT shim test mod"
cp "$UP/mewjector/release/version.dll" "$RUN/version.dll"
cp "$UP/mewjector/release/chainloader.ini" "$RUN/chainloader.ini"

# Same flags as build.sh, so the shim is exercised exactly as shipped.
$ZIG cc $TARGET $CFLAGS -ffreestanding -fno-builtin -c $MINGW_INCLUDES -Isrc \
  -o "$RUN/crt_shim.o" src/crt_shim.c
$ZIG cc $TARGET $CFLAGS -ffreestanding -fno-builtin -c $MINGW_INCLUDES -Isrc \
  -o "$RUN/crt_format.o" src/crt_format.c

$ZIG cc $TARGET $CFLAGS -ffreestanding -fno-builtin -Wno-deprecated-declarations \
  -shared -nostdlib \
  $MINGW_INCLUDES -lkernel32 -lcompiler_rt -Wl,--entry,DllMain \
  -o "$RUN/mods/CrtShimTest.dll" \
  tools/smoke/tests/crt_shim_test.c \
  "$RUN/crt_shim.o" "$RUN/crt_format.o" \
  -I"$UP/mewjector"

echo "==> building the real mod (vendored MewUI + shim)"
./build.sh mod >/dev/null

$ZIG cc $TARGET -O2 -o "$RUN/wintest.exe" tools/smoke/wintest.c -lversion

echo "==> checking DLL imports"
check_kernel32_only() {
  local dll="$1"
  local names bad
  names="$(objdump -p "$dll" | awk '/DLL Name:/ {print $3}' | sort -u)"
  if [ -z "$names" ]; then
    echo "FAIL: $dll has no imports at all" >&2
    exit 1
  fi
  bad="$(printf '%s\n' "$names" | grep -viE '^KERNEL32\.dll$' || true)"
  if [ -n "$bad" ]; then
    echo "FAIL: $dll imports non-KERNEL32 DLLs:" >&2
    printf '  %s\n' $bad >&2
    exit 1
  fi
  echo "OK: $(basename "$dll") imports only KERNEL32.dll"
}
check_kernel32_only "$RUN/mods/CrtShimTest.dll"
check_kernel32_only dist/BreedingSpike.dll

echo "==> running under Wine"
(
  cd "$RUN"
  export WINEPREFIX="$PREFIX" WINEDEBUG=-all
  # A KERNEL32-only shim must still leave Wine's own version.dll overrides
  # alone; same overrides as tools/smoke/run_smoke.sh.
  export WINEDLLOVERRIDES="version=n,b;mscoree,mshtml="
  timeout 240 wine wintest.exe >/dev/null 2>&1 || true
  timeout 30 wineserver -k >/dev/null 2>&1 || true
)

log="$RUN/mod_logs/chainloader.log"
if [ ! -f "$log" ]; then
  echo "FAIL: no chainloader.log produced; the shim test mod did not run" >&2
  exit 1
fi

echo "==> chainloader.log (CrtShimTest lines)"
grep -a "CrtShimTest" "$log" || true
echo

if grep -aq "\[CrtShimTest\] FAIL" "$log"; then
  echo "FAIL: one or more shim tests failed (see above)" >&2
  exit 1
fi
if ! grep -aq "\[CrtShimTest\] DONE pass=[0-9]* fail=0" "$log"; then
  echo "FAIL: shim test did not finish cleanly (no 'DONE pass=N fail=0')" >&2
  exit 1
fi

echo "PASS: CRT shim tests all green"
