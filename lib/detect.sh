# lib/detect.sh — agent detection.
#
# Functions (per DESIGN.md Section 3 contract):
#   detect::is_tracked_agent <pane_id>  - returns "claude" if interactive Claude REPL, else ""
#   detect::pane_pid <pane_id>          - returns the PID of the claude REPL in this pane, or ""
#   detect::pane_project <cwd>          - derive a short project name from a path
#
# Hooks already provide an authoritative `pid` and `cwd` in their payload.
# detect:: is BEST-EFFORT — used as a fallback for panes that haven't fired
# a hook yet (e.g., user opens picker before any state event).
#
# Process-tree matching is bounded: at most 4096 processes scanned, BFS depth
# capped at 64 hops. Cycle detection via `visited` set in awk.
#
# This file is sourced. No shebang. set -u clean.

# Determine the kind of agent (currently only "claude") running in a tmux pane.
# Returns:
#   stdout: "claude" or ""
#   exit:   always 0
detect::is_tracked_agent() {
  local pane_id="$1"
  [ -n "$pane_id" ] || {
    printf ''
    return 0
  }

  local pane_pid
  pane_pid="$(tmux display-message -p -t "$pane_id" '#{pane_pid}' 2>/dev/null)"
  case "$pane_pid" in
    '' | *[!0-9]*)
      printf ''
      return 0
      ;;
  esac

  local hit
  hit="$(_detect_claude_in_subtree "$pane_pid")"
  if [ -n "$hit" ]; then
    printf 'claude'
  else
    printf ''
  fi
}

# Print the PID of the interactive claude process running in this pane, or "".
detect::pane_pid() {
  local pane_id="$1"
  [ -n "$pane_id" ] || {
    printf ''
    return 0
  }
  local pane_pid
  pane_pid="$(tmux display-message -p -t "$pane_id" '#{pane_pid}' 2>/dev/null)"
  case "$pane_pid" in
    '' | *[!0-9]*)
      printf ''
      return 0
      ;;
  esac
  _detect_claude_in_subtree "$pane_pid"
}

# Derive a short project name from a directory path.
# Examples:
#   /home/user/Projects/foo          -> foo
#   /home/user/Projects/foo/         -> foo  (trailing slash trimmed)
#   /                                -> /
#   ""                               -> ""
detect::pane_project() {
  local cwd="$1"
  [ -n "$cwd" ] || {
    printf ''
    return 0
  }
  # Special-case the root: "/" stays "/".
  if [ "$cwd" = "/" ]; then
    printf '/'
    return 0
  fi
  # Strip trailing slashes (but not the lone-slash "/" handled above).
  while [ "${#cwd}" -gt 1 ] && [ "${cwd: -1}" = "/" ]; do
    cwd="${cwd:0:${#cwd}-1}"
  done
  printf '%s' "${cwd##*/}"
}

# --- internal ----------------------------------------------------------------

# BFS down a process tree from $1, return the first interactive `claude` PID.
#
# Interactive heuristic:
#   - basename of argv[0] is exactly "claude" (NOT a substring match)
#   - argv does not contain --print or -p as a standalone token, and does not
#     start an arg with --print= (long-opt with value)
#
# Defensive bounds:
#   - max 4096 process records
#   - max BFS depth 64
#   - cycle detection via visited set
_detect_claude_in_subtree() {
  local root="$1"
  case "$root" in
    '' | *[!0-9]*) return 0 ;;
  esac

  ps -eo pid=,ppid=,args= 2>/dev/null \
    | awk -v root="$root" '
      function basename(p,    n, parts) {
        n = split(p, parts, "/")
        return parts[n]
      }
      {
        pid = $1
        ppid = $2
        $1 = $2 = ""
        args = $0
        sub(/^[ \t]+/, "", args)

        ppid_map[pid] = ppid
        args_map[pid] = args
        all_pids[++total] = pid
        if (total > 4096) exit 1   # blast radius cap
      }
      END {
        # Build child index for O(1) child lookup.
        for (i = 1; i <= total; i++) {
          p = all_pids[i]
          parent = ppid_map[p]
          if (parent != "") {
            children[parent, ++child_count[parent]] = p
          }
        }

        # BFS
        queue[1] = root
        depth[root] = 0
        qhead = 1; qtail = 2
        visited[root] = 1

        while (qhead < qtail) {
          cur = queue[qhead++]
          if (depth[cur] >= 64) continue   # depth cap

          n = child_count[cur] + 0
          for (i = 1; i <= n; i++) {
            child = children[cur, i]
            if (child in visited) continue   # cycle / already seen
            visited[child] = 1
            depth[child] = depth[cur] + 1
            queue[qtail++] = child

            # Inspect this child for interactive claude.
            cmdline = args_map[child]
            if (cmdline == "") continue
            # First whitespace token = path. (Imperfect for paths with spaces;
            # Claude-Code is normally installed at a path without spaces.)
            split(cmdline, parts, " ")
            cmdpath = parts[1]
            if (basename(cmdpath) != "claude") continue

            # Reject one-shot: --print, -p (standalone) or --print=value.
            one_shot = 0
            for (j = 2; j in parts; j++) {
              tok = parts[j]
              if (tok == "--print" || tok == "-p") { one_shot = 1; break }
              if (substr(tok, 1, 8) == "--print=") { one_shot = 1; break }
            }
            if (one_shot) continue

            print child
            exit 0
          }
        }
      }
    '
}
