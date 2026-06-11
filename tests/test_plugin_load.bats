#!/usr/bin/env bats
# tests/test_plugin_load.bats — TPM entrypoint loads cleanly + idempotently
# in a real isolated tmux server.

load test_helper

setup() {
  setup_isolated_cache
  TMUX_SOCKET="tca-test-$$"
  export TMUX_SOCKET
  tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true
}

teardown() {
  tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true
}

@test "plugin loads without errors via run-shell" {
  tmux -L "$TMUX_SOCKET" -f /dev/null new-session -d -s probe -x 200 -y 50
  run tmux -L "$TMUX_SOCKET" run-shell "$PLUGIN_ROOT/tmux-coding-agents.tmux"
  assert_success
}

@test "plugin registers prefix + a binding for inbox-pick" {
  tmux -L "$TMUX_SOCKET" -f /dev/null new-session -d -s probe -x 200 -y 50
  tmux -L "$TMUX_SOCKET" run-shell "$PLUGIN_ROOT/tmux-coding-agents.tmux"
  run tmux -L "$TMUX_SOCKET" list-keys -T prefix
  assert_output --partial "inbox-pick"
}

@test "plugin sets default options when unset" {
  tmux -L "$TMUX_SOCKET" -f /dev/null new-session -d -s probe -x 200 -y 50
  tmux -L "$TMUX_SOCKET" run-shell "$PLUGIN_ROOT/tmux-coding-agents.tmux"
  pick_key=$(tmux -L "$TMUX_SOCKET" show-option -gqv '@inbox-pick-key')
  assert_equal "$pick_key" "a"
  qd=$(tmux -L "$TMUX_SOCKET" show-option -gqv '@inbox-question-detect')
  assert_equal "$qd" "on"
}

@test "plugin preserves user-set options on reload" {
  tmux -L "$TMUX_SOCKET" -f /dev/null new-session -d -s probe -x 200 -y 50
  tmux -L "$TMUX_SOCKET" set-option -gq '@inbox-pick-key' 'i'
  tmux -L "$TMUX_SOCKET" run-shell "$PLUGIN_ROOT/tmux-coding-agents.tmux"
  pick_key=$(tmux -L "$TMUX_SOCKET" show-option -gqv '@inbox-pick-key')
  assert_equal "$pick_key" "i"
}

@test "plugin reload is idempotent (no duplicate binds)" {
  tmux -L "$TMUX_SOCKET" -f /dev/null new-session -d -s probe -x 200 -y 50
  tmux -L "$TMUX_SOCKET" run-shell "$PLUGIN_ROOT/tmux-coding-agents.tmux"
  tmux -L "$TMUX_SOCKET" run-shell "$PLUGIN_ROOT/tmux-coding-agents.tmux"
  count=$(tmux -L "$TMUX_SOCKET" list-keys -T prefix | grep -c "inbox-pick" || true)
  assert_equal "$count" "1"
}

@test "plugin binds next-key only when configured" {
  tmux -L "$TMUX_SOCKET" -f /dev/null new-session -d -s probe -x 200 -y 50
  tmux -L "$TMUX_SOCKET" run-shell "$PLUGIN_ROOT/tmux-coding-agents.tmux"
  count=$(tmux -L "$TMUX_SOCKET" list-keys -T prefix | grep -c "inbox-next" || true)
  assert_equal "$count" "0"
  # Now set and reload.
  tmux -L "$TMUX_SOCKET" set-option -gq '@inbox-next-key' 'N'
  tmux -L "$TMUX_SOCKET" run-shell "$PLUGIN_ROOT/tmux-coding-agents.tmux"
  count=$(tmux -L "$TMUX_SOCKET" list-keys -T prefix | grep -c "inbox-next" || true)
  assert_equal "$count" "1"
}

@test "plugin exports TMUX_CODING_AGENTS_ROOT" {
  tmux -L "$TMUX_SOCKET" -f /dev/null new-session -d -s probe -x 200 -y 50
  tmux -L "$TMUX_SOCKET" run-shell "$PLUGIN_ROOT/tmux-coding-agents.tmux"
  root=$(tmux -L "$TMUX_SOCKET" show-environment -g TMUX_CODING_AGENTS_ROOT | sed 's/^TMUX_CODING_AGENTS_ROOT=//')
  assert_equal "$root" "$PLUGIN_ROOT"
}
