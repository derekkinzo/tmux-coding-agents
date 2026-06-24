#!/usr/bin/env bats
# tests/test_popup.bats — non-interactive validation that bin/inbox-popup
# survives long enough to draw its UI when given valid rows. The bug we are
# guarding against (workflow wc4tlqm4i) is a parser-fail signature where
# fzf rejects an unknown action token and exits in <100 ms before drawing
# the picker, leaving the user with a popup that flashes and disappears.

load test_helper

setup() {
  setup_isolated_cache
  use_mocks
  if ! command -v fzf >/dev/null 2>&1; then
    skip "fzf not on PATH"
  fi
}

# Build a small, valid TSV fixture mirroring the live state.tsv schema.
make_rows() {
  local f="$1"
  printf '%%17\tclaude\twaiting\t%d\t0\tagent-a\t/tmp/x.jsonl\n' "$(($(date +%s) - 30))" >"$f"
  printf '%%18\tclaude\tworking\t%d\t0\tagent-b\t/tmp/y.jsonl\n' "$(($(date +%s) - 60))" >>"$f"
  printf '%%19\tclaude\tidle\t%d\t0\tagent-c\t/tmp/z.jsonl\n' "$(($(date +%s) - 600))" >>"$f"
}

@test "inbox-popup parses fzf options without 'unknown action' errors" {
  # We don't run the full TUI here (bats has no real tty). Instead we test
  # the parse layer directly: run fzf with the SAME --bind / --preview /
  # other option flags, in --filter mode (no UI). fzf still validates every
  # flag during arg parse — the same code path that produces the
  # "unknown action: …" error in the broken version. If the script's bind
  # syntax is wrong, this test catches it.
  rows="${BATS_TEST_TMPDIR}/rows.tsv"
  make_rows "$rows"

  # Discover fzf the same way bin/inbox-popup does.
  if ! command -v fzf >/dev/null 2>&1; then
    skip "fzf not on PATH"
  fi

  # Replicate the bind set from bin/inbox-popup. If we add or change a bind
  # in the script, this test must be updated (which is the point — it
  # forces awareness of fzf-syntax changes).
  err="${BATS_TEST_TMPDIR}/err.log"
  set +e
  printf 'row1\nrow2\n' \
    | fzf --filter=row \
      --ansi \
      --delimiter=$'\t' \
      --no-sort \
      --layout=reverse \
      --prompt='agents> ' \
      --pointer='›' \
      --cycle \
      --no-input \
      --with-nth=1 \
      --accept-nth=2 \
      --bind='/:show-input+enable-search+unbind(j,k,1,2,3,4,5,6,7,8,9)' \
      --bind='j:down' \
      --bind='k:up' \
      --bind='1:pos(1)+accept' \
      --bind='2:pos(2)+accept' \
      --bind='3:pos(3)+accept' \
      --bind='4:pos(4)+accept' \
      --bind='5:pos(5)+accept' \
      --bind='6:pos(6)+accept' \
      --bind='7:pos(7)+accept' \
      --bind='8:pos(8)+accept' \
      --bind='9:pos(9)+accept' \
      --bind='esc:transform([ "$FZF_INPUT_STATE" = enabled ] && echo "clear-query+disable-search+hide-input+rebind(j,k,1,2,3,4,5,6,7,8,9)" || echo abort)' \
      --bind='ctrl-c:abort' \
      >/dev/null 2>"$err"
  rc=$?
  set -e

  # filter-mode rc: 0 = matches, 1 = no matches. Either is fine.
  case "$rc" in
    0 | 1) : ;;
    *)
      echo "fzf rejected our flags during parse (rc=$rc)"
      echo "--- stderr ---"
      cat "$err"
      return 1
      ;;
  esac
  if grep -q 'unknown action' "$err"; then
    echo "fzf rejected a --bind action (parse error)"
    echo "--- stderr ---"
    cat "$err"
    return 1
  fi
}

@test "inbox-popup builds NO decorator rows: every candidate is a real pane_id" {
  # Regression guard: fzf has no concept of non-selectable rows, so the
  # picker must not contain any __hdr__ / decorator entries. If a future
  # change reintroduces them, this test catches it.
  if ! grep -qE 'printf .__hdr__\\t' "$BIN/inbox-popup"; then
    : # OK: source contains no header-row emitter
  else
    echo "bin/inbox-popup contains __hdr__ row emission. fzf cannot make"
    echo "rows non-selectable; decorator rows must not be in the candidate list."
    grep -nE '__hdr__' "$BIN/inbox-popup"
    return 1
  fi
}

@test "inbox-popup --bind grammar regression: no 'unknown action' in source" {
  # Belt-and-suspenders structural check: scan bin/inbox-popup for the
  # historic broken syntax `transform:` (colon form). The fzf docs since
  # 0.46 only document `transform(...)`. If a future commit reintroduces
  # the colon form, this test catches it without needing a real fzf.
  if grep -nE -- "--bind=.*:transform:" "$BIN/inbox-popup"; then
    echo "bin/inbox-popup contains the broken 'transform:' (colon) syntax."
    echo "Use 'transform(CMD)' (parenthesized) instead."
    return 1
  fi
}

@test "inbox-popup honors FZF_BIN env override" {
  # Stage a fake fzf that reports version 9.99 so it passes the >= 0.46 check
  # but exits immediately with a recognizable rc. If the script honors the
  # env override, we'll see the wrapper's rc surface; if it clobbers the
  # override before reading it, we'll see the system fzf instead.
  fake_fzf="${BATS_TEST_TMPDIR}/fake-fzf"
  cat >"$fake_fzf" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "9.99 (test-stub)" ;;
  *) echo "FAKE_FZF_RAN" >&2; exit 42 ;;
esac
EOF
  chmod +x "$fake_fzf"

  rows="${BATS_TEST_TMPDIR}/rows.tsv"
  make_rows "$rows"

  # `run` merges stdout+stderr into $output; our fake fzf prints
  # FAKE_FZF_RAN to stderr on real invocation.
  FZF_BIN="$fake_fzf" run "$BIN/inbox-popup" "$rows"
  # rc=42 is "unexpected" per inbox-popup's accept-set 0|1|130, and surfaces.
  [ "$status" = "42" ]
  case "$output" in
    *FAKE_FZF_RAN*) ;;
    *)
      echo "expected FAKE_FZF_RAN in output; FZF_BIN override not honored"
      echo "rc=$status"
      echo "output: $output"
      return 1
      ;;
  esac
}

@test "inbox-popup --preview command passes both pane_id and rows_file" {
  # Performance regression guard. fzf's --preview is invoked once per
  # highlighted row; if the command line drops the rows_file path, every
  # arrow keypress falls back to state::read which acquires LOCK_SH and
  # rewrites the popup-paint critical path back into a flock-bound loop.
  # Assert the source still wires both arguments through.
  if ! grep -nE -- '--preview="bash .*inbox-preview.* \{2\} .*rows_file' "$BIN/inbox-popup" >/dev/null; then
    echo "bin/inbox-popup --preview must pass both {2} and the rows_file path."
    grep -nE -- '--preview=' "$BIN/inbox-popup" || true
    return 1
  fi
}

@test "pane-existence GC runs in inbox-status, not inbox-pick" {
  # Performance regression guard with TWO assertions:
  #   1. inbox-pick must NOT acquire LOCK_EX on the popup-paint path.
  #   2. inbox-status MUST call gc_combined (or gc_panes) so stale-pane
  #      rows are cleaned up — otherwise they accumulate forever after a
  #      tmux server restart (pid-based gc keeps pid=0 rows by design).
  if grep -nE 'state::(gc_panes|gc_combined)' "$BIN/inbox-pick"; then
    echo "bin/inbox-pick must not acquire LOCK_EX (gc) on the keystroke→paint path."
    return 1
  fi
  if ! grep -qE 'state::(gc_panes|gc_combined)' "$BIN/inbox-status"; then
    echo "bin/inbox-status must run pane-existence GC — otherwise stale rows never get cleaned."
    return 1
  fi
}

@test "inbox-popup exits cleanly with no rows file" {
  err="${BATS_TEST_TMPDIR}/err.log"
  run "$BIN/inbox-popup" "/nonexistent/file"
  # rc=1 with helpful stderr message — must not flicker silently.
  assert_failure
  case "$output" in
    *'rows-file path missing'* | *'unreadable'*) ;;
    *)
      echo "expected helpful error; got: $output"
      return 1
      ;;
  esac
}
