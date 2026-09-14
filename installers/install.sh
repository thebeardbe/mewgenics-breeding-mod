#!/usr/bin/env bash
# Install the Mewgenics Breeding mod under Linux/Proton, NixOS included.
#
#   ./install.sh                  install into the game in your Steam libraries
#   ./install.sh --dry-run        report what would happen, change nothing
#   ./install.sh --uninstall      remove files this script installed, restore backups
#   ./install.sh --game-dir DIR   override the game folder
#
# Set MEWGENICS_DIR instead of --game-dir if you prefer that. The three
# artifacts must sit beside this script: version.dll, chainloader.ini,
# BreedingSpike.dll. The loader is a native proxy that shadows the system
# version.dll by living next to the game exe; the mod DLL goes into mods/.
#
# Achievements stay ON: nothing here passes -modpaths or enables the debug
# console, the only two things the game checks before it disables them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source file beside this script -> path under the game folder. One list keeps
# install, uninstall and the payload check in agreement.
TARGETS=(
  "version.dll:version.dll"
  "chainloader.ini:chainloader.ini"
  "BreedingSpike.dll:mods/BreedingSpike.dll"
)

# Install record written after a successful install. One target path per line,
# relative to the game folder. Uninstall only touches what this file lists.
MANIFEST_REL="mods/.breeding-spike-installed"

# Mewgenics' Steam app id, used only to locate the Proton prefix in compatdata.
MEWGENICS_APPID=686060

DRY_RUN=0
UNINSTALL=0
GAME_DIR="${MEWGENICS_DIR:-}"

usage() {
  cat <<'EOF'
Usage: install.sh [--dry-run] [--uninstall] [--game-dir DIR]

  (no flags)         install the mod into the Mewgenics game folder
  --dry-run          report what would happen and change nothing
  --uninstall        remove the files this script installed and restore backups
  --game-dir DIR     use DIR as the game folder (overrides MEWGENICS_DIR)
  -h, --help         show this help
EOF
}

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '       %s\n' "$*"; }
ok()   { printf '  ok   %s\n' "$*"; }
warn() { printf '  warn %s\n' "$*"; }
plan() { printf ' [dry] %s\n' "$*"; }

# The Wine-registry override lives in its own file to keep this script small.
# shellcheck source=./proton-registry.sh
if [ ! -f "$SCRIPT_DIR/proton-registry.sh" ]; then
  die "proton-registry.sh is missing from $SCRIPT_DIR"
fi
. "$SCRIPT_DIR/proton-registry.sh"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --game-dir)
      [ "$#" -ge 2 ] || die "--game-dir needs a folder"
      GAME_DIR="$2"
      shift
      ;;
    --game-dir=*) GAME_DIR="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

steam_roots() {
  # Steam's location depends on how it was packaged. Flatpak and snap keep
  # their own copies of the same layout.
  local candidate
  for candidate in \
    "$HOME/.steam/steam" \
    "$HOME/.local/share/Steam" \
    "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam" \
    "$HOME/snap/steam/common/.local/share/Steam"
  do
    if [ -d "$candidate/steamapps" ]; then
      printf '%s\n' "$candidate"
    fi
  done
}

steam_libraries() {
  # The Steam root plus every additional library listed in libraryfolders.vdf.
  local root vdf path
  while IFS= read -r root; do
    printf '%s\n' "$root"
    vdf="$root/steamapps/libraryfolders.vdf"
    [ -f "$vdf" ] || continue
    # Lines look like: "path"    "/games/SteamLibrary"
    while IFS= read -r path; do
      if [ -n "$path" ]; then
        printf '%s\n' "$path"
      fi
    done < <(sed -n 's/.*"path"[[:space:]]*"\([^"]*\)".*/\1/p' "$vdf")
  done < <(steam_roots)
}

find_game_dir() {
  local lib dir
  while IFS= read -r lib; do
    dir="$lib/steamapps/common/Mewgenics"
    if [ -f "$dir/Mewgenics.exe" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done < <(steam_libraries)
  return 1
}

find_proton_prefix() {
  local lib pfx
  while IFS= read -r lib; do
    pfx="$lib/steamapps/compatdata/$MEWGENICS_APPID/pfx"
    if [ -d "$pfx" ]; then
      printf '%s\n' "$pfx"
      return 0
    fi
  done < <(steam_libraries)
  return 1
}

game_running() {
  # A running game has version.dll loaded, so replacing it is unsafe. Proton
  # runs the game with comm "Mewgenics.exe" (see RESEARCH.md "Live shape of the
  # game process"), so match the exact process name rather than any command
  # line that merely mentions it.
  pgrep -x 'Mewgenics.exe' >/dev/null 2>&1
}

require_game_closed() {
  if game_running; then
    die "Mewgenics is running. Close the game, then run this again."
  fi
}

backup_path() {
  # Beside the file it replaces, with a timestamp so no backup is overwritten.
  # The numeric suffix handles two backups in the same second.
  local target="$1" stamp candidate n=1
  stamp="$(date +%Y%m%d-%H%M%S)"
  candidate="$target.$stamp.bak"
  while [ -e "$candidate" ]; do
    candidate="$target.$stamp.$n.bak"
    n=$((n + 1))
  done
  printf '%s\n' "$candidate"
}

newest_backup() {
  # Pick the newest backup for one target. The names carry their creation stamp
  # and, when two backups landed in the same second, a collision counter:
  #   version.dll.20260914-130739.bak
  #   version.dll.20260914-130739.1.bak
  # Plain text order cannot be trusted here: it puts "...130739.1.bak" before
  # "...130739.bak" ('1' < 'b') and would restore the older file. Compare the
  # parsed stamp instead, with the counter as a numeric tiebreaker.
  local stem="$1"; shift
  local candidate middle stamp suffix key best='' best_key=''
  for candidate in "$@"; do
    middle="${candidate##*/}"
    middle="${middle#"$stem".}"
    middle="${middle%.bak}"
    stamp="${middle%%.*}"
    suffix=0
    case "$middle" in
      *.*) suffix="${middle##*.}" ;;
    esac
    case "$suffix" in
      ''|*[!0-9]*) suffix=0 ;;
    esac
    # The stamp is fixed width; zero-pad the counter so 10 sorts after 2.
    printf -v key '%s %010d' "$stamp" "$suffix"
    if [ -z "$best" ] || [[ "$key" > "$best_key" ]]; then
      best="$candidate"
      best_key="$key"
    fi
  done
  printf '%s\n' "$best"
}

ere_escape() {
  # Escape ERE metacharacters so a file name can be embedded in a regex.
  printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g'
}

list_backups() {
  # Backups this installer itself can have made, and nothing else:
  #   <leaf>.<YYYYMMDD-HHMMSS>.bak
  #   <leaf>.<YYYYMMDD-HHMMSS>.<n>.bak
  # A stray file such as version.dll.old.bak must never be treated as a backup.
  local dir="$1" leaf="$2" candidate base
  local pattern="^$(ere_escape "$leaf")\\.[0-9]{8}-[0-9]{6}(\\.[0-9]+)?\\.bak$"
  local -a found=()
  if [ -d "$dir" ]; then
    shopt -s nullglob
    for candidate in "$dir/$leaf".*.bak; do
      base="${candidate##*/}"
      if [[ "$base" =~ $pattern ]]; then
        found+=("$candidate")
      fi
    done
    shopt -u nullglob
  fi
  if [ "${#found[@]}" -gt 0 ]; then
    printf '%s\n' "${found[@]}"
  fi
}

same_content() {
  # Content compare; a missing target is never "same".
  [ -f "$2" ] && cmp -s "$1" "$2"
}

manifest_has() {
  # Fixed-string match; tolerate CRLF in a record a Windows install may write.
  local manifest="$1" rel="$2"
  [ -f "$manifest" ] || return 1
  tr -d '\r' < "$manifest" | grep -Fxq "$rel"
}

write_manifest_paths() {
  # Rewrite an install record to exactly the given target paths, one per line.
  # A temporary file keeps the record intact if writing is interrupted.
  local manifest="$1"; shift
  local tmp="$manifest.tmp" rel
  mkdir -p "$(dirname "$manifest")"
  : > "$tmp"
  for rel in "$@"; do
    printf '%s\n' "$rel" >> "$tmp"
  done
  mv -f "$tmp" "$manifest"
}

write_manifest() {
  # Record the targets now in place. Called only after the copies succeed, so a
  # failed install never claims a file this script did not write.
  local game_dir="$1" rel entry
  local -a records=()
  for entry in "${TARGETS[@]}"; do
    rel="${entry#*:}"
    if same_content "$SCRIPT_DIR/${entry%%:*}" "$game_dir/$rel"; then
      records+=("$rel")
    fi
  done
  write_manifest_paths "$game_dir/$MANIFEST_REL" ${records[@]+"${records[@]}"}
}

check_payload() {
  # Fail before touching the game folder when the bundle is incomplete.
  local entry missing=()
  for entry in "${TARGETS[@]}"; do
    if [ ! -f "$SCRIPT_DIR/${entry%%:*}" ]; then
      missing+=("$SCRIPT_DIR/${entry%%:*}")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    printf 'error: the installer payload is incomplete. These files must sit beside install.sh:\n' >&2
    printf '       %s\n' "${missing[@]}" >&2
    die "unpack the whole release folder before running this"
  fi
}

do_install() {
  local game_dir="$1"
  check_payload
  require_game_closed

  local entry src rel dst dst_dir backup
  local written=0 current=0 backed=0

  for entry in "${TARGETS[@]}"; do
    src="$SCRIPT_DIR/${entry%%:*}"
    rel="${entry#*:}"
    dst="$game_dir/$rel"
    dst_dir="$(dirname "$dst")"

    if same_content "$src" "$dst"; then
      ok "$rel is already up to date"
      current=$((current + 1))
      continue
    fi

    if [ ! -d "$dst_dir" ]; then
      if [ "$DRY_RUN" = 1 ]; then
        plan "create folder $dst_dir"
      else
        mkdir -p "$dst_dir"
        info "created $dst_dir"
      fi
    fi

    if [ -f "$dst" ]; then
      backup="$(backup_path "$dst")"
      if [ "$DRY_RUN" = 1 ]; then
        plan "back up $rel to $(basename "$backup")"
      else
        cp -p "$dst" "$backup"
        warn "backed up existing $rel to $(basename "$backup")"
        backed=$((backed + 1))
      fi
    fi

    if [ "$DRY_RUN" = 1 ]; then
      plan "copy ${entry%%:*} to $dst"
    else
      cp "$src" "$dst"
      ok "installed $rel"
      written=$((written + 1))
    fi
  done

  if [ "$DRY_RUN" = 1 ]; then
    printf '\n'
    info "dry run complete: nothing was changed."
    return
  fi

  write_manifest "$game_dir"
  printf '\n'
  info "install complete: $written written, $current already up to date, $backed backed up."
  info "recorded the installed files in $MANIFEST_REL"
}

do_uninstall() {
  local game_dir="$1"
  require_game_closed

  local manifest="$game_dir/$MANIFEST_REL"
  local entry rel dst src dst_dir leaf backup
  local removed=0 restored=0 left=0
  local -a kept=()
  local -a backups

  if [ ! -f "$manifest" ]; then
    warn "no record of an install by this script ($MANIFEST_REL is missing)."
    info "leaving everything as it is; nothing was removed."
    for entry in "${TARGETS[@]}"; do
      rel="${entry#*:}"
      if [ -e "$game_dir/$rel" ]; then
        warn "left $rel: this script has no record of installing it"
        left=$((left + 1))
      fi
    done
    printf '\n'
    if [ "$DRY_RUN" = 1 ]; then
      info "dry run complete: nothing was changed."
    else
      info "uninstall complete: 0 removed, 0 restored, $left left in place."
    fi
    return
  fi

  for entry in "${TARGETS[@]}"; do
    rel="${entry#*:}"
    dst="$game_dir/$rel"
    src="$SCRIPT_DIR/${entry%%:*}"
    dst_dir="$(dirname "$dst")"
    leaf="$(basename "$dst")"

    if ! manifest_has "$manifest" "$rel"; then
      if [ -e "$dst" ]; then
        warn "left $rel: not recorded as installed by this script"
        left=$((left + 1))
        kept+=("$rel")
      else
        info "$rel is not installed"
      fi
      continue
    fi

    # The record says this script put the file there. Touch it only while the
    # content still matches the bundle, so a user's replacement is left alone.
    if [ -f "$dst" ]; then
      if [ ! -f "$src" ]; then
        warn "left $rel: cannot verify it against the bundle ($(basename "$src") is missing)"
        left=$((left + 1))
        kept+=("$rel")
        continue
      fi
      if ! same_content "$src" "$dst"; then
        warn "left $rel: it was modified after this script installed it"
        left=$((left + 1))
        kept+=("$rel")
        continue
      fi
    fi

    mapfile -t backups < <(list_backups "$dst_dir" "$leaf")

    if [ "${#backups[@]}" -gt 0 ]; then
      backup="$(newest_backup "$leaf" "${backups[@]}")"
      if [ "$DRY_RUN" = 1 ]; then
        plan "restore $rel from $(basename "$backup")"
      else
        rm -f "$dst"
        cp -p "$backup" "$dst"
        ok "restored $rel from $(basename "$backup") (backup kept)"
        restored=$((restored + 1))
      fi
    elif [ -f "$dst" ]; then
      if [ "$DRY_RUN" = 1 ]; then
        plan "remove $rel"
      else
        rm -f "$dst"
        ok "removed $rel"
        removed=$((removed + 1))
      fi
    else
      info "$rel is not installed"
    fi
  done

  printf '\n'
  if [ "$DRY_RUN" = 1 ]; then
    info "dry run complete: nothing was changed."
  else
    if [ "${#kept[@]}" -gt 0 ]; then
      write_manifest_paths "$manifest" "${kept[@]}"
      if [ "${#kept[@]}" -eq 1 ]; then
        info "kept install record $MANIFEST_REL: 1 file is still installed, so a later run can clean it up."
      else
        info "kept install record $MANIFEST_REL: ${#kept[@]} files are still installed, so a later run can clean them up."
      fi
    else
      rm -f "$manifest"
      info "removed install record $MANIFEST_REL"
    fi
    info "uninstall complete: $removed removed, $restored restored from backup, $left left in place."
  fi
}

main() {
  local game_dir prefix

  if [ -n "$GAME_DIR" ]; then
    game_dir="$GAME_DIR"
  else
    game_dir="$(find_game_dir)" || die "Mewgenics was not found in any Steam library. Pass --game-dir DIR or set MEWGENICS_DIR."
  fi

  [ -d "$game_dir" ] || die "game folder does not exist: $game_dir"
  if [ ! -f "$game_dir/Mewgenics.exe" ]; then
    warn "Mewgenics.exe not found under $game_dir; using it anyway."
  fi

  local mode='install'
  if [ "$UNINSTALL" = 1 ]; then
    mode='uninstall'
  fi
  if [ "$DRY_RUN" = 1 ]; then
    mode="$mode (dry run)"
  fi

  printf '\nMewgenics Breeding mod installer (%s)\n\n' "$mode"
  info "game folder: $game_dir"

  if [ "$UNINSTALL" = 1 ]; then
    do_uninstall "$game_dir"
  else
    do_install "$game_dir"
    printf '\n'
    print_launch_option
    printf '\n'
    if prefix="$(find_proton_prefix)"; then
      offer_prefix_override "$prefix"
    else
      info "no Proton prefix found; use the Steam launch option above."
    fi
  fi

  printf '\n'
  printf '*** ACHIEVEMENTS STAY ON: nothing here passes -modpaths or enables the debug console, the only two things the game checks before it disables Steam achievements. ***\n'
}

main "$@"
