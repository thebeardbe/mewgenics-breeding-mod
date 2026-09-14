#!/usr/bin/env bash
# Tests for the loader-resolution step shared by install.sh and install.ps1:
# installers/loader-release.sh and installers/loader-release.ps1.
#
# The official-upstream check is exercised entirely offline through
# MEWJECTOR_RELEASE_OVERRIDE stand-ins (a directory, an ini file and a metadata
# file). Every installer run in this file either has an override set or a
# stubbed download tool first on PATH, so none of these checks can reach the
# network.
#
#   ./tools/smoke/tests/run_loader_release_test.sh
#
# The PowerShell half needs pwsh; when it is absent that half fails loudly
# rather than passing quietly.
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
    diff -u "$1" "$2" | head -30 >&2 || true
  fi
}

# The exact achievements line both installers print. Comparing it byte for byte
# is what "the wording is unchanged" means here.
ACHIEVEMENTS_LINE='*** ACHIEVEMENTS STAY ON: nothing here passes -modpaths or enables the debug console, the only two things the game checks before it disables Steam achievements. ***'

# The loader report is the loader line plus an optional provenance block (the
# source: line, and for a downloaded loader a sha256: line). The achievements
# line must come right after that block, and the loader line right before it.
# With a third argument, the loader line must match it exactly.
expect_loader_above_achievements() { # out-file desc [exact-loader-line]
  local file="$1" desc="$2" want="${3:-}"
  local -a lines=()
  local line found=0 i j
  while IFS= read -r line; do lines+=("$line"); done < "$file"
  for ((i = 0; i < ${#lines[@]}; i++)); do
    if [ "${lines[$i]}" = "$ACHIEVEMENTS_LINE" ]; then
      found=$((found + 1))
      j=$((i - 1))
      while [ "$j" -ge 0 ] && { [[ "${lines[$j]}" == '       source: '* ]] || [[ "${lines[$j]}" == '       sha256: '* ]]; }; do
        j=$((j - 1))
      done
      case "${lines[$j]}" in
        '       loader: '*)
          if [ -n "$want" ] && [ "${lines[$j]}" != "       loader: $want" ]; then
            fail "$desc: loader line was [${lines[$j]}], want [loader: $want]"
          else
            pass "$desc"
          fi
          ;;
        *) fail "$desc: no loader line above the achievements line (saw [${lines[$j]}], achievements line $i)" ;;
      esac
    fi
  done
  if [ "$found" -ne 1 ]; then
    fail "$desc: achievements line found $found time(s), want exactly 1"
  fi
}

# The provenance block must be the two lines directly under the loader line:
# the source line, then the sha256 line for the installed version.dll. The hash
# is compared case-insensitively: Windows' Get-FileHash returns upper case and
# sha256sum returns lower, but they are the same digest.
expect_provenance_block() { # out-file source-literal hash-literal desc
  local file="$1" source_text="$2" hash="$3" desc="$4"
  local -a lines=()
  local line found=0 i
  while IFS= read -r line; do lines+=("$line"); done < "$file"
  shopt -s nocasematch
  for ((i = 0; i + 2 < ${#lines[@]}; i++)); do
    if [[ "${lines[$i]}" == '       loader: '* ]] \
       && [[ "${lines[$((i + 1))]}" == "       source: $source_text" ]] \
       && [[ "${lines[$((i + 2))]}" == "       sha256: $hash  version.dll" ]]; then
      found=1
    fi
  done
  shopt -u nocasematch
  if [ "$found" -eq 1 ]; then
    pass "$desc"
  else
    fail "$desc: loader/source/sha256 block not found in $(basename "$file")"
  fi
}

# A loader taken from MEWJECTOR_RELEASE_OVERRIDE is deliberately unverified and
# must say so, naming the override value.
expect_override_provenance() { # out-file override-path desc
  expect_fixed "$1" "source: MEWJECTOR_RELEASE_OVERRIDE=$2 (trusted developer/mirror hook; not verified)" "$3"
}

expect_no_sha256() { # file desc
  if grep -qF 'sha256:' "$1" 2>/dev/null; then
    fail "$2: a deliberately unverified loader must not print a hash"
  else
    pass "$2"
  fi
}

# ---------------------------------------------------------------------------
# fixtures and runners
# ---------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mew-loader-test.XXXXXX")"
BUNDLE="$WORK/bundle"
FAKE_HOME="$WORK/home"
NOFIX="$WORK/standin-nofix"
FIXED="$WORK/standin-fixed"
NETBIN="$WORK/netbin"
NETLOG="$WORK/net.log"
DLBIN="$WORK/dlbin"
DLDIR="$WORK/dlfiles"
DL_LOG="$WORK/dl.log"

cleanup() {
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT INT TERM

mkdir -p "$BUNDLE" "$FAKE_HOME" "$NOFIX" "$FIXED" "$NETBIN" "$DLBIN" "$DLDIR"

# The three fake bundle artifacts, each with distinct content so identity
# checks mean something.
write_payload_file() { # dir name
  case "$2" in
    version.dll)       printf 'BUNDLE-LOADER-PAYLOAD\n' > "$1/$2" ;;
    chainloader.ini)   printf '[chainloader]\nmods=mods\n' > "$1/$2" ;;
    BreedingSpike.dll) printf 'BUNDLE-MOD-PAYLOAD\n' > "$1/$2" ;;
    *) fail "unknown fixture $2" ;;
  esac
}

# A complete bundle: the two installers, both loader helpers, and the payload.
# The real installers fail when a helper is missing, so every bundle here
# carries all of them.
make_bundle() { # dir
  local dir="$1"
  mkdir -p "$dir"
  cp -p "$REPO_ROOT/installers/install.sh" "$dir/install.sh"
  cp -p "$REPO_ROOT/installers/proton-registry.sh" "$dir/proton-registry.sh"
  cp -p "$REPO_ROOT/installers/loader-release.sh" "$dir/loader-release.sh"
  cp -p "$REPO_ROOT/installers/install.ps1" "$dir/install.ps1"
  cp -p "$REPO_ROOT/installers/loader-release.ps1" "$dir/loader-release.ps1"
  chmod +x "$dir/install.sh" "$dir/proton-registry.sh"
  write_payload_file "$dir" version.dll
  write_payload_file "$dir" chainloader.ini
  write_payload_file "$dir" BreedingSpike.dll
}

# A stand-in for an unpacked official release. "fixed" carries the
# EnableEPFallback key our patch adds; "nofix" is the unpatched layout.
make_standin() { # dir kind(fixed|nofix)
  local dir="$1" kind="$2"
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

# A prepared official release archive plus the API answers that point at it (and
# at a non-official URL), so the installer can be driven through its real
# download path with curl stubbed out. The zip holds version.dll beside a
# chainloader.ini carrying EnableEPFallback, the key that makes the installer
# prefer the release over the bundle.
OFFICIAL_ZIP_URL="https://github.com/githubuser508/mewjector/releases/download/v9.9.9/mewjector-v9.9.9.zip"
RELEASE_DLL="$DLDIR/release-version.dll"
RELEASE_INI="$DLDIR/release-chainloader.ini"
HAVE_DOWNLOAD_FIXTURE=0

make_download_fixture() {
  local python="${PYTHON_BIN:-python3}"
  if ! command -v "$python" >/dev/null 2>&1; then
    return
  fi
  printf 'DOWNLOADED-LOADER-PAYLOAD\n' > "$RELEASE_DLL"
  printf '[Chainloader]\nmods=mods\nEnableEPFallback=1\n' > "$RELEASE_INI"
  "$python" - "$DLDIR/official.zip" "$RELEASE_DLL" "$RELEASE_INI" <<'PY'
import sys, zipfile

dest, dll, ini = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(dest, "w") as archive:
    archive.write(dll, "release/version.dll")
    archive.write(ini, "release/chainloader.ini")
PY
  printf '{"tag_name":"v9.9.9","assets":[{"name":"mewjector-v9.9.9.zip","browser_download_url":"%s"}]}\n' \
    "$OFFICIAL_ZIP_URL" > "$DLDIR/api-official.json"
  printf '{"tag_name":"v9.9.9","assets":[{"name":"mewjector-v9.9.9.zip","browser_download_url":"https://evil.example.com/mewjector-v9.9.9.zip"}]}\n' \
    > "$DLDIR/api-evil.json"
  HAVE_DOWNLOAD_FIXTURE=1
}

# An offline stand-in for curl. An api.github.com URL returns the prepared API
# JSON; any other URL copies the prepared release zip to -o. Nothing here can
# reach a network, so the download checks cannot pass for the wrong reason.
cat > "$DLBIN/curl" <<'EOF'
#!/bin/sh
log="${DL_LOG:-/dev/null}"
if [ -n "$log" ]; then printf 'curl %s\n' "$*" >> "$log"; fi
out=""
url=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out="$arg"; fi
  case "$arg" in
    https://*|http://*) url="$arg" ;;
  esac
  prev="$arg"
done
case "$url" in
  *api.github.com*) cat "${DL_API_JSON:?missing DL_API_JSON}" ;;
  *) if [ -n "$out" ]; then cp "${DL_ZIP:?missing DL_ZIP}" "$out"; else cat "${DL_ZIP:?missing DL_ZIP}"; fi ;;
esac
EOF
chmod +x "$DLBIN/curl"
cat > "$DLBIN/wget" <<'EOF'
#!/bin/sh
echo "wget must not be reached: the curl stand-in is first on PATH" >&2
exit 1
EOF
chmod +x "$DLBIN/wget"

# A PowerShell harness that drives the real loader-release.ps1 with only the two
# network cmdlets stubbed. Everything else (the URL check, the zip unpack, the
# EnableEPFallback test, the provenance lines) is the code under test.
PS_HARNESS="$WORK/ps_download_harness.ps1"
cat > "$PS_HARNESS" <<'PS'
param(
    [Parameter(Mandatory)][string]$LoaderScript,
    [Parameter(Mandatory)][string]$WorkDir,
    [Parameter(Mandatory)][string]$ReleaseZip,
    [Parameter(Mandatory)][string]$Mode,
    [Parameter(Mandatory)][string]$MarkerFile
)

$ErrorActionPreference = 'Stop'

# The helpers install.ps1 defines; the harness prints them with the installer's
# own prefix so the test can match the report lines.
function Write-Info { param([string]$Message) Write-Output "       $Message" }
function Write-Warn { param([string]$Message) Write-Output "  warn $Message" }

. $LoaderScript

# Offline stand-ins for the two network cmdlets. Function lookup beats a cmdlet
# of the same name, so Get-LoaderFromUpstream calls these and never the network.
function Invoke-RestMethod {
    param($Uri, $Headers, $TimeoutSec)
    $download = if ($Mode -eq 'evil') {
        'https://evil.example.com/mewjector-v9.9.9.zip'
    } else {
        'https://github.com/githubuser508/mewjector/releases/download/v9.9.9/mewjector-v9.9.9.zip'
    }
    return [pscustomobject]@{
        tag_name = 'v9.9.9'
        assets = @([pscustomobject]@{
            name = 'mewjector-v9.9.9.zip'
            browser_download_url = $download
        })
    }
}
function Invoke-WebRequest {
    param($Uri, $Headers, $OutFile, $TimeoutSec)
    Set-Content -LiteralPath $MarkerFile -Value 'downloaded'
    Copy-Item -LiteralPath $ReleaseZip -Destination $OutFile -Force
}

$BundledLoader = $false
$DryRun = $false
$Script:SourceDir = $WorkDir
Select-Loader
Write-Output "KIND=$($Script:LoaderKind)"
Write-Output "REASON=$($Script:LoaderReason)"
Write-Output "ORIGIN=$($Script:LoaderOrigin)"
Write-Output "URL=$($Script:LoaderUrl)"
Write-Info "loader: $(Get-LoaderSummary)"
if ($Script:LoaderKind -eq 'upstream') {
    $installed = Join-Path $WorkDir 'installed-version.dll'
    Copy-Item -LiteralPath (Join-Path $Script:LoaderDir 'version.dll') -Destination $installed -Force
    Show-LoaderProvenance -Installed $installed
}
Remove-LoaderScratch
PS

new_game() { # tag -> prints a fresh game folder
  local dir="$WORK/game-$1"
  rm -rf "$dir"
  seed_game "$dir"
  printf '%s\n' "$dir"
}

# A download tool that always fails and records that it was called. It is only
# ever put first on PATH for the "no network" checks, so those checks cannot
# silently reach GitHub and pass for the wrong reason. Both curl and wget are
# stubbed: loader_http_get prefers curl but falls back to wget, and an
# environment with only wget must stay offline too.
cat > "$NETBIN/curl" <<EOF
#!/bin/sh
echo "INVOKED curl \$*" >> "$NETLOG"
exit 1
EOF
cat > "$NETBIN/wget" <<EOF
#!/bin/sh
echo "INVOKED wget \$*" >> "$NETLOG"
exit 1
EOF
chmod +x "$NETBIN/curl" "$NETBIN/wget"

LAST_OUT=""
RC=0
SH_OVERRIDE="$NOFIX"
SH_NETBIN=""
SH_CWD=""
PS_OVERRIDE="$NOFIX"
PS_CWD=""

run_sh() { # bundle args...
  local bundle="$1"
  shift
  LAST_OUT="$WORK/last-sh.out"
  local -a envargs=(env -u MEWGENICS_DIR -u MEWJECTOR_RELEASE_OVERRIDE HOME="$FAKE_HOME")
  [ -n "$SH_OVERRIDE" ] && envargs+=("MEWJECTOR_RELEASE_OVERRIDE=$SH_OVERRIDE")
  [ -n "$SH_NETBIN" ] && envargs+=("PATH=$SH_NETBIN:$PATH")
  if ( cd "${SH_CWD:-$PWD}" && "${envargs[@]}" "$bundle/install.sh" "$@" > "$LAST_OUT" 2>&1 ); then
    RC=0
  else
    RC=$?
  fi
}

run_ps() { # args...
  LAST_OUT="$WORK/last-ps.out"
  local -a envargs=(env -u MEWGENICS_DIR -u MEWJECTOR_RELEASE_OVERRIDE HOME="$FAKE_HOME")
  [ -n "$PS_OVERRIDE" ] && envargs+=("MEWJECTOR_RELEASE_OVERRIDE=$PS_OVERRIDE")
  if ( cd "${PS_CWD:-$PWD}" && "${envargs[@]}" "$PWSH" -NoProfile -NonInteractive "$@" > "$LAST_OUT" 2>&1 ); then
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
# install.sh
# ---------------------------------------------------------------------------
test_sh_upstream_with_fix() {
  section "install.sh: an upstream stand-in carrying EnableEPFallback is used byte for byte"
  local game
  game="$(new_game upstream-fix)"
  SH_OVERRIDE="$FIXED"; SH_NETBIN=""

  run_sh "$BUNDLE" --game-dir "$game"

  expect_eq 0 "$RC" "install exits 0"
  expect_files_equal "$FIXED/version.dll" "$game/version.dll" "installed version.dll matches the upstream stand-in byte for byte"
  expect_files_equal "$FIXED/chainloader.ini" "$game/chainloader.ini" "installed chainloader.ini matches the upstream stand-in byte for byte"
  expect_fixed "$LAST_OUT" 'loader: upstream Mewjector override - it carries the EnableEPFallback fix' "loader line says upstream carries the fix"
  expect_fixed "$LAST_OUT" "$ACHIEVEMENTS_LINE" "achievements wording is unchanged"
  expect_loader_above_achievements "$LAST_OUT" "the loader line sits immediately above the achievements line"
}

test_sh_bundled_without_fix() {
  section "install.sh: an upstream stand-in without the key falls back to the bundled patched loader"
  local game
  game="$(new_game nofix)"
  SH_OVERRIDE="$NOFIX"; SH_NETBIN=""

  run_sh "$BUNDLE" --game-dir "$game"

  expect_eq 0 "$RC" "install exits 0"
  expect_files_equal "$BUNDLE/version.dll" "$game/version.dll" "installed version.dll matches the bundled patched loader"
  expect_files_equal "$BUNDLE/chainloader.ini" "$game/chainloader.ini" "installed chainloader.ini matches the bundled patched loader"
  expect_fixed "$LAST_OUT" 'upstream override does not carry the fix yet; using the bundled patched loader' "reason says upstream does not carry the fix yet"
  expect_loader_above_achievements "$LAST_OUT" "the loader line sits immediately above the achievements line"
}

test_sh_no_network() {
  section "install.sh: a failed upstream check falls back to the bundled loader, touching no network"
  local game
  game="$(new_game no-network)"
  SH_OVERRIDE=""; SH_NETBIN="$NETBIN"
  rm -f "$NETLOG"

  run_sh "$BUNDLE" --game-dir "$game"

  expect_eq 0 "$RC" "install exits 0"
  expect_exists "$NETLOG" "the stubbed download tool was the one consulted (it can never reach the real network)"
  expect_fixed "$LAST_OUT" 'could not check upstream (could not reach the Mewjector releases API)' "reason says the check could not reach upstream"
  expect_files_equal "$BUNDLE/version.dll" "$game/version.dll" "installed version.dll matches the bundled patched loader"
  expect_loader_above_achievements "$LAST_OUT" "the loader line sits immediately above the achievements line"
}

test_sh_force_flag() {
  section "install.sh: --bundled-loader forces the bundled loader even when upstream carries the fix"
  local game
  game="$(new_game force)"
  SH_OVERRIDE="$FIXED"; SH_NETBIN=""

  run_sh "$BUNDLE" --bundled-loader --game-dir "$game"

  expect_eq 0 "$RC" "install exits 0"
  expect_files_equal "$BUNDLE/version.dll" "$game/version.dll" "installed version.dll is the bundled one, not the upstream stand-in"
  expect_files_equal "$BUNDLE/chainloader.ini" "$game/chainloader.ini" "installed chainloader.ini is the bundled one"
  expect_fixed "$LAST_OUT" 'loader: bundled patched Mewjector - forced with --bundled-loader' "reason says the bundled loader was forced"
  expect_loader_above_achievements "$LAST_OUT" "the loader line sits immediately above the achievements line"
}

test_sh_override_missing() {
  section "install.sh: an override that points at nothing falls back to the bundled loader"
  local game
  game="$(new_game override-missing)"
  SH_OVERRIDE="$WORK/does-not-exist"; SH_NETBIN=""

  run_sh "$BUNDLE" --game-dir "$game"

  expect_eq 0 "$RC" "install exits 0"
  expect_fixed "$LAST_OUT" 'could not check upstream (override path does not exist:' "reason says the override could not be read"
  expect_files_equal "$BUNDLE/version.dll" "$game/version.dll" "installed version.dll matches the bundled patched loader"
  expect_loader_above_achievements "$LAST_OUT" "the loader line sits immediately above the achievements line"
}

test_sh_override_file_forms() {
  section "install.sh: MEWJECTOR_RELEASE_OVERRIDE accepts a directory, an ini file and a metadata file"
  local game
  game="$(new_game override-forms)"
  SH_NETBIN=""
  snapshot "$game" "$WORK/forms-before"

  SH_OVERRIDE="$FIXED"
  run_sh "$BUNDLE" --dry-run --game-dir "$game"
  expect_eq 0 "$RC" "directory override dry run exits 0"
  expect_fixed "$LAST_OUT" 'it carries the EnableEPFallback fix' "directory override selects upstream"

  SH_OVERRIDE="$FIXED/chainloader.ini"
  run_sh "$BUNDLE" --dry-run --game-dir "$game"
  expect_fixed "$LAST_OUT" 'it carries the EnableEPFallback fix' "ini-file override selects upstream"

  printf 'chainloader_ini=%s\n' "$FIXED/chainloader.ini" > "$WORK/meta-ini.txt"
  SH_OVERRIDE="$WORK/meta-ini.txt"
  run_sh "$BUNDLE" --dry-run --game-dir "$game"
  expect_fixed "$LAST_OUT" 'it carries the EnableEPFallback fix' "metadata chainloader_ini= override selects upstream"

  printf 'directory=%s\n' "$FIXED" > "$WORK/meta-dir.txt"
  SH_OVERRIDE="$WORK/meta-dir.txt"
  run_sh "$BUNDLE" --dry-run --game-dir "$game"
  expect_fixed "$LAST_OUT" 'it carries the EnableEPFallback fix' "metadata directory= override selects upstream"

  # A relative directory= resolves against the metadata file's own folder.
  printf 'directory=%s\n' 'standin-fixed' > "$WORK/meta-rel.txt"
  SH_OVERRIDE="$WORK/meta-rel.txt"
  run_sh "$BUNDLE" --dry-run --game-dir "$game"
  expect_fixed "$LAST_OUT" 'it carries the EnableEPFallback fix' "relative directory= override selects upstream"

  snapshot "$game" "$WORK/forms-after"
  expect_same_tree "$WORK/forms-before" "$WORK/forms-after" "the override-form dry runs wrote nothing"
}

test_sh_download_provenance() {
  section "install.sh: a downloaded official loader prints its source URL and the installed SHA-256"
  local game dlog
  game="$(new_game download-provenance)"
  dlog="$WORK/dl-official.log"
  SH_OVERRIDE=""; SH_NETBIN="$DLBIN"
  if [ "$HAVE_DOWNLOAD_FIXTURE" != 1 ]; then
    fail "python3 not found: it is needed to build the offline release archive fixture"
    SH_NETBIN=""
    return
  fi
  export DL_API_JSON="$DLDIR/api-official.json" DL_ZIP="$DLDIR/official.zip" DL_LOG="$dlog"
  rm -f "$dlog"

  run_sh "$BUNDLE" --game-dir "$game"

  unset DL_API_JSON DL_ZIP DL_LOG
  SH_NETBIN=""

  expect_eq 0 "$RC" "download install exits 0"
  expect_fixed "$LAST_OUT" 'loader: upstream Mewjector v9.9.9 - it carries the EnableEPFallback fix' "loader line names the downloaded release tag"
  expect_files_equal "$RELEASE_DLL" "$game/version.dll" "installed version.dll is the downloaded one"
  expect_files_equal "$RELEASE_INI" "$game/chainloader.ini" "installed chainloader.ini is the downloaded one"

  local hash
  hash="$(sha256sum "$game/version.dll" | awk '{print $1}')"
  expect_provenance_block "$LAST_OUT" "$OFFICIAL_ZIP_URL" "$hash" "provenance names the source URL and the SHA-256 of the installed version.dll"
  expect_loader_above_achievements "$LAST_OUT" "the loader block sits above the achievements line"

  local downloads
  downloads="$(grep -cF -- "$OFFICIAL_ZIP_URL" "$dlog" || true)"
  expect_eq 1 "$downloads" "the official asset URL was fetched exactly once"
}

test_sh_non_official_url_refused() {
  section "install.sh: a release asset that is not the official Mewjector URL is refused"
  local game elog
  game="$(new_game non-official-url)"
  elog="$WORK/dl-evil.log"
  SH_OVERRIDE=""; SH_NETBIN="$DLBIN"
  if [ "$HAVE_DOWNLOAD_FIXTURE" != 1 ]; then
    fail "python3 not found: it is needed to build the offline release archive fixture"
    SH_NETBIN=""
    return
  fi
  export DL_API_JSON="$DLDIR/api-evil.json" DL_ZIP="$DLDIR/official.zip" DL_LOG="$elog"
  rm -f "$elog"

  run_sh "$BUNDLE" --game-dir "$game"

  unset DL_API_JSON DL_ZIP DL_LOG
  SH_NETBIN=""

  expect_eq 0 "$RC" "install exits 0 and falls back to the bundled loader"
  expect_fixed "$LAST_OUT" 'could not check upstream (the release asset is not from the official Mewjector GitHub release)' "reason says the non-official asset was refused"
  expect_files_equal "$BUNDLE/version.dll" "$game/version.dll" "the bundled patched loader is installed instead"
  expect_loader_above_achievements "$LAST_OUT" "the loader block sits above the achievements line"

  local api_calls
  api_calls="$(grep -cF 'api.github.com' "$elog" || true)"
  expect_eq 1 "$api_calls" "the release API was queried once"
  if grep -qF 'evil.example.com' "$elog" 2>/dev/null; then
    fail "the non-official asset URL must never be downloaded"
  else
    pass "the non-official asset URL was never downloaded"
  fi
  expect_no_sha256 "$LAST_OUT" "a refused download prints no hash"
}

test_sh_override_provenance_unverified() {
  section "install.sh: an override loader is named as an unverified trusted hook"
  local game
  game="$(new_game override-provenance)"
  SH_OVERRIDE="$FIXED"; SH_NETBIN=""

  run_sh "$BUNDLE" --game-dir "$game"

  expect_eq 0 "$RC" "override install exits 0"
  expect_override_provenance "$LAST_OUT" "$FIXED" "provenance names the override as unverified"
  expect_no_sha256 "$LAST_OUT" "an override prints no hash"
  expect_loader_above_achievements "$LAST_OUT" "the override loader block sits above the achievements line"
}

test_sh_relative_chainloader_ini_other_cwd() {
  section "install.sh: a relative chainloader_ini= resolves against the metadata file, not the working directory"
  local game base other
  game="$(new_game rel-ini-cwd)"
  base="$WORK/relbase"
  other="$WORK/rel-elsewhere"
  rm -rf "$base" "$other"
  mkdir -p "$base/meta/inner/release" "$other/inner/release"
  printf 'RELATIVE-META-LOADER\n' > "$base/meta/inner/release/version.dll"
  printf '[Chainloader]\nmods=mods\nEnableEPFallback=1\n' > "$base/meta/inner/release/chainloader.ini"
  # A same-named decoy under the working directory. If the relative path were
  # resolved against the working directory instead of the metadata folder, this
  # one (without the key) would be picked and the installer would fall back to
  # the bundled loader.
  printf 'CWD-DECOY-LOADER\n' > "$other/inner/release/version.dll"
  printf '[chainloader]\nmods=mods\n' > "$other/inner/release/chainloader.ini"
  printf 'chainloader_ini=inner/release/chainloader.ini\n' > "$base/meta/meta.txt"
  printf 'directory=inner/release\n' > "$base/meta/meta-dir.txt"

  SH_OVERRIDE="$base/meta/meta.txt"; SH_NETBIN=""; SH_CWD="$other"
  run_sh "$BUNDLE" --game-dir "$game"
  SH_CWD=""

  expect_eq 0 "$RC" "install from another working directory exits 0"
  expect_fixed "$LAST_OUT" 'it carries the EnableEPFallback fix' "relative chainloader_ini= resolved against the metadata folder"
  expect_files_equal "$base/meta/inner/release/version.dll" "$game/version.dll" "the relative-ini loader is installed byte for byte"
  expect_files_equal "$base/meta/inner/release/chainloader.ini" "$game/chainloader.ini" "the relative-ini chainloader.ini is installed byte for byte"
  expect_loader_above_achievements "$LAST_OUT" "the loader block sits above the achievements line"

  # The same relative path under the working directory points nowhere, so a
  # working-directory lookup would have fallen back to the bundled loader.
  local other_game
  other_game="$(new_game rel-dir-cwd)"
  SH_OVERRIDE="$base/meta/meta-dir.txt"; SH_CWD="$other"
  run_sh "$BUNDLE" --game-dir "$other_game"
  SH_CWD=""
  expect_eq 0 "$RC" "directory= install from another working directory exits 0"
  expect_fixed "$LAST_OUT" 'it carries the EnableEPFallback fix' "relative directory= resolved against the metadata folder"
  expect_files_equal "$base/meta/inner/release/version.dll" "$other_game/version.dll" "the relative-directory loader is installed byte for byte"
}

test_sh_dry_run_never_downloads() {
  section "install.sh: dry runs write nothing and never download, with or without an override"
  SH_NETBIN="$NETBIN"

  # No override: the dry-run guard skips the upstream check entirely.
  local game_a
  game_a="$(new_game dry-no-override)"
  rm -f "$NETLOG"
  snapshot "$game_a" "$WORK/dry-a-before"
  SH_OVERRIDE=""
  run_sh "$BUNDLE" --dry-run --game-dir "$game_a"
  expect_eq 0 "$RC" "dry run without an override exits 0"
  expect_absent "$NETLOG" "dry run without an override downloaded nothing"
  expect_fixed "$LAST_OUT" 'loader: bundled patched Mewjector - dry run: upstream was not checked' "reason says the dry run skipped upstream"
  expect_loader_above_achievements "$LAST_OUT" "the loader line sits immediately above the achievements line"
  snapshot "$game_a" "$WORK/dry-a-after"
  expect_same_tree "$WORK/dry-a-before" "$WORK/dry-a-after" "dry run without an override changed nothing"

  # Override with the fix: read locally, still no download and no writes.
  local game_b
  game_b="$(new_game dry-fixed)"
  rm -f "$NETLOG"
  snapshot "$game_b" "$WORK/dry-b-before"
  SH_OVERRIDE="$FIXED"
  run_sh "$BUNDLE" --dry-run --game-dir "$game_b"
  expect_eq 0 "$RC" "dry run with the fixed override exits 0"
  expect_absent "$NETLOG" "dry run with the fixed override downloaded nothing"
  expect_fixed "$LAST_OUT" 'it carries the EnableEPFallback fix' "dry run with the fixed override selects upstream"
  expect_loader_above_achievements "$LAST_OUT" "the loader line sits immediately above the achievements line"
  snapshot "$game_b" "$WORK/dry-b-after"
  expect_same_tree "$WORK/dry-b-before" "$WORK/dry-b-after" "dry run with the fixed override changed nothing"

  # Override without the fix: still local, still no writes.
  local game_c
  game_c="$(new_game dry-nofix)"
  rm -f "$NETLOG"
  snapshot "$game_c" "$WORK/dry-c-before"
  SH_OVERRIDE="$NOFIX"
  run_sh "$BUNDLE" --dry-run --game-dir "$game_c"
  expect_eq 0 "$RC" "dry run with the no-fix override exits 0"
  expect_absent "$NETLOG" "dry run with the no-fix override downloaded nothing"
  expect_fixed "$LAST_OUT" 'upstream override does not carry the fix yet' "dry run with the no-fix override stays bundled"
  snapshot "$game_c" "$WORK/dry-c-after"
  expect_same_tree "$WORK/dry-c-before" "$WORK/dry-c-after" "dry run with the no-fix override changed nothing"
}

test_sh_idempotent_and_backup() {
  section "install.sh: loader resolution stays idempotent and a replaced loader is still backed up"
  local game
  game="$(new_game idempotent)"
  SH_NETBIN=""

  # First install: no-fix stand-in -> bundled patched loader.
  SH_OVERRIDE="$NOFIX"
  run_sh "$BUNDLE" --game-dir "$game"
  expect_eq 0 "$RC" "bundled install exits 0"
  expect_fixed "$LAST_OUT" 'install complete: 3 written, 0 already up to date, 0 backed up.' "bundled install wrote three files"

  # Same resolution again: everything is already current.
  cp -p "$game/mods/.breeding-spike-installed" "$WORK/record-before"
  snapshot_excluding "$game" "$WORK/idem-before" '(^d .* mods$|\.breeding-spike-installed)'
  SH_OVERRIDE="$NOFIX"
  run_sh "$BUNDLE" --game-dir "$game"
  expect_eq 0 "$RC" "repeat bundled install exits 0"
  expect_fixed "$LAST_OUT" 'install complete: 0 written, 3 already up to date, 0 backed up.' "repeat install reports all files current"
  snapshot_excluding "$game" "$WORK/idem-after" '(^d .* mods$|\.breeding-spike-installed)'
  expect_same_tree "$WORK/idem-before" "$WORK/idem-after" "repeat install left every payload file untouched"
  expect_files_equal "$WORK/record-before" "$game/mods/.breeding-spike-installed" "repeat install left the record byte-identical"

  # Switch to the upstream loader: the two differing files are backed up.
  SH_OVERRIDE="$FIXED"
  run_sh "$BUNDLE" --game-dir "$game"
  expect_eq 0 "$RC" "upstream install exits 0"
  expect_fixed "$LAST_OUT" 'install complete: 2 written, 1 already up to date, 2 backed up.' "switching loaders backs up the two replaced files"
  expect_files_equal "$FIXED/version.dll" "$game/version.dll" "upstream version.dll is now installed"
  expect_files_equal "$FIXED/chainloader.ini" "$game/chainloader.ini" "upstream chainloader.ini is now installed"

  local backup
  backup="$(find "$game" -maxdepth 1 -name 'version.dll.*.bak' | LC_ALL=C sort | head -n1)"
  expect_exists "$backup" "a version.dll backup was created"
  expect_content "$BUNDLE/version.dll" "$backup" "the version.dll backup holds the bundled loader it replaced"

  backup="$(find "$game" -maxdepth 1 -name 'chainloader.ini.*.bak' | LC_ALL=C sort | head -n1)"
  expect_exists "$backup" "a chainloader.ini backup was created"
  expect_content "$BUNDLE/chainloader.ini" "$backup" "the chainloader.ini backup holds the bundled ini it replaced"
}

test_sh_uninstall_leaves_upstream() {
  section "install.sh: uninstall leaves the upstream loader in place and keeps the record"
  local game
  game="$(new_game uninstall-upstream)"
  SH_NETBIN=""
  SH_OVERRIDE="$FIXED"

  run_sh "$BUNDLE" --game-dir "$game"
  expect_eq 0 "$RC" "upstream install exits 0"

  # Uninstall never consults the loader step: it compares the recorded files
  # against the bundle, so the upstream files look modified and are left. This
  # is the limitation README.md documents.
  run_sh "$BUNDLE" --uninstall --game-dir "$game"
  expect_eq 0 "$RC" "uninstall exits 0"
  expect_fixed "$LAST_OUT" 'left version.dll: it was modified after this script installed it' "leaves the upstream version.dll with the documented reason"
  expect_fixed "$LAST_OUT" 'left chainloader.ini: it was modified after this script installed it' "leaves the upstream chainloader.ini with the documented reason"
  expect_fixed "$LAST_OUT" 'uninstall complete: 1 removed, 0 restored from backup, 2 left in place.' "removes the mod DLL but leaves the two loader files"
  expect_files_equal "$FIXED/version.dll" "$game/version.dll" "the upstream version.dll survives uninstall"
  expect_files_equal "$FIXED/chainloader.ini" "$game/chainloader.ini" "the upstream chainloader.ini survives uninstall"
  expect_absent "$game/mods/BreedingSpike.dll" "the mod DLL is removed as usual"

  expect_exists "$game/mods/.breeding-spike-installed" "the install record is kept"
  printf 'version.dll\nchainloader.ini\n' > "$WORK/upstream-kept-record.txt"
  expect_files_equal "$WORK/upstream-kept-record.txt" "$game/mods/.breeding-spike-installed" "the kept record lists exactly the two loader files"
  expect_fixed "$LAST_OUT" '2 files are still installed, so a later run can clean them up.' "says the record was kept and why"
}

# ---------------------------------------------------------------------------
# install.ps1 (Linux checks only)
# ---------------------------------------------------------------------------
test_ps_loader_resolution() {
  section "install.ps1: the same loader choices, offline"
  printf '  NOTE: PowerShell checks run on Linux under pwsh; the loader resolution\n'
  printf '  NOTE: and the install path are covered, but a real Windows session is not.\n'

  local game
  game="$(new_game ps-upstream)"
  PS_OVERRIDE="$FIXED"
  run_ps -File "$BUNDLE/install.ps1" -GameDir "$game"
  expect_eq 0 "$RC" "ps upstream install exits 0"
  expect_files_equal "$FIXED/version.dll" "$game/version.dll" "ps installed the upstream version.dll byte for byte"
  expect_files_equal "$FIXED/chainloader.ini" "$game/chainloader.ini" "ps installed the upstream chainloader.ini byte for byte"
  expect_fixed "$LAST_OUT" 'loader: upstream Mewjector override - it carries the EnableEPFallback fix' "ps loader line says upstream carries the fix"
  expect_fixed "$LAST_OUT" "$ACHIEVEMENTS_LINE" "ps achievements wording is unchanged"
  expect_override_provenance "$LAST_OUT" "$FIXED" "ps names the override as an unverified trusted hook"
  expect_no_sha256 "$LAST_OUT" "ps prints no hash for an override"
  expect_loader_above_achievements "$LAST_OUT" "ps loader block sits above the achievements line"

  local nofix_game
  nofix_game="$(new_game ps-nofix)"
  PS_OVERRIDE="$NOFIX"
  run_ps -File "$BUNDLE/install.ps1" -GameDir "$nofix_game"
  expect_eq 0 "$RC" "ps no-fix install exits 0"
  expect_files_equal "$BUNDLE/version.dll" "$nofix_game/version.dll" "ps falls back to the bundled loader"
  expect_fixed "$LAST_OUT" 'upstream override does not carry the fix yet; using the bundled patched loader' "ps reason says upstream lacks the fix yet"
  expect_loader_above_achievements "$LAST_OUT" "ps loader line sits immediately above the achievements line"

  local force_game
  force_game="$(new_game ps-force)"
  PS_OVERRIDE="$FIXED"
  run_ps -File "$BUNDLE/install.ps1" -GameDir "$force_game" -BundledLoader
  expect_eq 0 "$RC" "ps forced install exits 0"
  expect_files_equal "$BUNDLE/version.dll" "$force_game/version.dll" "ps -BundledLoader uses the bundled loader"
  expect_fixed "$LAST_OUT" 'loader: bundled patched Mewjector - forced with -BundledLoader' "ps reason says the bundled loader was forced"
  expect_loader_above_achievements "$LAST_OUT" "ps forced loader line sits immediately above the achievements line"

  # An override that points at nothing: the offline failure path. It never
  # falls through to a real network call because the override is set.
  local missing_game
  missing_game="$(new_game ps-missing)"
  PS_OVERRIDE="$WORK/does-not-exist"
  run_ps -File "$BUNDLE/install.ps1" -GameDir "$missing_game"
  expect_eq 0 "$RC" "ps install with a broken override exits 0"
  expect_fixed "$LAST_OUT" 'could not check upstream (override path does not exist:' "ps reason says the override could not be read"
  expect_files_equal "$BUNDLE/version.dll" "$missing_game/version.dll" "ps falls back to the bundled loader on a broken override"
  expect_loader_above_achievements "$LAST_OUT" "ps broken-override loader line sits immediately above the achievements line"

  # The ini-file form of the override.
  local ini_game
  ini_game="$(new_game ps-ini)"
  PS_OVERRIDE="$FIXED/chainloader.ini"
  run_ps -File "$BUNDLE/install.ps1" -DryRun -GameDir "$ini_game"
  expect_eq 0 "$RC" "ps ini-file override dry run exits 0"
  expect_fixed "$LAST_OUT" 'it carries the EnableEPFallback fix' "ps accepts an ini file as the override"
}

test_ps_dry_run_writes_nothing() {
  section "install.ps1: dry runs write nothing and skip the network, with or without an override"

  local no_override_game
  no_override_game="$(new_game ps-dry-no-override)"
  PS_OVERRIDE=""
  snapshot "$no_override_game" "$WORK/ps-dry-a-before"
  run_ps -File "$BUNDLE/install.ps1" -DryRun -GameDir "$no_override_game"
  expect_eq 0 "$RC" "ps dry run without an override exits 0"
  expect_fixed "$LAST_OUT" 'loader: bundled patched Mewjector - dry run: upstream was not checked' "ps dry run without an override skips upstream"
  expect_loader_above_achievements "$LAST_OUT" "ps dry-run loader line sits immediately above the achievements line"
  snapshot "$no_override_game" "$WORK/ps-dry-a-after"
  expect_same_tree "$WORK/ps-dry-a-before" "$WORK/ps-dry-a-after" "ps dry run without an override changed nothing"

  local fixed_game
  fixed_game="$(new_game ps-dry-fixed)"
  PS_OVERRIDE="$FIXED"
  snapshot "$fixed_game" "$WORK/ps-dry-b-before"
  run_ps -File "$BUNDLE/install.ps1" -DryRun -GameDir "$fixed_game"
  expect_eq 0 "$RC" "ps dry run with the fixed override exits 0"
  expect_fixed "$LAST_OUT" 'it carries the EnableEPFallback fix' "ps dry run with the fixed override resolves the loader"
  expect_loader_above_achievements "$LAST_OUT" "ps dry-run loader line sits immediately above the achievements line"
  snapshot "$fixed_game" "$WORK/ps-dry-b-after"
  expect_same_tree "$WORK/ps-dry-b-before" "$WORK/ps-dry-b-after" "ps dry run with the fixed override changed nothing"
  expect_absent "$fixed_game/mods/.breeding-spike-installed" "ps dry run wrote no install record"
}

test_ps_relative_chainloader_ini_other_cwd() {
  section "install.ps1: a relative chainloader_ini= resolves against the metadata file, not the working directory"
  local game base other
  game="$(new_game ps-rel-ini)"
  base="$WORK/ps-relbase"
  other="$WORK/ps-rel-elsewhere"
  rm -rf "$base" "$other"
  mkdir -p "$base/meta/inner/release" "$other/inner/release"
  printf 'PS-RELATIVE-META-LOADER\n' > "$base/meta/inner/release/version.dll"
  printf '[Chainloader]\nmods=mods\nEnableEPFallback=1\n' > "$base/meta/inner/release/chainloader.ini"
  # A same-named decoy under the working directory, for the same reason as the
  # install.sh check above.
  printf 'PS-CWD-DECOY-LOADER\n' > "$other/inner/release/version.dll"
  printf '[chainloader]\nmods=mods\n' > "$other/inner/release/chainloader.ini"
  printf 'chainloader_ini=inner/release/chainloader.ini\n' > "$base/meta/meta.txt"

  PS_OVERRIDE="$base/meta/meta.txt"; PS_CWD="$other"
  run_ps -File "$BUNDLE/install.ps1" -GameDir "$game"
  PS_CWD=""

  expect_eq 0 "$RC" "ps install from another working directory exits 0"
  expect_fixed "$LAST_OUT" 'it carries the EnableEPFallback fix' "ps resolved the relative chainloader_ini= against the metadata folder"
  expect_files_equal "$base/meta/inner/release/version.dll" "$game/version.dll" "ps installed the relative-ini loader byte for byte"
  expect_files_equal "$base/meta/inner/release/chainloader.ini" "$game/chainloader.ini" "ps installed the relative-ini chainloader.ini byte for byte"
  expect_override_provenance "$LAST_OUT" "$base/meta/meta.txt" "ps names the relative-ini override as unverified"
  expect_loader_above_achievements "$LAST_OUT" "ps loader block sits above the achievements line"
}

test_ps_download_provenance() {
  section "install.ps1: a downloaded official loader prints its source URL and the installed SHA-256"
  if [ "$HAVE_DOWNLOAD_FIXTURE" != 1 ]; then
    fail "python3 not found: it is needed to build the offline release archive fixture"
    return
  fi
  local work="$WORK/ps-dl-official"
  rm -rf "$work"; mkdir -p "$work"
  PS_OVERRIDE=""
  run_ps -File "$PS_HARNESS" -LoaderScript "$BUNDLE/loader-release.ps1" -WorkDir "$work" \
    -ReleaseZip "$DLDIR/official.zip" -Mode official -MarkerFile "$work/downloaded.marker"
  expect_eq 0 "$RC" "ps download harness exits 0"
  expect_fixed "$LAST_OUT" 'KIND=upstream' "ps selected the downloaded loader"
  expect_fixed "$LAST_OUT" 'ORIGIN=download' "ps records the download origin"
  expect_exists "$work/downloaded.marker" "ps downloaded the release asset"
  local hash
  hash="$(sha256sum "$work/installed-version.dll" | awk '{print $1}')"
  expect_provenance_block "$LAST_OUT" "$OFFICIAL_ZIP_URL" "$hash" "ps provenance names the source URL and the installed SHA-256"
}

test_ps_non_official_url_refused() {
  section "install.ps1: a release asset that is not the official Mewjector URL is refused"
  if [ "$HAVE_DOWNLOAD_FIXTURE" != 1 ]; then
    fail "python3 not found: it is needed to build the offline release archive fixture"
    return
  fi
  local work="$WORK/ps-dl-evil"
  rm -rf "$work"; mkdir -p "$work"
  PS_OVERRIDE=""
  run_ps -File "$PS_HARNESS" -LoaderScript "$BUNDLE/loader-release.ps1" -WorkDir "$work" \
    -ReleaseZip "$DLDIR/official.zip" -Mode evil -MarkerFile "$work/downloaded.marker"
  expect_eq 0 "$RC" "ps refusal harness exits 0"
  expect_fixed "$LAST_OUT" 'KIND=bundled' "ps falls back to the bundled loader"
  expect_fixed "$LAST_OUT" 'REASON=could not check upstream (the release asset is not from the official Mewjector GitHub release); using the bundled patched loader' "ps reason says the non-official asset was refused"
  expect_absent "$work/downloaded.marker" "ps never downloaded the non-official asset"
  expect_no_sha256 "$LAST_OUT" "ps refusal prints no hash"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
printf 'loader-resolution tests: temp dir %s\n' "$WORK"
printf 'loader-resolution tests: repo %s\n' "$REPO_ROOT"

make_bundle "$BUNDLE"
make_standin "$NOFIX" nofix
make_standin "$FIXED" fixed
make_download_fixture
if [ "$HAVE_DOWNLOAD_FIXTURE" != 1 ]; then
  printf '  warn the download checks need python3 to build their offline release archive\n'
fi

test_sh_upstream_with_fix
test_sh_bundled_without_fix
test_sh_no_network
test_sh_force_flag
test_sh_override_missing
test_sh_override_file_forms
test_sh_override_provenance_unverified
test_sh_relative_chainloader_ini_other_cwd
test_sh_download_provenance
test_sh_non_official_url_refused
test_sh_dry_run_never_downloads
test_sh_idempotent_and_backup
test_sh_uninstall_leaves_upstream

if [ -z "$PWSH" ]; then
  section "install.ps1"
  fail "pwsh not found: install nixpkgs#powershell (or set PWSH=/path/to/pwsh)"
else
  printf '  info using pwsh: %s\n' "$PWSH"
  test_ps_loader_resolution
  test_ps_relative_chainloader_ini_other_cwd
  test_ps_download_provenance
  test_ps_non_official_url_refused
  test_ps_dry_run_writes_nothing
fi

printf '\n============================================\n'
if [ "$FAILED" -eq 0 ]; then
  printf 'PASS: loader-resolution tests: %d checks passed, 0 failed\n' "$PASSED"
  exit 0
fi
printf 'FAIL: loader-resolution tests: %d passed, %d FAILED\n' "$PASSED" "$FAILED" >&2
exit 1
