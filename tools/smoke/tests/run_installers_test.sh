#!/usr/bin/env bash
# Tests for the standalone installers: installers/install.sh,
# installers/proton-registry.sh and installers/install.ps1.
#
# Everything runs inside a private temp tree. No real game install, Steam
# library, Proton/Wine prefix or HOME is read or written: the three payload
# artifacts are fakes (install.sh never inspects their contents) and HOME is
# pointed at an empty temp directory so Steam discovery finds nothing.
#
#   ./tools/smoke/tests/run_installers_test.sh
#
# The PowerShell part needs `pwsh` (nixpkgs `powershell`). It checks what Linux
# can check: the script parses, and a -DryRun against a fake game folder changes
# nothing and reports the plan. Windows-only behaviour is NOT covered; say so
# explicitly rather than pretending otherwise.
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

expect_exists() { if [ -e "$1" ]; then pass "$2"; else fail "$2: [$1] does not exist"; fi; }
expect_absent() { if [ ! -e "$1" ]; then pass "$2"; else fail "$2: [$1] should not exist"; fi; }

# Content + mtime + mode + type of everything under a directory. Used to prove a
# dry run or a repeat run changed literally nothing.
snapshot() { # dir out-file
  (
    cd "$1" || exit 1
    find . -mindepth 1 -printf '%y %m %s %T@ %P\n' | LC_ALL=C sort
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  ) > "$2"
}

# Like snapshot, but paths matching the ERE are dropped. Used where the
# installer is expected to rewrite one file (the install record) while every
# other file keeps its content and timestamp.
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mew-installers-test.XXXXXX")"
BUNDLE="$WORK/bundle"
FAKE_HOME="$WORK/home"
FAKE_GAME_PID=""

cleanup() {
  if [ -n "$FAKE_GAME_PID" ]; then
    kill "$FAKE_GAME_PID" 2>/dev/null || true
  fi
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT INT TERM

mkdir -p "$FAKE_HOME" "$BUNDLE"

# The three fake artifacts, each with distinct content so identity checks mean
# something.
write_payload_file() { # dir name
  case "$2" in
    version.dll)       printf 'FAKE-LOADER-PAYLOAD-v1\n' > "$1/$2" ;;
    chainloader.ini)   printf '[chainloader]\nmods=mods\n' > "$1/$2" ;;
    BreedingSpike.dll) printf 'FAKE-MOD-PAYLOAD-v1\n' > "$1/$2" ;;
    *) fail "unknown fixture $2" ;;
  esac
}

# Copy the real installers into a temp bundle (so SCRIPT_DIR is the temp folder)
# plus the fake payload. With no names, the complete payload is written.
make_bundle() { # dir [payload-name...]
  local dir="$1"
  shift
  local names=("$@")
  [ "${#names[@]}" -gt 0 ] || names=(version.dll chainloader.ini BreedingSpike.dll)

  mkdir -p "$dir"
  cp -p "$REPO_ROOT/installers/install.sh" "$dir/install.sh"
  cp -p "$REPO_ROOT/installers/proton-registry.sh" "$dir/proton-registry.sh"
  cp -p "$REPO_ROOT/installers/loader-release.sh" "$dir/loader-release.sh"
  cp -p "$REPO_ROOT/installers/install.ps1" "$dir/install.ps1"
  cp -p "$REPO_ROOT/installers/loader-release.ps1" "$dir/loader-release.ps1"
  chmod +x "$dir/install.sh" "$dir/proton-registry.sh"

  local name
  for name in "${names[@]}"; do write_payload_file "$dir" "$name"; done
}

# A fake game folder with things the installer must never touch.
seed_game() { # dir
  mkdir -p "$1/mod_logs"
  printf 'fake game executable\n' > "$1/Mewgenics.exe"
  printf 'a file the installer must never touch\n' > "$1/decoy.txt"
  printf 'previous loader log\n' > "$1/mod_logs/chainloader.log"
}

# Reference copies of the seed contents, for post-install comparisons.
mkdir -p "$WORK/fixtures"
printf 'a file the installer must never touch\n' > "$WORK/fixtures/decoy.txt"
printf 'previous loader log\n' > "$WORK/fixtures/chainloader.log"

# A local stand-in for an official Mewjector release whose chainloader.ini does
# NOT carry EnableEPFallback. Every installer run that is not specifically about
# the upstream resolution points MEWJECTOR_RELEASE_OVERRIDE at this folder, so
# the offline checks never touch the network and choose the bundled loader.
STANDIN_NOFIX="$WORK/standin-nofix"
mkdir -p "$STANDIN_NOFIX"
printf 'STANDIN-LOADER-NOFIX\n' > "$STANDIN_NOFIX/version.dll"
printf '[chainloader]\nmods=mods\n' > "$STANDIN_NOFIX/chainloader.ini"

# The exact line both installers end with. The loader line must sit right above
# it, and this wording must not change.
ACHIEVEMENTS_LINE='*** ACHIEVEMENTS STAY ON: nothing here passes -modpaths or enables the debug console, the only two things the game checks before it disables Steam achievements. ***'

# The loader line must be the line immediately above the achievements line.
expect_loader_above_achievements() { # out-file desc
  local file="$1" desc="$2" prev='' line found=0
  while IFS= read -r line; do
    if [ "$line" = "$ACHIEVEMENTS_LINE" ]; then
      found=$((found + 1))
      case "$prev" in
        '       loader: '*) pass "$desc" ;;
        *) fail "$desc: line above achievements was [$prev]" ;;
      esac
    fi
    prev="$line"
  done < "$file"
  if [ "$found" -ne 1 ]; then
    fail "$desc: achievements line found $found time(s), want exactly 1"
  fi
}

LAST_OUT=""
RC=0

run_installer() { # bundle args...
  local bundle="$1"
  shift
  LAST_OUT="$WORK/last-installer.out"
  if env -u MEWGENICS_DIR HOME="$FAKE_HOME" \
       MEWJECTOR_RELEASE_OVERRIDE="$STANDIN_NOFIX" \
       "$bundle/install.sh" "$@" > "$LAST_OUT" 2>&1; then
    RC=0
  else
    RC=$?
  fi
}

# Same, with a `date` shim first on PATH. Only used to force two backups into
# the same second deterministically; the shim passes every other call through.
run_installer_shim() { # bindir bundle args...
  local bindir="$1"
  local bundle="$2"
  shift 2
  LAST_OUT="$WORK/last-installer.out"
  if env -u MEWGENICS_DIR HOME="$FAKE_HOME" \
       MEWJECTOR_RELEASE_OVERRIDE="$STANDIN_NOFIX" \
       PATH="$bindir:$PATH" "$bundle/install.sh" "$@" > "$LAST_OUT" 2>&1; then
    RC=0
  else
    RC=$?
  fi
}

# ---------------------------------------------------------------------------
# install.sh
# ---------------------------------------------------------------------------
test_dry_run() {
  section "install.sh --dry-run reports the plan and changes nothing"
  local game="$WORK/dry-run-game"
  seed_game "$game"
  snapshot "$game" "$WORK/dry-before"

  run_installer "$BUNDLE" --dry-run --game-dir "$game"

  expect_eq 0 "$RC" "dry run exits 0"
  expect_count "$LAST_OUT" '\[dry\] copy ' 3 "dry run reports the three planned copies"
  expect_match "$LAST_OUT" '\[dry\] copy version\.dll to .*/version\.dll$' "plans version.dll beside the game exe"
  expect_match "$LAST_OUT" '\[dry\] copy chainloader\.ini to .*/chainloader\.ini$' "plans chainloader.ini beside the game exe"
  expect_match "$LAST_OUT" '\[dry\] copy BreedingSpike\.dll to .*/mods/BreedingSpike\.dll$' "plans the mod DLL into mods/"
  expect_match "$LAST_OUT" '\[dry\] create folder .*/mods$' "plans to create the missing mods/ folder"
  expect_fixed "$LAST_OUT" 'dry run complete: nothing was changed.' "dry run says nothing was changed"
  expect_absent "$game/mods" "dry run did not create mods/"

  snapshot "$game" "$WORK/dry-after"
  expect_same_tree "$WORK/dry-before" "$WORK/dry-after" "dry run changed nothing at all"
}

test_dry_run_with_existing_file() {
  section "install.sh --dry-run over an existing file plans the backup too"
  local game="$WORK/dry-run-existing"
  seed_game "$game"
  printf 'OLD-LOADER-v0\n' > "$game/version.dll"
  printf 'OLD-LOADER-v0\n' > "$WORK/fixtures/old-loader.txt"
  snapshot "$game" "$WORK/dry-existing-before"

  run_installer "$BUNDLE" --dry-run --game-dir "$game"

  expect_eq 0 "$RC" "dry run over an existing file exits 0"
  expect_match "$LAST_OUT" '\[dry\] back up version\.dll to version\.dll\.[0-9]{8}-[0-9]{6}\.bak' "plans a timestamped backup"
  expect_match "$LAST_OUT" '\[dry\] copy version\.dll to ' "still plans the copy"
  expect_content "$WORK/fixtures/old-loader.txt" "$game/version.dll" "existing file still has its old content"

  snapshot "$game" "$WORK/dry-existing-after"
  expect_same_tree "$WORK/dry-existing-before" "$WORK/dry-existing-after" "dry run changed nothing at all"
}

test_real_install() {
  section "install.sh installs the loader beside the exe and the mod into mods/"
  local game="$WORK/install-game"
  seed_game "$game"

  run_installer "$BUNDLE" --game-dir "$game"

  expect_eq 0 "$RC" "install exits 0"
  expect_files_equal "$BUNDLE/version.dll" "$game/version.dll" "loader placed beside the game exe"
  expect_files_equal "$BUNDLE/chainloader.ini" "$game/chainloader.ini" "loader ini placed beside the game exe"
  expect_exists "$game/mods" "mods/ created when missing"
  expect_files_equal "$BUNDLE/BreedingSpike.dll" "$game/mods/BreedingSpike.dll" "mod DLL placed in mods/"
  expect_fixed "$LAST_OUT" 'install complete: 3 written, 0 already up to date, 0 backed up.' "reports 3 written"
  expect_content "$WORK/fixtures/decoy.txt" "$game/decoy.txt" "unrelated game file untouched"
  expect_content "$WORK/fixtures/chainloader.log" "$game/mod_logs/chainloader.log" "existing mod_logs/ untouched"
  expect_fixed "$LAST_OUT" 'loader: bundled patched Mewjector - upstream override does not carry the fix yet; using the bundled patched loader' "loader line explains the bundled choice"
  expect_fixed "$LAST_OUT" "$ACHIEVEMENTS_LINE" "achievements wording is unchanged"
  expect_loader_above_achievements "$LAST_OUT" "the loader line sits immediately above the achievements line"
}

test_install_writes_record() {
  section "a successful install writes a record listing exactly the installed paths"
  local game="$WORK/record-game"
  seed_game "$game"

  run_installer "$BUNDLE" --game-dir "$game"

  expect_eq 0 "$RC" "install exits 0"
  expect_exists "$game/mods/.breeding-spike-installed" "record written inside the game folder"
  expect_fixed "$LAST_OUT" 'recorded the installed files in mods/.breeding-spike-installed' "install reports where the record went"
  printf 'version.dll\nchainloader.ini\nmods/BreedingSpike.dll\n' > "$WORK/fixtures/manifest-expected.txt"
  expect_files_equal "$WORK/fixtures/manifest-expected.txt" "$game/mods/.breeding-spike-installed" "record lists exactly the installed paths, in order"
}

test_second_run_writes_nothing() {
  section "a second install reports everything up to date and rewrites only the record"
  local game="$WORK/second-run-game"
  seed_game "$game"

  run_installer "$BUNDLE" --game-dir "$game"
  expect_eq 0 "$RC" "first install exits 0"
  cp -p "$game/mods/.breeding-spike-installed" "$WORK/second-manifest-before"
  snapshot_excluding "$game" "$WORK/second-before" '(^d .* mods$|\.breeding-spike-installed)'

  run_installer "$BUNDLE" --game-dir "$game"

  expect_eq 0 "$RC" "second install exits 0"
  expect_count "$LAST_OUT" 'is already up to date' 3 "all three files reported already up to date"
  expect_fixed "$LAST_OUT" 'install complete: 0 written, 3 already up to date, 0 backed up.' "reports 0 written"

  snapshot_excluding "$game" "$WORK/second-after" '(^d .* mods$|\.breeding-spike-installed)'
  expect_same_tree "$WORK/second-before" "$WORK/second-after" "second run left every payload file and its timestamp untouched"
  expect_files_equal "$WORK/second-manifest-before" "$game/mods/.breeding-spike-installed" "record content is byte-identical after a repeat install"
}

test_backup_of_differing_file() {
  section "replacing a differing file keeps a timestamped backup of the old content"
  local game="$WORK/backup-game"
  seed_game "$game"
  printf 'OLD-LOADER-v0\n' > "$game/version.dll"
  printf 'OLD-LOADER-v0\n' > "$WORK/fixtures/old-loader.txt"

  run_installer "$BUNDLE" --game-dir "$game"

  expect_eq 0 "$RC" "install over an existing version.dll exits 0"
  expect_files_equal "$BUNDLE/version.dll" "$game/version.dll" "new loader installed over the old one"
  expect_match "$LAST_OUT" 'backed up existing version\.dll to version\.dll\.[0-9]{8}-[0-9]{6}\.bak' "backup name reported with a timestamp"
  expect_fixed "$LAST_OUT" 'install complete: 3 written, 0 already up to date, 1 backed up.' "reports 1 backed up"

  local backups count
  backups="$(find "$game" -maxdepth 1 -name 'version.dll.*.bak' | sort)"
  count="$(printf '%s\n' "$backups" | grep -c . || true)"
  expect_eq 1 "$count" "exactly one backup created"
  expect_content "$WORK/fixtures/old-loader.txt" "$backups" "backup preserves the previous file content"
}

test_uninstall_restores_backup() {
  section "uninstall restores the backup it made and removes the rest of its files"
  local game="$WORK/uninstall-restore-game"
  seed_game "$game"
  printf 'OLD-LOADER-v0\n' > "$game/version.dll"
  printf 'OLD-LOADER-v0\n' > "$WORK/fixtures/old-loader.txt"

  run_installer "$BUNDLE" --game-dir "$game"
  expect_eq 0 "$RC" "install before uninstall exits 0"
  local backup
  backup="$(find "$game" -maxdepth 1 -name 'version.dll.*.bak' | sort | head -n 1)"
  expect_exists "$backup" "install made a backup to restore"

  run_installer "$BUNDLE" --uninstall --game-dir "$game"

  expect_eq 0 "$RC" "uninstall exits 0"
  expect_content "$WORK/fixtures/old-loader.txt" "$game/version.dll" "previous loader restored from its backup"
  expect_exists "$backup" "backup kept in place after the restore"
  expect_absent "$game/chainloader.ini" "installed ini removed (no backup existed)"
  expect_absent "$game/mods/BreedingSpike.dll" "installed mod DLL removed"
  expect_absent "$game/mods/.breeding-spike-installed" "install record removed by uninstall"
  expect_fixed "$LAST_OUT" 'uninstall complete: 2 removed, 1 restored from backup, 0 left in place.' "reports 2 removed, 1 restored, 0 left"
  expect_content "$WORK/fixtures/decoy.txt" "$game/decoy.txt" "unrelated game file untouched by uninstall"
}

test_uninstall_removes_only_installed() {
  section "uninstall removes only the files the installer put there"
  local game="$WORK/uninstall-clean-game"
  seed_game "$game"
  snapshot "$game" "$WORK/uninstall-clean-before"

  run_installer "$BUNDLE" --game-dir "$game"
  expect_eq 0 "$RC" "install exits 0"
  run_installer "$BUNDLE" --uninstall --game-dir "$game"

  expect_eq 0 "$RC" "uninstall exits 0"
  expect_fixed "$LAST_OUT" 'uninstall complete: 3 removed, 0 restored from backup, 0 left in place.' "reports 3 removed, 0 restored, 0 left"
  expect_absent "$game/version.dll" "installed loader removed"
  expect_absent "$game/chainloader.ini" "installed ini removed"
  expect_absent "$game/mods/BreedingSpike.dll" "installed mod DLL removed"
  expect_absent "$game/mods/.breeding-spike-installed" "install record removed by uninstall"
  expect_content "$WORK/fixtures/decoy.txt" "$game/decoy.txt" "unrelated game file left alone"
  expect_content "$WORK/fixtures/chainloader.log" "$game/mod_logs/chainloader.log" "existing mod_logs/ left alone"

  local stray
  stray="$(find "$game" -name '*.bak' | wc -l)"
  expect_eq 0 "$stray" "no backups created or needed"
}

test_uninstall_picks_newest_backup() {
  section "uninstall restores the newest backup by name, ignoring modification time"
  local game="$WORK/uninstall-newest-game"
  seed_game "$game"

  # A real install writes the record and places the verified payload, so the
  # uninstall is allowed to touch version.dll.
  run_installer "$BUNDLE" --game-dir "$game"
  expect_eq 0 "$RC" "install exits 0"

  # The older name carries the newer mtime, so ordering by time would restore
  # the wrong backup; this pins the name-based ordering.
  printf 'BACKUP-OLDEST\n' > "$game/version.dll.20200101-000000.bak"
  printf 'BACKUP-NEWEST\n' > "$game/version.dll.20200102-000000.bak"
  touch -d '2030-01-01 00:00:00' "$game/version.dll.20200101-000000.bak"
  touch -d '2000-01-01 00:00:00' "$game/version.dll.20200102-000000.bak"
  printf 'BACKUP-NEWEST\n' > "$WORK/fixtures/newest-backup.txt"

  run_installer "$BUNDLE" --uninstall --game-dir "$game"

  expect_eq 0 "$RC" "uninstall exits 0"
  expect_content "$WORK/fixtures/newest-backup.txt" "$game/version.dll" "newest backup restored over the current file"
}

test_uninstall_two_backups_same_second() {
  section "uninstall restores the newest of two backups from the same second"
  # README: "restores the newest backup of each". Two installs in the same
  # second yield version.dll.<stamp>.bak then version.dll.<stamp>.1.bak (the .N
  # suffix is install.sh's own collision handling), so uninstall must pick the
  # .1 one. A `date` shim pins the timestamp so the collision is deterministic.
  local bundle="$WORK/same-second-bundle"
  local game="$WORK/same-second-game"
  local fakebin="$WORK/same-second-bin"
  make_bundle "$bundle"
  seed_game "$game"
  mkdir -p "$fakebin"
  local real_date
  real_date="$(command -v date)"
  cat > "$fakebin/date" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "+%Y%m%d-%H%M%S" ]; then printf '20260101-120000\n'; else exec "$real_date" "\$@"; fi
EOF
  chmod +x "$fakebin/date"

  # Install 1: FIRST-ORIGINAL is backed up, payload v1 is installed.
  printf 'FIRST-ORIGINAL\n' > "$game/version.dll"
  run_installer_shim "$fakebin" "$bundle" --game-dir "$game"
  expect_eq 0 "$RC" "first install exits 0"

  # Install 2: the v1 payload differs from the new v2 source, so it is backed
  # up too, into the very same second as the first backup.
  printf 'FAKE-LOADER-PAYLOAD-v2\n' > "$bundle/version.dll"
  printf 'FAKE-LOADER-PAYLOAD-v1\n' > "$WORK/fixtures/intermediate-loader.txt"
  run_installer_shim "$fakebin" "$bundle" --game-dir "$game"
  expect_eq 0 "$RC" "second install exits 0"

  local backups count
  backups="$(find "$game" -maxdepth 1 -name 'version.dll.*.bak' | LC_ALL=C sort)"
  count="$(printf '%s\n' "$backups" | grep -c . || true)"
  expect_eq 2 "$count" "both backups exist (same timestamp, .N suffix)"

  run_installer_shim "$fakebin" "$bundle" --uninstall --game-dir "$game"
  expect_eq 0 "$RC" "uninstall exits 0"
  expect_content "$WORK/fixtures/intermediate-loader.txt" "$game/version.dll" "the newer (.1 suffix) backup is restored, not the older one"
}

test_uninstall_ignores_stray_backup_name() {
  section "uninstall ignores a stray <target>.old.bak and restores the real timestamped backup"
  local game="$WORK/stray-backup-game"
  seed_game "$game"

  run_installer "$BUNDLE" --game-dir "$game"
  expect_eq 0 "$RC" "install exits 0"
  # version.dll did not exist before the install, so no backup was made then:
  # the two files below are the only candidates. The stray name sorts after the
  # real timestamp, so a search that accepted it would pick it.
  printf 'STRAY-NOT-OURS\n' > "$game/version.dll.old.bak"
  printf 'STRAY-NOT-OURS\n' > "$WORK/fixtures/stray-backup.txt"
  printf 'REAL-TIMESTAMPED-BACKUP\n' > "$game/version.dll.20200102-000000.bak"
  printf 'REAL-TIMESTAMPED-BACKUP\n' > "$WORK/fixtures/real-backup.txt"

  run_installer "$BUNDLE" --uninstall --game-dir "$game"

  expect_eq 0 "$RC" "uninstall exits 0"
  expect_match "$LAST_OUT" 'restored version\.dll from version\.dll\.20200102-000000\.bak' "restores the real timestamped backup"
  expect_content "$WORK/fixtures/real-backup.txt" "$game/version.dll" "real backup content restored over the target"
  expect_content "$WORK/fixtures/stray-backup.txt" "$game/version.dll.old.bak" "stray .old.bak left untouched"
  if grep -qF 'version.dll.old.bak' "$LAST_OUT"; then
    fail "the stray .old.bak must never be treated as a backup"
  else
    pass "the stray .old.bak is never named as a backup"
  fi
}

test_uninstall_without_record() {
  section "uninstall with no record removes nothing and warns, naming what it leaves"
  local game="$WORK/no-record-game"
  seed_game "$game"
  # A foreign install: the same filenames, but no record from this script.
  mkdir -p "$game/mods"
  printf 'FOREIGN-LOADER\n' > "$game/version.dll"
  printf '[chainloader]\nmods=mods\n' > "$game/chainloader.ini"
  printf 'FOREIGN-MOD\n' > "$game/mods/BreedingSpike.dll"
  printf 'FOREIGN-LOADER\n' > "$WORK/fixtures/foreign-loader.txt"
  printf '[chainloader]\nmods=mods\n' > "$WORK/fixtures/foreign-ini.txt"
  printf 'FOREIGN-MOD\n' > "$WORK/fixtures/foreign-mod.txt"

  run_installer "$BUNDLE" --uninstall --game-dir "$game"

  expect_eq 0 "$RC" "uninstall exits 0"
  expect_fixed "$LAST_OUT" 'no record of an install by this script' "says it found no record"
  expect_fixed "$LAST_OUT" 'leaving everything as it is; nothing was removed.' "says nothing was removed"
  expect_fixed "$LAST_OUT" 'uninstall complete: 0 removed, 0 restored, 3 left in place.' "reports nothing removed"
  expect_fixed "$LAST_OUT" 'left version.dll: this script has no record of installing it' "names the loader it leaves"
  expect_fixed "$LAST_OUT" 'left chainloader.ini: this script has no record of installing it' "names the foreign chainloader.ini"
  expect_fixed "$LAST_OUT" 'left mods/BreedingSpike.dll: this script has no record of installing it' "names the mod DLL it leaves"
  expect_content "$WORK/fixtures/foreign-loader.txt" "$game/version.dll" "foreign loader survives"
  expect_content "$WORK/fixtures/foreign-ini.txt" "$game/chainloader.ini" "foreign chainloader.ini survives"
  expect_content "$WORK/fixtures/foreign-mod.txt" "$game/mods/BreedingSpike.dll" "foreign mod DLL survives"
  expect_absent "$game/mods/.breeding-spike-installed" "still no record after a no-op uninstall"
}

test_uninstall_leaves_modified_file() {
  section "uninstall leaves a file modified after install and removes the rest"
  local game="$WORK/modified-game"
  seed_game "$game"

  run_installer "$BUNDLE" --game-dir "$game"
  expect_eq 0 "$RC" "install exits 0"
  printf 'USER-EDITED-AFTER-INSTALL\n' > "$game/chainloader.ini"
  printf 'USER-EDITED-AFTER-INSTALL\n' > "$WORK/fixtures/user-edited.txt"

  run_installer "$BUNDLE" --uninstall --game-dir "$game"

  expect_eq 0 "$RC" "uninstall exits 0"
  expect_fixed "$LAST_OUT" 'left chainloader.ini: it was modified after this script installed it' "warns the modified file is left"
  expect_fixed "$LAST_OUT" 'uninstall complete: 2 removed, 0 restored from backup, 1 left in place.' "reports 2 removed, 1 left"
  expect_content "$WORK/fixtures/user-edited.txt" "$game/chainloader.ini" "modified file keeps the user's content"
  expect_absent "$game/version.dll" "the untouched recorded loader is still removed"
  expect_absent "$game/mods/BreedingSpike.dll" "the untouched recorded mod DLL is still removed"

  # A file was deliberately left behind, so the record must survive and list
  # exactly that file: the removed files are no longer its business.
  expect_exists "$game/mods/.breeding-spike-installed" "record kept because a file was left"
  printf 'chainloader.ini\n' > "$WORK/fixtures/kept-manifest-expected.txt"
  expect_files_equal "$WORK/fixtures/kept-manifest-expected.txt" "$game/mods/.breeding-spike-installed" "kept record lists exactly the file still installed"
  expect_fixed "$LAST_OUT" 'kept install record mods/.breeding-spike-installed: 1 file is still installed, so a later run can clean it up.' "says it kept the record and why"
}

test_uninstall_removes_record_once_leftover_gone() {
  section "a later uninstall removes the record once the left-behind file is gone"
  local game="$WORK/record-cleanup-game"
  seed_game "$game"

  run_installer "$BUNDLE" --game-dir "$game"
  expect_eq 0 "$RC" "install exits 0"
  # A user edit makes uninstall leave chainloader.ini behind, so the record is
  # rewritten to list only that file.
  printf 'USER-EDITED-AFTER-INSTALL\n' > "$game/chainloader.ini"

  run_installer "$BUNDLE" --uninstall --game-dir "$game"
  expect_eq 0 "$RC" "first uninstall exits 0"
  printf 'chainloader.ini\n' > "$WORK/fixtures/cleanup-manifest.txt"
  expect_files_equal "$WORK/fixtures/cleanup-manifest.txt" "$game/mods/.breeding-spike-installed" "first uninstall left a one-file record"

  # The user removes the leftover. Nothing the record listed is left, so the
  # next uninstall can at last drop the record.
  rm -f "$game/chainloader.ini"

  run_installer "$BUNDLE" --uninstall --game-dir "$game"

  expect_eq 0 "$RC" "second uninstall exits 0"
  expect_fixed "$LAST_OUT" 'uninstall complete: 0 removed, 0 restored from backup, 0 left in place.' "reports there was nothing left to do"
  expect_absent "$game/mods/.breeding-spike-installed" "record removed once everything it listed is gone"
  expect_fixed "$LAST_OUT" 'removed install record mods/.breeding-spike-installed' "says the record was removed"
  expect_absent "$game/version.dll" "loader stays gone"
  expect_absent "$game/mods/BreedingSpike.dll" "mod DLL stays gone"
}

test_refuses_while_game_running() {
  section "install.sh refuses to run while the game is running"
  local game="$WORK/game-running"
  seed_game "$game"
  snapshot "$game" "$WORK/running-before"

  # A fake process whose name matches exactly what the installer greps for.
  mkdir -p "$WORK/fake-bin"
  cp "$(command -v bash)" "$WORK/fake-bin/Mewgenics.exe"
  "$WORK/fake-bin/Mewgenics.exe" -c 'while :; do sleep 0.2; done' &
  FAKE_GAME_PID=$!

  local i detected=0
  for i in $(seq 1 50); do
    if pgrep -x 'Mewgenics.exe' >/dev/null 2>&1; then detected=1; break; fi
    if ! kill -0 "$FAKE_GAME_PID" 2>/dev/null; then break; fi
    sleep 0.1
  done
  if [ "$detected" != 1 ]; then
    fail "could not start a fake Mewgenics.exe process visible to pgrep; guard not tested"
    return
  fi
  expect_eq 1 "$detected" "fake Mewgenics.exe process is visible to pgrep"

  run_installer "$BUNDLE" --game-dir "$game"
  expect_eq 1 "$RC" "install refuses while the game runs"
  expect_fixed "$LAST_OUT" 'Mewgenics is running. Close the game, then run this again.' "explains why it refused"

  run_installer "$BUNDLE" --dry-run --game-dir "$game"
  expect_eq 1 "$RC" "dry run also refuses while the game runs"

  snapshot "$game" "$WORK/running-after"
  expect_same_tree "$WORK/running-before" "$WORK/running-after" "nothing installed while the game ran"

  kill "$FAKE_GAME_PID" 2>/dev/null || true
  wait "$FAKE_GAME_PID" 2>/dev/null || true
  FAKE_GAME_PID=""
}

test_incomplete_payload() {
  section "an incomplete payload fails clearly before touching the game folder"
  local bundle="$WORK/bundle-incomplete"
  local game="$WORK/incomplete-game"
  make_bundle "$bundle" version.dll chainloader.ini   # BreedingSpike.dll deliberately absent
  seed_game "$game"
  snapshot "$game" "$WORK/incomplete-before"

  run_installer "$bundle" --game-dir "$game"

  expect_eq 1 "$RC" "install fails when an artifact is missing"
  expect_fixed "$LAST_OUT" 'the installer payload is incomplete' "says the payload is incomplete"
  expect_fixed "$LAST_OUT" "$bundle/BreedingSpike.dll" "names the missing artifact"
  expect_fixed "$LAST_OUT" 'unpack the whole release folder before running this' "tells the user what to do"
  expect_absent "$game/version.dll" "nothing copied"
  expect_absent "$game/mods/.breeding-spike-installed" "no install record written when the payload is incomplete"

  snapshot "$game" "$WORK/incomplete-after"
  expect_same_tree "$WORK/incomplete-before" "$WORK/incomplete-after" "game folder untouched"
}

test_missing_helper_and_bad_args() {
  section "install.sh rejects a missing helper and bad arguments"
  local game="$WORK/bad-args-game"
  seed_game "$game"

  local bundle="$WORK/bundle-nohelper"
  mkdir -p "$bundle"
  cp -p "$REPO_ROOT/installers/install.sh" "$bundle/install.sh"
  chmod +x "$bundle/install.sh"
  write_payload_file "$bundle" version.dll
  write_payload_file "$bundle" chainloader.ini
  write_payload_file "$bundle" BreedingSpike.dll

  run_installer "$bundle" --game-dir "$game"
  expect_eq 1 "$RC" "missing proton-registry.sh fails"
  expect_fixed "$LAST_OUT" 'proton-registry.sh is missing' "names the missing helper"

  # loader-release.sh is the other helper install.sh sources; it must fail
  # loudly with its own name too, or an incomplete bundle would install the
  # wrong loader (or crash) instead of saying what is wrong.
  local bundle_noloader="$WORK/bundle-noloader"
  mkdir -p "$bundle_noloader"
  cp -p "$REPO_ROOT/installers/install.sh" "$bundle_noloader/install.sh"
  cp -p "$REPO_ROOT/installers/proton-registry.sh" "$bundle_noloader/proton-registry.sh"
  chmod +x "$bundle_noloader/install.sh"
  write_payload_file "$bundle_noloader" version.dll
  write_payload_file "$bundle_noloader" chainloader.ini
  write_payload_file "$bundle_noloader" BreedingSpike.dll
  run_installer "$bundle_noloader" --game-dir "$game"
  expect_eq 1 "$RC" "missing loader-release.sh fails"
  expect_fixed "$LAST_OUT" 'loader-release.sh is missing' "names the missing loader helper"

  run_installer "$BUNDLE" --bogus
  expect_eq 1 "$RC" "unknown argument fails"
  expect_fixed "$LAST_OUT" 'unknown argument: --bogus' "names the unknown argument"

  run_installer "$BUNDLE" --game-dir
  expect_eq 1 "$RC" "--game-dir without a value fails"
  expect_fixed "$LAST_OUT" '--game-dir needs a folder' "explains the missing value"

  run_installer "$BUNDLE" --game-dir "$WORK/does-not-exist"
  expect_eq 1 "$RC" "non-existent game folder fails"
  expect_fixed "$LAST_OUT" 'game folder does not exist' "explains the missing folder"
}

# ---------------------------------------------------------------------------
# proton-registry.sh
# ---------------------------------------------------------------------------
# shellcheck source=../../../installers/proton-registry.sh
. "$REPO_ROOT/installers/proton-registry.sh"

run_reg() { # timestamp input-file output-file
  if prefix_override_reg "$1" < "$2" > "$3"; then
    RC=0
  else
    RC=$?
  fi
}

test_proton_registry() {
  section "proton-registry.sh adds the AppDefaults override when absent"

  cat > "$WORK/reg-base.reg" <<'EOF'
WINE REGISTRY Version 2
;; All keys relative to \\User\\S-1-5-21-0-0-0-1000

[Software\\Wine\\DllOverrides] 1700000000
"winemenubuilder.exe"=""

[Software\\Wine\\AppDefaults\\Other.exe\\DllOverrides] 1700000001
"version"="builtin"
EOF

  run_reg 1700000002 "$WORK/reg-base.reg" "$WORK/reg-added.reg"
  expect_eq 0 "$RC" "helper exits 0"
  expect_fixed "$WORK/reg-added.reg" '[Software\\Wine\\AppDefaults\\Mewgenics.exe\\DllOverrides] 1700000002' "Mewgenics override section added"
  expect_fixed "$WORK/reg-added.reg" '"version"="native,builtin"' "version override is native,builtin"
  expect_fixed "$WORK/reg-added.reg" '"winemenubuilder.exe"=""' "unrelated global override preserved"
  expect_fixed "$WORK/reg-added.reg" 'AppDefaults\\Other.exe\\DllOverrides' "another app's override preserved"

  run_reg 1700000002 "$WORK/reg-added.reg" "$WORK/reg-added-2.reg"
  expect_eq 0 "$RC" "second run exits 0"
  expect_files_equal "$WORK/reg-added.reg" "$WORK/reg-added-2.reg" "running twice is byte-identical (idempotent)"
  expect_count "$WORK/reg-added-2.reg" 'AppDefaults\\\\Mewgenics\.exe\\\\DllOverrides' 1 "no duplicate Mewgenics section"
}

test_proton_registry_replaces_wrong_value() {
  section "proton-registry.sh replaces a wrong value in an existing section"

  cat > "$WORK/reg-wrong.reg" <<'EOF'
WINE REGISTRY Version 2

[Software\\Wine\\AppDefaults\\Mewgenics.exe\\DllOverrides] 1600000000
"version"="builtin"
"other"="keep-me"

[Software\\Wine\\DllOverrides] 1600000001
"winemenubuilder.exe"=""
EOF

  run_reg 1700000002 "$WORK/reg-wrong.reg" "$WORK/reg-fixed.reg"
  expect_eq 0 "$RC" "helper exits 0"
  expect_fixed "$WORK/reg-fixed.reg" '"version"="native,builtin"' "wrong value replaced"
  if grep -qF '"version"="builtin"' "$WORK/reg-fixed.reg"; then
    fail "the wrong value is still present"
  else
    pass "the wrong value is gone"
  fi
  expect_fixed "$WORK/reg-fixed.reg" '"other"="keep-me"' "other keys in the section preserved"
  expect_count "$WORK/reg-fixed.reg" 'AppDefaults\\\\Mewgenics\.exe\\\\DllOverrides' 1 "section not duplicated"

  run_reg 1700000002 "$WORK/reg-fixed.reg" "$WORK/reg-fixed-2.reg"
  expect_files_equal "$WORK/reg-fixed.reg" "$WORK/reg-fixed-2.reg" "running twice is byte-identical (idempotent)"
}

# ---------------------------------------------------------------------------
# install.ps1 (Linux checks only)
# ---------------------------------------------------------------------------
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
  # NixOS: the package is in the store even when it is not on PATH. Try the
  # nixpkgs flake too, in case the config does not carry it.
  for candidate in /nix/store/*-powershell-[0-9]*/bin/pwsh; do
    if [ -x "$candidate" ]; then
      PWSH="$candidate"
      return
    fi
  done
  PWSH=""
}
find_pwsh

run_pwsh() { # args...
  LAST_OUT="$WORK/last-pwsh.out"
  if env -u MEWGENICS_DIR HOME="$FAKE_HOME" \
       MEWJECTOR_RELEASE_OVERRIDE="$STANDIN_NOFIX" \
       "$PWSH" -NoProfile -NonInteractive "$@" > "$LAST_OUT" 2>&1; then
    RC=0
  else
    RC=$?
  fi
}

test_ps1() {
  section "install.ps1 under pwsh on Linux"
  printf '  NOTE: PowerShell checks run on Linux under pwsh. The real install,\n'
  printf '  NOTE: backup selection and uninstall paths are exercised here; registry\n'
  printf '  NOTE: writes, Steam discovery and the Get-Process game guard are NOT\n'
  printf '  NOTE: covered, because they need a real Windows session.\n'

  if [ -z "$PWSH" ]; then
    fail "pwsh not found: install nixpkgs#powershell (or set PWSH=/path/to/pwsh)"
    return
  fi
  printf '  info using pwsh: %s\n' "$PWSH"

  local bundle="$WORK/ps-bundle"
  local game="$WORK/ps-game"
  make_bundle "$bundle"
  seed_game "$game"

  # 1. It must at least parse as PowerShell.
  local parse_cmd
  parse_cmd="\$errors = \$null; [System.Management.Automation.Language.Parser]::ParseFile('$bundle/install.ps1', [ref]\$null, [ref]\$errors) | Out-Null; if (\$errors.Count -gt 0) { \$errors | ForEach-Object { Write-Output \$_.Message }; exit 1 }; Write-Output 'parse-ok: no syntax errors'"
  run_pwsh -Command "$parse_cmd"
  expect_eq 0 "$RC" "install.ps1 parses without syntax errors"
  expect_fixed "$LAST_OUT" 'parse-ok: no syntax errors' "parser reports a clean file"

  # 2. A dry run against the fake game folder reports the plan and writes nothing.
  snapshot "$game" "$WORK/ps-before"
  run_pwsh -File "$bundle/install.ps1" -DryRun -GameDir "$game"
  expect_eq 0 "$RC" "install.ps1 -DryRun exits 0"
  expect_count "$LAST_OUT" '\[dry\] copy ' 3 "dry run reports the three planned copies"
  expect_match "$LAST_OUT" '\[dry\] copy version\.dll to ' "plans version.dll"
  expect_match "$LAST_OUT" '\[dry\] copy chainloader\.ini to ' "plans chainloader.ini"
  expect_match "$LAST_OUT" '\[dry\] copy BreedingSpike\.dll to .*BreedingSpike\.dll' "plans the mod DLL"
  expect_fixed "$LAST_OUT" 'dry run complete: nothing was changed.' "dry run says nothing was changed"

  snapshot "$game" "$WORK/ps-after"
  expect_same_tree "$WORK/ps-before" "$WORK/ps-after" "install.ps1 dry run changed nothing at all"
  expect_absent "$game/mods" "install.ps1 dry run did not create mods/"

  # 3. Same payload guard as the shell installer.
  rm -f "$bundle/BreedingSpike.dll"
  run_pwsh -File "$bundle/install.ps1" -DryRun -GameDir "$game"
  expect_eq 1 "$RC" "install.ps1 fails when an artifact is missing"
  expect_fixed "$LAST_OUT" 'the installer payload is incomplete' "install.ps1 says the payload is incomplete"

  # 3b. install.ps1 dot-sources loader-release.ps1; a bundle without it must
  # fail loudly rather than silently skip the loader resolution.
  local no_loader_bundle="$WORK/ps-no-loader-bundle"
  mkdir -p "$no_loader_bundle"
  cp -p "$REPO_ROOT/installers/install.ps1" "$no_loader_bundle/install.ps1"
  write_payload_file "$no_loader_bundle" version.dll
  write_payload_file "$no_loader_bundle" chainloader.ini
  write_payload_file "$no_loader_bundle" BreedingSpike.dll
  run_pwsh -File "$no_loader_bundle/install.ps1" -DryRun -GameDir "$game"
  expect_eq 1 "$RC" "install.ps1 missing loader-release.ps1 fails"
  expect_fixed "$LAST_OUT" 'loader-release.ps1 is missing' "install.ps1 names the missing loader helper"

  # 4. A non-existent game folder is refused.
  run_pwsh -File "$bundle/install.ps1" -DryRun -GameDir "$WORK/ps-does-not-exist"
  expect_eq 1 "$RC" "install.ps1 fails on a non-existent game folder"
  expect_fixed "$LAST_OUT" 'does not exist' "install.ps1 explains the missing folder"

  # 5. A real install writes the same record install.sh does and lists the
  # same three paths, so the two installers stay interchangeable.
  local real_bundle="$WORK/ps-real-bundle"
  local real_game="$WORK/ps-real-game"
  make_bundle "$real_bundle"
  seed_game "$real_game"
  run_pwsh -File "$real_bundle/install.ps1" -GameDir "$real_game"
  expect_eq 0 "$RC" "install.ps1 real install exits 0"
  expect_files_equal "$real_bundle/version.dll" "$real_game/version.dll" "install.ps1 placed the loader"
  expect_files_equal "$real_bundle/chainloader.ini" "$real_game/chainloader.ini" "install.ps1 placed the ini"
  expect_files_equal "$real_bundle/BreedingSpike.dll" "$real_game/mods/BreedingSpike.dll" "install.ps1 placed the mod DLL"
  expect_exists "$real_game/mods/.breeding-spike-installed" "install.ps1 wrote the install record"
  printf 'version.dll\nchainloader.ini\nmods/BreedingSpike.dll\n' > "$WORK/fixtures/ps-manifest-expected.txt"
  expect_files_equal "$WORK/fixtures/ps-manifest-expected.txt" "$real_game/mods/.breeding-spike-installed" "install.ps1 record lists exactly the installed paths"

  # 6. Uninstall restores the newest backup by the stamp in its name. The two
  # copies get mtimes that contradict their names, so ordering by modification
  # time would restore the wrong file.
  printf 'BACKUP-OLDEST' > "$real_game/version.dll.20200101-000000.bak"
  printf 'BACKUP-NEWEST' > "$real_game/version.dll.20200102-000000.bak"
  # A stray name that matches the glob but not the installer's backup pattern.
  printf 'PS-STRAY-NOT-OURS' > "$real_game/version.dll.old.bak"
  printf 'PS-STRAY-NOT-OURS' > "$WORK/fixtures/ps-stray-backup.txt"
  touch -d '2030-01-01 00:00:00' "$real_game/version.dll.20200101-000000.bak"
  touch -d '2000-01-01 00:00:00' "$real_game/version.dll.20200102-000000.bak"
  printf 'BACKUP-NEWEST' > "$WORK/fixtures/ps-newest-backup.txt"

  run_pwsh -File "$real_bundle/install.ps1" -Uninstall -GameDir "$real_game"
  expect_eq 0 "$RC" "install.ps1 uninstall exits 0"
  expect_content "$WORK/fixtures/ps-newest-backup.txt" "$real_game/version.dll" "install.ps1 restored the newest backup by name, not modification time"
  expect_content "$WORK/fixtures/ps-stray-backup.txt" "$real_game/version.dll.old.bak" "install.ps1 left the stray .old.bak alone"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
printf 'installer tests: temp dir %s\n' "$WORK"
printf 'installer tests: repo %s\n' "$REPO_ROOT"

make_bundle "$BUNDLE"

test_dry_run
test_dry_run_with_existing_file
test_real_install
test_install_writes_record
test_second_run_writes_nothing
test_backup_of_differing_file
test_uninstall_restores_backup
test_uninstall_removes_only_installed
test_uninstall_picks_newest_backup
test_uninstall_two_backups_same_second
test_uninstall_without_record
test_uninstall_leaves_modified_file
test_uninstall_removes_record_once_leftover_gone
test_uninstall_ignores_stray_backup_name
test_refuses_while_game_running
test_incomplete_payload
test_missing_helper_and_bad_args
test_proton_registry
test_proton_registry_replaces_wrong_value
test_ps1

printf '\n============================================\n'
if [ "$FAILED" -eq 0 ]; then
  printf 'PASS: installer tests: %d checks passed, 0 failed\n' "$PASSED"
  exit 0
fi
printf 'FAIL: installer tests: %d passed, %d FAILED\n' "$PASSED" "$FAILED" >&2
exit 1
