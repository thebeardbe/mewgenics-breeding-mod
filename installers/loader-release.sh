#!/usr/bin/env bash
# Choose which Mewjector loader install.sh puts in the game folder: the
# bundled patched build, or the official loader from the latest upstream
# release once it carries our startup-hang fix (PR #6).
#
# Sourced by install.sh; not run on its own. It uses that script's DRY_RUN and
# its info/warn/die helpers.
#
# Why the bundle ships a patched loader: the official Mewjector v3.4 loader
# hangs on some Proton/Wine launches because it always installs its
# entry-point fallback. PR #6 adds the Chainloader/EnableEPFallback option (and
# makes Logging=0 actually suppress output). Until that fix lands upstream the
# bundle ships the patched build; the installer switches to upstream
# automatically once the release's chainloader.ini contains EnableEPFallback.
#
# MEWJECTOR_RELEASE_OVERRIDE (environment variable): a trusted developer and
# mirror hook that points the upstream check at a local stand-in. It is
# deliberately NOT verified: it exists for the installers' offline checks, for
# development, and for users who must obtain the release through a mirror. Only
# point it at a loader you trust. Accepted values:
#
#   <directory>   an unpacked release (version.dll + chainloader.ini)
#   <file>.ini    a release's chainloader.ini; version.dll is read from the
#                 same folder
#   <metadata>    a small text file with a `directory=<path>` line naming an
#                 unpacked release (a `chainloader_ini=<path>` line also works)
#
# A relative `chainloader_ini=` path is resolved against the metadata file's
# own folder, as `directory=` already is, so the result does not depend on the
# working directory the installer was launched from.
#
# Without the variable the installer asks the official Mewjector GitHub
# release API for the latest release and downloads its .zip asset over HTTPS.
# That is the only loader accepted from the network; anything else is refused.
# The source URL and the SHA-256 of the installed version.dll are printed so
# the result can be checked against the release.

MEWJECTOR_REPO="githubuser508/mewjector"
MEWJECTOR_LATEST_API="https://api.github.com/repos/${MEWJECTOR_REPO}/releases/latest"

# Result of select_loader. LOADER_KIND is "bundled" or "upstream"; LOADER_DIR
# is set only for "upstream"; LOADER_REASON is the one-line explanation.
LOADER_KIND="bundled"
LOADER_DIR=""
LOADER_TAG=""
LOADER_URL=""
LOADER_ORIGIN=""
LOADER_REASON=""
LOADER_SELECTED=0

# Scratch state for one release lookup. LOADER_TMP is removed on exit.
LOADER_TMP=""
LOADER_FETCH_DIR=""
LOADER_FETCH_INI=""
LOADER_FETCH_TAG=""
LOADER_FETCH_REASON=""
LOADER_FETCH_URL=""
LOADER_FETCH_ORIGIN=""
LOADER_OVERRIDE_DIR=""
LOADER_OVERRIDE_INI=""

loader_release_cleanup() {
  if [ -n "$LOADER_TMP" ] && [ -d "$LOADER_TMP" ]; then
    rm -rf "$LOADER_TMP"
  fi
  LOADER_TMP=""
}

loader_http_get() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 30 -H 'User-Agent: mewgenics-breeding-mod-installer' "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --timeout=30 --header='User-Agent: mewgenics-breeding-mod-installer' "$1"
  else
    return 1
  fi
}

loader_http_download() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 120 -H 'User-Agent: mewgenics-breeding-mod-installer' -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=120 --header='User-Agent: mewgenics-breeding-mod-installer' -O "$2" "$1"
  else
    return 1
  fi
}

loader_extract_zip() {
  local archive="$1" dest="$2"
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$archive" -d "$dest"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$archive" "$dest" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
  else
    return 1
  fi
}

# Upstream release JSON: the tag and the first .zip asset URL.
loader_json_tag() {
  printf '%s' "$1" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

loader_json_zip_url() {
  printf '%s' "$1" \
    | tr ',' '\n' \
    | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | grep -i '\.zip$' \
    | head -n1
}

# Turn MEWJECTOR_RELEASE_OVERRIDE into LOADER_OVERRIDE_DIR + LOADER_OVERRIDE_INI.
loader_override_paths() {
  local target="$1" value
  LOADER_OVERRIDE_DIR=""
  LOADER_OVERRIDE_INI=""

  if [ -d "$target" ]; then
    LOADER_OVERRIDE_DIR="$target"
    LOADER_OVERRIDE_INI="$target/chainloader.ini"
    return 0
  fi
  if [ ! -f "$target" ]; then
    LOADER_FETCH_REASON="override path does not exist: $target"
    return 1
  fi

  # An ini file: use it as-is and read version.dll from the same folder.
  if grep -qE '^[[:space:]]*\[Chainloader\]' "$target" 2>/dev/null; then
    LOADER_OVERRIDE_DIR="$(cd "$(dirname "$target")" && pwd)"
    LOADER_OVERRIDE_INI="$target"
    return 0
  fi

  # A metadata file: `chainloader_ini=` wins, else `directory=`.
  value="$(sed -n 's/^[[:space:]]*chainloader_ini[[:space:]]*=[[:space:]]*//p' "$target" | head -n1)"
  if [ -n "$value" ]; then
    # A relative path is resolved against the metadata file's own folder,
    # exactly as `directory=` is, so the result does not depend on the working
    # directory the installer was launched from.
    case "$value" in
      /*) ;;
      *) value="$(cd "$(dirname "$target")" && pwd)/$value" ;;
    esac
    LOADER_OVERRIDE_DIR="$(dirname "$value")"
    LOADER_OVERRIDE_INI="$value"
    return 0
  fi
  value="$(sed -n 's/^[[:space:]]*directory[[:space:]]*=[[:space:]]*//p' "$target" | head -n1)"
  if [ -z "$value" ]; then
    LOADER_FETCH_REASON="override file is neither an ini nor a metadata file: $target"
    return 1
  fi
  case "$value" in
    /*) ;;
    *) value="$(cd "$(dirname "$target")" && pwd)/$value" ;;
  esac
  LOADER_OVERRIDE_DIR="$value"
  LOADER_OVERRIDE_INI="$value/chainloader.ini"
  return 0
}

# Resolve a release folder and its chainloader.ini, from the override or from
# GitHub. Sets LOADER_FETCH_DIR/INI/TAG/REASON/URL/ORIGIN; returns non-zero on
# failure with LOADER_FETCH_REASON saying why.
loader_fetch_release() {
  LOADER_FETCH_DIR=""
  LOADER_FETCH_INI=""
  LOADER_FETCH_TAG=""
  LOADER_FETCH_REASON=""
  LOADER_FETCH_URL=""
  LOADER_FETCH_ORIGIN=""

  if [ -n "${MEWJECTOR_RELEASE_OVERRIDE:-}" ]; then
    loader_override_paths "$MEWJECTOR_RELEASE_OVERRIDE" || return 1
    if [ ! -d "$LOADER_OVERRIDE_DIR" ]; then
      LOADER_FETCH_REASON="override release folder is missing: $LOADER_OVERRIDE_DIR"
      return 1
    fi
    LOADER_FETCH_DIR="$LOADER_OVERRIDE_DIR"
    LOADER_FETCH_INI="$LOADER_OVERRIDE_INI"
    LOADER_FETCH_TAG="override"
    LOADER_FETCH_ORIGIN="override"
    return 0
  fi

  local json tag url tmp root vdll dir found=""
  json="$(loader_http_get "$MEWJECTOR_LATEST_API")" \
    || { LOADER_FETCH_REASON="could not reach the Mewjector releases API"; return 1; }
  tag="$(loader_json_tag "$json")"
  url="$(loader_json_zip_url "$json")"
  if [ -z "$url" ]; then
    LOADER_FETCH_REASON="the latest release has no .zip asset"
    return 1
  fi
  # Only the official Mewjector GitHub release asset, over HTTPS, may be
  # installed. Anything else is refused: the loader never comes from another
  # source.
  case "$url" in
    "https://github.com/${MEWJECTOR_REPO}/releases/download/"*) ;;
    *)
      LOADER_FETCH_REASON="the release asset is not from the official Mewjector GitHub release"
      return 1
      ;;
  esac

  tmp="$(mktemp -d)" || { LOADER_FETCH_REASON="could not create a temporary folder"; return 1; }
  LOADER_TMP="$tmp"
  loader_http_download "$url" "$tmp/release.zip" \
    || { LOADER_FETCH_REASON="downloading the release failed"; return 1; }
  mkdir -p "$tmp/extracted"
  loader_extract_zip "$tmp/release.zip" "$tmp/extracted" \
    || { LOADER_FETCH_REASON="extracting the release failed"; return 1; }

  # Prefer a version.dll that sits beside a chainloader.ini.
  root="$tmp/extracted"
  while IFS= read -r vdll; do
    dir="$(dirname "$vdll")"
    if [ -f "$dir/chainloader.ini" ]; then
      found="$dir"
      break
    fi
  done < <(find "$root" -type f -name version.dll 2>/dev/null)
  if [ -z "$found" ]; then
    vdll="$(find "$root" -type f -name version.dll 2>/dev/null | head -n1)"
    if [ -n "$vdll" ]; then
      found="$(dirname "$vdll")"
    fi
  fi
  if [ -z "$found" ]; then
    LOADER_FETCH_REASON="the release archive contains no version.dll"
    return 1
  fi

  LOADER_FETCH_DIR="$found"
  LOADER_FETCH_INI="$found/chainloader.ini"
  LOADER_FETCH_TAG="${tag:-latest}"
  LOADER_FETCH_ORIGIN="download"
  LOADER_FETCH_URL="$url"
  return 0
}

# Decide the loader. Always succeeds; the caller reads LOADER_KIND/REASON.
select_loader() {
  LOADER_KIND="bundled"
  LOADER_DIR=""
  LOADER_TAG=""
  LOADER_URL=""
  LOADER_ORIGIN=""
  LOADER_REASON=""
  LOADER_SELECTED=1

  if [ "${BUNDLED_LOADER:-0}" = 1 ]; then
    LOADER_REASON="forced with --bundled-loader"
    return 0
  fi
  if [ "${DRY_RUN:-0}" = 1 ] && [ -z "${MEWJECTOR_RELEASE_OVERRIDE:-}" ]; then
    # A dry run never downloads, and the offline override is left out on
    # purpose only when there is nothing local to read.
    LOADER_REASON="dry run: upstream was not checked"
    return 0
  fi
  if ! loader_fetch_release; then
    LOADER_REASON="could not check upstream (${LOADER_FETCH_REASON:-reason unknown}); using the bundled patched loader"
    return 0
  fi
  if [ ! -f "$LOADER_FETCH_DIR/version.dll" ]; then
    LOADER_REASON="the release has no version.dll; using the bundled patched loader"
    return 0
  fi
  if [ ! -f "$LOADER_FETCH_INI" ]; then
    LOADER_REASON="the release has no chainloader.ini; using the bundled patched loader"
    return 0
  fi
  if grep -qiE '^[[:space:]]*EnableEPFallback[[:space:]]*=' "$LOADER_FETCH_INI"; then
    LOADER_KIND="upstream"
    LOADER_DIR="$LOADER_FETCH_DIR"
    LOADER_TAG="$LOADER_FETCH_TAG"
    LOADER_URL="$LOADER_FETCH_URL"
    LOADER_ORIGIN="$LOADER_FETCH_ORIGIN"
    LOADER_REASON="it carries the EnableEPFallback fix"
  else
    LOADER_REASON="upstream $LOADER_FETCH_TAG does not carry the fix yet; using the bundled patched loader"
  fi
  return 0
}

# One line for the report, printed beside the achievements line.
loader_summary() {
  if [ "$LOADER_KIND" = "upstream" ]; then
    printf 'upstream Mewjector %s - %s' "$LOADER_TAG" "$LOADER_REASON"
  else
    printf 'bundled patched Mewjector - %s' "$LOADER_REASON"
  fi
}

# Provenance for the report. A downloaded upstream loader prints its source
# URL and the SHA-256 of the installed version.dll, so the file can be checked
# against the release. The override is a deliberately unverified trusted hook
# and says so. $1 is the installed version.dll path (may be empty on a dry run).
loader_provenance() {
  local installed="${1:-}" hash=""
  [ "$LOADER_KIND" = "upstream" ] || return 0

  if [ "$LOADER_ORIGIN" = "override" ]; then
    info "source: MEWJECTOR_RELEASE_OVERRIDE=${MEWJECTOR_RELEASE_OVERRIDE:-} (trusted developer/mirror hook; not verified)"
    return 0
  fi

  info "source: $LOADER_URL"
  if [ -z "$installed" ] || [ ! -f "$installed" ]; then
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(sha256sum "$installed" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    hash="$(shasum -a 256 "$installed" | awk '{print $1}')"
  fi
  if [ -n "$hash" ]; then
    info "sha256: $hash  version.dll"
  else
    warn "could not compute the SHA-256 of $installed (no sha256sum or shasum)"
  fi
}

# Source path for a bundle artifact: the chosen release for the loader files,
# the unpacked bundle for everything else.
loader_source_path() {
  local name="$1"
  case "$name" in
    version.dll|chainloader.ini)
      if [ "$LOADER_KIND" = "upstream" ] && [ -n "$LOADER_DIR" ]; then
        printf '%s/%s\n' "$LOADER_DIR" "$name"
        return 0
      fi
      ;;
  esac
  printf '%s/%s\n' "$SCRIPT_DIR" "$name"
}
