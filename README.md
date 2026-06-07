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

### 1. Install the plugin via [TPM](https://github.com/tmux-plugins/tpm)

Add to `~/.tmux.conf`:

```tmux
set -g @plugin 'derekkinzo/tmux-coding-agents'
```

Then, inside tmux, press `prefix + I` to fetch.

### 2. Wire Claude Code hooks (one-time)

This step requires `jq`. From a regular shell:

```sh
~/.tmux/plugins/tmux-coding-agents/bin/install-hooks
```

The installer adds entries to `~/.claude/settings.json` so Claude Code
sends events to this plugin. It's idempotent — safe to re-run.

### 3. (Optional) Add the status segment to your status bar

```tmux
set -ag status-right ' #(~/.tmux/plugins/tmux-coding-agents/bin/inbox-status)'
```

The leading space is a separator. tmux refreshes `#(...)` segments on
its `status-interval` cadence (default 15s — set `set -g status-interval 5`
for snappier updates).

## Usage

| Keybind | Action |
|---|---|
| `prefix + a` | Open the picker (fzf-driven). Type to filter; j/k or arrows to navigate; Enter to jump; Esc closes. |
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

tmux 3.2+, bash 3.2+, Claude Code, plus two small CLI tools:

- `jq` — safe JSON parsing of hook payloads (also required by `install-hooks`)
- `fzf >= 0.50` — picker selection UI. Distro fzf packages older than 0.50
  (notably Ubuntu 24.04 / Debian's 0.44) have rendering issues inside tmux
  display-popup; the picker will hard-error rather than draw a blank popup.

Install on macOS: `brew install jq fzf` (Homebrew tracks recent fzf).
Install on Linux: `apt install jq` for jq, then grab a recent fzf from
[releases](https://github.com/junegunn/fzf/releases) — set
`FZF_BIN=/path/to/fzf` if it's not on `PATH`.

To target a non-default settings file, set `CLAUDE_SETTINGS=/path/to/settings.json`
before running `install-hooks`. Symlinked settings files are preserved.

## Uninstall

```sh
~/.tmux/plugins/tmux-coding-agents/bin/uninstall-hooks
# or `uninstall-hooks --restore` to roll back from the most recent .bak.*
```

## License

MIT — see [LICENSE](./LICENSE).
