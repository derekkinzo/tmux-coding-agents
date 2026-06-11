# lib/render.sh — visual rendering helpers.
#
# Functions:
#   render::scrub_ansi    - strip control bytes / ESC / NULs from stdin (security)
#   render::tmux_escape   - double `#` characters for tmux format-string safety
#   render::status        - format a status segment given waiting/working counts
#   render::row           - format a picker row given (status, project, age_seconds)
#   render::ago           - render a time delta from epoch seconds
#
# Three-color palette chosen for distinguishability under common red/green
# color-vision deficiencies. Combined with the icon glyphs (! / ▶ / ·),
# state is identifiable without color at all.
#   waiting = #dc322f (red)
#   working = #cb4b16 (orange)
#   idle    = #586e75 (grey)
#
# This file is sourced. No shebang. set -u clean. Re-source-safe.

# --- palette / icons ---------------------------------------------------------
# Idempotent guard so re-source under `set -e` does not abort on `readonly`
# re-declaration (bats setup() commonly re-sources libs across tests).
if [ -z "${RENDER_COLOR_WAITING:-}" ]; then
  readonly RENDER_COLOR_WAITING='#dc322f'
  readonly RENDER_COLOR_WORKING='#cb4b16'
  readonly RENDER_COLOR_IDLE='#586e75'
  readonly RENDER_ICON_WAITING='!'
  readonly RENDER_ICON_WORKING='▶'
  readonly RENDER_ICON_IDLE='·'
fi

# --- security: scrub control bytes ------------------------------------------
#
# Defends against CWE-117 (log injection) and CWE-150 (terminal escape
# injection) when an LLM-controlled string flows into status bar / picker.
# Strips: NUL (\000), BS et al (\001-\010), VT/FF (\013-\014), CR (\015),
# control range (\016-\037), ESC (\033), DEL (\177).
# Preserves: TAB (\011, meaningful in TSV) and LF (\012, meaningful for line
# framing — but render::row strips LF separately when needed).
#
# Named scrub_ANSI per the design contract (Section 9 step 5; Section 15 rule
# #4). The legacy alias render::scrub is preserved as a thin wrapper to
# avoid breaking tests written against earlier prototypes.
render::scrub_ansi() {
  # POSIX-portable tr. LC_ALL=C ensures byte-level interpretation across BSD
  # and GNU coreutils alike.
  LC_ALL=C tr -d '\000-\010\013-\014\015-\037\033\177'
}

# Legacy alias.
render::scrub() {
  render::scrub_ansi
}

# --- security: escape `#` for tmux format strings ----------------------------
#
# tmux interprets `#` as the format-expression introducer. Any user/LLM-derived
# string that reaches a tmux #(format) or #[markup] context must double its
# `#` characters or risk arbitrary expression evaluation.
render::tmux_escape() {
  sed 's/#/##/g'
}

# --- UTF-8-safe byte truncation ---------------------------------------------
#
# Truncate a string to at most $2 bytes WITHOUT splitting a multi-byte
# UTF-8 codepoint. Walks backward from the byte limit, dropping any
# continuation byte (10xxxxxx) and the start byte that began the partial
# sequence. Pure bash so we don't fork on every render.
#
# $1 = string
# $2 = maximum byte length (positive integer)
render::utf8_truncate_bytes() {
  local s="$1" max_bytes="$2"
  case "$max_bytes" in
    '' | *[!0-9]*)
      printf '%s' "$s"
      return 0
      ;;
  esac
  # Edge: zero-byte truncation is valid and yields empty string.
  if [ "$max_bytes" -eq 0 ]; then
    return 0
  fi
  if [ "${#s}" -le "$max_bytes" ]; then
    # ${#s} returns byte count under LC_ALL=C; under UTF-8 locale it
    # returns codepoint count. We force LC_ALL=C below for a deterministic
    # byte-count slice.
    :
  fi
  local out
  out=$(LC_ALL=C printf '%s' "$s" | LC_ALL=C cut -b "1-${max_bytes}")
  # Walk back removing trailing high-bit bytes that are mid-codepoint.
  # Continuation byte: 10xxxxxx (0x80–0xBF).
  # Lead bytes: 110xxxxx (2-byte), 1110xxxx (3-byte), 11110xxx (4-byte).
  while [ -n "$out" ]; do
    local last_byte
    last_byte=$(LC_ALL=C printf '%s' "${out: -1}" | LC_ALL=C od -An -tx1 | tr -d ' \n')
    case "$last_byte" in
      [89ab]?)
        # Continuation byte; drop and continue. Stop at length 1 so cut -b 1-0
        # doesn't fire (invalid range on some cut implementations).
        if [ "${#out}" -le 1 ]; then
          out=""
          break
        fi
        out=$(LC_ALL=C printf '%s' "$out" | LC_ALL=C cut -b "1-$((${#out} - 1))")
        ;;
      [cdef]?)
        # Lead byte at the very end → started a multibyte but no continuations
        # made it through the cut. Drop the lead byte too.
        if [ "${#out}" -le 1 ]; then
          out=""
          break
        fi
        out=$(LC_ALL=C printf '%s' "$out" | LC_ALL=C cut -b "1-$((${#out} - 1))")
        break
        ;;
      *)
        break
        ;;
    esac
  done
  printf '%s' "$out"
}

# --- status segment ---------------------------------------------------------
#
# Inputs:  $1 = waiting count, $2 = working count, $3 = idle count,
#          $4 (optional) = template
# Output:  empty string when all three are 0; otherwise a tmux-format-ready
#          segment "NEED N  WORK N  IDLE N" with embedded #[fg=...] markup.
#          Total count = waiting + working + idle = number of tracked panes.
#
# Template substitution: when $4 is non-empty, substitutes `{NEED}`, `{WORK}`,
# `{IDLE}`, and `{TOTAL}` placeholders and emits the template even when all
# counts are zero (so a user can have a persistent badge in their status bar).
render::status() {
  local waiting="${1:-0}" working="${2:-0}" idle="${3:-0}" template="${4:-}"
  case "$waiting" in *[!0-9]* | '') waiting=0 ;; esac
  case "$working" in *[!0-9]* | '') working=0 ;; esac
  case "$idle" in *[!0-9]* | '') idle=0 ;; esac

  if [ -n "$template" ]; then
    local total=$((waiting + working + idle))
    local out="$template"
    out="${out//\{NEED\}/$waiting}"
    out="${out//\{WORK\}/$working}"
    out="${out//\{IDLE\}/$idle}"
    out="${out//\{TOTAL\}/$total}"
    printf '%s' "$out"
    return 0
  fi

  # Hide entirely when nothing is tracked. Otherwise show all three segments
  # so the total reads as: NEED + WORK + IDLE = tracked Claude sessions.
  if [ "$waiting" -eq 0 ] && [ "$working" -eq 0 ] && [ "$idle" -eq 0 ]; then
    return 0
  fi
  printf '#[fg=%s,bold]NEED %d#[default]  #[fg=%s]WORK %d#[default]  #[fg=%s]IDLE %d#[default]' \
    "$RENDER_COLOR_WAITING" "$waiting" \
    "$RENDER_COLOR_WORKING" "$working" \
    "$RENDER_COLOR_IDLE" "$idle"
}

# --- picker row -------------------------------------------------------------
#
# Inputs:  $1 = status (idle|working|waiting), $2 = project, $3 = age_seconds
# Output:  one-line tmux-format string for choose-tree -F, with the icon, project
#          (truncated to ≤22 BYTES, UTF-8 safe), and age (always ≤3 chars).
render::row() {
  local status="$1" project="$2" age_secs="${3:-0}"
  local icon color
  case "$status" in
    waiting)
      icon="$RENDER_ICON_WAITING"
      color="$RENDER_COLOR_WAITING"
      ;;
    working)
      icon="$RENDER_ICON_WORKING"
      color="$RENDER_COLOR_WORKING"
      ;;
    *)
      icon="$RENDER_ICON_IDLE"
      color="$RENDER_COLOR_IDLE"
      ;;
  esac
  local age
  age="$(render::ago "$age_secs")"
  # Truncate the RAW project name first (visible-byte count), then escape `#`.
  # If we truncated against the post-escape length, projects with `#` chars
  # would show up shorter visually because the escape doubles each `#`.
  local proj_raw proj_clean
  proj_raw="$(printf '%s' "$project" | render::scrub_ansi)"
  if [ "${#proj_raw}" -gt 22 ]; then
    proj_raw="$(render::utf8_truncate_bytes "$proj_raw" 21)…"
  fi
  proj_clean="$(printf '%s' "$proj_raw" | render::tmux_escape)"
  printf '#[fg=%s]%s#[default]  %-22s  %3s' \
    "$color" "$icon" "$proj_clean" "$age"
}

# --- ago (relative time) -----------------------------------------------------
#
# Input:   $1 = age in seconds (non-negative integer)
# Output:  bounded to 3 chars: "Ns" "Nm" "Nh" "Nd". Saturates at "99d" for any
#          age ≥ 100 days so the column alignment in render::row remains stable.
render::ago() {
  local s="${1:-0}"
  case "$s" in *[!0-9]* | '') s=0 ;; esac
  if [ "$s" -lt 60 ]; then
    printf '%2ds' "$s"
  elif [ "$s" -lt 3600 ]; then
    printf '%2dm' "$((s / 60))"
  elif [ "$s" -lt 86400 ]; then
    printf '%2dh' "$((s / 3600))"
  else
    local days=$((s / 86400))
    if [ "$days" -gt 99 ]; then
      printf '99d'
    else
      printf '%2dd' "$days"
    fi
  fi
}
