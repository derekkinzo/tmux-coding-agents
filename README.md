# tmux-coding-agents

A tmux plugin that surfaces which Claude Code session needs your input — at a
glance from the status bar, one keystroke from the picker.

```
status bar:   NEED 1  WORK 2
prefix + a    →  picker:  ! laptop-opt        2m
                          ▶ daily-reports    15s
                          ▶ icprogrammer     45s
                          · career-2026       1h
```

## Install

Three steps with [TPM](https://github.com/tmux-plugins/tpm):

```tmux
# in ~/.tmux.conf
set -g @plugin 'derekkinzo/tmux-coding-agents'
```

```sh
# inside tmux
prefix + I

# one-shot, wires Claude Code hooks into ~/.claude/settings.json
~/.tmux/plugins/tmux-coding-agents/bin/install-hooks
```

Add the status segment somewhere in your `status-right`:

```tmux
set -ag status-right ' #(~/.tmux/plugins/tmux-coding-agents/bin/inbox-status)'
```

## Usage

| Keybind | Action |
|---|---|
| `prefix + a` | Open the picker. j/k to navigate, Enter to jump, q to close, v to toggle preview. |
| `prefix + <next-key>` (opt-in) | Jump to next waiting pane without opening the picker. |

The plugin tracks every interactive `claude` REPL running in a tmux pane.
States: **waiting** (red `!`) → needs your input now; **working** (orange `▶`)
→ doing something autonomously; **idle** (grey `·`) → tracked but dormant.

## Options

| Option | Default | Purpose |
|---|---|---|
| `@inbox-pick-key` | `a` | Key after prefix to open the picker. |
| `@inbox-next-key` | (empty) | Key after prefix to jump to next waiting. Empty = unbound to avoid prefix+n conflict with `next-window`. |
| `@inbox-status-format` | (built-in) | Status segment format template. Placeholders: `{NEED}`, `{WORK}`. |
| `@inbox-question-detect` | `on` | Treat `Stop` event ending in `?` as `waiting` (best-effort question detection). |
| `@inbox-debug` | `off` | Write hook events + transitions to `$XDG_CACHE_HOME/tmux-coding-agents/log`. |

## Requirements

- tmux 3.2+ (for `display-popup` and `choose-tree -f` filter)
- bash 3.2+ (works with macOS system bash)
- Claude Code with hooks support
- `jq` — **required** for safe JSON parsing of hook payloads. Install:
  - macOS: `brew install jq`
  - Debian/Ubuntu: `apt-get install jq`
  - Alpine: `apk add jq`
  - Amazon Linux / RHEL: `dnf install jq`
- `flock(1)`, `awk`, `sed` — present on every supported platform

## Multi-config installs

Claude Code reads several settings files; install hooks into each you use:

```sh
# Default user-wide settings
~/.tmux/plugins/tmux-coding-agents/bin/install-hooks

# Local override (per-user, not committed to dotfiles)
CLAUDE_SETTINGS=$HOME/.claude/settings.local.json \
  ~/.tmux/plugins/tmux-coding-agents/bin/install-hooks

# Project-scoped (run inside a project dir)
CLAUDE_SETTINGS=$PWD/.claude/settings.json \
  ~/.tmux/plugins/tmux-coding-agents/bin/install-hooks
```

If your `~/.claude/settings.json` is a symlink (dotfiles workflow), the
installer preserves the inode — your dotfiles repo will receive the new
hook entries.

## Uninstall

```sh
# Remove our hook entries in-place (default; preserves user's other settings)
~/.tmux/plugins/tmux-coding-agents/bin/uninstall-hooks

# Or restore settings.json from the most recent .bak.* file
~/.tmux/plugins/tmux-coding-agents/bin/uninstall-hooks --restore

# Then remove the @plugin line and run prefix + alt + u (TPM clean)
```

## Security

We treat hook payloads as untrusted (an LLM tool result, MCP server response,
or prompt-injection vector can land arbitrary strings in the JSON Claude
sends us). Defenses applied:

- **TSV row injection blocked.** Field values are validated to refuse tabs,
  newlines, CR, and any literal backslash. The awk write path passes values
  via `ENVIRON` (no `-v` escape expansion) so a 2-byte `\n` cannot become a
  real newline mid-write.
- **Pane_id format validated.** Both on the read path (`bin/inbox-pick`)
  and the write path (`bin/hook` against `TMUX_PANE`), pane_ids must match
  `^%[0-9]+$`. Malformed values are dropped with a debug log entry.
- **Picker shell parse eliminated.** `bin/inbox-pick` invokes
  `tmux display-popup -E` with **argv** form (no inner `sh -c`), so a `'`
  in any tmux format value cannot escape a quoted region.
- **Symlink defenses.** State TSV, lock file, debug log, settings tmpfile
  all refuse to follow symlinks. State cache dir is auto-tightened to 0700
  on every read.
- **Resource caps.** Hook payloads >64 KiB and JSON nested deeper than 8
  levels are dropped silently.

Found a vulnerability? Open an issue tagged `security` (or email the
maintainer privately if you'd prefer coordinated disclosure).

## License

MIT — see [LICENSE](./LICENSE).
