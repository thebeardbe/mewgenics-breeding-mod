#!/usr/bin/env bash
# Proton/Wine side of install.sh: the launch-option message and the optional
# DLL override written into the game's prefix. Sourced by install.sh, not run on
# its own; it uses that script's DRY_RUN, info/ok/plan/die helpers.
#
# The override is what Wine's own "version=n,b" means, persisted per
# application: load our native version.dll, fall back to the builtin elsewhere.

print_launch_option() {
  cat <<'EOF'
Required for Linux/Proton, set once per game, in Steam:

  Steam -> Mewgenics -> Properties -> Launch Options

  WINEDLLOVERRIDES="version=n,b" %command%

Why: Wine prefers its builtin version.dll, so our proxy only runs when it is
forced to native. The ",b" is not optional: "version=n" alone forces our 64-bit
DLL on every process in the prefix, 32-bit processes fail to load it, and the
game launch aborts silently. ",b" falls back to the builtin elsewhere.
EOF
}

prefix_override_reg() {
  # Add or update the Wine AppDefaults DLL override for Mewgenics.exe in a
  # user.reg. Reads the old file on stdin, writes the new one on stdout, and is
  # idempotent: running it twice changes nothing. $1 is the section timestamp.
  local now="$1"
  awk -v now="$now" '
    function section(line,   s) {
      if (line !~ /^\[/) return ""
      s = line
      sub(/^\[/, "", s)
      sub(/\].*$/, "", s)
      return s
    }
    BEGIN {
      key = "Software\\\\Wine\\\\AppDefaults\\\\Mewgenics.exe\\\\DllOverrides"
      in_section = 0
      seen = 0
      wrote = 0
    }
    {
      sec = section($0)
      if (sec != "") {
        if (in_section && !wrote) { print "\"version\"=\"native,builtin\""; wrote = 1 }
        in_section = (sec == key)
        if (in_section) seen = 1
        print
        next
      }
      if (in_section && $0 ~ /^"version"[ \t]*=/) {
        if (!wrote) { print "\"version\"=\"native,builtin\""; wrote = 1 }
        next
      }
      print
    }
    END {
      if (in_section && !wrote) { print "\"version\"=\"native,builtin\""; wrote = 1 }
      if (!seen) {
        print ""
        print "[" key "] " now
        print "\"version\"=\"native,builtin\""
      }
    }
  '
}

write_prefix_override() {
  local prefix="$1" reg="$1/user.reg" tmp
  [ -f "$reg" ] || die "no user.reg under $prefix; cannot write the override"
  tmp="$(mktemp)"
  if prefix_override_reg "$(date +%s)" < "$reg" > "$tmp"; then
    mv "$tmp" "$reg"
  else
    rm -f "$tmp"
    die "failed to update $reg"
  fi
}

offer_prefix_override() {
  # Asks before touching the prefix. A dry run never writes to a real prefix.
  local prefix="$1" answer
  info "found Proton prefix: $prefix"

  if [ "$DRY_RUN" = 1 ]; then
    info "dry run: would offer to write the version=n,b override into that prefix."
    return 0
  fi

  printf '\nWrite the version=n,b override into that prefix now? [y/N] '
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES) ;;
    *) info "left the prefix untouched."; return 0 ;;
  esac

  write_prefix_override "$prefix"
  ok "wrote version=n,b into $prefix/user.reg"
  info "you can drop the Steam launch option now, if you had set it."
}
