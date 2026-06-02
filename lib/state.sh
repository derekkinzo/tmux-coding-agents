# lib/state.sh — TSV state read/write under flock.
#
# Files:
#   $XDG_CACHE_HOME/tmux-coding-agents/state.tsv   - the truth
#   $XDG_CACHE_HOME/tmux-coding-agents/state.lock  - flock target
#
# Schema:
#   Header line 1: "#v1\tpane_id\tkind\tstatus\tsince_epoch\tpid\tproject\ttranscript_path"
#   Data lines: tab-separated, one row per tracked pane.
#
# Functions:
#   state::cache_dir              - resolve cache dir (creates if missing); refuse symlinks
#   state::tsv_path               - print TSV path
#   state::lock_path              - print lock file path
#   state::upsert <pane_id> <kind> <status> <since_epoch> <pid> <project> <transcript_path>
#   state::remove <pane_id>
#   state::read                   - print all data rows (no header) under LOCK_SH
#   state::snapshot               - alias for state::read (DESIGN.md Section 3 nomenclature)
#   state::count <status>         - count rows with the given status
#   state::list_by_status <status> - print rows with given status, sorted by since_epoch desc
#   state::gc <live_pids>         - remove rows whose pid is not in the live set
#
# Concurrency invariant:
#   - writers acquire LOCK_EX with 200ms timeout
#   - readers acquire LOCK_SH with 200ms timeout
#   - full rewrite uses tmpfile (PID + nanos suffix) + atomic rename
#   - no caller-visible fd is used; every function opens a fresh fd via the
#     bash 4.1+ {var}>>file syntax with a graceful bash 3.2 fallback
#
# Failure modes (all soft — never fail Claude or tmux):
#   - lock timeout → return 3
#   - cache dir unwritable → return 1
#   - corrupt TSV → readers treat as empty
#
# This file is sourced. No shebang. set -u clean. Re-source-safe.

if [ -z "${STATE_TSV_VERSION:-}" ]; then
  readonly STATE_TSV_VERSION='#v1'
  readonly STATE_LOCK_TIMEOUT_SECS='1'   # integer for max BSD/util-linux compatibility
fi

# Resolve cache dir; create if missing; refuse to use it if it's a symlink.
state::cache_dir() {
  local base="${XDG_CACHE_HOME:-$HOME/.cache}"
  local dir="$base/tmux-coding-agents"
  if [ -L "$dir" ]; then
    return 1
  fi
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" 2>/dev/null || return 1
    chmod 0700 "$dir" 2>/dev/null || true
  fi
  printf '%s' "$dir"
}

state::tsv_path() {
  local dir
  dir="$(state::cache_dir)" || return 1
  printf '%s/state.tsv' "$dir"
}

state::lock_path() {
  local dir
  dir="$(state::cache_dir)" || return 1
  printf '%s/state.lock' "$dir"
}

# --- internal: ensure header ------------------------------------------------
_state_ensure_header() {
  local tsv="$1"
  if [ ! -s "$tsv" ]; then
    printf '%s\tpane_id\tkind\tstatus\tsince_epoch\tpid\tproject\ttranscript_path\n' \
      "$STATE_TSV_VERSION" >"$tsv"
  fi
}

# --- internal: validate field has no tab/newline/CR -------------------------
_state_validate_field() {
  case "$1" in
    *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  return 0
}

# --- internal: unique tmpfile ------------------------------------------------
# Combines PID + nanosecond clock + bash $RANDOM. Falls back gracefully if any
# component is missing.
_state_tmpfile_for() {
  local target="$1"
  local nanos
  nanos=$(date +%N 2>/dev/null)
  case "$nanos" in
    ''|*N*) nanos="$RANDOM" ;;
  esac
  printf '%s.tmp.%s.%s.%s' "$target" "$$" "$nanos" "${RANDOM:-0}"
}

# --- internal: with-lock helper ---------------------------------------------
# Run a callback with the lock held. Uses bash 4.1+ named-fd if available,
# falls back to a fixed-fd-but-saved/restore for bash 3.2.
#
# $1 = mode (-x for exclusive, -s for shared)
# $2 = callback function name (called with the open fd as $1)
# remaining args = forwarded to callback
_state_with_lock() {
  local mode="$1" cb="$2"
  shift 2
  local lock
  # shellcheck disable=SC2034  # used inside `eval` below
  lock="$(state::lock_path)" || return 1

  # Open a fresh fd. Try named-fd syntax first (bash 4.1+).
  local lock_fd
  if eval 'exec {lock_fd}>>"$lock"' 2>/dev/null; then
    :
  else
    # Bash 3.2 fallback: pick fd 200 (high enough to avoid stdin/stdout/stderr
    # and the conventional 9). Save any existing fd 200 first.
    lock_fd=200
    eval "exec ${lock_fd}>>\"\$lock\"" || return 1
  fi

  if ! flock -w "$STATE_LOCK_TIMEOUT_SECS" "$mode" "$lock_fd"; then
    eval "exec ${lock_fd}>&-"
    return 3
  fi

  "$cb" "$lock_fd" "$@"
  local rc=$?

  flock -u "$lock_fd"
  eval "exec ${lock_fd}>&-"
  return $rc
}

# --- upsert -----------------------------------------------------------------
state::upsert() {
  local pane_id="$1" kind="$2" status="$3" since="$4" pid="$5"
  local project="$6" tpath="$7"

  local f
  for f in "$pane_id" "$kind" "$status" "$since" "$pid" "$project" "$tpath"; do
    _state_validate_field "$f" || return 2
  done

  _state_with_lock -x _state_do_upsert \
    "$pane_id" "$kind" "$status" "$since" "$pid" "$project" "$tpath"
}

_state_do_upsert() {
  local lock_fd="$1"
  shift
  local pane_id="$1" kind="$2" status="$3" since="$4" pid="$5" project="$6" tpath="$7"

  local tsv tmp
  tsv="$(state::tsv_path)" || return 1
  tmp="$(_state_tmpfile_for "$tsv")"

  _state_ensure_header "$tsv"

  local new_row
  printf -v new_row '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$pane_id" "$kind" "$status" "$since" "$pid" "$project" "$tpath"

  awk -F'\t' -v pid_target="$pane_id" -v new="$new_row" '
    NR == 1 { print; next }
    $1 == pid_target { found = 1; print new; next }
    { print }
    END { if (!found) print new }
  ' "$tsv" >"$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }

  mv -f "$tmp" "$tsv" || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# --- remove -----------------------------------------------------------------
state::remove() {
  local pane_id="$1"
  _state_validate_field "$pane_id" || return 2
  _state_with_lock -x _state_do_remove "$pane_id"
}

_state_do_remove() {
  local lock_fd="$1"
  shift
  local pane_id="$1"

  local tsv tmp
  tsv="$(state::tsv_path)" || return 1
  [ -f "$tsv" ] || return 0
  tmp="$(_state_tmpfile_for "$tsv")"

  awk -F'\t' -v pid_target="$pane_id" '
    NR == 1 { print; next }
    $1 == pid_target { next }
    { print }
  ' "$tsv" >"$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }

  mv -f "$tmp" "$tsv" || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# --- read -------------------------------------------------------------------
# Print data rows (no header) under LOCK_SH.
# If the TSV doesn't exist yet, returns 0 with empty output (NOT an error).
state::read() {
  local tsv
  tsv="$(state::tsv_path)" || return 1
  [ -f "$tsv" ] || return 0

  _state_with_lock -s _state_do_read "$tsv"
}

_state_do_read() {
  # $1 = lock_fd, $2 = tsv path
  awk 'NR > 1' "$2"
}

# Alias per DESIGN.md naming.
state::snapshot() {
  state::read
}

# --- count ------------------------------------------------------------------
state::count() {
  local target="$1"
  state::read | awk -F'\t' -v t="$target" '$3 == t' | wc -l | tr -d ' '
}

# --- list_by_status ---------------------------------------------------------
state::list_by_status() {
  local target="$1"
  state::read | awk -F'\t' -v t="$target" '$3 == t' | sort -t$'\t' -k4,4nr
}

# --- gc ---------------------------------------------------------------------
# Remove rows whose pid is not in the supplied "alive set" (one pid per line
# on stdin). The caller computes alive PIDs OUTSIDE the lock so we hold the
# lock for the minimum time.
#
# Usage:
#   pgrep claude | state::gc        # drop any tracked pane whose claude is dead
#
# If stdin is empty / not a pipe, all rows are considered dead (use carefully).
state::gc() {
  local alive_pids=""
  if [ ! -t 0 ]; then
    alive_pids="$(cat)"
  fi
  _state_with_lock -x _state_do_gc "$alive_pids"
}

_state_do_gc() {
  local lock_fd="$1"
  shift
  local alive_pids="$1"

  local tsv tmp
  tsv="$(state::tsv_path)" || return 1
  [ -f "$tsv" ] || return 0
  tmp="$(_state_tmpfile_for "$tsv")"

  # Pass alive_pids to awk via env to keep values out of script source.
  awk -F'\t' -v alive="$alive_pids" '
    BEGIN {
      n = split(alive, parts, "\n")
      for (i = 1; i <= n; i++) if (parts[i] != "") alive_set[parts[i]] = 1
    }
    NR == 1 { print; next }
    {
      pid = $5
      if (pid == "" || pid == "0") next
      if (pid in alive_set) print
    }
  ' "$tsv" >"$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }

  mv -f "$tmp" "$tsv" || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}
