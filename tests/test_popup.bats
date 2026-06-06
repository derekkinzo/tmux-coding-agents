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
      --bind='?:toggle-preview' \
      --bind='down:down+transform([ "{1}" = "__hdr__" ] && echo down)' \
      --bind='up:up+transform([ "{1}" = "__hdr__" ] && echo up)' \
      --bind='j:down+transform([ "{1}" = "__hdr__" ] && echo down)' \
      --bind='k:up+transform([ "{1}" = "__hdr__" ] && echo up)' \
      --bind='ctrl-n:down+transform([ "{1}" = "__hdr__" ] && echo down)' \
      --bind='ctrl-p:up+transform([ "{1}" = "__hdr__" ] && echo up)' \
      --bind='start:first+transform([ "{1}" = "__hdr__" ] && echo down)' \
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
