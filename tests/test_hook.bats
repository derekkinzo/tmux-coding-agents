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

@test "hook accepts TMUX_PANE with 6+ digits (regression: case-glob was 5-digit max)" {
  # On long-uptime tmux servers the pane_id counter can hit %100000+. The
  # previous 1-5-digit case-glob silently dropped these.
  run bash -c "cat '$FIXTURES/hook_user_prompt.json' | TMUX_PANE='%123456' '$BIN/hook' UserPromptSubmit"
  assert_success
  source "$LIB/state.sh"
  rows=$(awk 'NR>1' "$(state::tsv_path)" | wc -l | tr -d ' ')
  assert_equal "$rows" "1"
  pane=$(awk -F'\t' 'NR>1 {print $1}' "$(state::tsv_path)")
  assert_equal "$pane" "%123456"
}

@test "hook rejects malformed TMUX_PANE (RCE-defense regression)" {
  # TMUX_PANE controls the pane_id column. Without strict validation a hostile
  # value like "%1'; touch /tmp/RCE; echo '" would be stored as a row whose
  # pane_id contained shell metachars — which then RCE'd through inbox-pick.
  run bash -c "cat '$FIXTURES/hook_user_prompt.json' | TMUX_PANE='%1; touch /tmp/RCE-NOPE-1; echo' '$BIN/hook' UserPromptSubmit"
  assert_success # hook ALWAYS exits 0
  source "$LIB/state.sh"
  if [ -f "$(state::tsv_path)" ]; then
    rows=$(awk 'NR>1' "$(state::tsv_path)" | wc -l | tr -d ' ')
  else
    rows=0
  fi
  # No row should have been written for the malformed pane_id.
  assert_equal "$rows" "0"
  [ ! -e /tmp/RCE-NOPE-1 ]
}

@test "hook drops payload at JSON-depth>8 (DESIGN §15 rule #2)" {
  # Build a 12-deep nested object. jq depth count starts at 0 (root), so 12
  # levels makes max(paths|length) = 12 > 8 → drop.
  deep=$(printf '{"a":{"a":{"a":{"a":{"a":{"a":{"a":{"a":{"a":{"a":{"a":{"a":1}}}}}}}}}}}}')
  run bash -c "printf '%s' '$deep' | TMUX_PANE='%17' '$BIN/hook' UserPromptSubmit"
  assert_success
  source "$LIB/state.sh"
  rows=0
  if [ -f "$(state::tsv_path)" ]; then
    rows=$(awk 'NR>1' "$(state::tsv_path)" | wc -l | tr -d ' ')
  fi
  assert_equal "$rows" "0"
}

@test "hook honors TMUX_CODING_AGENTS_DRY_RUN=1 (no state mutation)" {
  TMUX_CODING_AGENTS_DRY_RUN=1 run_hook UserPromptSubmit hook_user_prompt.json
  source "$LIB/state.sh"
  rows=0
  if [ -f "$(state::tsv_path)" ]; then
    rows=$(awk 'NR>1' "$(state::tsv_path)" | wc -l | tr -d ' ')
  fi
  assert_equal "$rows" "0"
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
  # Project should be the basename of the fixture's cwd, not the full path.
  assert_equal "$proj_col" "foo"
  # Transcript path should look like a path.
  case "$tpath_col" in /*) ;; *) printf 'tpath_col=%s\n' "$tpath_col"; false ;; esac
}
