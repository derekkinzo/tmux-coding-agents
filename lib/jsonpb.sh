# lib/jsonpb.sh — JSON peeker. Requires jq (no fallback).
#
# Per DESIGN.md Section 18, jq is a hard runtime dependency. The previous
# pure-bash fallback was found to have multiple correctness bugs (regex
# metacharacter injection, no escape handling, no string-awareness in depth
# tracking, naive substring matching for object/array extraction). All of
# these are unfixable in pure bash without writing a real parser.
#
# jq is on every dev system and is genuinely the only correct way to parse
# adversarial JSON in shell. We accept the dependency.
#
# Functions:
#   jsonpb::require_jq    - exit non-zero if jq missing; print actionable error to stderr
#   jsonpb::peek <json> <key>           - top-level scalar (string/number/bool)
#   jsonpb::peek_nested <json> <a.b>    - one-level-nested scalar (e.g. "notification.kind")
#   jsonpb::array_len <json> <key>      - length of top-level array; 0 if absent or non-array
#
# Output: extracted value to stdout (always exits 0 on miss — empty output)
# Output: array_len always prints a non-negative integer
#
# All functions take the JSON document as the FIRST positional arg. The earlier
# stdin-based variant was removed; explicit args are clearer and avoid the
# "cat with no tty" hang reported by the audit.
#
# This file is sourced. No shebang. set -u clean.

jsonpb::require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'tmux-coding-agents: jq is required but not on PATH. Install jq.\n' >&2
    return 1
  fi
}

# Extract a top-level value. Returns "" for missing or null.
# $1 = JSON document, $2 = key name (literal, not a path expression).
jsonpb::peek() {
  local payload="${1:-}" key="${2:-}"
  [ -n "$payload" ] && [ -n "$key" ] || return 0
  printf '%s' "$payload" | jq -r --arg k "$key" '.[$k] // ""' 2>/dev/null
}

# Extract a one-level-nested value. $2 must be "outer.inner".
# Returns "" if outer or inner is absent, or if dotted form is malformed.
jsonpb::peek_nested() {
  local payload="${1:-}" dotted="${2:-}"
  [ -n "$payload" ] && [ -n "$dotted" ] || return 0
  case "$dotted" in
    *.*) ;;
    *)
      # No dot: contract violation. Return empty.
      return 0
      ;;
  esac
  local outer="${dotted%%.*}"
  local inner="${dotted#*.}"
  printf '%s' "$payload" \
    | jq -r --arg o "$outer" --arg i "$inner" '(.[$o] // {}) | (.[$i] // "")' 2>/dev/null
}

# Length of a top-level array. Always prints a non-negative integer.
# Non-array, missing, or unparseable → 0.
jsonpb::array_len() {
  local payload="${1:-}" key="${2:-}"
  if [ -z "$payload" ] || [ -z "$key" ]; then
    printf '0'
    return 0
  fi
  local n
  n=$(printf '%s' "$payload" \
    | jq -r --arg k "$key" '.[$k] | if type == "array" then length else 0 end' 2>/dev/null)
  case "$n" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$n" ;;
  esac
}
