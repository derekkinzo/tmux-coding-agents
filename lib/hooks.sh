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
  local cache_dir tag mtime_at_entry mtime_tag
  cache_dir="$(state::cache_dir 2>/dev/null)" || return 1
  tag="$cache_dir/.hooks-installed"

  # Capture the settings-file mtime ONCE per call. The same value drives both
  # the cache-validity check and the sentinel write — this closes a TOCTOU
  # where a touch landing between jq running and the sentinel write would
  # cause the sentinel to record an mtime newer than what jq actually
  # verified, leading the next call to skip verification on unverified
  # content.
  if [ -r "$settings" ]; then
    mtime_at_entry="$(_hooks_mtime "$settings")"
  else
    mtime_at_entry=0
  fi

  # Sentinel hit: only when the cached mtime EXACTLY equals the settings
  # file's current mtime. Equality (not >=) is the right check: a backward
  # mtime change (cp -p from dotfiles, restore from .bak.*, touch -t) means
  # the file has been replaced with content we haven't verified, and >= would
  # produce a false-positive cache hit. Sentinel is a plain ASCII integer.
  if [ -r "$tag" ] && [ "$mtime_at_entry" != "0" ]; then
    mtime_tag="$(cat "$tag" 2>/dev/null || echo 0)"
    case "$mtime_tag" in '' | *[!0-9]*) mtime_tag=0 ;; esac
    if [ "$mtime_tag" = "$mtime_at_entry" ]; then
      return 0
    fi
  fi

  # Cache miss → verify with jq. On success, record the mtime we captured
  # BEFORE jq ran. If the file was touched during jq, the captured value is
  # pre-touch; the next call will see a higher file mtime and re-verify.
  if hooks::_verify_uncached "$settings"; then
    printf '%s' "$mtime_at_entry" >"$tag" 2>/dev/null || true
    return 0
  fi
  return 1
}
