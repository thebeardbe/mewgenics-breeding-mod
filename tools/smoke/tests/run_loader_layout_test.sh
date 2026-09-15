#!/usr/bin/env bash
# Tests that the loader-resolution step in install.sh / install.ps1 is unchanged
# by the bundle's new folder layout: for the same MEWJECTOR_RELEASE_OVERRIDE, the
# release layout (scripts in linux/ or windows/, payload in a sibling payload/
# folder) and the old flat layout (scripts and payload in one folder) must pick
# the same loader and install the same bytes.
#
# Everything runs offline: each check points MEWJECTOR_RELEASE_OVERRIDE at a
# local stand-in, so neither GitHub nor any other network endpoint is touched.
# The temp tree holds only fakes and HOME is an empty temp directory.
#
#   ./tools/smoke/tests/run_loader_layout_test.sh
#
# The PowerShell half needs pwsh (nixpkgs `powershell`); when it is absent that
# half fails loudly rather than passing quietly.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

# ---------------------------------------------------------------------------
# tiny assertion harness
# ---------------------------------------------------------------------------
PASSED=0
FAILED=0

pass() { printf '  ok   %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '  FAIL %s\n' "$1" >&2; FAILED=$((FAILED + 1)); }
section() { printf '\n== %s\n' "$1"; }

expect_eq() { # want got desc
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3: want [$1], got [$2]"; fi
}

expect_fixed() { # file literal desc
  if grep -qF -- "$2" "$1" 2>/dev/null; then
    pass "$3"
  else
    fail "$3: [$2] not found in $(basename "$1")"
  fi
}

expect_files_equal() { # a b desc
  if cmp -s "$1" "$2"; then pass "$3"; else fail "$3: [$(basename "$1")] and [$(basename "$2")] differ"; fi
}

expect_content() { # expected-file actual-file desc
  if [ -f "$2" ] && cmp -s "$1" "$2"; then
    pass "$3"
  else
    fail "$3: [$(basename "$2")] missing or content changed"
  fi
}

# ---------------------------------------------------------------------------
# fixtures and runners
# ---------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mew-loader-layout-test.XXXXXX")"
FAKE_HOME="$WORK/home"

cleanup() {
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT INT TERM

mkdir -p "$FAKE_HOME"

# The bundled payload, identical in both layouts so the installed bytes can be
# compared across them too.
write_payload_file() { # dir name
  local dir="$1" name="$2"
  mkdir -p "$dir"
  case "$name" in
    version.dll)       printf 'BUNDLE-LOADER-PAYLOAD\n' > "$dir/$name" ;;
    chainloader.ini)   printf '[chainloader]\nmods=mods\n' > "$dir/$name" ;;
    BreedingSpike.dll) printf 'BUNDLE-MOD-PAYLOAD\n' > "$dir/$name" ;;
    *) fail "unknown fixture $name" ;;
  esac
}

copy_shell_scripts() { # dir
  local dir="$1"
  mkdir -p "$dir"
  cp -p "$REPO_ROOT/installers/install.sh" "$dir/install.sh"
  cp -p "$REPO_ROOT/installers/proton-registry.sh" "$dir/proton-registry.sh"
  cp -p "$REPO_ROOT/installers/loader-release.sh" "$dir/loader-release.sh"
  chmod +x "$dir/install.sh" "$dir/proton-registry.sh"
}

copy_windows_scripts() { # dir
  local dir="$1"
  mkdir -p "$dir"
  cp -p "$REPO_ROOT/installers/install.ps1" "$dir/install.ps1"
  cp -p "$REPO_ROOT/installers/loader-release.ps1" "$dir/loader-release.ps1"
}

# The documented release layout: docs and payload/ at the root, scripts under
# linux/ and windows/.
make_release_layout() { # dir
  local dir="$1"
  mkdir -p "$dir/payload" "$dir/linux" "$dir/windows"
  printf 'install notes\n' > "$dir/README.md"
  printf 'what the patch changes\n' > "$dir/PATCHES.md"
  printf 'Mewjector licence text\n' > "$dir/MEWJECTOR-LICENSE.txt"
  copy_shell_scripts "$dir/linux"
  copy_windows_scripts "$dir/windows"
  write_payload_file "$dir/payload" version.dll
  write_payload_file "$dir/payload" chainloader.ini
  write_payload_file "$dir/payload" BreedingSpike.dll
}

# The old flat layout: scripts and the three payload files in one folder.
make_flat_layout() { # dir
  local dir="$1"
  mkdir -p "$dir"
  copy_shell_scripts "$dir"
  copy_windows_scripts "$dir"
  write_payload_file "$dir" version.dll
  write_payload_file "$dir" chainloader.ini
  write_payload_file "$dir" BreedingSpike.dll
}

make_standin() { # dir kind(fixed|nofix)
  local dir="$1" kind="$2"
  mkdir -p "$dir"
  printf 'UPSTREAM-LOADER-%s\n' "$kind" > "$dir/version.dll"
  if [ "$kind" = fixed ]; then
    printf '[Chainloader]\nmods=mods\nEnableEPFallback=0\n' > "$dir/chainloader.ini"
  else
    printf '[chainloader]\nmods=mods\n' > "$dir/chainloader.ini"
  fi
}

seed_game() { # dir
  mkdir -p "$1/mod_logs"
  printf 'fake game executable\n' > "$1/Mewgenics.exe"
  printf 'a file the installer must never touch\n' > "$1/decoy.txt"
  printf 'previous loader log\n' > "$1/mod_logs/chainloader.log"
}

new_game() { # tag
  local dir="$WORK/game-$1"
  rm -rf "$dir"
  seed_game "$dir"
  printf '%s\n' "$dir"
}

LAST_OUT=""
RC=0
SH_OVERRIDE=""

run_sh() { # install-sh args...
  local script="$1"
  shift
  LAST_OUT="$WORK/last-sh.out"
  if env -u MEWGENICS_DIR -u PAYLOAD_DIR HOME="$FAKE_HOME" \
       MEWJECTOR_RELEASE_OVERRIDE="$SH_OVERRIDE" \
       "$script" "$@" > "$LAST_OUT" 2>&1; then
    RC=0
  else
    RC=$?
  fi
}

PS_OVERRIDE=""
run_ps() { # install-ps1 args...
  LAST_OUT="$WORK/last-ps.out"
  if env -u MEWGENICS_DIR HOME="$FAKE_HOME" \
       MEWJECTOR_RELEASE_OVERRIDE="$PS_OVERRIDE" \
       "$PWSH" -NoProfile -NonInteractive -File "$@" > "$LAST_OUT" 2>&1; then
    RC=0
  else
    RC=$?
  fi
}

PWSH="${PWSH:-}"
find_pwsh() {
  local candidate
  if [ -n "$PWSH" ] && command -v "$PWSH" >/dev/null 2>&1; then
    PWSH="$(command -v "$PWSH")"
    return
  fi
  if command -v pwsh >/dev/null 2>&1; then
    PWSH="$(command -v pwsh)"
    return
  fi
  # NixOS: the package is in the store even when it is not on PATH.
  for candidate in /nix/store/*-powershell-[0-9]*/bin/pwsh; do
    if [ -x "$candidate" ]; then
      PWSH="$candidate"
      return
    fi
  done
  PWSH=""
}
find_pwsh

# The one line the installer prints for the loader, without its indent.
loader_line() { # out-file
  sed -n 's/^       loader: //p' "$1" | head -n1
}

# ---------------------------------------------------------------------------
# install.sh
# ---------------------------------------------------------------------------
test_sh_same_override_same_loader() {
  local kind="$1" reason="$2"
  section "install.sh: a $kind override picks the same loader in both layouts"
  local game_rel game_flat out_rel out_flat
  game_rel="$(new_game "sh-rel-$kind")"
  game_flat="$(new_game "sh-flat-$kind")"

  SH_OVERRIDE="$STANDIN/$kind"
  run_sh "$RELEASE/linux/install.sh" --game-dir "$game_rel"
  expect_eq 0 "$RC" "release layout install exits 0"
  cp "$LAST_OUT" "$WORK/sh-rel-$kind.out"
  run_sh "$FLAT/install.sh" --game-dir "$game_flat"
  expect_eq 0 "$RC" "flat layout install exits 0"
  cp "$LAST_OUT" "$WORK/sh-flat-$kind.out"
  out_rel="$WORK/sh-rel-$kind.out"
  out_flat="$WORK/sh-flat-$kind.out"

  # Both install the same loader bytes, and both name the same reason.
  expect_files_equal "$game_rel/version.dll" "$game_flat/version.dll" "$kind: both layouts installed the same version.dll"
  expect_files_equal "$game_rel/chainloader.ini" "$game_flat/chainloader.ini" "$kind: both layouts installed the same chainloader.ini"
  expect_eq "$(loader_line "$out_rel")" "$(loader_line "$out_flat")" "$kind: both layouts report the same loader line"
  expect_fixed "$out_rel" "$reason" "$kind: release layout reason is the expected one"
  expect_fixed "$out_flat" "$reason" "$kind: flat layout reason is the expected one"

  # Where the loader came from, per layout.
  if [ "$kind" = fixed ]; then
    expect_files_equal "$STANDIN/fixed/version.dll" "$game_rel/version.dll" "$kind: release layout used the override loader"
    expect_files_equal "$STANDIN/fixed/version.dll" "$game_flat/version.dll" "$kind: flat layout used the override loader"
  else
    expect_files_equal "$RELEASE/payload/version.dll" "$game_rel/version.dll" "$kind: release layout used its payload loader"
    expect_files_equal "$FLAT/version.dll" "$game_flat/version.dll" "$kind: flat layout used its own loader"
  fi

  # The mod DLL has no override and always comes from the payload of the layout
  # it was installed from.
  expect_files_equal "$RELEASE/payload/BreedingSpike.dll" "$game_rel/mods/BreedingSpike.dll" "$kind: release layout mod DLL is its payload copy"
  expect_files_equal "$FLAT/BreedingSpike.dll" "$game_flat/mods/BreedingSpike.dll" "$kind: flat layout mod DLL is its own copy"
  expect_content "$WORK/fixtures/decoy.txt" "$game_rel/decoy.txt" "$kind: release layout left the unrelated file alone"
  expect_content "$WORK/fixtures/decoy.txt" "$game_flat/decoy.txt" "$kind: flat layout left the unrelated file alone"
}

# ---------------------------------------------------------------------------
# install.ps1
# ---------------------------------------------------------------------------
test_ps_same_override_same_loader() {
  local kind="$1" reason="$2"
  section "install.ps1: a $kind override picks the same loader in both layouts"
  local game_rel game_flat out_rel out_flat
  game_rel="$(new_game "ps-rel-$kind")"
  game_flat="$(new_game "ps-flat-$kind")"

  PS_OVERRIDE="$STANDIN/$kind"
  run_ps "$RELEASE/windows/install.ps1" -GameDir "$game_rel"
  expect_eq 0 "$RC" "ps release layout install exits 0"
  cp "$LAST_OUT" "$WORK/ps-rel-$kind.out"
  run_ps "$FLAT/install.ps1" -GameDir "$game_flat"
  expect_eq 0 "$RC" "ps flat layout install exits 0"
  cp "$LAST_OUT" "$WORK/ps-flat-$kind.out"
  out_rel="$WORK/ps-rel-$kind.out"
  out_flat="$WORK/ps-flat-$kind.out"

  expect_files_equal "$game_rel/version.dll" "$game_flat/version.dll" "$kind: ps both layouts installed the same version.dll"
  expect_files_equal "$game_rel/chainloader.ini" "$game_flat/chainloader.ini" "$kind: ps both layouts installed the same chainloader.ini"
  expect_eq "$(loader_line "$out_rel")" "$(loader_line "$out_flat")" "$kind: ps both layouts report the same loader line"
  expect_fixed "$out_rel" "$reason" "$kind: ps release layout reason is the expected one"
  expect_fixed "$out_flat" "$reason" "$kind: ps flat layout reason is the expected one"

  if [ "$kind" = fixed ]; then
    expect_files_equal "$STANDIN/fixed/version.dll" "$game_rel/version.dll" "$kind: ps release layout used the override loader"
    expect_files_equal "$STANDIN/fixed/version.dll" "$game_flat/version.dll" "$kind: ps flat layout used the override loader"
  else
    expect_files_equal "$RELEASE/payload/version.dll" "$game_rel/version.dll" "$kind: ps release layout used its payload loader"
    expect_files_equal "$FLAT/version.dll" "$game_flat/version.dll" "$kind: ps flat layout used its own loader"
  fi
  expect_files_equal "$RELEASE/payload/BreedingSpike.dll" "$game_rel/mods/BreedingSpike.dll" "$kind: ps release layout mod DLL is its payload copy"
  expect_files_equal "$FLAT/BreedingSpike.dll" "$game_flat/mods/BreedingSpike.dll" "$kind: ps flat layout mod DLL is its own copy"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
printf 'loader-layout tests: temp dir %s\n' "$WORK"
printf 'loader-layout tests: repo %s\n' "$REPO_ROOT"

STANDIN="$WORK/standin"
make_standin "$STANDIN/fixed" fixed
make_standin "$STANDIN/nofix" nofix

RELEASE="$WORK/release"
FLAT="$WORK/flat"
make_release_layout "$RELEASE"
make_flat_layout "$FLAT"

mkdir -p "$WORK/fixtures"
printf 'a file the installer must never touch\n' > "$WORK/fixtures/decoy.txt"

# EnableEPFallback present -> the override loader wins in both layouts.
test_sh_same_override_same_loader fixed "it carries the EnableEPFallback fix"
# EnableEPFallback absent -> the bundled payload loader wins in both layouts.
test_sh_same_override_same_loader nofix "does not carry the fix yet; using the bundled patched loader"

if [ -z "$PWSH" ]; then
  section "install.ps1"
  fail "pwsh not found: install nixpkgs#powershell (or set PWSH=/path/to/pwsh)"
else
  printf '  info using pwsh: %s\n' "$PWSH"
  test_ps_same_override_same_loader fixed "it carries the EnableEPFallback fix"
  test_ps_same_override_same_loader nofix "does not carry the fix yet; using the bundled patched loader"
fi

printf '\n============================================\n'
if [ "$FAILED" -eq 0 ]; then
  printf 'PASS: loader-layout tests: %d checks passed, 0 failed\n' "$PASSED"
  exit 0
fi
printf 'FAIL: loader-layout tests: %d passed, %d FAILED\n' "$PASSED" "$FAILED" >&2
exit 1
