#!/usr/bin/env bash
# tmux-coding-agents.tmux — TPM entrypoint.
#
# Sourced (executed) by TPM on every `tmux source-file` of the user's config.
# Idempotent by construction: every operation here is safe to re-run.
#
# Responsibilities:
#   1. Self-locate the plugin directory (no hardcoded paths).
#   2. Verify tmux >= 3.2; bail with display-message if too old.
#   3. Set default tmux options for any @inbox-* knob the user has not set.
#   4. Bind keys for `prefix + <pick-key>` and `prefix + <next-key>` (latter opt-in).
#
# This script does NOT spawn a daemon, write state files, or modify
# ~/.claude/settings.json. The user runs `bin/install-hooks` once, separately.
#
# Version: 0.1.0-dev (semver tagged in git when v0.1.0 ships)

set -uo pipefail

# Self-locate.
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- 1. tmux version gate --------------------------------------------------
# Parse `tmux -V` output: "tmux 3.4" or "tmux next-3.5" or "tmux master-abc123".
# We require 3.2+ (display-popup, choose-tree -f). Fail soft: print message,
# return 0, do not bind anything.
tmux_version_string="$(tmux -V 2>/dev/null | awk '{print $2}')"
# Strip non-numeric prefix (handles "next-" or "master-" forks).
tmux_version_numeric="$(printf '%s' "$tmux_version_string" \
  | LC_ALL=C sed 's/^[^0-9]*//;s/[^0-9.].*$//')"

if [ -z "$tmux_version_numeric" ]; then
  tmux display-message "tmux-coding-agents: could not detect tmux version; skipping load"
  exit 0
fi

# Compare major.minor as integer pair.
ver_major="$(printf '%s' "$tmux_version_numeric" | cut -d. -f1)"
ver_minor="$(printf '%s' "$tmux_version_numeric" | cut -d. -f2)"
case "$ver_major" in *[!0-9]* | '') ver_major=0 ;; esac
case "$ver_minor" in *[!0-9]* | '') ver_minor=0 ;; esac

if [ "$ver_major" -lt 3 ] || { [ "$ver_major" -eq 3 ] && [ "$ver_minor" -lt 2 ]; }; then
  tmux display-message \
    "tmux-coding-agents: requires tmux 3.2+ (you have ${tmux_version_string:-unknown}); plugin not loaded"
  exit 0
fi

# ---- 2. set option defaults (only if unset) --------------------------------
#
# Distinguish "not set" from "set to empty". `tmux show-option -gqv` returns
# empty for both, so we check the option's PRESENCE first using `show-options
# -g | grep`. If the user explicitly sets `@inbox-pick-key ''` they want NO
# binding (opt-out); we honor that.
tca_option_is_set() {
  local opt="$1"
  tmux show-options -g 2>/dev/null | awk -v o="$opt" '$1 == o { found = 1 } END { exit !found }'
}

tca_default_opt() {
  local opt="$1" default="$2"
  if ! tca_option_is_set "$opt"; then
    tmux set-option -gq "$opt" "$default"
  fi
}

tca_default_opt "@inbox-pick-key" "a"
# @inbox-next-key intentionally NO default — empty = unbound (opt-in feature).
tca_default_opt "@inbox-question-detect" "on"
tca_default_opt "@inbox-debug" "off"
# @inbox-status-format intentionally has no default — empty triggers built-in.

# ---- 3. bind keys ----------------------------------------------------------
# Pick key: bound only if set + non-empty. User who wants to disable: `set -g @inbox-pick-key ''`.
pick_key="$(tmux show-option -gqv '@inbox-pick-key' 2>/dev/null)"
if [ -n "$pick_key" ]; then
  tmux bind-key -N "Open Claude inbox picker" "$pick_key" \
    run-shell "$PLUGIN_ROOT/bin/inbox-pick"
fi

# Next key: opt-in only. Empty value = no binding.
next_key="$(tmux show-option -gqv '@inbox-next-key' 2>/dev/null)"
if [ -n "$next_key" ]; then
  tmux bind-key -N "Jump to next waiting Claude pane" "$next_key" \
    run-shell "$PLUGIN_ROOT/bin/inbox-next"
fi

# ---- 4. expose plugin root for hook script self-test -----------------------
# (Useful for `inbox-pick` to detect "hooks not installed" via path matching.)
tmux set-environment -g TMUX_CODING_AGENTS_ROOT "$PLUGIN_ROOT"

exit 0
