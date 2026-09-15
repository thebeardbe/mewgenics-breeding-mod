#!/usr/bin/env bash
# Tests the release workflow's own bundle assembly, offline.
#
# The "Assemble the installer bundles" step in .github/workflows/release.yml is
# extracted and run verbatim in a sandbox, so the checks below describe exactly
# what the workflow ships. Fake dist/ artifacts, a fake vendored licence and the
# real installers/ tree stand in for the build output; no network and no zig.
#
# It asserts each zip holds exactly the expected per-platform structure:
#
#   windows: install.bat uninstall.bat README.md
#            scripts/{install.ps1,loader-release.ps1}
#            payload/{version.dll,chainloader.ini,BreedingSpike.dll}
#            docs/{HOW-IT-WORKS.md,PATCHES.md,MEWJECTOR-LICENSE.txt}
#
#   linux:   install.sh uninstall.sh README.md
#            scripts/{loader-release.sh,proton-registry.sh}
#            payload/{version.dll,chainloader.ini,BreedingSpike.dll}
#            docs/{HOW-IT-WORKS.md,PATCHES.md,MEWJECTOR-LICENSE.txt}
#
# and that the two distinct zips carry the matching platform README and docs.
# The READMEs themselves are checked for the platform split: each holds only
# that platform's install and uninstall steps and points at docs/, while the
# loader and patch explanation lives in docs/HOW-IT-WORKS.md.
#
#   ./tools/smoke/tests/run_release_assembly_test.sh
#
# Needs zip (for the workflow's own command) and python3 (to read the zips back,
# in the pinned dev shell). When either is missing the check fails loudly rather
# than passing quietly.
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

expect_exists() { if [ -e "$1" ]; then pass "$2"; else fail "$2: [$1] does not exist"; fi; }
expect_absent() { if [ ! -e "$1" ]; then pass "$2"; else fail "$2: [$1] should not exist"; fi; }
expect_files_equal() { # a b desc
  if cmp -s "$1" "$2"; then pass "$3"; else fail "$3: [$(basename "$1")] and [$(basename "$2")] differ"; fi
}

# ---------------------------------------------------------------------------
# fixtures and runners
# ---------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mew-release-assembly-test.XXXXXX")"
SANDBOX="$WORK/sandbox"

cleanup() {
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT INT TERM

# Find a tool on PATH, else in the Nix store (this repo is Nix-first and zip is
# not always on PATH even where it is installed).
find_tool() { # name
  local name="$1" candidate
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  for candidate in /nix/store/*-"$name"-[0-9]*/bin/"$name" \
                   "/usr/bin/$name" "/bin/$name" "/usr/local/bin/$name"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

ZIP="$(find_tool zip || true)"
PYTHON="$(find_tool python3 || true)"

# Extract the step named in $2 from the workflow at $1 and print its run block,
# dedented. A plain Python reader avoids depending on a YAML tool.
extract_workflow_step() { # workflow-file step-name
  "$PYTHON" - "$1" "$2" <<'PY'
import sys

path, wanted = sys.argv[1], sys.argv[2]
with open(path, encoding='utf-8') as handle:
    lines = handle.read().splitlines()

start = None
for i, line in enumerate(lines):
    if line.strip() == f'- name: {wanted}':
        start = i
        break
if start is None:
    sys.exit(f'workflow step not found: {wanted}')

run_at = None
for j in range(start + 1, len(lines)):
    stripped = lines[j].strip()
    if stripped.startswith('- name:'):
        break
    if stripped == 'run: |':
        run_at = j
        break
if run_at is None:
    sys.exit(f'no run block under step: {wanted}')

body = []
for k in range(run_at + 1, len(lines)):
    line = lines[k]
    if not line.strip():
        body.append('')
        continue
    if len(line) - len(line.lstrip()) <= len(lines[run_at]) - len(lines[run_at].lstrip()):
        break
    body.append(line)

indents = [len(l) - len(l.lstrip()) for l in body if l.strip()]
content_indent = min(indents) if indents else 0
out = [l[content_indent:] if l.strip() else '' for l in body]
while out and not out[-1]:
    out.pop()
print('\n'.join(out))
PY
}

# Print the file members (directory entries excluded), one per line, sorted.
zip_list() { # zip
  "$PYTHON" - "$1" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    for name in sorted(archive.namelist()):
        if not name.endswith('/'):
            print(name)
PY
}

zip_extract() { # zip member dest
  "$PYTHON" - "$1" "$2" "$3" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    with archive.open(sys.argv[2]) as src, open(sys.argv[3], 'wb') as dst:
        dst.write(src.read())
PY
}

# ---------------------------------------------------------------------------
# the workflow assembly
# ---------------------------------------------------------------------------
test_workflow_assembly() {
  section "the release workflow assembles one self-contained zip per platform"

  if [ -z "$ZIP" ]; then
    fail "zip not found: install zip or nixpkgs#zip"
    return
  fi
  if [ -z "$PYTHON" ]; then
    fail "python3 not found: run this inside the pinned dev shell"
    return
  fi
  printf '  info using zip: %s\n' "$ZIP"
  printf '  info using python3: %s\n' "$PYTHON"

  local workflow="$REPO_ROOT/.github/workflows/release.yml"
  expect_exists "$workflow" "the release workflow exists"
  extract_workflow_step "$workflow" 'Assemble the installer bundles' > "$WORK/assemble.sh"
  expect_exists "$WORK/assemble.sh" "the assembly run block was extracted"
  if grep -qF 'release-artifacts' "$WORK/assemble.sh"; then
    pass "the extracted script is the bundle assembly step"
  else
    fail "the extracted script does not look like the bundle assembly step"
    return
  fi

  # The inputs the assembly step copies. The vendored licence is intentionally
  # different from installers/MEWJECTOR-LICENSE.txt, to prove the shipped copy
  # is refreshed from vendor/ rather than copied from installers/.
  mkdir -p "$SANDBOX/dist" "$SANDBOX/installers" "$SANDBOX/vendor/upstream/mewjector"
  printf 'DIST-LOADER-V1\n' > "$SANDBOX/dist/version.dll"
  printf '[chainloader]\nmods=mods\nEnableEPFallback=0\n' > "$SANDBOX/dist/chainloader.ini"
  printf 'DIST-MOD-V1\n' > "$SANDBOX/dist/BreedingSpike.dll"
  cp -rp "$REPO_ROOT"/installers/. "$SANDBOX/installers/"
  printf 'VENDORED-MEWJECTOR-LICENCE-TEXT\n' > "$SANDBOX/vendor/upstream/mewjector/LICENSE"

  local rc=0
  ( cd "$SANDBOX" && PATH="$(dirname "$ZIP"):$PATH" GITHUB_REF_NAME='test/1.2.3' \
      bash "$WORK/assemble.sh" > "$WORK/assemble.out" 2>&1 ) || rc=$?
  expect_eq 0 "$rc" "the assembly step exits 0"
  if [ "$rc" != 0 ]; then
    sed -n '1,40p' "$WORK/assemble.out" >&2
    return
  fi

  local windows_zip="MewgenicsBreedingMod-test-1.2.3-windows.zip"
  local linux_zip="MewgenicsBreedingMod-test-1.2.3-linux.zip"
  expect_fixed "$WORK/assemble.out" "$windows_zip" "the ref's slash is sanitized in the Windows bundle name"
  expect_fixed "$WORK/assemble.out" "$linux_zip" "the ref's slash is sanitized in the Linux bundle name"

  # release-artifacts/ holds exactly the two zips and nothing else.
  local arts
  arts="$(find "$SANDBOX/release-artifacts" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)"
  expect_eq "$(printf '%s\n' "$linux_zip" "$windows_zip")" "$arts" "release-artifacts/ holds exactly the two platform zips"

  # --- linux bundle --------------------------------------------------------
  local got_linux
  got_linux="$(zip_list "$SANDBOX/release-artifacts/$linux_zip")"
  local want_linux
  want_linux="$(printf '%s\n' \
    'README.md' \
    'docs/HOW-IT-WORKS.md' \
    'docs/MEWJECTOR-LICENSE.txt' \
    'docs/PATCHES.md' \
    'install.sh' \
    'payload/BreedingSpike.dll' \
    'payload/chainloader.ini' \
    'payload/version.dll' \
    'scripts/loader-release.sh' \
    'scripts/proton-registry.sh' \
    'uninstall.sh')"
  expect_eq "$want_linux" "$got_linux" "the Linux zip contains exactly the expected files"

  # --- windows bundle ------------------------------------------------------
  local got_windows
  got_windows="$(zip_list "$SANDBOX/release-artifacts/$windows_zip")"
  local want_windows
  want_windows="$(printf '%s\n' \
    'README.md' \
    'docs/HOW-IT-WORKS.md' \
    'docs/MEWJECTOR-LICENSE.txt' \
    'docs/PATCHES.md' \
    'install.bat' \
    'payload/BreedingSpike.dll' \
    'payload/chainloader.ini' \
    'payload/version.dll' \
    'scripts/install.ps1' \
    'scripts/loader-release.ps1' \
    'uninstall.bat')"
  expect_eq "$want_windows" "$got_windows" "the Windows zip contains exactly the expected files"

  # The old windows/+linux/+payload single bundle must not come back.
  if printf '%s\n' "$got_linux" "$got_windows" | grep -qE '^(windows|linux)/'; then
    fail "a zip still nests the old windows/ and linux/ folders"
  else
    pass "neither zip nests the old windows/ and linux/ folders"
  fi
  if printf '%s\n' "$got_linux" | grep -qF 'install.ps1'; then
    fail "the Linux zip carries the Windows helper install.ps1"
  else
    pass "the Linux zip carries no Windows-only helper"
  fi
  if printf '%s\n' "$got_windows" | grep -qF 'proton-registry.sh'; then
    fail "the Windows zip carries the Linux helper proton-registry.sh"
  else
    pass "the Windows zip carries no Linux-only helper"
  fi
  if printf '%s\n' "$got_windows" | grep -qF 'install.sh'; then
    fail "the Windows zip carries the Linux entry script"
  else
    pass "the Windows zip carries no Linux entry script"
  fi

  # --- the bytes inside the zips ------------------------------------------
  zip_extract "$SANDBOX/release-artifacts/$linux_zip" 'payload/version.dll' "$WORK/linux-version.dll"
  expect_files_equal "$SANDBOX/dist/version.dll" "$WORK/linux-version.dll" "the Linux payload loader is the built dist/ artifact"
  zip_extract "$SANDBOX/release-artifacts/$windows_zip" 'payload/BreedingSpike.dll' "$WORK/windows-mod.dll"
  expect_files_equal "$SANDBOX/dist/BreedingSpike.dll" "$WORK/windows-mod.dll" "the Windows payload mod DLL is the built dist/ artifact"

  zip_extract "$SANDBOX/release-artifacts/$linux_zip" 'README.md' "$WORK/linux-readme.md"
  expect_files_equal "$REPO_ROOT/installers/README-linux.md" "$WORK/linux-readme.md" "the Linux zip's README is the Linux platform README"
  zip_extract "$SANDBOX/release-artifacts/$windows_zip" 'README.md' "$WORK/windows-readme.md"
  expect_files_equal "$REPO_ROOT/installers/README-windows.md" "$WORK/windows-readme.md" "the Windows zip's README is the Windows platform README"

  zip_extract "$SANDBOX/release-artifacts/$linux_zip" 'docs/HOW-IT-WORKS.md' "$WORK/linux-how.md"
  expect_files_equal "$REPO_ROOT/installers/HOW-IT-WORKS.md" "$WORK/linux-how.md" "the Linux zip's docs/ carries the explanation"
  zip_extract "$SANDBOX/release-artifacts/$windows_zip" 'docs/HOW-IT-WORKS.md' "$WORK/windows-how.md"
  expect_files_equal "$REPO_ROOT/installers/HOW-IT-WORKS.md" "$WORK/windows-how.md" "the Windows zip's docs/ carries the explanation"

  zip_extract "$SANDBOX/release-artifacts/$windows_zip" 'docs/MEWJECTOR-LICENSE.txt' "$WORK/windows-licence.txt"
  expect_files_equal "$SANDBOX/vendor/upstream/mewjector/LICENSE" "$WORK/windows-licence.txt" \
    "the shipped licence is refreshed from the vendored source"
  if cmp -s "$REPO_ROOT/installers/MEWJECTOR-LICENSE.txt" "$WORK/windows-licence.txt"; then
    fail "the shipped licence must come from vendor/, not installers/ (they are identical, so the check is vacuous)"
  else
    pass "the shipped licence differs from installers/MEWJECTOR-LICENSE.txt, proving the vendor refresh"
  fi
}

# ---------------------------------------------------------------------------
# the README split
# ---------------------------------------------------------------------------
test_readme_split() {
  section "each platform README holds only its own steps; the explanation lives in docs/"
  local win="$REPO_ROOT/installers/README-windows.md"
  local lin="$REPO_ROOT/installers/README-linux.md"
  local how="$REPO_ROOT/installers/HOW-IT-WORKS.md"
  local patches="$REPO_ROOT/installers/PATCHES.md"

  expect_exists "$win" "the Windows platform README exists"
  expect_exists "$lin" "the Linux platform README exists"
  expect_exists "$how" "docs/HOW-IT-WORKS.md exists"
  expect_absent "$REPO_ROOT/installers/README.md" "the old single bundle README is gone"

  # --- Windows README: Windows steps only ---------------------------------
  expect_match "$win" '^## Install' "the Windows README has an Install section"
  expect_match "$win" '^## Uninstall' "the Windows README has an Uninstall section"
  expect_fixed "$win" 'install.bat' "the Windows README names install.bat"
  expect_fixed "$win" 'uninstall.bat' "the Windows README names uninstall.bat"
  expect_fixed "$win" 'docs/HOW-IT-WORKS.md' "the Windows README points at docs/HOW-IT-WORKS.md"
  if grep -qF 'install.sh' "$win"; then
    fail "the Windows README must not carry the Linux install step"
  else
    pass "the Windows README carries no Linux install step"
  fi
  if grep -qiE 'WINEDLLOVERRIDES|Proton' "$win"; then
    fail "the Windows README must not carry Linux/Proton launch specifics"
  else
    pass "the Windows README carries no Linux/Proton launch specifics"
  fi

  # --- Linux README: Linux steps only -------------------------------------
  expect_match "$lin" '^## Install' "the Linux README has an Install section"
  expect_match "$lin" '^## Uninstall' "the Linux README has an Uninstall section"
  expect_fixed "$lin" './install.sh' "the Linux README names ./install.sh"
  expect_fixed "$lin" './uninstall.sh' "the Linux README names ./uninstall.sh"
  expect_fixed "$lin" 'WINEDLLOVERRIDES="version=n,b"' "the Linux README carries the launch option"
  expect_fixed "$lin" 'docs/HOW-IT-WORKS.md' "the Linux README points at docs/HOW-IT-WORKS.md"
  if grep -qF 'install.bat' "$lin"; then
    fail "the Linux README must not carry the Windows install step"
  else
    pass "the Linux README carries no Windows install step"
  fi

  # --- the loader and patch discussion is not in either README ------------
  local readme
  for readme in "$win" "$lin"; do
    if grep -qE 'EnableEPFallback|PR #6|Where the loader comes from|AppDefaults|loader-release' "$readme"; then
      fail "$(basename "$readme") carries the loader/patch discussion instead of pointing at docs/"
    else
      pass "$(basename "$readme") does not carry the loader/patch discussion"
    fi
  done

  # --- the explanation is where the READMEs point -------------------------
  expect_fixed "$how" 'Mewjector PR #6' "docs/HOW-IT-WORKS.md discusses the loader patch"
  expect_fixed "$how" 'Where the loader comes from' "docs/HOW-IT-WORKS.md explains where the loader comes from"
  expect_fixed "$how" 'PATCHES.md' "docs/HOW-IT-WORKS.md points at the patch detail"
  expect_fixed "$patches" 'EnableEPFallback' "docs/PATCHES.md carries the patch detail"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
printf 'release-assembly tests: temp dir %s\n' "$WORK"
printf 'release-assembly tests: repo %s\n' "$REPO_ROOT"

test_readme_split
test_workflow_assembly

printf '\n============================================\n'
if [ "$FAILED" -eq 0 ]; then
  printf 'PASS: release-assembly tests: %d checks passed, 0 failed\n' "$PASSED"
  exit 0
fi
printf 'FAIL: release-assembly tests: %d passed, %d FAILED\n' "$PASSED" "$FAILED" >&2
exit 1
