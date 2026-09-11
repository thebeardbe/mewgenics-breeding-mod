#!/usr/bin/env bash
# Install or remove the spike in the local Steam Mewgenics install.
#
#   ./tools/install_game.sh            # copy artifacts into the game dir
#   ./tools/install_game.sh --uninstall
#
# Linux/Proton only (this script assumes the Steam library in $HOME). On Windows
# copy the files manually: version.dll + chainloader.ini into the game folder,
# BreedingSpike.dll into mods/.
set -euo pipefail
cd "$(dirname "$0")/.."

GAME_DIR="${MEWGENICS_DIR:-$HOME/.local/share/Steam/steamapps/common/Mewgenics}"
DIST="dist"

if [ ! -d "$GAME_DIR" ]; then
  echo "error: game dir not found: $GAME_DIR" >&2
  echo "set MEWGENICS_DIR to override" >&2
  exit 1
fi

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$GAME_DIR/version.dll" "$GAME_DIR/chainloader.ini" "$GAME_DIR/mods/BreedingSpike.dll"
  echo "removed version.dll, chainloader.ini, mods/BreedingSpike.dll from $GAME_DIR"
  echo "mod_logs/ was left in place; delete it manually if you want it gone."
  exit 0
fi

if [ ! -f "$DIST/version.dll" ] || [ ! -f "$DIST/BreedingSpike.dll" ]; then
  echo "error: dist artifacts missing; run ./build.sh first" >&2
  exit 1
fi

# A pre-existing version.dll would mean another version.dll mod is installed.
if [ -f "$GAME_DIR/version.dll" ]; then
  backup="$GAME_DIR/version.dll.premod-backup"
  if [ ! -f "$backup" ]; then
    cp "$GAME_DIR/version.dll" "$backup"
    echo "notice: backed up existing version.dll to $(basename "$backup")"
  fi
fi

mkdir -p "$GAME_DIR/mods"
cp "$DIST/version.dll" "$GAME_DIR/version.dll"
cp "$DIST/chainloader.ini" "$GAME_DIR/chainloader.ini"
cp "$DIST/BreedingSpike.dll" "$GAME_DIR/mods/BreedingSpike.dll"

cat <<EOF

Installed into: $GAME_DIR
  version.dll
  chainloader.ini
  mods/BreedingSpike.dll

Required: force Wine to load our version.dll instead of its builtin one.
Steam -> Mewgenics -> Properties -> Launch Options:

  WINEDLLOVERRIDES="version=n" %command%

Then launch the game and load a save, and read:

  $GAME_DIR/mod_logs/chainloader.log

Remove with: ./tools/install_game.sh --uninstall
EOF
