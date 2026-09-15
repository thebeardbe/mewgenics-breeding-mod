#!/usr/bin/env bash
# Tests for the new one-zip-per-platform release bundles, end to end.
#
# Each platform zip is self-contained:
#
#   linux bundle:                      windows bundle:
#     install.sh    uninstall.sh         install.bat   uninstall.bat
#     scripts/      loader-release.sh    scripts/      install.ps1
#                   proton-registry.sh                 loader-release.ps1
#     payload/      version.dll          payload/      version.dll
#                   chainloader.ini                    chainloader.ini
#                   BreedingSpike.dll                  BreedingSpike.dll
#     docs/         HOW-IT-WORKS.md      docs/         HOW-IT-WORKS.md
#                   PATCHES.md                         PATCHES.md
#                   MEWJECTOR-LICENSE.txt              MEWJECTOR-LICENSE.txt
#     README.md                          README.md
#
# install.sh sits at the bundle root and must find its helpers under scripts/
# (falling back to beside itself for an older flat unpack) and its payload in
# payload/. install.ps1 sits in scripts/ and finds its helper beside itself and
# the payload beside its parent.
#
# Install, re-install, dry-run, uninstall, payload provenance and helper
# provenance are all exercised. Everything runs inside a private temp tree with
# fake artifacts and an empty HOME, and every installer run gets a local
# MEWJECTOR_RELEASE_OVERRIDE stand-in, so no check can reach the network.
#
#   ./tools/smoke/tests/run_per_platform_bundle_test.sh
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

# Content + mtime + mode + type of everything under a directory. Proves a dry
# run or a repeat run changed literally nothing.
snapshot() { # dir out-file
  (
    cd "$1" || exit 1
    find . -mindepth 1 -printf '%y %m %s %T@ %P\n' | LC_ALL=C sort
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  ) > "$2"
}

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

# ---------------------------------------------------------------------------
# fixtures and runners
# ---------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mew-per-platform-test.XXXXXX")"
FAKE_HOME="$WORK/home"

cleanup() {
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT INT TERM

mkdir -p "$FAKE_HOME" "$WORK/fixtures"

# Fake artifacts with distinct content, so "came from payload/" and "came from
# a stray copy" are different byte strings.
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

# The new Linux bundle: entry scripts at the root, helpers in scripts/, the
# three artifacts in payload/, the docs in docs/.
make_linux_bundle() { # dir
  local dir="$1"
  mkdir -p "$dir/scripts" "$dir/payload" "$dir/docs"
  cp -p "$REPO_ROOT/installers/install.sh" "$dir/install.sh"
  cp -p "$REPO_ROOT/installers/uninstall.sh" "$dir/uninstall.sh"
  cp -p "$REPO_ROOT/installers/loader-release.sh" "$dir/scripts/loader-release.sh"
  cp -p "$REPO_ROOT/installers/proton-registry.sh" "$dir/scripts/proton-registry.sh"
  chmod +x "$dir/install.sh" "$dir/uninstall.sh" "$dir/scripts/loader-release.sh" "$dir/scripts/proton-registry.sh"
  cp -p "$REPO_ROOT/installers/HOW-IT-WORKS.md" "$dir/docs/HOW-IT-WORKS.md"
  cp -p "$REPO_ROOT/installers/PATCHES.md" "$dir/docs/PATCHES.md"
  cp -p "$REPO_ROOT/installers/MEWJECTOR-LICENSE.txt" "$dir/docs/MEWJECTOR-LICENSE.txt"
  cp -p "$REPO_ROOT/installers/README-linux.md" "$dir/README.md"
  write_payload_file "$dir/payload" version.dll
  write_payload_file "$dir/payload" chainloader.ini
  write_payload_file "$dir/payload" BreedingSpike.dll
}

# The new Windows bundle: the .bat entries at the root, install.ps1 and its
# helper in scripts/, the artifacts in payload/.
make_windows_bundle() { # dir
  local dir="$1"
  mkdir -p "$dir/scripts" "$dir/payload" "$dir/docs"
  cp -p "$REPO_ROOT/installers/install.bat" "$dir/install.bat"
  cp -p "$REPO_ROOT/installers/uninstall.bat" "$dir/uninstall.bat"
  cp -p "$REPO_ROOT/installers/install.ps1" "$dir/scripts/install.ps1"
  cp -p "$REPO_ROOT/installers/loader-release.ps1" "$dir/scripts/loader-release.ps1"
  cp -p "$REPO_ROOT/installers/HOW-IT-WORKS.md" "$dir/docs/HOW-IT-WORKS.md"
  cp -p "$REPO_ROOT/installers/PATCHES.md" "$dir/docs/PATCHES.md"
  cp -p "$REPO_ROOT/installers/MEWJECTOR-LICENSE.txt" "$dir/docs/MEWJECTOR-LICENSE.txt"
  cp -p "$REPO_ROOT/installers/README-windows.md" "$dir/README.md"
  write_payload_file "$dir/payload" version.dll
  write_payload_file "$dir/payload" chainloader.ini
  write_payload_file "$dir/payload" BreedingSpike.dll
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

MANIFEST_CONTENT=$'version.dll\nchainloader.ini\nmods/BreedingSpike.dll\n'

LAST_OUT=""
RC=0

run_sh() { # install-sh args...
  local script="$1"
  shift
  LAST_OUT="$WORK/last-sh.out"
  if env -u MEWGENICS_DIR -u PAYLOAD_DIR HOME="$FAKE_HOME" \
       MEWJECTOR_RELEASE_OVERRIDE="$STANDIN_NOFIX" \
       "$script" "$@" > "$LAST_OUT" 2>&1; then
    RC=0
  else
    RC=$?
  fi
}

run_ps() { # install-ps1 args...
  LAST_OUT="$WORK/last-ps.out"
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
# Linux bundle, end to end
# ---------------------------------------------------------------------------
test_linux_bundle_lifecycle() { # dir
  local bundle="$1"
  local game="$WORK/linux-game"
  local manifest="$game/mods/.breeding-spike-installed"
  local old="$WORK/fixtures/linux-old-loader.txt"
  seed_game "$game"
  # An existing loader: install must back it up, uninstall must restore it.
  printf 'OLD-LOADER-linux\n' > "$game/version.dll"
  printf 'OLD-LOADER-linux\n' > "$old"

  section "linux bundle: dry-run reports the plan and changes nothing"
  snapshot "$game" "$WORK/linux-dry-before"
  run_sh "$bundle/install.sh" --dry-run --game-dir "$game"
  expect_eq 0 "$RC" "dry run exits 0"
  expect_count "$LAST_OUT" '\[dry\] copy ' 3 "dry run plans the three copies"
  expect_match "$LAST_OUT" '\[dry\] copy version\.dll to .*/version\.dll$' "plans version.dll beside the game exe"
  expect_match "$LAST_OUT" '\[dry\] copy BreedingSpike\.dll to .*/mods/BreedingSpike\.dll$' "plans the mod DLL into mods/"
  expect_match "$LAST_OUT" '\[dry\] back up version\.dll to version\.dll\.[0-9]{8}-[0-9]{6}\.bak' "plans the backup of the existing loader"
  expect_fixed "$LAST_OUT" 'dry run complete: nothing was changed.' "dry run says nothing was changed"
  expect_absent "$game/mods" "dry run did not create mods/"
  snapshot "$game" "$WORK/linux-dry-after"
  expect_same_tree "$WORK/linux-dry-before" "$WORK/linux-dry-after" "dry run changed nothing at all"

  section "linux bundle: installs the payload and backs up the replaced loader"
  run_sh "$bundle/install.sh" --game-dir "$game"
  expect_eq 0 "$RC" "install exits 0"
  expect_files_equal "$bundle/payload/version.dll" "$game/version.dll" "installed loader is the payload copy"
  expect_files_equal "$bundle/payload/chainloader.ini" "$game/chainloader.ini" "installed ini is the payload copy"
  expect_files_equal "$bundle/payload/BreedingSpike.dll" "$game/mods/BreedingSpike.dll" "installed mod DLL is the payload copy"
  expect_fixed "$LAST_OUT" 'install complete: 3 written, 0 already up to date, 1 backed up.' "reports 3 written and 1 backup"
  expect_content "$WORK/fixtures/decoy.txt" "$game/decoy.txt" "unrelated game file untouched"
  printf '%s' "$MANIFEST_CONTENT" > "$WORK/fixtures/linux-manifest.txt"
  expect_files_equal "$WORK/fixtures/linux-manifest.txt" "$manifest" "record lists exactly the installed paths"

  section "linux bundle: a re-install writes nothing but the record"
  cp -p "$manifest" "$WORK/linux-record-before"
  snapshot_excluding "$game" "$WORK/linux-re-before" '(^d .* mods$|\.breeding-spike-installed)'
  run_sh "$bundle/install.sh" --game-dir "$game"
  expect_eq 0 "$RC" "re-install exits 0"
  expect_count "$LAST_OUT" 'is already up to date' 3 "re-install reports every file current"
  expect_fixed "$LAST_OUT" 'install complete: 0 written, 3 already up to date, 0 backed up.' "re-install writes nothing"
  snapshot_excluding "$game" "$WORK/linux-re-after" '(^d .* mods$|\.breeding-spike-installed)'
  expect_same_tree "$WORK/linux-re-before" "$WORK/linux-re-after" "re-install left the installed files untouched"
  expect_files_equal "$WORK/linux-record-before" "$manifest" "re-install left the record byte-identical"

  section "linux bundle: uninstall restores the backup and removes the rest"
  run_sh "$bundle/install.sh" --uninstall --game-dir "$game"
  expect_eq 0 "$RC" "uninstall exits 0"
  expect_content "$old" "$game/version.dll" "uninstall restored the pre-install loader from its backup"
  expect_absent "$game/chainloader.ini" "installed ini removed"
  expect_absent "$game/mods/BreedingSpike.dll" "installed mod DLL removed"
  expect_absent "$manifest" "install record removed by uninstall"
  expect_fixed "$LAST_OUT" 'uninstall complete: 2 removed, 1 restored from backup, 0 left in place.' "reports 2 removed, 1 restored, 0 left"
}

# ---------------------------------------------------------------------------
# Linux helper provenance: scripts/ wins, beside is the fallback
# ---------------------------------------------------------------------------
test_linux_helper_provenance() {
  section "linux bundle: a helper beside install.sh does not shadow the scripts/ one"
  local bundle="$WORK/linux-helper-scripts"
  local game="$WORK/linux-helper-scripts-game"
  make_linux_bundle "$bundle"
  seed_game "$game"
  # Traps that die the moment they are sourced. If install.sh used either one,
  # the run would fail with the trap's message instead of installing.
  printf 'die "BESIDE-PROTON-REGISTRY-WAS-SOURCED"\n' > "$bundle/proton-registry.sh"
  printf 'die "BESIDE-LOADER-RELEASE-WAS-SOURCED"\n' > "$bundle/loader-release.sh"
  chmod +x "$bundle/proton-registry.sh" "$bundle/loader-release.sh"

  run_sh "$bundle/install.sh" --game-dir "$game"
  expect_eq 0 "$RC" "install exits 0, so the scripts/ helpers were the ones sourced"
  expect_files_equal "$bundle/payload/version.dll" "$game/version.dll" "the scripts/ helpers ran the install"
  if grep -qF 'WAS-SOURCED' "$LAST_OUT"; then
    fail "a beside-script helper was sourced instead of the scripts/ one"
  else
    pass "neither beside-script helper was sourced"
  fi
}

test_linux_helper_fallback() {
  section "linux bundle: with no scripts/ helper, install.sh falls back to beside itself"
  local bundle="$WORK/linux-helper-fallback"
  local game="$WORK/linux-helper-fallback-game"
  make_linux_bundle "$bundle"
  seed_game "$game"
  cp -p "$bundle/scripts/proton-registry.sh" "$bundle/proton-registry.sh"
  cp -p "$bundle/scripts/loader-release.sh" "$bundle/loader-release.sh"
  chmod +x "$bundle/proton-registry.sh" "$bundle/loader-release.sh"
  rm -f "$bundle/scripts/proton-registry.sh" "$bundle/scripts/loader-release.sh"

  run_sh "$bundle/install.sh" --game-dir "$game"
  expect_eq 0 "$RC" "install exits 0 using the helpers beside install.sh"
  expect_files_equal "$bundle/payload/version.dll" "$game/version.dll" "install completed from the beside-script helpers"
}

test_linux_missing_both_helpers() {
  section "linux bundle: with neither helper, install.sh fails loudly"
  local bundle="$WORK/linux-helper-missing"
  local game="$WORK/linux-helper-missing-game"
  make_linux_bundle "$bundle"
  seed_game "$game"
  rm -f "$bundle/scripts/proton-registry.sh"

  run_sh "$bundle/install.sh" --game-dir "$game"
  expect_eq 1 "$RC" "missing proton-registry.sh fails"
  expect_fixed "$LAST_OUT" 'proton-registry.sh is missing' "names the missing helper"

  make_linux_bundle "$bundle"
  rm -f "$bundle/scripts/loader-release.sh"
  run_sh "$bundle/install.sh" --game-dir "$game"
  expect_eq 1 "$RC" "missing loader-release.sh fails"
  expect_fixed "$LAST_OUT" 'loader-release.sh is missing' "names the missing loader helper"
}

test_linux_payload_provenance() {
  section "linux bundle: a stray copy beside install.sh does not beat payload/"
  local bundle="$WORK/linux-payload-prov"
  local game="$WORK/linux-payload-prov-game"
  make_linux_bundle "$bundle"
  seed_game "$game"
  # Only version.dll sits beside the script, so the "all three beside" rule
  # cannot match and payload/ must be chosen for every artifact.
  printf 'STRAY-BESIDE-THE-SCRIPT\n' > "$bundle/version.dll"

  run_sh "$bundle/install.sh" --game-dir "$game"
  expect_eq 0 "$RC" "install exits 0"
  expect_files_equal "$bundle/payload/version.dll" "$game/version.dll" "loader came from payload/, not the stray"
  if cmp -s "$bundle/version.dll" "$game/version.dll"; then
    fail "installed loader came from the stray copy beside install.sh"
  else
    pass "installed loader is not the stray copy beside install.sh"
  fi
  expect_files_equal "$bundle/payload/chainloader.ini" "$game/chainloader.ini" "ini came from payload/"
  expect_files_equal "$bundle/payload/BreedingSpike.dll" "$game/mods/BreedingSpike.dll" "mod DLL came from payload/"
}

test_linux_missing_artifact_names_payload() {
  section "linux bundle: a missing artifact names the payload/ folder that exists"
  local bundle="$WORK/linux-incomplete"
  local game="$WORK/linux-incomplete-game"
  make_linux_bundle "$bundle"
  rm -f "$bundle/payload/chainloader.ini"
  seed_game "$game"
  snapshot "$game" "$WORK/linux-incomplete-before"

  run_sh "$bundle/install.sh" --game-dir "$game"
  expect_eq 1 "$RC" "install fails when an artifact is missing"
  expect_fixed "$LAST_OUT" 'the installer payload is incomplete' "says the payload is incomplete"
  expect_fixed "$LAST_OUT" "$bundle/payload/chainloader.ini" "names the missing artifact under the payload/ folder"
  expect_match "$LAST_OUT" '^       .*/payload/chainloader\.ini$' "the named path is an existing payload folder"
  expect_exists "$bundle/payload" "the named payload folder exists"
  expect_absent "$game/version.dll" "nothing copied"
  expect_absent "$game/mods/.breeding-spike-installed" "no install record written"
  snapshot "$game" "$WORK/linux-incomplete-after"
  expect_same_tree "$WORK/linux-incomplete-before" "$WORK/linux-incomplete-after" "game folder untouched"
}

# ---------------------------------------------------------------------------
# Windows bundle, end to end (Linux checks only)
# ---------------------------------------------------------------------------
test_windows_bundle_lifecycle() { # dir
  local bundle="$1"
  local game="$WORK/windows-game"
  local manifest="$game/mods/.breeding-spike-installed"
  local old="$WORK/fixtures/windows-old-loader.txt"
  seed_game "$game"
  printf 'OLD-LOADER-windows\n' > "$game/version.dll"
  printf 'OLD-LOADER-windows\n' > "$old"

  section "windows bundle: dry-run reports the plan and changes nothing"
  snapshot "$game" "$WORK/windows-dry-before"
  run_ps "$bundle/scripts/install.ps1" -DryRun -GameDir "$game"
  expect_eq 0 "$RC" "ps dry run exits 0"
  expect_count "$LAST_OUT" '\[dry\] copy ' 3 "ps dry run plans the three copies"
  expect_match "$LAST_OUT" '\[dry\] copy version\.dll to ' "ps plans version.dll"
  expect_match "$LAST_OUT" '\[dry\] back up version\.dll to version\.dll\.[0-9]{8}-[0-9]{6}\.bak' "ps plans the backup of the existing loader"
  expect_fixed "$LAST_OUT" 'dry run complete: nothing was changed.' "ps dry run says nothing was changed"
  expect_absent "$game/mods" "ps dry run did not create mods/"
  snapshot "$game" "$WORK/windows-dry-after"
  expect_same_tree "$WORK/windows-dry-before" "$WORK/windows-dry-after" "ps dry run changed nothing at all"

  section "windows bundle: installs the payload and backs up the replaced loader"
  run_ps "$bundle/scripts/install.ps1" -GameDir "$game"
  expect_eq 0 "$RC" "ps install exits 0"
  expect_files_equal "$bundle/payload/version.dll" "$game/version.dll" "ps installed loader is the payload copy"
  expect_files_equal "$bundle/payload/chainloader.ini" "$game/chainloader.ini" "ps installed ini is the payload copy"
  expect_files_equal "$bundle/payload/BreedingSpike.dll" "$game/mods/BreedingSpike.dll" "ps installed mod DLL is the payload copy"
  expect_fixed "$LAST_OUT" 'install complete: 3 written, 0 already up to date, 1 backed up.' "ps reports 3 written and 1 backup"
  expect_content "$WORK/fixtures/decoy.txt" "$game/decoy.txt" "ps left the unrelated game file untouched"
  printf '%s' "$MANIFEST_CONTENT" > "$WORK/fixtures/windows-manifest.txt"
  expect_files_equal "$WORK/fixtures/windows-manifest.txt" "$manifest" "ps record lists exactly the installed paths"

  section "windows bundle: a re-install writes nothing but the record"
  cp -p "$manifest" "$WORK/windows-record-before"
  snapshot_excluding "$game" "$WORK/windows-re-before" '(^d .* mods$|\.breeding-spike-installed)'
  run_ps "$bundle/scripts/install.ps1" -GameDir "$game"
  expect_eq 0 "$RC" "ps re-install exits 0"
  expect_count "$LAST_OUT" 'is already up to date' 3 "ps re-install reports every file current"
  expect_fixed "$LAST_OUT" 'install complete: 0 written, 3 already up to date, 0 backed up.' "ps re-install writes nothing"
  snapshot_excluding "$game" "$WORK/windows-re-after" '(^d .* mods$|\.breeding-spike-installed)'
  expect_same_tree "$WORK/windows-re-before" "$WORK/windows-re-after" "ps re-install left the installed files untouched"
  expect_files_equal "$WORK/windows-record-before" "$manifest" "ps re-install left the record byte-identical"

  section "windows bundle: uninstall restores the backup and removes the rest"
  run_ps "$bundle/scripts/install.ps1" -Uninstall -GameDir "$game"
  expect_eq 0 "$RC" "ps uninstall exits 0"
  expect_content "$old" "$game/version.dll" "ps uninstall restored the pre-install loader from its backup"
  expect_absent "$game/chainloader.ini" "ps installed ini removed"
  expect_absent "$game/mods/BreedingSpike.dll" "ps installed mod DLL removed"
  expect_absent "$manifest" "ps install record removed by uninstall"
  expect_fixed "$LAST_OUT" 'uninstall complete: 2 removed, 1 restored from backup, 0 left in place.' "ps reports 2 removed, 1 restored, 0 left"
}

test_windows_helper_and_payload_provenance() {
  section "windows bundle: scripts/install.ps1 uses its own helper and the parent payload/"
  local bundle="$WORK/windows-payload-prov"
  local game="$WORK/windows-payload-prov-game"
  make_windows_bundle "$bundle"
  seed_game "$game"
  # A stray copy beside install.ps1 (in scripts/) and a trap helper in the
  # bundle root (the parent of scripts/). Neither may be used.
  printf 'STRAY-BESIDE-INSTALL-PS1\n' > "$bundle/scripts/version.dll"
  printf 'throw "PARENT-LOADER-RELEASE-WAS-SOURCED"\n' > "$bundle/loader-release.ps1"

  run_ps "$bundle/scripts/install.ps1" -GameDir "$game"
  expect_eq 0 "$RC" "ps install exits 0, so the helper beside install.ps1 was used"
  expect_files_equal "$bundle/payload/version.dll" "$game/version.dll" "ps loader came from the parent payload/, not the stray"
  if cmp -s "$bundle/scripts/version.dll" "$game/version.dll"; then
    fail "ps installed loader came from the stray beside install.ps1"
  else
    pass "ps installed loader is not the stray beside install.ps1"
  fi
  expect_files_equal "$bundle/payload/BreedingSpike.dll" "$game/mods/BreedingSpike.dll" "ps mod DLL came from the parent payload/"
}

test_windows_missing_helper_and_artifact() {
  section "windows bundle: a missing scripts/ helper and a missing payload/ artifact both fail loudly"
  local bundle="$WORK/windows-incomplete"
  local game="$WORK/windows-incomplete-game"
  make_windows_bundle "$bundle"
  seed_game "$game"
  snapshot "$game" "$WORK/windows-incomplete-before"

  rm -f "$bundle/scripts/loader-release.ps1"
  run_ps "$bundle/scripts/install.ps1" -DryRun -GameDir "$game"
  expect_eq 1 "$RC" "missing scripts/loader-release.ps1 fails"
  expect_fixed "$LAST_OUT" 'loader-release.ps1 is missing' "names the missing helper"

  make_windows_bundle "$bundle"
  rm -f "$bundle/payload/BreedingSpike.dll"
  run_ps "$bundle/scripts/install.ps1" -DryRun -GameDir "$game"
  expect_eq 1 "$RC" "missing payload artifact fails"
  expect_fixed "$LAST_OUT" 'the installer payload is incomplete' "says the payload is incomplete"
  expect_fixed "$LAST_OUT" "$bundle/payload/BreedingSpike.dll" "names the missing artifact under the parent payload/ folder"
  expect_exists "$bundle/payload" "the named payload folder exists"

  snapshot "$game" "$WORK/windows-incomplete-after"
  expect_same_tree "$WORK/windows-incomplete-before" "$WORK/windows-incomplete-after" "game folder untouched"
}

# ---------------------------------------------------------------------------
# .bat wrappers: the entry scripts at the bundle root prefer scripts/
# ---------------------------------------------------------------------------
test_bat_wrapper_helper_lookup() {
  section "windows bundle: the .bat wrappers prefer scripts/ and fall back beside"
  local bundle="$WORK/windows-bat"
  make_windows_bundle "$bundle"
  local bat="$bundle/install.bat"
  local unbat="$bundle/uninstall.bat"

  expect_exists "$bat" "install.bat is at the bundle root"
  expect_exists "$unbat" "uninstall.bat is at the bundle root"
  expect_absent "$bundle/install.ps1" "install.ps1 is not at the bundle root"

  local scripts_line fallback_line
  scripts_line="$(grep -nF 'scripts\install.ps1' "$bat" | head -n1 | cut -d: -f1)"
  fallback_line="$(grep -nF '%~dp0install.ps1' "$bat" | head -n1 | cut -d: -f1)"
  if [ -n "$scripts_line" ] && [ -n "$fallback_line" ] && [ "$scripts_line" -lt "$fallback_line" ]; then
    pass "install.bat tries scripts\\install.ps1 before the beside-script fallback"
  else
    fail "install.bat must prefer scripts\\install.ps1, then fall back beside (scripts=$scripts_line fallback=$fallback_line)"
  fi

  scripts_line="$(grep -nF 'scripts\install.ps1' "$unbat" | head -n1 | cut -d: -f1)"
  fallback_line="$(grep -nF '%~dp0install.ps1' "$unbat" | head -n1 | cut -d: -f1)"
  if [ -n "$scripts_line" ] && [ -n "$fallback_line" ] && [ "$scripts_line" -lt "$fallback_line" ]; then
    pass "uninstall.bat tries scripts\\install.ps1 before the beside-script fallback"
  else
    fail "uninstall.bat must prefer scripts\\install.ps1, then fall back beside (scripts=$scripts_line fallback=$fallback_line)"
  fi
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
printf 'per-platform bundle tests: temp dir %s\n' "$WORK"
printf 'per-platform bundle tests: repo %s\n' "$REPO_ROOT"

LINUX_BUNDLE="$WORK/linux-bundle"
make_linux_bundle "$LINUX_BUNDLE"
test_linux_bundle_lifecycle "$LINUX_BUNDLE"
test_linux_helper_provenance
test_linux_helper_fallback
test_linux_missing_both_helpers
test_linux_payload_provenance
test_linux_missing_artifact_names_payload

if [ -z "$PWSH" ]; then
  section "install.ps1"
  fail "pwsh not found: install nixpkgs#powershell (or set PWSH=/path/to/pwsh)"
else
  printf '  info using pwsh: %s\n' "$PWSH"
  WINDOWS_BUNDLE="$WORK/windows-bundle"
  make_windows_bundle "$WINDOWS_BUNDLE"
  test_windows_bundle_lifecycle "$WINDOWS_BUNDLE"
  test_windows_helper_and_payload_provenance
  test_windows_missing_helper_and_artifact
fi

test_bat_wrapper_helper_lookup

printf '\n============================================\n'
if [ "$FAILED" -eq 0 ]; then
  printf 'PASS: per-platform bundle tests: %d checks passed, 0 failed\n' "$PASSED"
  exit 0
fi
printf 'FAIL: per-platform bundle tests: %d passed, %d FAILED\n' "$PASSED" "$FAILED" >&2
exit 1
