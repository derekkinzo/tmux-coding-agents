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

@test "install-hooks wires all 6 events (no SessionStart)" {
  cp "$FIXTURES/settings_empty.json" "$CLAUDE_SETTINGS"
  "$BIN/install-hooks" >/dev/null
  for ev in UserPromptSubmit PreToolUse PostToolUse Notification Stop SessionEnd; do
    n=$(jq --arg e "$ev" '.hooks[$e] | length' "$CLAUDE_SETTINGS")
    [ "$n" -ge 1 ]
  done
  # SessionStart should NOT be wired (we don't transition on it).
  n=$(jq '.hooks.SessionStart // [] | length' "$CLAUDE_SETTINGS")
  [ "$n" = "0" ]
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

  # JSON must still parse and have exactly 6 hooks (one per event).
  jq -e . "$CLAUDE_SETTINGS" >/dev/null
  n=$(jq '[.hooks[] | length] | add' "$CLAUDE_SETTINGS")
  assert_equal "$n" "6"
}

@test "install-hooks preserves dotfiles symlink (write through cat, not mv)" {
  # User's actual settings live in dotfiles repo and are symlinked into ~/.claude.
  real_target="${BATS_TEST_TMPDIR}/dotfiles/settings.json"
  mkdir -p "$(dirname "$real_target")"
  cp "$FIXTURES/settings_with_user_hooks.json" "$real_target"
  rm -f "$CLAUDE_SETTINGS"
  ln -s "$real_target" "$CLAUDE_SETTINGS"
  inode_before=$(stat -c %i "$CLAUDE_SETTINGS" 2>/dev/null || stat -f %i "$CLAUDE_SETTINGS")
  "$BIN/install-hooks" >/dev/null
  # Symlink must still be a symlink (not replaced by a regular file).
  [ -L "$CLAUDE_SETTINGS" ]
  inode_after=$(stat -c %i "$CLAUDE_SETTINGS" 2>/dev/null || stat -f %i "$CLAUDE_SETTINGS")
  assert_equal "$inode_after" "$inode_before"
  # Real target now contains our hook entries.
  ours=$(jq -r '[.hooks[]?[]?.hooks[]?.command] | join(" ")' "$real_target" \
    | grep -c 'tmux-coding-agents/bin/hook' || true)
  [ "$ours" -ge 1 ]
}

@test "uninstall-hooks --restore replaces from most recent .bak" {
  cp "$FIXTURES/settings_with_user_hooks.json" "$CLAUDE_SETTINGS"
  pre_hash=$(jq -S -c . "$CLAUDE_SETTINGS")
  "$BIN/install-hooks" >/dev/null
  # Modify settings further to ensure restore actually changes content.
  jq '.somethingElse = "added"' "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.new"
  mv "$CLAUDE_SETTINGS.new" "$CLAUDE_SETTINGS"
  run "$BIN/uninstall-hooks" --restore
  assert_success
  post_hash=$(jq -S -c . "$CLAUDE_SETTINGS")
  assert_equal "$post_hash" "$pre_hash"
}

@test "uninstall-hooks --restore writes a pre-restore backup of the current file" {
  # Pre-restore backup pins the C12 fix: --restore must snapshot the
  # current settings.json under a distinct .prerestore.* namespace before
  # overwriting from the chosen .bak.*. Without this, picking the wrong
  # backup is irreversible.
  cp "$FIXTURES/settings_with_user_hooks.json" "$CLAUDE_SETTINGS"
  "$BIN/install-hooks" >/dev/null
  # Modify settings further so the current state is distinct from the .bak.
  jq '.somethingElse = "added"' "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.new"
  mv "$CLAUDE_SETTINGS.new" "$CLAUDE_SETTINGS"
  pre_restore_hash=$(jq -S -c . "$CLAUDE_SETTINGS")
  run "$BIN/uninstall-hooks" --restore
  assert_success
  # A .prerestore.* file must exist and match the pre-restore content.
  prerestore_count=$(ls "${CLAUDE_SETTINGS}".prerestore.* 2>/dev/null | wc -l | tr -d ' ')
  assert_equal "$prerestore_count" "1"
  prerestore_file=$(ls "${CLAUDE_SETTINGS}".prerestore.* 2>/dev/null | head -1)
  prerestore_content_hash=$(jq -S -c . "$prerestore_file")
  assert_equal "$prerestore_content_hash" "$pre_restore_hash"
  # The pre-restore file must NOT be in the .bak.* namespace, otherwise
  # the next --restore would pick it as a candidate.
  case "$prerestore_file" in
    *.bak.*) echo "prerestore file landed in .bak.* namespace: $prerestore_file" ; return 1 ;;
  esac
}

@test "uninstall-hooks --restore is atomic: invalid .bak.* leaves live file untouched" {
  # Atomicity pin: the restore writes to a same-dir tmpfile, validates JSON,
  # then mv -fs into place. If the chosen .bak.* is not valid JSON, the
  # staged tmpfile is rejected and the live settings.json must be byte-
  # identical to its pre-restore state — no truncation, no partial write.
  cp "$FIXTURES/settings_with_user_hooks.json" "$CLAUDE_SETTINGS"
  "$BIN/install-hooks" >/dev/null
  pre_hash=$(jq -S -c . "$CLAUDE_SETTINGS")
  # Plant a corrupt .bak with a future timestamp so `ls -t` picks it first.
  echo 'not valid JSON' > "${CLAUDE_SETTINGS}.bak.99999999999"
  run "$BIN/uninstall-hooks" --restore
  assert_failure
  # Live file must still parse and match the pre-restore content.
  post_hash=$(jq -S -c . "$CLAUDE_SETTINGS")
  assert_equal "$post_hash" "$pre_hash"
  # No partial tmpfile leaks in the settings dir.
  leak_count=$(ls "$(dirname "$CLAUDE_SETTINGS")"/.settings.json.* 2>/dev/null | wc -l | tr -d ' ')
  assert_equal "$leak_count" "0"
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

@test "uninstall-hooks preserves dotfiles symlink (write through cat, not mv)" {
  # Matches the install-side symlink test. The uninstaller must overwrite
  # the symlink target via cat rather than mv, so the symlink inode is
  # preserved and the user's dotfiles workflow doesn't break.
  real_target="${BATS_TEST_TMPDIR}/dotfiles/settings.json"
  mkdir -p "$(dirname "$real_target")"
  cp "$FIXTURES/settings_with_user_hooks.json" "$real_target"
  rm -f "$CLAUDE_SETTINGS"
  ln -s "$real_target" "$CLAUDE_SETTINGS"
  "$BIN/install-hooks" >/dev/null
  inode_before=$(stat -c %i "$CLAUDE_SETTINGS" 2>/dev/null || stat -f %i "$CLAUDE_SETTINGS")
  "$BIN/uninstall-hooks" >/dev/null
  [ -L "$CLAUDE_SETTINGS" ]
  inode_after=$(stat -c %i "$CLAUDE_SETTINGS" 2>/dev/null || stat -f %i "$CLAUDE_SETTINGS")
  assert_equal "$inode_after" "$inode_before"
  # Our hooks are gone from the real target.
  ours=$(jq -r '[.hooks[]?[]?.hooks[]?.command // empty] | join(" ")' "$real_target" \
    | grep -c 'tmux-coding-agents/bin/hook' || true)
  assert_equal "$ours" "0"
}

@test "uninstall-hooks refuses to write if input is invalid JSON" {
  # Matches the install-side test. Uninstall must validate input before
  # any mutation so a corrupt settings file is left exactly as found.
  echo '{bad json' > "$CLAUDE_SETTINGS"
  run "$BIN/uninstall-hooks"
  assert_failure
  content=$(cat "$CLAUDE_SETTINGS")
  assert_equal "$content" "{bad json"
}

@test "uninstall-hooks --restore refuses corrupted .bak.* (does not overwrite)" {
  # If the most recent .bak.* is itself broken JSON, restore must REFUSE
  # rather than blow up the live settings.json with garbage.
  cp "$FIXTURES/settings_with_user_hooks.json" "$CLAUDE_SETTINGS"
  pre_hash=$(jq -S -c . "$CLAUDE_SETTINGS")
  # Plant a corrupted .bak with a future-looking timestamp so it sorts first
  # under `ls -t`.
  echo '{not json' > "${CLAUDE_SETTINGS}.bak.99999999999"
  run "$BIN/uninstall-hooks" --restore
  assert_failure
  # Live file must be untouched.
  post_hash=$(jq -S -c . "$CLAUDE_SETTINGS")
  assert_equal "$post_hash" "$pre_hash"
}

@test "uninstall-hooks removes our entries from legacy nested-object shape" {
  # Mirror of the install-side legacy-shape test. The uninstaller's jq
  # filter must normalize the legacy {matcher: [...]} form to the array
  # shape before stripping our entries, OR walk both shapes; either way
  # the user's legacy entry must survive and ours must be gone.
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
  "$BIN/install-hooks" >/dev/null
  "$BIN/uninstall-hooks" >/dev/null
  # User's legacy tool survives.
  preserved=$(jq -r '[.hooks[]?[]?.hooks[]?.command // empty] | join(" ")' "$CLAUDE_SETTINGS")
  case "$preserved" in *"/usr/bin/legacy-tool"*) ;; *) echo "lost legacy entry: $preserved" ; false ;; esac
  # Our hooks are gone.
  case "$preserved" in
    *"tmux-coding-agents/bin/hook"*) echo "uninstall left our hook: $preserved" ; false ;;
    *) ;;
  esac
}
