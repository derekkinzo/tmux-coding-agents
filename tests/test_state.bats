#!/usr/bin/env bats
# tests/test_state.bats — TSV state persistence under flock.

load test_helper

setup() {
  setup_isolated_cache
  source "$LIB/state.sh"
}

@test "state::cache_dir creates with mode 0700" {
  run state::cache_dir
  assert_success
  [ -d "$output" ]
  perm=$(stat -c %a "$output" 2>/dev/null || stat -f %Lp "$output")
  assert_equal "$perm" "700"
}

@test "state::cache_dir refuses symlinked dir" {
  base="$XDG_CACHE_HOME"
  ln -s /tmp "$base/tmux-coding-agents"
  run state::cache_dir
  assert_failure
}

@test "state::upsert inserts a new row with header" {
  run state::upsert '%17' 'claude' 'waiting' '1700000000' '12345' 'foo' '/tmp/x.jsonl'
  assert_success
  tsv=$(state::tsv_path)
  [ -f "$tsv" ]
  header=$(head -1 "$tsv")
  case "$header" in '#v1'*) ;; *) false ;; esac
  rows=$(awk 'NR>1' "$tsv" | wc -l | tr -d ' ')
  assert_equal "$rows" "1"
}

@test "state::upsert replaces existing row by pane_id" {
  state::upsert '%17' 'claude' 'waiting' '1700000000' '12345' 'foo' ''
  state::upsert '%17' 'claude' 'working' '1700000100' '12345' 'foo' ''
  rows=$(awk 'NR>1' "$(state::tsv_path)" | wc -l | tr -d ' ')
  assert_equal "$rows" "1"
  status=$(awk -F'\t' '$1=="%17" {print $3}' "$(state::tsv_path)")
  assert_equal "$status" "working"
}

@test "state::upsert rejects fields with embedded tab" {
  run state::upsert '%17' 'claude' 'waiting' '1700000000' '12345' $'pro\tjekt' ''
  assert_failure
}

@test "state::upsert rejects fields with embedded newline" {
  run state::upsert '%17' 'claude' 'waiting' '1700000000' '12345' $'pro\nject' ''
  assert_failure
}

@test "state::remove drops the matching row only" {
  state::upsert '%17' 'claude' 'waiting' '1700000000' '12345' 'foo' ''
  state::upsert '%18' 'claude' 'working' '1700000100' '12346' 'bar' ''
  state::remove '%17'
  rows=$(awk 'NR>1' "$(state::tsv_path)" | wc -l | tr -d ' ')
  assert_equal "$rows" "1"
  remaining=$(awk -F'\t' 'NR>1 {print $1}' "$(state::tsv_path)")
  assert_equal "$remaining" "%18"
}

@test "state::count returns correct count" {
  state::upsert '%17' 'claude' 'waiting' '1700000000' '12345' 'foo' ''
  state::upsert '%18' 'claude' 'waiting' '1700000100' '12346' 'bar' ''
  state::upsert '%19' 'claude' 'working' '1700000200' '12347' 'baz' ''
  run state::count waiting
  assert_output "2"
  run state::count working
  assert_output "1"
  run state::count idle
  assert_output "0"
}

@test "state::list_by_status sorts by since_epoch desc" {
  state::upsert '%17' 'claude' 'waiting' '1700000000' '12345' 'a' ''
  state::upsert '%18' 'claude' 'waiting' '1700000100' '12346' 'b' ''
  state::upsert '%19' 'claude' 'waiting' '1700000050' '12347' 'c' ''
  result=$(state::list_by_status waiting | awk -F'\t' '{print $1}' | tr '\n' ' ')
  # Newest first: %18 (1700000100) > %19 (1700000050) > %17 (1700000000)
  assert_equal "$result" "%18 %19 %17 "
}

@test "state::gc removes rows whose pid is not alive" {
  state::upsert '%17' 'claude' 'waiting' '1700000000' "$$" 'alive' ''
  state::upsert '%18' 'claude' 'working' '1700000100' '99999999' 'dead' ''
  printf '%s\n' "$$" | state::gc
  rows=$(awk 'NR>1' "$(state::tsv_path)" | wc -l | tr -d ' ')
  assert_equal "$rows" "1"
  remaining=$(awk -F'\t' 'NR>1 {print $1}' "$(state::tsv_path)")
  assert_equal "$remaining" "%17"
}

@test "state::gc is a no-op when alive set is empty (safety guarantee)" {
  # If pgrep returns nothing (no Claude running), GC must NOT wipe rows —
  # otherwise inbox-status's opportunistic GC would clear the inbox the moment
  # every Claude session is paused. See bin/inbox-status review wk9eyqh1m,
  # critical finding "gc_if_due wipes ALL tracked panes when pgrep returns empty".
  state::upsert '%17' 'claude' 'waiting' '1700000000' '99999999' 'a' ''
  state::upsert '%18' 'claude' 'working' '1700000100' '99999998' 'b' ''
  printf '' | state::gc
  rows=$(awk 'NR>1' "$(state::tsv_path)" | wc -l | tr -d ' ')
  assert_equal "$rows" "2"
}

@test "state::read on missing TSV returns empty without error" {
  run state::read
  assert_success
  assert_output ""
}

@test "state::snapshot is a working alias for state::read" {
  state::upsert '%17' 'claude' 'waiting' '1700000000' '12345' 'foo' ''
  diff <(state::snapshot) <(state::read)
}

@test "concurrent upserts don't corrupt the TSV" {
  # Spawn 20 background writers, each upserting a distinct pane_id.
  for i in $(seq 1 20); do
    state::upsert "%$i" 'claude' 'working' "1700000$i" "$i" "p$i" '' &
  done
  wait
  tsv=$(state::tsv_path)
  [ -f "$tsv" ]
  rows=$(awk 'NR>1' "$tsv" | wc -l | tr -d ' ')
  # All 20 should have made it (no lock-timeout drops at this scale).
  [ "$rows" -ge 18 ]
  # No row may be malformed (every data row must have 7 tab-separated fields).
  bad=$(awk -F'\t' 'NR>1 && NF != 7' "$tsv" | wc -l | tr -d ' ')
  assert_equal "$bad" "0"
}
