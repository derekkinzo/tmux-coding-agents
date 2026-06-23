#!/usr/bin/env bats
# tests/test_hooks.bats — hooks::installed sentinel-cache behavior.

load test_helper

setup() {
  setup_isolated_cache
  use_mocks
  export CLAUDE_SETTINGS="${BATS_TEST_TMPDIR}/settings.json"
  source "$LIB/state.sh"
  source "$LIB/hooks.sh"
}

teardown() {
  unset CLAUDE_SETTINGS
}

# Write a settings.json that wires bin/hook (so hooks::_verify_uncached returns 0).
_write_wired_settings() {
  cat >"$CLAUDE_SETTINGS" <<EOF
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"/path/to/tmux-coding-agents/bin/hook UserPromptSubmit"}]}]}}
EOF
}

# Write a settings.json that does NOT wire our hook.
_write_unwired_settings() {
  cat >"$CLAUDE_SETTINGS" <<'EOF'
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"/other/tool"}]}]}}
EOF
}

_sentinel_path() {
  printf '%s/.hooks-installed' "$(state::cache_dir)"
}

@test "hooks::installed returns 0 on wired settings + writes sentinel" {
  _write_wired_settings
  hooks::clear_sentinel
  run hooks::installed
  assert_success
  [ -r "$(_sentinel_path)" ]
}

@test "hooks::installed returns non-zero on unwired settings" {
  _write_unwired_settings
  hooks::clear_sentinel
  run hooks::installed
  assert_failure
}

@test "hooks::installed cache hit avoids re-parsing settings" {
  # Sentinel-cache contract: when the sentinel's recorded mtime is >= the
  # settings file's current mtime, hooks::installed returns success
  # WITHOUT reading the file. Stage a sentinel for an unwired settings
  # file to prove the cache short-circuits the verification.
  _write_unwired_settings
  current_mtime="$(date -r "$CLAUDE_SETTINGS" +%s 2>/dev/null \
    || stat -c %Y "$CLAUDE_SETTINGS" 2>/dev/null \
    || stat -f %m "$CLAUDE_SETTINGS")"
  # Plant a sentinel claiming "verified at current mtime". If the cache
  # short-circuits as designed, hooks::installed returns 0 even though jq
  # would actually return 1.
  printf '%s' "$current_mtime" >"$(_sentinel_path)"
  run hooks::installed
  assert_success
}

@test "hooks::installed cache invalidates when settings is touched (newer mtime)" {
  _write_wired_settings
  hooks::clear_sentinel
  hooks::installed
  # Bump settings mtime FORWARD, then replace it with unwired content.
  # The cached sentinel mtime is older than the file's new mtime, so we
  # must re-verify and find that the hook is gone.
  sleep 1
  _write_unwired_settings
  run hooks::installed
  assert_failure
}

@test "hooks::installed returns non-zero on missing settings" {
  rm -f "$CLAUDE_SETTINGS"
  hooks::clear_sentinel
  run hooks::installed
  assert_failure
}

@test "hooks::installed survives a corrupted sentinel (non-numeric content)" {
  _write_wired_settings
  hooks::clear_sentinel
  # Write garbage into the sentinel. The cache parser must treat it as
  # mtime=0 and fall through to verification, not panic on the bad input.
  printf '%s' 'XXX-not-a-number' >"$(_sentinel_path)"
  run hooks::installed
  assert_success
}

@test "hooks::installed sentinel stores PRE-jq mtime (TOCTOU regression)" {
  # Regression guard for the captured-mtime bug: the sentinel must record
  # the settings-file mtime as captured BEFORE jq runs. If jq writes
  # post-jq mtime instead, a touch landing during jq leaves the sentinel
  # claiming "verified up to a time later than what was actually
  # verified", and the next call returns a false-positive cache hit.
  _write_wired_settings
  hooks::clear_sentinel
  # Snapshot the file mtime we EXPECT the sentinel to record.
  expected_mtime="$(date -r "$CLAUDE_SETTINGS" +%s 2>/dev/null \
    || stat -c %Y "$CLAUDE_SETTINGS" 2>/dev/null \
    || stat -f %m "$CLAUDE_SETTINGS")"
  hooks::installed
  recorded_mtime="$(cat "$(_sentinel_path)")"
  assert_equal "$recorded_mtime" "$expected_mtime"
}

@test "hooks::installed accepts legacy nested-object hook shape" {
  # install-hooks normalizes legacy {matcher: [...]} object shape into the
  # array shape on write, but a hand-edited or imported settings.json may
  # still carry the legacy form with our hook present. The verifier must
  # walk both shapes — otherwise the cache locks in a false-negative until
  # the user runs install-hooks to re-normalize.
  cat >"$CLAUDE_SETTINGS" <<'EOF'
{"hooks":{"PreToolUse":{"Bash":[{"type":"command","command":"/path/to/tmux-coding-agents/bin/hook PreToolUse"}]}}}
EOF
  hooks::clear_sentinel
  run hooks::installed
  assert_success
}

@test "hooks::installed invalidates cache when settings mtime moves backward" {
  # Regression guard for the mtime-equality fix: a file replacement that
  # leaves the mtime LOWER than the sentinel (cp -p from dotfiles, restore
  # from .bak.*, touch -t with an older time) must invalidate the cache
  # rather than producing a false-positive hit. The pre-fix code used >=
  # which would treat older content as "verified".
  _write_wired_settings
  hooks::clear_sentinel
  hooks::installed
  # Roll mtime BACKWARD to a fixed historical value and swap to unwired content.
  _write_unwired_settings
  touch -t 200001010000 "$CLAUDE_SETTINGS"
  run hooks::installed
  assert_failure
}
