#!/usr/bin/env bash
# Fetch the pinned upstream sources and the official Mewjector release.
#
# We do not commit upstream code or binaries. This keeps the repo small and
# makes the exact revisions explicit. Re-run after editing the pins.
#
#   ./vendor/sync.sh
#
# Sources (both MIT):
#   mewjector        version.dll proxy + MJ_* mod API  (githubuser508)
#   mewgenics-ui-api MewUI scene/button/text helpers   (Pseudonym-Tim)
#
# The official Mewjector release `version.dll` is used as the shipped loader:
# it links its CRT statically and imports only KERNEL32.dll. A zig/mingw build of
# the same source imports api-ms-win-crt-* and fails to load under Proton.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
upstream="$here/upstream"

MEWJECTOR_URL="https://github.com/githubuser508/mewjector"
MEWJECTOR_REV="ccdd6813cef0f51342eb74c0cecb47654f7dbeef"
MEWJECTOR_RELEASE_URL="https://github.com/githubuser508/mewjector/releases/download/v3.4/release.zip"
MEWJECTOR_DLL_SHA256="ecb11b059d94347eb14f696a80d461c3305a8fc8dcebabe3fe196fadeeb7a3c2"

MEWUI_URL="https://github.com/Pseudonym-Tim/mewgenics-ui-api"
MEWUI_REV="fffef60696c50f0748052da8e6a1fb12dfaabbe9"

fetch_repo() {
  local name="$1" url="$2" rev="$3" dest="$upstream/$1"
  if [ -d "$dest/.git" ] && [ "$(git -C "$dest" rev-parse HEAD 2>/dev/null)" = "$rev" ]; then
    echo "  $name already at $rev"
    return 0
  fi
  rm -rf "$dest"
  git clone --quiet "$url" "$dest"
  git -C "$dest" checkout --quiet "$rev"
  echo "  $name -> $rev"
}

fetch_mewjector_release() {
  python3 - "$MEWJECTOR_RELEASE_URL" "$MEWJECTOR_DLL_SHA256" "$upstream/mewjector/release" <<'PY'
import hashlib, io, pathlib, sys, urllib.request, zipfile

url, want, dest_arg = sys.argv[1], sys.argv[2], sys.argv[3]
dest = pathlib.Path(dest_arg)
dest.mkdir(parents=True, exist_ok=True)
dll = dest / "version.dll"

if dll.exists() and hashlib.sha256(dll.read_bytes()).hexdigest() == want:
    print("  mewjector release already verified")
    raise SystemExit(0)

data = urllib.request.urlopen(url).read()
archive = zipfile.ZipFile(io.BytesIO(data))
for member in ("release/version.dll", "release/chainloader.ini"):
    (dest / member.split("/")[-1]).write_bytes(archive.read(member))

got = hashlib.sha256(dll.read_bytes()).hexdigest()
if got != want:
    raise SystemExit(f"sha256 mismatch for version.dll: {got} != {want}")
print("  mewjector release downloaded and verified")
PY
}

mkdir -p "$upstream"
echo "Syncing vendored upstream sources into $upstream"
fetch_repo mewjector "$MEWJECTOR_URL" "$MEWJECTOR_REV"
fetch_repo mewui "$MEWUI_URL" "$MEWUI_REV"
fetch_mewjector_release
echo "Done."
