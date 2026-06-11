#!/usr/bin/env bats
# tests/test_transitions.bats — pure state-transition function.

load test_helper

setup() {
  use_mocks
  source "$LIB/jsonpb.sh"
  source "$LIB/transitions.sh"
}

@test "UserPromptSubmit → working" {
  run transitions::next claude idle UserPromptSubmit '{}'
  assert_output "working"
}

@test "PreToolUse from idle → working" {
  run transitions::next claude idle PreToolUse '{}'
  assert_output "working"
}

@test "PostToolUse from working → working" {
  run transitions::next claude working PostToolUse '{}'
  assert_output "working"
}

@test "PreToolUse from waiting → working (Claude resumed after Allow)" {
  # When a permission_prompt has been resolved, the next thing Claude does
  # is invoke the tool — that's the unambiguous "I'm acting again" signal.
  # Holding 'waiting' past that point makes the status indicator stale
  # (live trace caught a pane stuck on NEED for 88+ seconds while tools
  # streamed unchallenged).
  run transitions::next claude waiting PreToolUse '{}'
  assert_output "working"
}

@test "PostToolUse from waiting → working (tool finished after Allow)" {
  # Same rationale as PreToolUse: a tool result coming back means the
  # human-needs-you signal has been resolved.
  run transitions::next claude waiting PostToolUse '{}'
  assert_output "working"
}

@test "UserPromptSubmit from waiting → working (human re-engaged clears NEED)" {
  # The strong signal that the human is back is a fresh prompt submission,
  # which always clears waiting.
  run transitions::next claude waiting UserPromptSubmit '{}'
  assert_output "working"
}

@test "Notification permission_prompt → waiting" {
  payload='{"notification":{"kind":"permission_prompt"}}'
  run transitions::next claude working Notification "$payload"
  assert_output "waiting"
}

@test "Notification permission_prompt via notification_type field → waiting" {
  payload='{"notification_type":"permission_prompt"}'
  run transitions::next claude working Notification "$payload"
  assert_output "waiting"
}

@test "Notification non-permission preserves current state" {
  payload='{"notification":{"kind":"auth_success"}}'
  run transitions::next claude working Notification "$payload"
  assert_output "working"
}

@test "Stop with clean message → idle" {
  payload='{"last_assistant_message":"Done."}'
  run transitions::next claude working Stop "$payload"
  assert_output "idle"
}

@test "Stop with ASCII question → waiting" {
  payload='{"last_assistant_message":"Should I do A or B?"}'
  run transitions::next claude working Stop "$payload"
  assert_output "waiting"
}

@test "Stop with full-width ？ → waiting (UTF-8 safe)" {
  payload='{"last_assistant_message":"私は何をすべきですか？"}'
  run transitions::next claude working Stop "$payload"
  assert_output "waiting"
}

@test "Stop with Arabic ؟ → waiting" {
  payload='{"last_assistant_message":"ما هذا؟"}'
  run transitions::next claude working Stop "$payload"
  assert_output "waiting"
}

@test "Stop with non-empty background_tasks → working" {
  payload='{"last_assistant_message":"Building...","background_tasks":["task-1"]}'
  run transitions::next claude working Stop "$payload"
  assert_output "working"
}

@test "Stop with question AND background_tasks → working (bg wins)" {
  # Per DESIGN Section 4: bg_count check happens before question detection
  payload='{"last_assistant_message":"Should I do A or B?","background_tasks":["x"]}'
  run transitions::next claude working Stop "$payload"
  assert_output "working"
}

@test "Stop with empty payload → idle" {
  run transitions::next claude working Stop '{}'
  assert_output "idle"
}

@test "SessionEnd → empty (caller should remove row)" {
  run transitions::next claude working SessionEnd '{}'
  assert_output ""
}

@test "SessionEnd from untracked is a no-op (still empty)" {
  run transitions::next claude '' SessionEnd '{}'
  assert_output ""
}

@test "Unknown event preserves current state" {
  run transitions::next claude working FrobnicateZot '{}'
  assert_output "working"
}

@test "trailing whitespace before ? still detected" {
  payload='{"last_assistant_message":"What now?   "}'
  run transitions::next claude working Stop "$payload"
  assert_output "waiting"
}

@test "very long message clamped without panic" {
  long_msg=$(head -c 8000 /dev/urandom | base64 | tr -d '\n=' | head -c 7000)
  payload=$(jq -nc --arg m "${long_msg}?" '{last_assistant_message: $m}')
  run transitions::next claude working Stop "$payload"
  assert_output "waiting"
}

@test "Stop with trailing NBSP before ? still detected" {
  # NBSP (U+00A0) trailing whitespace must be trimmed before the question test.
  payload=$(printf '{"last_assistant_message":"What now?\xc2\xa0"}')
  run transitions::next claude working Stop "$payload"
  assert_output "waiting"
}

@test "Stop with ASCII semicolon NO LONGER recognized as question" {
  # We dropped the Greek-question-mark glyph match because semicolon is too
  # common in normal text/code. Genuine Greek interrogatives are rare; the
  # tradeoff favors precision over recall (review wwbo2gfgl LOW).
  payload='{"last_assistant_message":"Done; ready."}'
  run transitions::next claude working Stop "$payload"
  assert_output "idle"
}

@test "transitions::next works without tmux on PATH (graceful fallback)" {
  # Stage a PATH that has coreutils but no tmux (the real failure mode is
  # running the hook from a Claude process whose env inherited just enough
  # to exec but not the user's tmux binary).
  staged="${BATS_TEST_TMPDIR}/no-tmux-bin"
  mkdir -p "$staged"
  for util in head tail od cut wc jq awk tr sed cat printf bash sleep; do
    if command -v "$util" >/dev/null 2>&1; then
      ln -sf "$(command -v "$util")" "$staged/$util"
    fi
  done
  # Question-detect defaults ON when tmux is unreachable.
  PATH="$staged" run transitions::next claude working Stop '{"last_assistant_message":"What?"}'
  assert_output "waiting"
}

@test "@inbox-question-detect=off skips heuristic" {
  # mock var name: MOCK_OPT_ + tr-mapped key (@inbox-question-detect → _inbox_question_detect)
  export MOCK_OPT__inbox_question_detect="off"
  payload='{"last_assistant_message":"Done?"}'
  run transitions::next claude working Stop "$payload"
  assert_output "idle"
}
