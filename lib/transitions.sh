# lib/transitions.sh — pure state-transition function.
#
# Function:
#   transitions::next <kind> <current_state> <event> <payload_json> -> new_state
#
#   Output: one of "idle", "working", "waiting", or "" to mean "remove the row".
#   Exit:   always 0.
#
# This is the single source of truth for the state machine. See docs/DESIGN.md
# Section 4 for the full table.
#
# Inputs:
#   kind            - "claude" (currently the only supported agent kind)
#   current_state   - "idle"|"working"|"waiting"|"" (empty = untracked / first event)
#   event           - "PreToolUse"|"PostToolUse"|"UserPromptSubmit"|"Stop"|"Notification"|"SessionEnd"
#   payload_json    - the full JSON envelope from Claude's hook (passed as one arg)
#
# This file is sourced. Depends on lib/jsonpb.sh.
# No shebang. set -u clean.

# Whether question-detection is enabled. Falls back to "on" if tmux option
# unset OR tmux is not on PATH (the hook can run from a Claude environment
# that inherits the tmux pane env but lacks the tmux binary).
_transitions_question_detect_enabled() {
  if ! command -v tmux >/dev/null 2>&1; then
    return 0
  fi
  local v
  v="$(tmux show-option -gqv '@inbox-question-detect' 2>/dev/null)"
  case "$v" in
    off | false | 0) return 1 ;;
    *) return 0 ;;
  esac
}

# Heuristic: does the last assistant message look like a question?
# Trims trailing whitespace, checks if the last (UTF-8 safe) char is in a small
# set of question terminators across common languages and conventions.
# Recognized: ASCII '?', Spanish '¿…?' (already covered by trailing ?), Greek
# question mark ';' (U+037E), Arabic question mark '؟' (U+061F), full-width
# Chinese/Japanese '？' (U+FF1F).
_transitions_looks_like_question() {
  local msg="$1"
  [ -n "$msg" ] || return 1

  # IMPORTANT: bash's ${var: -N} slices CODEPOINTS in a UTF-8 locale and BYTES
  # under LC_ALL=C. We need byte-level slicing to match raw multibyte sequences,
  # so we shell-out to `od` once per call (cost: ~0.5ms — negligible).
  #
  # Strategy: take last 4 bytes of the trimmed message, test against a small set
  # of question terminators across languages.
  #
  # Recognized terminators:
  #   '?'     ASCII (1 byte)              0x3F
  #   ';'     Greek ano teleia / ASCII semicolon (accepted false positive, 1 byte) 0x3B
  #   '؟'     Arabic question mark (2 bytes) 0xD8 0x9F
  #   '？'    Full-width question mark (3 bytes) 0xEF 0xBC 0x9F
  #
  # Note: the ASCII semicolon false positive is documented and accepted —
  # cleaner than a locale-dependent test for the rare Greek interrogative.

  # Trim trailing whitespace — ASCII (space/tab/LF/CR), NBSP (U+00A0,
  # 0xC2 0xA0), ZWSP/ZWJ/LTR/RTL marks (U+200B-200F: 0xE2 0x80 0x8B-0x8F).
  # IMPORTANT: bash slicing is codepoint-aware under UTF-8 locale, so we use
  # head -c byte-counted to perform the truncation. Cheap (<1ms per call).
  local trim_hex msg_bytes
  while [ -n "$msg" ]; do
    trim_hex=$(LC_ALL=C printf '%s' "$msg" \
      | LC_ALL=C tail -c 3 \
      | LC_ALL=C od -An -tx1 \
      | tr -d ' \n')
    msg_bytes=$(LC_ALL=C printf '%s' "$msg" | LC_ALL=C wc -c)
    case "$trim_hex" in
      *20 | *09 | *0a | *0d)
        # Drop 1 byte.
        msg=$(LC_ALL=C printf '%s' "$msg" | LC_ALL=C head -c $((msg_bytes - 1)))
        ;;
      *c2a0)
        # Drop 2 bytes (NBSP).
        msg=$(LC_ALL=C printf '%s' "$msg" | LC_ALL=C head -c $((msg_bytes - 2)))
        ;;
      *e2808[bcdef])
        # Drop 3 bytes (ZWSP / ZWJ / LTR / RTL marks).
        msg=$(LC_ALL=C printf '%s' "$msg" | LC_ALL=C head -c $((msg_bytes - 3)))
        ;;
      *) break ;;
    esac
  done
  [ -n "$msg" ] || return 1

  # Hex-dump last 3 bytes for byte-exact comparison.
  local tail_hex
  tail_hex=$(LC_ALL=C printf '%s' "$msg" \
    | LC_ALL=C tail -c 3 \
    | LC_ALL=C od -An -tx1 \
    | tr -d ' \n')

  # Test in order from longest to shortest match.
  case "$tail_hex" in
    *efbc9f) return 0 ;; # full-width ？
    *d89f) return 0 ;;   # Arabic ؟
    *3f) return 0 ;;     # ASCII '?'
      # ASCII ';' (0x3b) is intentionally NOT recognized: Greek U+037E shares
      # the glyph but is rare enough that false positives on normal text
      # outweigh true positives.
  esac
  return 1
}

transitions::next() {
  # shellcheck disable=SC2034  # kind reserved for multi-agent dispatch (Decision 16: future extensibility)
  local kind="$1" current="$2" event="$3" payload="${4:-}"

  # Untracked + SessionEnd is a no-op (still untracked).
  if [ -z "$current" ] && [ "$event" = "SessionEnd" ]; then
    printf ''
    return 0
  fi

  case "$event" in
    UserPromptSubmit | PreToolUse | PostToolUse)
      # PreToolUse / PostToolUse / UserPromptSubmit all express "Claude is
      # active right now". If the pane was previously 'waiting' (set by a
      # permission_prompt Notification or a question-on-Stop heuristic),
      # the act of running a tool means the human-needs-you signal has
      # been resolved — the user clicked Allow, or answered the question,
      # or otherwise unblocked the agent. Hold 'waiting' past that point
      # and the indicator goes stale (live trace caught NEED stuck for
      # 88+ seconds while tools streamed unchallenged).
      printf 'working'
      ;;
    Notification)
      # Per DESIGN Section 4: only permission_prompt produces 'waiting'.
      # Other Notification kinds (auth_success, elicitation_*) preserve current.
      # Claude has historically named the field either notification.kind or
      # notification_type — we accept either.
      local n_kind
      n_kind="$(jsonpb::peek_nested "$payload" 'notification.kind')"
      if [ -z "$n_kind" ]; then
        n_kind="$(jsonpb::peek "$payload" 'notification_type')"
      fi
      case "$n_kind" in
        permission_prompt)
          printf 'waiting'
          ;;
        *)
          # Unknown / non-permission notification → keep current.
          printf '%s' "$current"
          ;;
      esac
      ;;
    Stop)
      # Order matters:
      # 1. If background_tasks non-empty → working (parent idle, children active)
      # 2. If question-detect on AND last_assistant_message ends with ? → waiting
      # 3. Otherwise → idle
      local bg_count
      bg_count="$(jsonpb::array_len "$payload" 'background_tasks')"
      if [ "${bg_count:-0}" -gt 0 ]; then
        printf 'working'
        return 0
      fi
      if _transitions_question_detect_enabled; then
        local last_msg
        last_msg="$(jsonpb::peek "$payload" 'last_assistant_message')"
        # Tail-clamp for safety. Question heuristic only needs the trailing few
        # bytes; clamping caps the runtime + scrub cost on huge transcripts.
        # Take a generous tail then byte-truncate forward to a UTF-8 boundary.
        if [ "${#last_msg}" -gt 4096 ]; then
          # Take last 4096 bytes; then forward-trim any leading partial codepoint.
          last_msg="${last_msg: -4096}"
          # Drop leading continuation bytes (0x80-0xBF) — they're orphaned by tail-slice.
          while [ -n "$last_msg" ]; do
            local first_byte
            first_byte=$(LC_ALL=C printf '%s' "${last_msg:0:1}" | LC_ALL=C od -An -tx1 | tr -d ' \n')
            case "$first_byte" in
              [89ab]?) last_msg="${last_msg:1}" ;;
              *) break ;;
            esac
          done
        fi
        if _transitions_looks_like_question "$last_msg"; then
          printf 'waiting'
          return 0
        fi
      fi
      printf 'idle'
      ;;
    SessionEnd)
      # Empty output → caller (bin/hook) should call state::remove.
      printf ''
      ;;
    *)
      # Unknown event: keep current state.
      printf '%s' "$current"
      ;;
  esac
}
