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
  # Sentinel-cache contract: when the sentinel's recorded fingerprint
  # matches the settings file's current fingerprint, hooks::installed
  # returns success WITHOUT running the jq verifier. Stage a sentinel for
  # an unwired settings file to prove the cache short-circuits the check.
  _write_unwired_settings
  current_fp="$(_hooks_fingerprint "$CLAUDE_SETTINGS")"
  printf '%s' "$current_fp" >"$(_sentinel_path)"
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

@test "hooks::installed survives a corrupted sentinel" {
  _write_wired_settings
  hooks::clear_sentinel
  # Garbage in the sentinel must NOT match any real fingerprint, so the
  # cache misses and falls through to verification — no panic on bad input.
  printf '%s' 'XXX-not-a-fingerprint' >"$(_sentinel_path)"
  run hooks::installed
  assert_success
}

@test "hooks::installed sentinel stores PRE-jq fingerprint (TOCTOU regression)" {
  # Regression guard for the captured-mtime bug: the sentinel must record
  # the settings-file fingerprint as captured BEFORE jq runs. If a future
  # change captures it post-jq, an edit landing during jq leaves the
  # sentinel claiming the post-edit state was verified, and the next call
  # returns a false-positive cache hit.
  _write_wired_settings
  hooks::clear_sentinel
  expected_fp="$(_hooks_fingerprint "$CLAUDE_SETTINGS")"
  hooks::installed
  recorded_fp="$(cat "$(_sentinel_path)")"
  assert_equal "$recorded_fp" "$expected_fp"
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

@test "hooks::installed invalidates cache on same-second edit (sub-second tiebreaker)" {
  # On coarse-mtime filesystems (HFS+, FAT, exFAT) an edit within the same
  # wall-clock second leaves mtime unchanged. The mtime+crc+size fingerprint
  # must catch this case: same mtime + different content = different
  # fingerprint = cache miss = re-verify.
  _write_wired_settings
  hooks::clear_sentinel
  hooks::installed
  # Capture mtime, swap content, then pin mtime to the captured value to
  # simulate a same-second edit even on fine-grained filesystems.
  prev_mtime="$(_hooks_mtime "$CLAUDE_SETTINGS")"
  _write_unwired_settings
  # touch -d @<epoch> is GNU; -t YYYYMMDDhhmm.ss is the BSD form.
  if ! touch -d "@$prev_mtime" "$CLAUDE_SETTINGS" 2>/dev/null; then
    ts="$(date -r "$prev_mtime" '+%Y%m%d%H%M.%S' 2>/dev/null || true)"
    if [ -n "$ts" ]; then
      touch -t "$ts" "$CLAUDE_SETTINGS"
    fi
  fi
  run hooks::installed
  assert_failure
}
