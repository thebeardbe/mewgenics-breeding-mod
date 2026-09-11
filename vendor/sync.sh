#!/usr/bin/env bash
# Fetch the pinned upstream sources this mod builds against.
#
# We do not commit upstream code. This keeps the repo small and makes the
# exact revision we depend on explicit. Re-run after editing the pins.
#
#   ./vendor/sync.sh
#
# Sources (both MIT):
#   mewjector        version.dll proxy + MJ_* mod API  (githubuser508)
#   mewgenics-ui-api MewUI scene/button/text helpers   (Pseudonym-Tim)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
upstream="$here/upstream"

MEWJECTOR_URL="https://github.com/githubuser508/mewjector"
MEWJECTOR_REV="ccdd6813cef0f51342eb74c0cecb47654f7dbeef"

MEWUI_URL="https://github.com/Pseudonym-Tim/mewgenics-ui-api"
MEWUI_REV="fffef60696c50f0748052da8e6a1fb12dfaabbe9"

fetch() {
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

mkdir -p "$upstream"
echo "Syncing vendored upstream sources into $upstream"
fetch mewjector "$MEWJECTOR_URL" "$MEWJECTOR_REV"
fetch mewui "$MEWUI_URL" "$MEWUI_REV"
echo "Done."
