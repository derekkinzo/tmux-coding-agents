#!/usr/bin/env bats
# tests/test_install_hooks.bats — hook installer idempotency + preservation.

load test_helper

setup() {
  setup_isolated_cache
  export CLAUDE_SETTINGS="${BATS_TEST_TMPDIR}/settings.json"
}

teardown() {
  rm -f "$CLAUDE_SETTINGS"
}

@test "install-hooks creates settings.json if missing" {
  rm -f "$CLAUDE_SETTINGS"
  run "$BIN/install-hooks"
  assert_success
  [ -f "$CLAUDE_SETTINGS" ]
  jq -e . "$CLAUDE_SETTINGS" >/dev/null
}

@test "install-hooks wires all 7 events" {
  cp "$FIXTURES/settings_empty.json" "$CLAUDE_SETTINGS"
  "$BIN/install-hooks" >/dev/null
  for ev in SessionStart UserPromptSubmit PreToolUse PostToolUse Notification Stop SessionEnd; do
    n=$(jq --arg e "$ev" '.hooks[$e] | length' "$CLAUDE_SETTINGS")
    [ "$n" -ge 1 ]
  done
}

@test "install-hooks is idempotent (re-run does not duplicate)" {
  cp "$FIXTURES/settings_empty.json" "$CLAUDE_SETTINGS"
  "$BIN/install-hooks" >/dev/null
  count1=$(jq '[.hooks[] | length] | add' "$CLAUDE_SETTINGS")
  "$BIN/install-hooks" >/dev/null
  count2=$(jq '[.hooks[] | length] | add' "$CLAUDE_SETTINGS")
  assert_equal "$count2" "$count1"
}

@test "install-hooks preserves user-owned config" {
  cp "$FIXTURES/settings_with_user_hooks.json" "$CLAUDE_SETTINGS"
  "$BIN/install-hooks" >/dev/null
  aws=$(jq -r .awsCredentialExport "$CLAUDE_SETTINGS")
  assert_equal "$aws" "/path/to/creds"
  perms=$(jq -r '.permissions.allow | join(",")' "$CLAUDE_SETTINGS")
  assert_equal "$perms" "Read,Bash(ls *)"
}

@test "install-hooks preserves user hooks alongside ours" {
  cp "$FIXTURES/settings_with_user_hooks.json" "$CLAUDE_SETTINGS"
  "$BIN/install-hooks" >/dev/null
  preserved=$(jq -r '.hooks.Stop | map(.hooks[].command) | join(" ")' "$CLAUDE_SETTINGS")
  case "$preserved" in *"my-other-tool"*) ;; *) false ;; esac
}

@test "install-hooks creates a backup file" {
  cp "$FIXTURES/settings_empty.json" "$CLAUDE_SETTINGS"
  "$BIN/install-hooks" >/dev/null
  bak=$(ls "${CLAUDE_SETTINGS}".bak.* 2>/dev/null | head -1)
  [ -n "$bak" ]
  [ -f "$bak" ]
}

@test "install-hooks refuses to write if input is invalid JSON" {
  echo '{bad json' > "$CLAUDE_SETTINGS"
  run "$BIN/install-hooks"
  assert_failure
  # Original file should be untouched.
  content=$(cat "$CLAUDE_SETTINGS")
  assert_equal "$content" "{bad json"
}

@test "uninstall-hooks removes our hooks but keeps user hooks" {
  cp "$FIXTURES/settings_with_user_hooks.json" "$CLAUDE_SETTINGS"
  "$BIN/install-hooks" >/dev/null
  "$BIN/uninstall-hooks" >/dev/null
  ours=$(jq -r '.hooks // {} | tostring' "$CLAUDE_SETTINGS" | grep -c 'tmux-coding-agents/bin/hook' || true)
  assert_equal "$ours" "0"
  preserved=$(jq -r '.hooks.Stop | map(.hooks[].command) | join(" ")' "$CLAUDE_SETTINGS")
  case "$preserved" in *"my-other-tool"*) ;; *) false ;; esac
}

@test "uninstall-hooks no-op on missing settings.json" {
  rm -f "$CLAUDE_SETTINGS"
  run "$BIN/uninstall-hooks"
  assert_success
}

@test "install-hooks handles legacy nested-object hook shape (matcher object form)" {
  cat > "$CLAUDE_SETTINGS" <<'EOF'
{
  "hooks": {
    "PreToolUse": {
      "Bash": [
        {"type": "command", "command": "/usr/bin/legacy-tool"}
      ]
    }
  }
}
EOF
  run "$BIN/install-hooks"
  assert_success
  # Legacy entry preserved.
  preserved=$(jq -r '[.hooks.PreToolUse[].hooks[].command] | join(" ")' "$CLAUDE_SETTINGS")
  case "$preserved" in *"/usr/bin/legacy-tool"*) ;; *) false ;; esac
  # Our entry added.
  case "$preserved" in *"bin/hook"*) ;; *) false ;; esac
}

@test "install-hooks: idempotent re-run on alt install path (no 'tmux-coding-agents' in path)" {
  cp "$FIXTURES/settings_empty.json" "$CLAUDE_SETTINGS"

  # Stage plugin files at a path that does NOT contain "tmux-coding-agents".
  alt="${BATS_TEST_TMPDIR}/some other dir"
  mkdir -p "$alt/bin" "$alt/lib"
  cp "$BIN/"* "$alt/bin/"
  cp "$LIB/"*.sh "$alt/lib/"
  chmod +x "$alt/bin/"*

  "$alt/bin/install-hooks" >/dev/null
  n1=$(jq '[.hooks[] | length] | add' "$CLAUDE_SETTINGS")
  "$alt/bin/install-hooks" >/dev/null
  n2=$(jq '[.hooks[] | length] | add' "$CLAUDE_SETTINGS")
  assert_equal "$n1" "$n2"
  # Hook command must contain spaces correctly quoted with @sh form.
  cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$CLAUDE_SETTINGS")
  case "$cmd" in
    *"'$alt/bin/hook'"*) ;;
    *) printf 'cmd=%s\n' "$cmd"; false ;;
  esac
}

@test "install-hooks: concurrent runs serialize via flock (no JSON corruption)" {
  cp "$FIXTURES/settings_empty.json" "$CLAUDE_SETTINGS"

  for _ in $(seq 1 5); do
    "$BIN/install-hooks" >/dev/null 2>&1 &
  done
  wait

  # JSON must still parse and have exactly 7 hooks (one per event).
  jq -e . "$CLAUDE_SETTINGS" >/dev/null
  n=$(jq '[.hooks[] | length] | add' "$CLAUDE_SETTINGS")
  assert_equal "$n" "7"
}

@test "uninstall-hooks: nothing-to-do path (no backup, no churn)" {
  cp "$FIXTURES/settings_with_user_hooks.json" "$CLAUDE_SETTINGS"
  before_mtime=$(stat -c %Y "$CLAUDE_SETTINGS" 2>/dev/null || stat -f %m "$CLAUDE_SETTINGS")
  # Wait one second to detect mtime changes if they happen.
  sleep 1
  run "$BIN/uninstall-hooks"
  assert_success
  after_mtime=$(stat -c %Y "$CLAUDE_SETTINGS" 2>/dev/null || stat -f %m "$CLAUDE_SETTINGS")
  assert_equal "$after_mtime" "$before_mtime"
  # No new .bak should be created.
  bak_count=$(ls "${CLAUDE_SETTINGS}".bak.* 2>/dev/null | wc -l | tr -d ' ')
  assert_equal "$bak_count" "0"
}
