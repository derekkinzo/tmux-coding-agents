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
#   state::snapshot               - alias for state::read
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
  # 0.2s lock timeout — short enough to keep hooks responsive, long enough
  # to wait out routine concurrent writers. util-linux and BSD flock both
  # accept fractional -w on every supported platform.
  readonly STATE_LOCK_TIMEOUT_SECS='0.2'
fi

# Resolve cache dir; create if missing; refuse to use it if it's a symlink.
# SECURITY (review wwbo2gfgl HIGH/MEDIUM):
#   - if the path exists as a symlink → refuse (could redirect writes)
#   - if it exists with permissive mode (group/other read/write/exec) → tighten
#     to 0700. This handles upgrade paths where an older umask left it at 0755
#     and protects against hostile log-file appends via symlinks placed inside.
state::cache_dir() {
  local base="${XDG_CACHE_HOME:-$HOME/.cache}"
  local dir="$base/tmux-coding-agents"
  if [ -L "$dir" ]; then
    return 1
  fi
  if [ ! -d "$dir" ]; then
    (umask 077 && mkdir -p "$dir") 2>/dev/null || return 1
    chmod 0700 "$dir" 2>/dev/null || true
  else
    # Tighten if currently more permissive than 0700.
    local mode
    mode="$(stat -c '%a' "$dir" 2>/dev/null || stat -f '%Lp' "$dir" 2>/dev/null || echo '')"
    case "$mode" in
      700) : ;;
      *) chmod 0700 "$dir" 2>/dev/null || true ;;
    esac
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

# --- internal: validate field has no row-corrupting bytes -------------------
# Rejects:
#   - tab/newline/CR (would corrupt the TSV row directly)
#   - any literal backslash (would be re-expanded by awk -v as \n/\t/\r/\\,
#     allowing TSV row injection — see review wwbo2gfgl critical finding).
#     Even though _state_do_upsert/remove now use ENVIRON instead of -v,
#     refusing backslash at validation is defense in depth and gives a clear
#     contract: project names and transcript paths must be backslash-free
#     (which is true for every realistic value Claude produces).
_state_validate_field() {
  case "$1" in
    *$'\t'* | *$'\n'* | *$'\r'*) return 1 ;;
    *\\*) return 1 ;;
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
    '' | *N*) nanos="$RANDOM" ;;
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

  # Open a fresh fd. Use the named-fd syntax on bash 4.1+; fall back to a
  # fixed fd 200 on bash 3.2 (which silently creates a `{lock_fd}` file
  # rather than allocating a fd if we let the named-fd form run).
  local lock_fd
  local bash_major="${BASH_VERSINFO[0]:-0}" bash_minor="${BASH_VERSINFO[1]:-0}"
  if [ "$bash_major" -gt 4 ] || { [ "$bash_major" -eq 4 ] && [ "$bash_minor" -ge 1 ]; }; then
    eval 'exec {lock_fd}>>"$lock"' || return 1
  else
    lock_fd=200
    eval "exec ${lock_fd}>>\"\$lock\"" || return 1
  fi

  # Try to acquire the lock. The timeout is short (200ms) to avoid blocking
  # the caller for any user-perceptible amount of time;
  # several -n retries with short jittered sleeps absorb the burst when
  # many writers hit at once. Total worst-case wait: ~1.8s (8 * 200ms +
  # ~200ms cumulative backoff), well within the caller's tolerance for an
  # event-driven workload.
  local attempts=0
  while ! flock -w "$STATE_LOCK_TIMEOUT_SECS" "$mode" "$lock_fd"; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 8 ]; then
      eval "exec ${lock_fd}>&-"
      return 3
    fi
    # Brief jittered backoff between retries; uses bash $RANDOM modulo
    # rather than sleep fractions for portability across BSD sleep.
    case "$((RANDOM % 4))" in
      0) sleep 0.05 ;;
      1) sleep 0.1 ;;
      2) sleep 0.15 ;;
      3) sleep 0.2 ;;
    esac
  done

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
  # SECURITY: refuse to write through a symlink. Without this, an attacker who
  # can place a symlink at $XDG_CACHE_HOME/tmux-coding-agents/state.tsv can
  # cause our writes to land in arbitrary files (review wwbo2gfgl HIGH).
  if [ -L "$tsv" ]; then
    return 1
  fi
  tmp="$(_state_tmpfile_for "$tsv")"
  # SIGTERM cleanup. SIGKILL is uncatchable — see _state_sweep_orphan_tmps.
  # shellcheck disable=SC2064  # we want $tmp expanded NOW, not at trap time
  trap "rm -f '$tmp' 2>/dev/null" RETURN

  _state_ensure_header "$tsv"

  local new_row
  printf -v new_row '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$pane_id" "$kind" "$status" "$since" "$pid" "$project" "$tpath"

  # SECURITY: pass values via ENVIRON (no escape expansion) rather than -v
  # (which performs C-style escape expansion on its values, allowing a
  # backslash-n in the input to become a real newline and inject TSV rows).
  # Validation in _state_validate_field already rejects backslash, so this is
  # defense in depth.
  STATE_PID_TARGET="$pane_id" STATE_NEW_ROW="$new_row" \
    awk -F'\t' '
      BEGIN { pid_target = ENVIRON["STATE_PID_TARGET"]; new = ENVIRON["STATE_NEW_ROW"] }
      NR == 1 { print; next }
      $1 == pid_target { found = 1; print new; next }
      { print }
      END { if (!found) print new }
    ' "$tsv" >"$tmp" || return 1

  mv -f "$tmp" "$tsv" || return 1
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
  if [ -L "$tsv" ]; then
    return 1
  fi
  [ -f "$tsv" ] || return 0
  tmp="$(_state_tmpfile_for "$tsv")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp' 2>/dev/null" RETURN

  STATE_PID_TARGET="$pane_id" \
    awk -F'\t' '
      BEGIN { pid_target = ENVIRON["STATE_PID_TARGET"] }
      NR == 1 { print; next }
      $1 == pid_target { next }
      { print }
    ' "$tsv" >"$tmp" || return 1

  mv -f "$tmp" "$tsv" || return 1
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

# --- orphan tmpfile sweep ---------------------------------------------------
# A SIGKILL between awk-write and mv-rename leaves behind state.tsv.tmp.* files.
# Sweep any older than 60 seconds (stale, no in-flight writer should still hold
# them). Cheap; called opportunistically by bin/inbox-status.
state::sweep_orphan_tmps() {
  local dir
  dir="$(state::cache_dir)" 2>/dev/null || return 0
  # Only consider files matching our tmpfile pattern. Use find with -mmin so
  # we don't risk deleting an in-flight writer's tmpfile.
  find "$dir" -maxdepth 1 -type f -name 'state.tsv.tmp.*' -mmin +1 \
    -delete 2>/dev/null || true
}

# --- gc ---------------------------------------------------------------------
# Remove rows whose pid is not in the supplied "alive set" (one pid per line
# on stdin). The caller computes alive PIDs OUTSIDE the lock so we hold the
# lock for the minimum time.
#
# Usage:
#   pgrep claude | state::gc        # drop any tracked pane whose claude is dead
#
# Safety: if stdin yields zero alive pids, GC is a no-op (returns 0). This
# protects against the common case where `pgrep` finds nothing and would
# otherwise nuke every tracked row. Callers that genuinely want a wipe should
# use state::remove explicitly per pane.
state::gc() {
  local alive_pids=""
  if [ ! -t 0 ]; then
    alive_pids="$(cat)"
  fi
  # No alive pids known → refuse to GC. This is the empty-input safety net.
  case "$alive_pids" in
    '' | $'\n' | *[!0-9$'\n']*)
      # Strip non-numeric noise; if nothing useful remains, no-op.
      alive_pids="$(printf '%s\n' "$alive_pids" | awk 'NF && /^[0-9]+$/')"
      ;;
  esac
  if [ -z "$alive_pids" ]; then
    return 0
  fi
  _state_with_lock -x _state_do_gc "$alive_pids"
}

_state_do_gc() {
  local lock_fd="$1"
  shift
  local alive_pids="$1"

  local tsv tmp
  tsv="$(state::tsv_path)" || return 1
  if [ -L "$tsv" ]; then
    return 1
  fi
  [ -f "$tsv" ] || return 0
  tmp="$(_state_tmpfile_for "$tsv")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp' 2>/dev/null" RETURN

  # alive_pids is a newline-separated PID list, validated as numeric-only by
  # state::gc before we got here. Pass via ENVIRON to avoid awk -v escape
  # expansion (defense in depth).
  STATE_ALIVE_PIDS="$alive_pids" \
    awk -F'\t' '
      BEGIN {
        n = split(ENVIRON["STATE_ALIVE_PIDS"], parts, "\n")
        for (i = 1; i <= n; i++) if (parts[i] != "") alive_set[parts[i]] = 1
      }
      # pid=="" or pid=="0" means unknown (some hook payloads omit pid).
      # Keep those rows; gc_panes (tmux-pane existence) is the authoritative
      # cleanup. Dropping them here would cause status-bar flicker.
      NR == 1 { print; next }
      {
        pid = $5
        if (pid == "" || pid == "0") { print; next }
        if (pid in alive_set) print
      }
    ' "$tsv" >"$tmp" || return 1

  mv -f "$tmp" "$tsv" || return 1
  return 0
}

# --- gc_panes ---------------------------------------------------------------
# Remove rows whose pane_id (column 1) is NOT in the supplied alive-pane set.
# Lazy garbage-collect via read-then-rewrite —
# bin/inbox-pick calls this with `tmux list-panes` output
# so a tmux restart (every pane gone) eventually empties the TSV.
#
# Usage:
#   tmux list-panes -as -F '#{pane_id}' | state::gc_panes
#
# Safety: empty input is a no-op, same rationale as state::gc.
state::gc_panes() {
  local alive_panes=""
  if [ ! -t 0 ]; then
    alive_panes="$(cat)"
  fi
  case "$alive_panes" in
    '' | $'\n' | *[!%0-9$'\n']*)
      alive_panes="$(printf '%s\n' "$alive_panes" | awk 'NF && /^%[0-9]+$/')"
      ;;
  esac
  if [ -z "$alive_panes" ]; then
    return 0
  fi
  _state_with_lock -x _state_do_gc_panes "$alive_panes"
}

_state_do_gc_panes() {
  local lock_fd="$1"
  shift
  local alive_panes="$1"

  local tsv tmp
  tsv="$(state::tsv_path)" || return 1
  if [ -L "$tsv" ]; then
    return 1
  fi
  [ -f "$tsv" ] || return 0
  tmp="$(_state_tmpfile_for "$tsv")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp' 2>/dev/null" RETURN

  STATE_ALIVE_PANES="$alive_panes" \
    awk -F'\t' '
      BEGIN {
        n = split(ENVIRON["STATE_ALIVE_PANES"], parts, "\n")
        for (i = 1; i <= n; i++) if (parts[i] != "") alive_set[parts[i]] = 1
      }
      NR == 1 { print; next }
      $1 in alive_set { print }
    ' "$tsv" >"$tmp" || return 1

  mv -f "$tmp" "$tsv" || return 1
  return 0
}
