# lib/hooks.sh — fast check for whether Claude Code hooks are wired.
#
# Functions:
#   hooks::installed [settings_path]
#       Return 0 if the supplied settings.json (default: $HOME/.claude/settings.json,
#       overridable via $CLAUDE_SETTINGS env var) contains an entry pointing at
#       this plugin's bin/hook. Caches the verification by settings-file mtime
#       so the lookup is a stat() on hot paths instead of a full jq run.
#
#   hooks::_verify_uncached <settings_path>
#       Internal: the actual jq check, exposed as a seam so tests can exercise
#       the verifier without going through the cache layer.
#
#   hooks::clear_sentinel
#       Internal/test: remove the sentinel cache file. Tests use this to force
#       a cache miss without having to touch settings.
#
# Depends on lib/state.sh (for state::cache_dir). Caller must source it first.
# No shebang. set -u clean. Re-source-safe.

# Compute the mtime of a file as a unix-epoch integer, with GNU-vs-BSD fallback.
_hooks_mtime() {
  local path="$1"
  date -r "$path" +%s 2>/dev/null \
    || stat -c %Y "$path" 2>/dev/null \
    || stat -f %m "$path" 2>/dev/null \
    || echo 0
}

# Compute a compact cache fingerprint for the settings file: <mtime>:<crc>:<size>.
# mtime is the cheap discriminator; <crc>:<size> from cksum (POSIX, ubiquitous,
# ~0.2ms on a typical settings.json) is the sub-second tiebreaker that catches
# same-wall-clock-second edits on coarse-mtime filesystems (HFS+, FAT, exFAT).
# A missing/unreadable file fingerprints to "0::0".
_hooks_fingerprint() {
  local path="$1"
  if [ ! -r "$path" ]; then
    printf '0::0'
    return 0
  fi
  local mtime sum
  mtime="$(_hooks_mtime "$path")"
  # cksum prints "<crc> <size> [path]"; we want the first two fields only.
  sum="$(cksum <"$path" 2>/dev/null | awk '{ printf "%s:%s", $1, $2 }')"
  [ -n "$sum" ] || sum=":"
  printf '%s:%s' "$mtime" "$sum"
}

# The jq filter that detects our hook entries in settings.json. Walks both
# the modern array-shaped event values AND the legacy nested-object shape
# (e.g. .hooks.PreToolUse = {"Bash": [...]}) that install/uninstall-hooks
# normalize. Matching the command substring is sufficient because
# install-hooks always writes a fully-qualified path containing
# "tmux-coding-agents/bin/hook".
hooks::_verify_uncached() {
  local settings="$1"
  [ -r "$settings" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '
    # commands_of(v) yields every hook-command string under an event value,
    # walking both shapes that install/uninstall accept:
    #   modern: v is an array of {matcher, hooks: [{type, command}]}
    #   legacy: v is an object { matcher_name: [{type, command}] }
    def commands_of(v):
      if (v | type) == "array" then
        v[]? | (.hooks // [])[]? | (.command // "")
      elif (v | type) == "object" then
        v[]? | (
          if type == "array" then .[]? | (.command // "")
          elif type == "object" and (.command | type) == "string" then .command
          else empty
          end
        )
      else empty
      end;
    (.hooks // {})
    | to_entries
    | any(commands_of(.value) | contains("tmux-coding-agents/bin/hook"))
  ' "$settings" >/dev/null 2>&1
}

hooks::clear_sentinel() {
  local cache_dir tag
  cache_dir="$(state::cache_dir 2>/dev/null)" || return 0
  tag="$cache_dir/.hooks-installed"
  rm -f "$tag" 2>/dev/null || true
}

hooks::installed() {
  local settings="${1:-${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}}"
  local cache_dir tag fp_at_entry fp_tag
  cache_dir="$(state::cache_dir 2>/dev/null)" || return 1
  tag="$cache_dir/.hooks-installed"

  # Capture a compact fingerprint ONCE per call: <mtime>:<crc>:<size>. The
  # same value drives both the cache-validity check and the sentinel write,
  # closing a TOCTOU where a touch landing during jq would cause a future
  # call to skip verification on content we never actually verified.
  fp_at_entry="$(_hooks_fingerprint "$settings")"

  # Sentinel hit: exact-match on the full fingerprint. mtime alone is
  # vulnerable to same-wall-clock-second edits on coarse filesystems (HFS+,
  # FAT, exFAT) AND to backward mtime changes (cp -p, restore-from-bak,
  # touch -t). The mtime+crc+size combination defends against both: a
  # same-second edit changes the crc; a backward mtime moves the entire
  # fingerprint away from the cached value.
  case "$fp_at_entry" in
    0:*) ;;
    *)
      if [ -r "$tag" ]; then
        fp_tag="$(cat "$tag" 2>/dev/null || true)"
        if [ -n "$fp_tag" ] && [ "$fp_tag" = "$fp_at_entry" ]; then
          return 0
        fi
      fi
      ;;
  esac

  # Cache miss → verify with jq. On success, record the fingerprint captured
  # BEFORE jq ran. If the file was edited during jq, the captured fingerprint
  # is pre-edit; the next call sees a different fingerprint and re-verifies.
  if hooks::_verify_uncached "$settings"; then
    printf '%s' "$fp_at_entry" >"$tag" 2>/dev/null || true
    return 0
  fi
  return 1
}
