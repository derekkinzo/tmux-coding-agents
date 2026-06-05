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
| `prefix + a` | Open the picker (fzf-driven). Type to filter; j/k or arrows to navigate; Enter to jump; `?` toggles preview; Esc closes. |
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

tmux 3.2+, bash 3.2+, Claude Code, plus two small CLI tools the picker
relies on:

- `jq` for safe JSON parsing of hook payloads
- `fzf` for the picker's selection UI and live preview window

Install on Linux: `apt install jq fzf` (or `dnf` / `apk`).
Install on macOS: `brew install jq fzf`.

To target a non-default settings file, set `CLAUDE_SETTINGS=/path/to/settings.json`
before running `install-hooks`. Symlinked settings files are preserved.

## Uninstall

```sh
~/.tmux/plugins/tmux-coding-agents/bin/uninstall-hooks
# or `uninstall-hooks --restore` to roll back from the most recent .bak.*
```

## License

MIT — see [LICENSE](./LICENSE).
