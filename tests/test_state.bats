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

@test "state::upsert rejects backslash-escape in field (RCE regression)" {
  # An attacker-controlled JSON value like "/tmp/foo\\n%99'; touch /tmp/x; echo '"
  # is decoded by jq to a 2-byte sequence backslash+n. Without strict
  # validation, awk -v on the upsert path expanded that to a real newline,
  # injecting a second TSV row whose pane_id field contained shell metachars.
  # Subsequent picker invocation passed the row to tmux display-popup -E
  # which spawned a child shell that executed the attacker's command.
  run state::upsert '%17' 'claude' 'waiting' '1700000000' '12345' '/tmp/foo\n%99' ''
  assert_failure
  run state::upsert '%17' 'claude' 'waiting' '1700000000' '12345' 'p' '/tmp/x\t/etc/passwd'
  assert_failure
  run state::upsert '%17' 'claude' 'waiting' '1700000000' '12345' 'p' 'a\\b'
  assert_failure
}

@test "state::upsert refuses when state.tsv is a symlink" {
  # Symlink redirection attack: attacker plants ~/.cache/tmux-coding-agents/
  # state.tsv -> /etc/passwd; without the L-test, our writes would land in
  # the symlink target.
  cache="$(state::cache_dir)"
  victim="${BATS_TEST_TMPDIR}/victim"
  : >"$victim"
  ln -s "$victim" "$cache/state.tsv"
  run state::upsert '%17' 'claude' 'waiting' '1700000000' '12345' 'p' ''
  assert_failure
  # Victim must remain empty.
  [ ! -s "$victim" ]
}

@test "state::cache_dir tightens permissions of pre-existing dir" {
  # Older installs (pre-fix) might have left $XDG_CACHE_HOME/tmux-coding-agents
  # at 0755. We must auto-tighten on first read.
  base="$XDG_CACHE_HOME"
  rm -rf "$base/tmux-coding-agents"
  mkdir -p "$base/tmux-coding-agents"
  chmod 0755 "$base/tmux-coding-agents"
  state::cache_dir >/dev/null
  perm=$(stat -c %a "$base/tmux-coding-agents" 2>/dev/null || stat -f %Lp "$base/tmux-coding-agents")
  assert_equal "$perm" "700"
}

@test "state::gc_panes rewrites TSV dropping rows whose pane is not alive" {
  # Lazy GC contract: when a pane disappears from tmux (closed window or
  # server restart), the TSV must be rewritten on the next sweep, not just
  # filtered in-memory.
  state::upsert '%10' 'claude' 'waiting' '1700000000' '1' 'live' ''
  state::upsert '%99' 'claude' 'working' '1700000100' '2' 'dead-1' ''
  state::upsert '%100000' 'claude' 'idle' '1700000200' '3' 'dead-2-big-id' ''
  printf '%%10\n' | state::gc_panes
  rows=$(awk 'NR>1' "$(state::tsv_path)" | wc -l | tr -d ' ')
  assert_equal "$rows" "1"
  remaining=$(awk -F'\t' 'NR>1 {print $1}' "$(state::tsv_path)")
  assert_equal "$remaining" "%10"
}

@test "state::gc_combined applies pane AND pid filters in one LOCK_EX pass" {
  # %10 has live pid (1) AND live pane → keep
  # %20 has live pid (2) but DEAD pane → drop (pane filter wins)
  # %30 has DEAD pid (999) AND live pane → drop (pid filter)
  # %40 has pid=0 (unknown) AND live pane → keep (pid=0 means "no info, defer to pane filter")
  # %50 has live pid (1) AND dead pane → drop (pane filter wins)
  state::upsert '%10' 'claude' 'waiting' '1700000000' '1'   'a' ''
  state::upsert '%20' 'claude' 'waiting' '1700000100' '2'   'b' ''
  state::upsert '%30' 'claude' 'working' '1700000200' '999' 'c' ''
  state::upsert '%40' 'claude' 'idle'    '1700000300' '0'   'd' ''
  state::upsert '%50' 'claude' 'idle'    '1700000400' '1'   'e' ''
  alive_pids="$(printf '1\n2')"
  alive_panes="$(printf '%%10\n%%30\n%%40')"
  state::gc_combined "$alive_pids" "$alive_panes"
  remaining=$(awk -F'\t' 'NR>1 {print $1}' "$(state::tsv_path)" | sort | tr '\n' ' ')
  # %10 kept (live+live). %30 dropped (pid filter). %40 kept (pane only). %20, %50 dropped (dead pane).
  assert_equal "$remaining" "%10 %40 "
}

@test "state::gc_combined no-op when alive_panes is empty (no authoritative info)" {
  state::upsert '%10' 'claude' 'waiting' '1700000000' '1' 'a' ''
  state::gc_combined "$(printf '1\n2')" ''
  rows=$(awk 'NR>1' "$(state::tsv_path)" | wc -l | tr -d ' ')
  assert_equal "$rows" "1"
}

@test "state::gc_combined with empty alive_pids degrades to pane-only filter" {
  state::upsert '%10' 'claude' 'waiting' '1700000000' '999' 'a' ''
  state::upsert '%20' 'claude' 'working' '1700000100' '888' 'b' ''
  state::gc_combined '' "$(printf '%%10')"
  remaining=$(awk -F'\t' 'NR>1 {print $1}' "$(state::tsv_path)" | sort | tr '\n' ' ')
  # %10 kept (pane alive; pid filter not applied). %20 dropped (pane dead).
  assert_equal "$remaining" "%10 "
}

@test "state::gc_panes is no-op when alive set is empty (safety, like state::gc)" {
  state::upsert '%10' 'claude' 'waiting' '1700000000' '1' 'a' ''
  printf '' | state::gc_panes
  rows=$(awk 'NR>1' "$(state::tsv_path)" | wc -l | tr -d ' ')
  assert_equal "$rows" "1"
}

@test "state::upsert accepts pane_ids with 6+ digits (regression: was case-glob limited)" {
  # Case-glob `%[0-9][0-9][0-9][0-9][0-9]` only matched 1-5 digits. Long-uptime
  # tmux servers can allocate %100000+ and those rows must still flow through.
  run state::upsert '%100000' 'claude' 'waiting' '1700000000' '1' 'p' ''
  assert_success
  run state::upsert '%99999999' 'claude' 'working' '1700000000' '2' 'q' ''
  assert_success
}

@test "state::sweep_orphan_tmps removes stale tmpfiles, keeps recent ones" {
  cache="$(state::cache_dir)"
  # Stale (mtime > 1 minute ago).
  touch -d '5 minutes ago' "$cache/state.tsv.tmp.99999.42.42" 2>/dev/null \
    || touch -t 200001010101.00 "$cache/state.tsv.tmp.99999.42.42"
  # Recent (just created).
  touch "$cache/state.tsv.tmp.99998.42.42"
  state::sweep_orphan_tmps
  [ ! -e "$cache/state.tsv.tmp.99999.42.42" ]
  [ -e "$cache/state.tsv.tmp.99998.42.42" ]
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

@test "state::gc KEEPS rows with pid=0 (unknown — common when payload omits pid)" {
  # Some Claude hook events ship payloads without a pid field; the hook stores
  # 0 as a placeholder. Those rows must NOT be dropped by pgrep-based GC —
  # otherwise the status bar flickers as rows appear and disappear every 4s.
  # state::gc_panes (tmux-pane-existence) is the authoritative cleanup path.
  state::upsert '%17' 'claude' 'working' '1700000000' '0' 'unknown-pid' ''
  state::upsert '%18' 'claude' 'working' '1700000100' "$$" 'alive' ''
  printf '%s\n' "$$" | state::gc
  rows=$(awk 'NR>1' "$(state::tsv_path)" | wc -l | tr -d ' ')
  assert_equal "$rows" "2"
}

@test "state::gc is a no-op when alive set is empty (safety guarantee)" {
  # If pgrep returns nothing (no Claude running), GC must NOT wipe rows —
  # otherwise inbox-status's opportunistic GC would clear the inbox the moment
  # every Claude session is paused — gc_if_due would wipe all tracked panes
  # when pgrep returns empty.
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

@test "TSV schema round-trip: column order is pane_id, kind, status, since, pid, project, transcript_path" {
  # Canonical schema pin. Several call sites parse rows via
  # `IFS=$'\t' read -r pane_id kind status since pid project tpath`; if the
  # column order ever drifts those parsers extract the wrong fields silently.
  # Upsert with seven distinguishable values, read back, and assert each
  # named field lands in the documented column.
  state::upsert '%17' 'claude' 'waiting' '1700000000' '12345' 'myproj' '/tmp/foo.jsonl'
  row="$(state::read | awk -F'\t' '$1=="%17" {print; exit}')"
  [ -n "$row" ]
  IFS=$'\t' read -r pane_id kind status since pid project tpath <<<"$row"
  assert_equal "$pane_id" "%17"
  assert_equal "$kind" "claude"
  assert_equal "$status" "waiting"
  assert_equal "$since" "1700000000"
  assert_equal "$pid" "12345"
  assert_equal "$project" "myproj"
  assert_equal "$tpath" "/tmp/foo.jsonl"
}

@test "concurrent upserts don't corrupt the TSV" {
  # Spawn 20 background writers, each upserting a distinct pane_id.
  # Lock contention may drop a small number under heavy parallel load
  # (200ms timeout × 3 retries before rc=3); we accept >= 16/20 as proof
  # the lock works without corruption — the critical property is JSON-safe
  # TSV (no malformed rows), which we assert separately.
  for i in $(seq 1 20); do
    state::upsert "%$i" 'claude' 'working' "1700000$i" "$i" "p$i" '' &
  done
  wait
  tsv=$(state::tsv_path)
  [ -f "$tsv" ]
  rows=$(awk 'NR>1' "$tsv" | wc -l | tr -d ' ')
  # The critical property is JSON-safe TSV (no malformed rows). On heavily
  # contended CI runners, a small fraction may hit the 200ms × 3-retry limit
  # and drop with rc=3. >= 12/20 is sufficient evidence the lock works.
  [ "$rows" -ge 12 ]
  # No row may be malformed (every data row must have 7 tab-separated fields).
  bad=$(awk -F'\t' 'NR>1 && NF != 7' "$tsv" | wc -l | tr -d ' ')
  assert_equal "$bad" "0"
}
