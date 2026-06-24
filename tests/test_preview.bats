#!/usr/bin/env bats
# tests/test_preview.bats — bin/inbox-preview rows-file lookup contract.
#
# Pins the popup-open performance fix: when bin/inbox-popup invokes
# --preview, it passes the snapshot rows-file path as a 2nd argv. Preview
# must read from that file (no flock per arrow keypress) and must fall
# back gracefully when the file is missing or the row is absent.

load test_helper

setup() {
  setup_isolated_cache
  use_mocks
}

# Build a single-row TSV at the given path with the given pane_id and project.
make_rows_file() {
  local path="$1" pane_id="$2" project="$3"
  printf '%s\tclaude\tworking\t%d\t12345\t%s\t/tmp/x.jsonl\n' \
    "$pane_id" "$(($(date +%s) - 30))" "$project" >"$path"
}

@test "inbox-preview reads project from rows-file when supplied" {
  rows="${BATS_TEST_TMPDIR}/rows.tsv"
  make_rows_file "$rows" '%42' 'myproj'
  run "$BIN/inbox-preview" '%42' "$rows"
  assert_success
  # First line is the header: "<glyph> <state>  <project>  ·  <age>".
  case "$output" in
    *myproj*) ;;
    *)
      echo "expected project 'myproj' in preview header"
      echo "output: $output"
      return 1
      ;;
  esac
}

@test "inbox-preview falls through to state::read when rows-file lacks the queried pane" {
  # When the snapshot doesn't contain the pane (race: a new upsert landed
  # after inbox-pick took the snapshot), preview must fall through to
  # state::read so the user sees real data instead of '(untracked)'.
  rows="${BATS_TEST_TMPDIR}/rows.tsv"
  make_rows_file "$rows" '%17' 'other'
  # Stage state.tsv with the queried pane via state::upsert.
  source "$LIB/state.sh"
  state::upsert '%42' 'claude' 'waiting' "$(($(date +%s) - 30))" '12345' 'racewinner' '/tmp/x.jsonl'
  run "$BIN/inbox-preview" '%42' "$rows"
  assert_success
  case "$output" in
    *racewinner*) ;;
    *)
      echo "expected fall-through to state::read to find 'racewinner'"
      echo "output: $output"
      return 1
      ;;
  esac
}

@test "inbox-preview renders (untracked) when neither snapshot nor state has the pane" {
  # If the snapshot is empty AND state.tsv has no row for the pane, the
  # header must safely degrade to '(untracked)' without erroring.
  rows="${BATS_TEST_TMPDIR}/rows.tsv"
  : >"$rows"
  run "$BIN/inbox-preview" '%42' "$rows"
  assert_success
  case "$output" in
    *'(untracked)'*) ;;
    *)
      echo "expected '(untracked)' header for fully-unknown pane"
      echo "output: $output"
      return 1
      ;;
  esac
}

@test "inbox-preview falls back to state::read when no rows-file arg given" {
  # Direct invocation (e.g. tests, manual debug). With no rows-file, preview
  # sources lib/state.sh and reads from the live TSV under LOCK_SH.
  source "$LIB/state.sh"
  state::upsert '%42' 'claude' 'waiting' "$(($(date +%s) - 30))" '12345' 'fallbackproj' '/tmp/y.jsonl'
  run "$BIN/inbox-preview" '%42'
  assert_success
  case "$output" in
    *fallbackproj*) ;;
    *)
      echo "expected project 'fallbackproj' from state::read fallback"
      echo "output: $output"
      return 1
      ;;
  esac
}

@test "inbox-preview tolerates an unreadable rows-file path without erroring" {
  # If the snapshot tempfile was rm'd (parent's EXIT trap raced ahead),
  # preview must still degrade rather than crash. With an empty cache the
  # state::read fallback returns no row, so the header reports (untracked).
  run "$BIN/inbox-preview" '%42' "${BATS_TEST_TMPDIR}/no-such-file"
  assert_success
  case "$output" in
    *'(untracked)'*) ;;
    *)
      echo "expected '(untracked)' for missing rows-file"
      echo "output: $output"
      return 1
      ;;
  esac
}
