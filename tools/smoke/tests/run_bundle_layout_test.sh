#!/usr/bin/env bash
# Tests for how install.sh and install.ps1 find their payload in the two older
# bundle layouts that must keep working now that a release is one zip per
# platform (see run_per_platform_bundle_test.sh and run_release_assembly_test.sh
# for the current per-platform bundles):
#
# The legacy two-folder layout:
#
#   MewgenicsBreedingMod/
#     README.md   PATCHES.md   MEWJECTOR-LICENSE.txt
#     payload/    version.dll   chainloader.ini   BreedingSpike.dll
#     windows/    install.bat   install.ps1   uninstall.bat   loader-release.ps1
#     linux/      install.sh    uninstall.sh  loader-release.sh  proton-registry.sh
#
# and the flat unpack, where the scripts and the three artifacts share one
# folder.
#
# Each script must use the three artifacts beside itself when all three are
# there, otherwise the `payload` folder beside its own folder. Install,
# re-install, dry-run and uninstall must all work from both layouts, and the
# installed artifacts must be the payload copies, never a stray file that
# happens to sit elsewhere in the unpacked bundle.
#
# Everything runs inside a private temp tree. The payload artifacts are fakes
# (install.sh never inspects their contents) and HOME points at an empty temp
# directory, so neither a real game install nor Steam is read. Every installer
# run is given a local MEWJECTOR_RELEASE_OVERRIDE stand-in, so no check here can
# reach the network.
#
#   ./tools/smoke/tests/run_bundle_layout_test.sh
#
# The PowerShell half needs pwsh (nixpkgs `powershell`). It checks what Linux
# can check: parsing, and the install/dry-run/uninstall paths against a fake
# game folder. Windows-only behaviour is NOT covered; that is said plainly
# rather than pretended.
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

expect_match() { # file regex desc
  if grep -qE -- "$2" "$1" 2>/dev/null; then
    pass "$3"
  else
    fail "$3: /$2/ not found in $(basename "$1")"
  fi
}

expect_fixed() { # file literal desc
  if grep -qF -- "$2" "$1" 2>/dev/null; then
    pass "$3"
  else
    fail "$3: [$2] not found in $(basename "$1")"
  fi
}

expect_count() { # file regex want desc
  local got
  got="$(grep -cE -- "$2" "$1" 2>/dev/null || true)"
  expect_eq "$3" "$got" "$4"
}

expect_exists() { if [ -e "$1" ]; then pass "$2"; else fail "$2: [$1] does not exist"; fi; }
expect_absent() { if [ ! -e "$1" ]; then pass "$2"; else fail "$2: [$1] should not exist"; fi; }

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

# Content + mtime + mode + type of everything under a directory. Used to prove a
# dry run or a repeat run changed literally nothing.
snapshot() { # dir out-file
  (
    cd "$1" || exit 1
    find . -mindepth 1 -printf '%y %m %s %T@ %P\n' | LC_ALL=C sort
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  ) > "$2"
}

# Like snapshot, but paths matching the ERE are dropped. A re-install rewrites
# the install record (and so the mods/ folder mtime) while every payload file
# keeps its content and timestamp, so that one file is excluded.
snapshot_excluding() { # dir out-file grep-ERE
  (
    cd "$1" || exit 1
    find . -mindepth 1 -printf '%y %m %s %T@ %P\n' | LC_ALL=C sort | grep -vE -- "$3" || true
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum | grep -vE -- "$3" || true
  ) > "$2"
}

expect_same_tree() { # before after desc
  if cmp -s "$1" "$2"; then
    pass "$3"
  else
    fail "$3: the directory changed"
    diff -u "$1" "$2" | head -40 >&2 || true
  fi
}

# The manifest every successful install must write, one target per line.
MANIFEST_CONTENT=$'version.dll\nchainloader.ini\nmods/BreedingSpike.dll\n'

# ---------------------------------------------------------------------------
# fixtures and runners
# ---------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mew-bundle-layout-test.XXXXXX")"
FAKE_HOME="$WORK/home"

cleanup() {
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT INT TERM

mkdir -p "$FAKE_HOME" "$WORK/fixtures"

# Fake artifacts with distinct content per variant, so "came from payload/" and
# "came from the stray copy" are different byte strings.
write_payload_file() { # dir name [variant]
  local dir="$1" name="$2" variant="${3:-payload}"
  mkdir -p "$dir"
  case "$name" in
    version.dll)       printf 'FAKE-LOADER-%s\n' "$variant" > "$dir/$name" ;;
    chainloader.ini)   printf '[chainloader]\nmods=mods\n# %s\n' "$variant" > "$dir/$name" ;;
    BreedingSpike.dll) printf 'FAKE-MOD-%s\n' "$variant" > "$dir/$name" ;;
    *) fail "unknown fixture $name" ;;
  esac
}

copy_scripts() { # dir platform(shell|windows)
  local dir="$1" platform="$2"
  mkdir -p "$dir"
  if [ "$platform" = shell ]; then
    cp -p "$REPO_ROOT/installers/install.sh" "$dir/install.sh"
    cp -p "$REPO_ROOT/installers/proton-registry.sh" "$dir/proton-registry.sh"
    cp -p "$REPO_ROOT/installers/loader-release.sh" "$dir/loader-release.sh"
    cp -p "$REPO_ROOT/installers/uninstall.sh" "$dir/uninstall.sh"
    chmod +x "$dir/install.sh" "$dir/proton-registry.sh" "$dir/uninstall.sh"
  else
    cp -p "$REPO_ROOT/installers/install.ps1" "$dir/install.ps1"
    cp -p "$REPO_ROOT/installers/loader-release.ps1" "$dir/loader-release.ps1"
    cp -p "$REPO_ROOT/installers/install.bat" "$dir/install.bat"
    cp -p "$REPO_ROOT/installers/uninstall.bat" "$dir/uninstall.bat"
  fi
}

# The documented release layout: docs and payload/ at the root, the scripts in
# windows/ and linux/.
make_release_layout() { # dir
  local dir="$1"
  mkdir -p "$dir/payload" "$dir/windows" "$dir/linux"
  printf 'install notes\n' > "$dir/README.md"
  printf 'what the patch changes\n' > "$dir/PATCHES.md"
  printf 'Mewjector licence text\n' > "$dir/MEWJECTOR-LICENSE.txt"
  copy_scripts "$dir/linux" shell
  copy_scripts "$dir/windows" windows
  write_payload_file "$dir/payload" version.dll
  write_payload_file "$dir/payload" chainloader.ini
  write_payload_file "$dir/payload" BreedingSpike.dll
}

# The old flat layout: scripts and the three artifacts in one folder.
make_flat_layout() { # dir
  local dir="$1"
  mkdir -p "$dir"
  copy_scripts "$dir" shell
  copy_scripts "$dir" windows
  write_payload_file "$dir" version.dll
  write_payload_file "$dir" chainloader.ini
  write_payload_file "$dir" BreedingSpike.dll
}

# A fake game folder with things the installer must never touch.
seed_game() { # dir
  mkdir -p "$1/mod_logs"
  printf 'fake game executable\n' > "$1/Mewgenics.exe"
  printf 'a file the installer must never touch\n' > "$1/decoy.txt"
  printf 'previous loader log\n' > "$1/mod_logs/chainloader.log"
}
printf 'a file the installer must never touch\n' > "$WORK/fixtures/decoy.txt"

# A local stand-in for an official Mewjector release whose chainloader.ini does
# NOT carry EnableEPFallback. Pointing every run at it keeps the checks offline
# and makes both scripts choose the bundled payload rather than the network.
STANDIN_NOFIX="$WORK/standin-nofix"
mkdir -p "$STANDIN_NOFIX"
printf 'STANDIN-LOADER-NOFIX\n' > "$STANDIN_NOFIX/version.dll"
printf '[chainloader]\nmods=mods\n' > "$STANDIN_NOFIX/chainloader.ini"

LAST_OUT=""
RC=0

run_sh() { # install-sh args...
  local script="$1"
  shift
  LAST_OUT="$WORK/last-installer.out"
  if env -u MEWGENICS_DIR -u PAYLOAD_DIR HOME="$FAKE_HOME" \
       MEWJECTOR_RELEASE_OVERRIDE="$STANDIN_NOFIX" \
       "$script" "$@" > "$LAST_OUT" 2>&1; then
    RC=0
  else
    RC=$?
  fi
}

run_ps() { # install-ps1 args...
  LAST_OUT="$WORK/last-pwsh.out"
  if env -u MEWGENICS_DIR HOME="$FAKE_HOME" \
       MEWJECTOR_RELEASE_OVERRIDE="$STANDIN_NOFIX" \
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

# ---------------------------------------------------------------------------
# install.sh, both layouts
# ---------------------------------------------------------------------------
# One function covers install, re-install, dry-run and uninstall for either
# layout. $3 is the folder the installed artifacts must come from; any further
# arguments are stray copies that must NOT be installed.
test_sh_layout() { # label install-sh payload-dir [stray...]
  local label="$1" script="$2" payload="$3"
  shift 3
  local -a strays=("$@")
  local game="$WORK/sh-$label-game"
  local manifest="$game/mods/.breeding-spike-installed"
  local old="$WORK/fixtures/old-$label.txt"
  seed_game "$game"
  # An existing loader: install must back it up, uninstall must restore it.
  printf 'OLD-LOADER-%s\n' "$label" > "$game/version.dll"
  printf 'OLD-LOADER-%s\n' "$label" > "$old"

  section "install.sh ($label layout): dry-run reports the plan and changes nothing"
  snapshot "$game" "$WORK/sh-$label-dry-before"
  run_sh "$script" --dry-run --game-dir "$game"
  expect_eq 0 "$RC" "$label: dry run exits 0"
  expect_count "$LAST_OUT" '\[dry\] copy ' 3 "$label: dry run plans the three copies"
  expect_match "$LAST_OUT" '\[dry\] copy version\.dll to .*/version\.dll$' "$label: plans version.dll beside the game exe"
  expect_match "$LAST_OUT" '\[dry\] copy BreedingSpike\.dll to .*/mods/BreedingSpike\.dll$' "$label: plans the mod DLL into mods/"
  expect_match "$LAST_OUT" '\[dry\] back up version\.dll to version\.dll\.[0-9]{8}-[0-9]{6}\.bak' "$label: plans the backup of the existing loader"
  expect_fixed "$LAST_OUT" 'dry run complete: nothing was changed.' "$label: dry run says nothing was changed"
  expect_absent "$game/mods" "$label: dry run did not create mods/"
  snapshot "$game" "$WORK/sh-$label-dry-after"
  expect_same_tree "$WORK/sh-$label-dry-before" "$WORK/sh-$label-dry-after" "$label: dry run changed nothing at all"

  section "install.sh ($label layout): installs the payload and backs up the replaced loader"
  run_sh "$script" --game-dir "$game"
  expect_eq 0 "$RC" "$label: install exits 0"
  expect_files_equal "$payload/version.dll" "$game/version.dll" "$label: installed loader is the payload copy"
  expect_files_equal "$payload/chainloader.ini" "$game/chainloader.ini" "$label: installed ini is the payload copy"
  expect_files_equal "$payload/BreedingSpike.dll" "$game/mods/BreedingSpike.dll" "$label: installed mod DLL is the payload copy"
  expect_fixed "$LAST_OUT" 'install complete: 3 written, 0 already up to date, 1 backed up.' "$label: reports 3 written and 1 backup"
  expect_content "$WORK/fixtures/decoy.txt" "$game/decoy.txt" "$label: unrelated game file untouched"
  printf '%s' "$MANIFEST_CONTENT" > "$WORK/fixtures/manifest-$label.txt"
  expect_files_equal "$WORK/fixtures/manifest-$label.txt" "$manifest" "$label: record lists exactly the installed paths"

  local stray
  if [ "${#strays[@]}" -gt 0 ]; then
    for stray in "${strays[@]}"; do
      if [ ! -e "$stray" ]; then
        fail "$label: stray fixture $stray is missing, so the check would be vacuous"
      elif cmp -s "$stray" "$game/version.dll"; then
        fail "$label: installed version.dll came from the stray copy at $stray"
      else
        pass "$label: installed version.dll is not the stray copy at $stray"
      fi
    done
  fi

  section "install.sh ($label layout): a re-install writes nothing but the record"
  cp -p "$manifest" "$WORK/sh-$label-record-before"
  snapshot_excluding "$game" "$WORK/sh-$label-re-before" '(^d .* mods$|\.breeding-spike-installed)'
  run_sh "$script" --game-dir "$game"
  expect_eq 0 "$RC" "$label: re-install exits 0"
  expect_count "$LAST_OUT" 'is already up to date' 3 "$label: re-install reports every file current"
  expect_fixed "$LAST_OUT" 'install complete: 0 written, 3 already up to date, 0 backed up.' "$label: re-install writes nothing"
  snapshot_excluding "$game" "$WORK/sh-$label-re-after" '(^d .* mods$|\.breeding-spike-installed)'
  expect_same_tree "$WORK/sh-$label-re-before" "$WORK/sh-$label-re-after" "$label: re-install left the installed files untouched"
  expect_files_equal "$WORK/sh-$label-record-before" "$manifest" "$label: re-install left the record byte-identical"

  section "install.sh ($label layout): uninstall restores the backup and removes the rest"
  run_sh "$script" --uninstall --game-dir "$game"
  expect_eq 0 "$RC" "$label: uninstall exits 0"
  expect_content "$old" "$game/version.dll" "$label: uninstall restored the pre-install loader from its backup"
  expect_absent "$game/chainloader.ini" "$label: installed ini removed"
  expect_absent "$game/mods/BreedingSpike.dll" "$label: installed mod DLL removed"
  expect_absent "$manifest" "$label: install record removed by uninstall"
  expect_fixed "$LAST_OUT" 'uninstall complete: 2 removed, 1 restored from backup, 0 left in place.' "$label: reports 2 removed, 1 restored, 0 left"
}

# ---------------------------------------------------------------------------
# install.ps1, both layouts (Linux checks only)
# ---------------------------------------------------------------------------
test_ps_layout() { # label install-ps1 payload-dir [stray...]
  local label="$1" script="$2" payload="$3"
  shift 3
  local -a strays=("$@")
  local game="$WORK/ps-$label-game"
  local manifest="$game/mods/.breeding-spike-installed"
  local old="$WORK/fixtures/ps-old-$label.txt"
  seed_game "$game"
  printf 'PS-OLD-LOADER-%s\n' "$label" > "$game/version.dll"
  printf 'PS-OLD-LOADER-%s\n' "$label" > "$old"

  section "install.ps1 ($label layout): dry-run reports the plan and changes nothing"
  snapshot "$game" "$WORK/ps-$label-dry-before"
  run_ps "$script" -DryRun -GameDir "$game"
  expect_eq 0 "$RC" "$label: ps dry run exits 0"
  expect_count "$LAST_OUT" '\[dry\] copy ' 3 "$label: ps dry run plans the three copies"
  expect_match "$LAST_OUT" '\[dry\] copy version\.dll to ' "$label: ps plans version.dll"
  expect_match "$LAST_OUT" '\[dry\] back up version\.dll to version\.dll\.[0-9]{8}-[0-9]{6}\.bak' "$label: ps plans the backup of the existing loader"
  expect_fixed "$LAST_OUT" 'dry run complete: nothing was changed.' "$label: ps dry run says nothing was changed"
  expect_absent "$game/mods" "$label: ps dry run did not create mods/"
  snapshot "$game" "$WORK/ps-$label-dry-after"
  expect_same_tree "$WORK/ps-$label-dry-before" "$WORK/ps-$label-dry-after" "$label: ps dry run changed nothing at all"

  section "install.ps1 ($label layout): installs the payload and backs up the replaced loader"
  run_ps "$script" -GameDir "$game"
  expect_eq 0 "$RC" "$label: ps install exits 0"
  expect_files_equal "$payload/version.dll" "$game/version.dll" "$label: ps installed loader is the payload copy"
  expect_files_equal "$payload/chainloader.ini" "$game/chainloader.ini" "$label: ps installed ini is the payload copy"
  expect_files_equal "$payload/BreedingSpike.dll" "$game/mods/BreedingSpike.dll" "$label: ps installed mod DLL is the payload copy"
  expect_fixed "$LAST_OUT" 'install complete: 3 written, 0 already up to date, 1 backed up.' "$label: ps reports 3 written and 1 backup"
  expect_content "$WORK/fixtures/decoy.txt" "$game/decoy.txt" "$label: ps left the unrelated game file untouched"
  printf '%s' "$MANIFEST_CONTENT" > "$WORK/fixtures/ps-manifest-$label.txt"
  expect_files_equal "$WORK/fixtures/ps-manifest-$label.txt" "$manifest" "$label: ps record lists exactly the installed paths"

  local stray
  if [ "${#strays[@]}" -gt 0 ]; then
    for stray in "${strays[@]}"; do
      if [ ! -e "$stray" ]; then
        fail "$label: ps stray fixture $stray is missing, so the check would be vacuous"
      elif cmp -s "$stray" "$game/version.dll"; then
        fail "$label: ps installed version.dll came from the stray copy at $stray"
      else
        pass "$label: ps installed version.dll is not the stray copy at $stray"
      fi
    done
  fi

  section "install.ps1 ($label layout): a re-install writes nothing but the record"
  cp -p "$manifest" "$WORK/ps-$label-record-before"
  snapshot_excluding "$game" "$WORK/ps-$label-re-before" '(^d .* mods$|\.breeding-spike-installed)'
  run_ps "$script" -GameDir "$game"
  expect_eq 0 "$RC" "$label: ps re-install exits 0"
  expect_count "$LAST_OUT" 'is already up to date' 3 "$label: ps re-install reports every file current"
  expect_fixed "$LAST_OUT" 'install complete: 0 written, 3 already up to date, 0 backed up.' "$label: ps re-install writes nothing"
  snapshot_excluding "$game" "$WORK/ps-$label-re-after" '(^d .* mods$|\.breeding-spike-installed)'
  expect_same_tree "$WORK/ps-$label-re-before" "$WORK/ps-$label-re-after" "$label: ps re-install left the installed files untouched"
  expect_files_equal "$WORK/ps-$label-record-before" "$manifest" "$label: ps re-install left the record byte-identical"

  section "install.ps1 ($label layout): uninstall restores the backup and removes the rest"
  run_ps "$script" -Uninstall -GameDir "$game"
  expect_eq 0 "$RC" "$label: ps uninstall exits 0"
  expect_content "$old" "$game/version.dll" "$label: ps uninstall restored the pre-install loader from its backup"
  expect_absent "$game/chainloader.ini" "$label: ps installed ini removed"
  expect_absent "$game/mods/BreedingSpike.dll" "$label: ps installed mod DLL removed"
  expect_absent "$manifest" "$label: ps install record removed by uninstall"
  expect_fixed "$LAST_OUT" 'uninstall complete: 2 removed, 1 restored from backup, 0 left in place.' "$label: ps reports 2 removed, 1 restored, 0 left"
}

# ---------------------------------------------------------------------------
# incomplete payloads: the error must name where the installer looked
# ---------------------------------------------------------------------------
test_incomplete_payload_release_layout() {
  section "release layout: an incomplete payload/ names the missing file under payload/"
  local dir="$WORK/release-incomplete"
  local game="$WORK/release-incomplete-game"
  make_release_layout "$dir"
  rm -f "$dir/payload/BreedingSpike.dll"
  seed_game "$game"
  snapshot "$game" "$WORK/release-incomplete-before"

  run_sh "$dir/linux/install.sh" --game-dir "$game"

  expect_eq 1 "$RC" "install fails when a payload file is missing"
  expect_fixed "$LAST_OUT" 'the installer payload is incomplete' "says the payload is incomplete"
  expect_match "$LAST_OUT" '^       .*/payload/BreedingSpike\.dll$' "names the missing artifact under payload/"
  expect_count "$LAST_OUT" '^       .*/payload/' 1 "names exactly the one missing artifact, not the two present ones"
  expect_fixed "$LAST_OUT" 'unpack the whole release folder before running this' "tells the user what to do"
  expect_absent "$game/version.dll" "nothing copied"
  expect_absent "$game/mods/.breeding-spike-installed" "no install record written"
  snapshot "$game" "$WORK/release-incomplete-after"
  expect_same_tree "$WORK/release-incomplete-before" "$WORK/release-incomplete-after" "game folder untouched"
}

test_incomplete_payload_flat_layout() {
  section "flat layout: an incomplete payload names the missing file beside install.sh"
  local dir="$WORK/flat-incomplete"
  local game="$WORK/flat-incomplete-game"
  make_flat_layout "$dir"
  rm -f "$dir/BreedingSpike.dll"
  seed_game "$game"
  snapshot "$game" "$WORK/flat-incomplete-before"

  run_sh "$dir/install.sh" --game-dir "$game"

  expect_eq 1 "$RC" "install fails when an artifact beside the script is missing"
  expect_fixed "$LAST_OUT" 'the installer payload is incomplete' "says the payload is incomplete"
  expect_fixed "$LAST_OUT" "$dir/BreedingSpike.dll" "names the missing artifact where it looked: beside install.sh"
  if grep -qF "$dir/../payload/" "$LAST_OUT"; then
    fail "must not send the user to a payload/ folder that does not exist"
  else
    pass "does not point at a payload/ folder that does not exist"
  fi
  expect_absent "$game/version.dll" "nothing copied"
  expect_absent "$game/mods/.breeding-spike-installed" "no install record written"
  snapshot "$game" "$WORK/flat-incomplete-after"
  expect_same_tree "$WORK/flat-incomplete-before" "$WORK/flat-incomplete-after" "game folder untouched"
}

test_incomplete_payload_ps_release_layout() {
  section "release layout: install.ps1 names the missing payload/ file"
  local dir="$WORK/ps-release-incomplete"
  local game="$WORK/ps-release-incomplete-game"
  make_release_layout "$dir"
  rm -f "$dir/payload/BreedingSpike.dll"
  seed_game "$game"

  run_ps "$dir/windows/install.ps1" -GameDir "$game"

  expect_eq 1 "$RC" "ps install fails when a payload file is missing"
  expect_fixed "$LAST_OUT" 'the installer payload is incomplete' "ps says the payload is incomplete"
  expect_match "$LAST_OUT" '^       .*/payload/.*BreedingSpike\.dll$' "ps names the missing artifact under payload/"
  expect_absent "$game/version.dll" "ps copied nothing"
}

test_incomplete_payload_ps_flat_layout() {
  section "flat layout: install.ps1 names the missing file beside install.ps1"
  local dir="$WORK/ps-flat-incomplete"
  local game="$WORK/ps-flat-incomplete-game"
  make_flat_layout "$dir"
  rm -f "$dir/BreedingSpike.dll"
  seed_game "$game"

  run_ps "$dir/install.ps1" -GameDir "$game"

  expect_eq 1 "$RC" "ps install fails when an artifact beside the script is missing"
  expect_fixed "$LAST_OUT" 'the installer payload is incomplete' "ps says the payload is incomplete"
  expect_fixed "$LAST_OUT" "$dir/BreedingSpike.dll" "ps names the missing artifact where it looked: beside install.ps1"
  if grep -qF "$dir/../payload/" "$LAST_OUT"; then
    fail "ps must not send the user to a payload/ folder that does not exist"
  else
    pass "ps does not point at a payload/ folder that does not exist"
  fi
  expect_absent "$game/version.dll" "ps copied nothing"
}

# ---------------------------------------------------------------------------
# missing helper: still fails loudly in the release layout
# ---------------------------------------------------------------------------
test_missing_helper_release_layout() {
  section "release layout: a missing helper still fails loudly"
  local game="$WORK/helper-game"
  seed_game "$game"

  local no_registry="$WORK/release-no-registry"
  make_release_layout "$no_registry"
  rm -f "$no_registry/linux/proton-registry.sh"
  run_sh "$no_registry/linux/install.sh" --game-dir "$game"
  expect_eq 1 "$RC" "missing proton-registry.sh fails"
  expect_fixed "$LAST_OUT" 'proton-registry.sh is missing' "names the missing proton helper"

  local no_loader="$WORK/release-no-loader"
  make_release_layout "$no_loader"
  rm -f "$no_loader/linux/loader-release.sh"
  run_sh "$no_loader/linux/install.sh" --game-dir "$game"
  expect_eq 1 "$RC" "missing loader-release.sh fails"
  expect_fixed "$LAST_OUT" 'loader-release.sh is missing' "names the missing loader helper"
}

test_ps_missing_helper_release_layout() {
  section "release layout: install.ps1 fails loudly when its helper is missing"
  local game="$WORK/ps-helper-game"
  local dir="$WORK/release-ps-no-loader"
  seed_game "$game"
  make_release_layout "$dir"
  rm -f "$dir/windows/loader-release.ps1"
  run_ps "$dir/windows/install.ps1" -DryRun -GameDir "$game"
  expect_eq 1 "$RC" "install.ps1 missing loader-release.ps1 fails"
  expect_fixed "$LAST_OUT" 'loader-release.ps1 is missing' "install.ps1 names the missing loader helper"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
printf 'bundle-layout tests: temp dir %s\n' "$WORK"
printf 'bundle-layout tests: repo %s\n' "$REPO_ROOT"

# --- the release layout -----------------------------------------------------
RELEASE="$WORK/release"
make_release_layout "$RELEASE"
# Strays that must never be installed. Only version.dll sits beside the script,
# so the "all three beside the script" rule cannot match and the payload/ folder
# must be chosen; the release root is neither candidate.
printf 'STRAY-BESIDE-THE-SCRIPT\n' > "$RELEASE/linux/version.dll"
printf 'STRAY-BESIDE-THE-SCRIPT\n' > "$RELEASE/windows/version.dll"
printf 'STRAY-AT-THE-RELEASE-ROOT\n' > "$RELEASE/version.dll"
printf 'STRAY-INI-AT-THE-RELEASE-ROOT\n' > "$RELEASE/chainloader.ini"

test_sh_layout "release" "$RELEASE/linux/install.sh" "$RELEASE/payload" \
  "$RELEASE/linux/version.dll" "$RELEASE/version.dll"

# --- the flat layout --------------------------------------------------------
FLAT_CASE="$WORK/flatcase"
FLAT="$FLAT_CASE/MewgenicsBreedingMod"
make_flat_layout "$FLAT"
# A complete sibling payload/ folder with different content: the three files
# beside the script must win, because all three are there.
write_payload_file "$FLAT_CASE/payload" version.dll decoy
write_payload_file "$FLAT_CASE/payload" chainloader.ini decoy
write_payload_file "$FLAT_CASE/payload" BreedingSpike.dll decoy

test_sh_layout "flat" "$FLAT/install.sh" "$FLAT" "$FLAT_CASE/payload/version.dll"

# --- install.ps1 ------------------------------------------------------------
if [ -z "$PWSH" ]; then
  section "install.ps1"
  fail "pwsh not found: install nixpkgs#powershell (or set PWSH=/path/to/pwsh)"
else
  printf '  info using pwsh: %s\n' "$PWSH"
  test_ps_layout "release" "$RELEASE/windows/install.ps1" "$RELEASE/payload" \
    "$RELEASE/windows/version.dll" "$RELEASE/version.dll"
  test_ps_layout "flat" "$FLAT/install.ps1" "$FLAT" "$FLAT_CASE/payload/version.dll"
  test_incomplete_payload_ps_release_layout
  test_incomplete_payload_ps_flat_layout
  test_ps_missing_helper_release_layout
fi

# --- error paths on the shell side -----------------------------------------
test_incomplete_payload_release_layout
test_incomplete_payload_flat_layout
test_missing_helper_release_layout

printf '\n============================================\n'
if [ "$FAILED" -eq 0 ]; then
  printf 'PASS: bundle-layout tests: %d checks passed, 0 failed\n' "$PASSED"
  exit 0
fi
printf 'FAIL: bundle-layout tests: %d passed, %d FAILED\n' "$PASSED" "$FAILED" >&2
exit 1
