#!/usr/bin/env bash
# Uninstall the Mewgenics Breeding mod under Linux/Proton, NixOS included.
#
#   ./uninstall.sh                  ask, then remove what install.sh installed
#   ./uninstall.sh --dry-run        ask, then report what would change
#   ./uninstall.sh --game-dir DIR   override the game folder
#
# Removal itself is install.sh --uninstall: this script only adds the
# confirmation, so install and uninstall keep one implementation. It asks with
# the resolved game folder, which it learns from a read-only dry run of that
# same path, so the Steam lookup also lives in one place.
#
# Nothing is removed unless the answer is yes, and with no terminal to ask on
# it stops instead of guessing. Running it twice is fine: the second run finds
# no install record and says so.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/install.sh"

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--dry-run] [--game-dir DIR]

  (no flags)         ask, then remove the files install.sh installed
  --dry-run          ask, then report what would be restored, changing nothing
  --game-dir DIR     use DIR as the game folder (overrides MEWGENICS_DIR)
  -h, --help         show this help

The removal is done by install.sh --uninstall; see the bundle's README.md and
docs/HOW-IT-WORKS.md.
EOF
}

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# Answer --help here, before any prompt. A value that belongs to --game-dir is
# skipped, so a folder literally named "--help" is not read as the flag.
want_help=0
skip_value=0
for arg in "$@"; do
  if [ "$skip_value" = 1 ]; then
    skip_value=0
    continue
  fi
  case "$arg" in
    --game-dir) skip_value=1 ;;
    -h|--help)  want_help=1 ;;
  esac
done
if [ "$want_help" = 1 ]; then
  usage
  exit 0
fi

if [ ! -f "$INSTALLER" ]; then
  die "install.sh is missing from $SCRIPT_DIR. Unpack the whole release folder."
fi

if [ ! -t 0 ]; then
  die "uninstalling needs a yes/no confirmation and standard input is not a terminal. Run this in a terminal, or run install.sh --uninstall directly."
fi

# Read-only dry run first: it resolves the game folder, or fails with the
# reason (the game still running, no game folder found). The question below
# therefore names the real folder rather than a guess.
report="$("$INSTALLER" --uninstall --dry-run "$@")" || {
  rc=$?
  printf '%s\n' "$report" >&2
  printf 'error: nothing was removed (installer exited with code %s).\n' "$rc" >&2
  exit "$rc"
}

# The installer's own line: seven spaces, "game folder: ", then the path.
game_dir="$(printf '%s\n' "$report" | sed -n 's/^ *game folder: //p')"
if [ -z "$game_dir" ]; then
  printf '%s\n' "$report" >&2
  die "could not read the game folder from the installer's report, so nothing was removed. Run install.sh --uninstall directly."
fi

printf '\nThis removes the Mewgenics Breeding mod from:\n\n    %s\n\n' "$game_dir"
printf 'Remove it? [y/N] '
answer=''
read -r answer || answer=''
case "$answer" in
  [yY]|[yY][eE][sS]) ;;
  *)
    printf '\nNothing was removed.\n'
    exit 0
    ;;
esac

printf '\n'
"$INSTALLER" --uninstall "$@"
