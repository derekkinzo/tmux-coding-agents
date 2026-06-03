#!/usr/bin/env bats
# tests/test_hook.bats — bin/hook end-to-end (state mutation under TMUX_PANE).

load test_helper

setup() {
  setup_isolated_cache
  use_mocks
}

teardown() {
  unset TMUX_PANE
}

run_hook() {
  # $1 = event name, $2 = fixture filename in tests/fixtures/
  local event="$1" fix="$2"
  cat "$FIXTURES/$fix" | TMUX_PANE='%17' "$BIN/hook" "$event"
}

@test "hook UserPromptSubmit → working state" {
  run_hook UserPromptSubmit hook_user_prompt.json
  source "$LIB/state.sh"
  status=$(awk -F'\t' '$1=="%17" {print $3}' "$(state::tsv_path)")
  assert_equal "$status" "working"
}

@test "hook PreToolUse → working" {
  run_hook PreToolUse hook_pre_tool.json
  source "$LIB/state.sh"
  status=$(awk -F'\t' '$1=="%17" {print $3}' "$(state::tsv_path)")
  assert_equal "$status" "working"
}

@test "hook Notification permission_prompt → waiting" {
  run_hook Notification hook_notification_permission.json
  source "$LIB/state.sh"
  status=$(awk -F'\t' '$1=="%17" {print $3}' "$(state::tsv_path)")
  assert_equal "$status" "waiting"
}

@test "hook Stop clean → idle" {
  run_hook UserPromptSubmit hook_user_prompt.json
  run_hook Stop hook_stop_clean.json
  source "$LIB/state.sh"
  status=$(awk -F'\t' '$1=="%17" {print $3}' "$(state::tsv_path)")
  assert_equal "$status" "idle"
}

@test "hook Stop with question → waiting" {
  run_hook UserPromptSubmit hook_user_prompt.json
  run_hook Stop hook_stop_question.json
  source "$LIB/state.sh"
  status=$(awk -F'\t' '$1=="%17" {print $3}' "$(state::tsv_path)")
  assert_equal "$status" "waiting"
}

@test "hook Stop with background_tasks → working" {
  run_hook UserPromptSubmit hook_user_prompt.json
  run_hook Stop hook_stop_background.json
  source "$LIB/state.sh"
  status=$(awk -F'\t' '$1=="%17" {print $3}' "$(state::tsv_path)")
  assert_equal "$status" "working"
}

@test "hook SessionEnd removes the row" {
  run_hook UserPromptSubmit hook_user_prompt.json
  source "$LIB/state.sh"
  before=$(awk 'NR>1' "$(state::tsv_path)" | wc -l | tr -d ' ')
  assert_equal "$before" "1"
  run_hook SessionEnd hook_session_end.json
  after=$(awk 'NR>1' "$(state::tsv_path)" | wc -l | tr -d ' ')
  assert_equal "$after" "0"
}

@test "hook with no TMUX_PANE silently exits 0" {
  unset TMUX_PANE
  run bash -c "cat '$FIXTURES/hook_user_prompt.json' | '$BIN/hook' UserPromptSubmit"
  assert_success
}

@test "hook with invalid JSON exits 0 and writes nothing" {
  TMUX_PANE='%17'
  run bash -c "echo 'not json' | TMUX_PANE='%17' '$BIN/hook' UserPromptSubmit"
  assert_success
  source "$LIB/state.sh"
  rows=0
  if [ -f "$(state::tsv_path)" ]; then
    rows=$(awk 'NR>1' "$(state::tsv_path)" | wc -l | tr -d ' ')
  fi
  assert_equal "$rows" "0"
}

@test "hook with oversized payload (>64 KiB) drops silently" {
  TMUX_PANE='%17'
  run bash -c "head -c 70000 /dev/urandom | base64 | TMUX_PANE='%17' '$BIN/hook' UserPromptSubmit"
  assert_success
  source "$LIB/state.sh"
  rows=0
  if [ -f "$(state::tsv_path)" ]; then
    rows=$(awk 'NR>1' "$(state::tsv_path)" | wc -l | tr -d ' ')
  fi
  assert_equal "$rows" "0"
}

@test "hook with no event arg silently exits 0" {
  TMUX_PANE='%17'
  run bash -c "cat '$FIXTURES/hook_user_prompt.json' | TMUX_PANE='%17' '$BIN/hook'"
  assert_success
}

@test "hook carries forward project across multiple events" {
  run_hook UserPromptSubmit hook_user_prompt.json
  # Stop fixture has no cwd — should keep "foo" project from earlier hook
  source "$LIB/state.sh"
  proj_before=$(awk -F'\t' '$1=="%17" {print $6}' "$(state::tsv_path)")
  [ -n "$proj_before" ]   # First hook must populate the project field.
  # Manually craft a Stop with no cwd
  echo '{"hook_event":"Stop","last_assistant_message":"done"}' \
    | TMUX_PANE='%17' "$BIN/hook" Stop
  proj_after=$(awk -F'\t' '$1=="%17" {print $6}' "$(state::tsv_path)")
  assert_equal "$proj_after" "$proj_before"
}

@test "hook TSV column positions are correct (regression: was off-by-one)" {
  # Data row: 1=pane_id, 2=kind, 3=status, 4=since, 5=pid, 6=project, 7=tpath.
  # If the off-by-one returns, $6 would be the pid (numeric) and $7 would be
  # the project name — the assertions below would flip.
  run_hook UserPromptSubmit hook_user_prompt.json
  source "$LIB/state.sh"
  tsv="$(state::tsv_path)"
  pid_col=$(awk -F'\t' '$1=="%17" {print $5}' "$tsv")
  proj_col=$(awk -F'\t' '$1=="%17" {print $6}' "$tsv")
  tpath_col=$(awk -F'\t' '$1=="%17" {print $7}' "$tsv")
  # PID must be numeric (from fixture: 12345).
  case "$pid_col" in ''|*[!0-9]*) printf 'pid_col=%s\n' "$pid_col"; false ;; esac
  # Project should NOT look like a path, but DOES match the basename of cwd
  # (fixture cwd: /home/u/Projects/foo → project: foo).
  assert_equal "$proj_col" "foo"
  # Transcript path should look like a path.
  case "$tpath_col" in /*) ;; *) printf 'tpath_col=%s\n' "$tpath_col"; false ;; esac
}
