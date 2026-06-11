# tmux-coding-agents

> Know which Claude Code session needs you — without alt-tabbing through panes.

A tmux plugin that turns your status bar into a live inbox for every running
[Claude Code](https://docs.claude.com/en/docs/claude-code) session, so any
session blocked on your input is one keystroke away.

```
status bar:   NEED 1  WORK 2

prefix + a    →  ! laptop-opt        2m
                 ▶ daily-reports    15s
                 ▶ icprogrammer     45s
                 · career-2026       1h
```

## Why

Running multiple Claude Code sessions in tmux has a context-switching tax: any
one of them might be blocked on an `Allow?` prompt, an MCP elicitation dialog,
a clarifying question, or an idle nudge — and the only way to find out is to
flip through panes. This plugin watches Claude's hook events and tells you, at
a glance:

- **`NEED`** — Claude is waiting on you (permission prompt, MCP elicitation,
  idle nudge, or a question on `Stop`). The status bar increments and a
  toast lands on every attached client.
- **`WORK`** — Claude has the turn (running tools or processing a fresh
  prompt).
- **`IDLE`** — Tracked but dormant since the last turn ended.

`prefix + a` opens an fzf picker; press `1`–`9` to jump to one of the first
nine visible rows, or `j`/`k` then `Enter` to switch to any row.

## Features

- **Hook-driven, not polling.** State updates land within milliseconds of
  Claude's `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`,
  `Notification`, and `SessionEnd` events.
- **Picker that feels native.** fzf-powered, `j`/`k` navigation, `1`–`9`
  numeric quick-jump for the first nine visible rows, `/` to fuzzy-search,
  live preview of the pane on the right.
- **One toast per NEED transition.** A `tmux display-message` lands on every
  attached client when a pane flips into NEED — no desktop notifications, no
  duplicate toasts on subsequent events for the same pane.
- **Question detection.** When Claude `Stop`s on a sentence ending in `?`
  (ASCII), full-width `？`, or Arabic `؟`, the pane goes to NEED.
- **Idle-prompt aware.** Claude's idle nudge counts as NEED, picked up
  automatically.
- **Concurrency-safe state.** Many concurrent hook firings can't corrupt the
  inbox.
- **Colorblind-aware.** Three-color palette plus distinct icons (`!`/`▶`/`·`)
  so state is identifiable without color at all.

## Install

### 1. Add the plugin via [TPM](https://github.com/tmux-plugins/tpm)

```tmux
set -g @plugin 'derekkinzo/tmux-coding-agents'
```

Inside tmux, press `prefix + I` to fetch.

### 2. Wire Claude Code hooks (one-time)

```sh
~/.tmux/plugins/tmux-coding-agents/bin/install-hooks
```

This step requires `jq`. Install it first if needed (`brew install jq` on
macOS, `apt install jq` on Debian/Ubuntu).

The installer is idempotent and edits `~/.claude/settings.json`. Set
`CLAUDE_SETTINGS=/path/to/file` to target a different settings file.
Symlinked settings files are preserved.

### 3. (Optional) Add the status segment

```tmux
set -ag status-right ' #(~/.tmux/plugins/tmux-coding-agents/bin/inbox-status)'
set -g  status-interval 5
```

Keep the leading space — it separates this segment from whatever comes before
it. `-ag` *appends* so existing `status-right` segments are preserved (a bare
`-g` would clobber them). tmux's default `status-interval` is 15s; bumping it
to 5 keeps the counter snappy.

## Usage

| Key | Action |
|---|---|
| `prefix + a` | Open the inbox picker |
| `prefix + <next-key>` (opt-in) | Cycle to the next NEED pane without opening the picker |

Inside the picker:

| Key | Action |
|---|---|
| `1`–`9` | Jump to that row (first nine visible rows only) |
| `j` / `k` | Navigate |
| `Enter` | Switch to selected pane |
| `/` | Fuzzy-search by project name |
| `Esc` | Close, or exit search if active |

## Configuration

Set any of these in `~/.tmux.conf` before TPM loads the plugin:

| Option | Default | What it does |
|---|---|---|
| `@inbox-pick-key` | `a` | Picker keybind. Set to `''` to disable. |
| `@inbox-next-key` | (unset) | Next-NEED keybind. Empty = unbound (avoids `prefix+n` collision with `next-window`). |
| `@inbox-status-format` | (built-in) | Status segment template. Placeholders: `{NEED}`, `{WORK}`, `{IDLE}`, `{TOTAL}`. |
| `@inbox-question-detect` | `on` | Treat `Stop` ending in `?` as NEED. |
| `@inbox-debug` | `off` | Append every hook event to `$XDG_CACHE_HOME/tmux-coding-agents/log`. |

## Requirements

- **tmux 3.2+** (for `display-popup`)
- **bash 3.2+**
- **Claude Code**
- **`jq`** — required by `install-hooks` *and* by every hook event at runtime
- **`fzf >= 0.59`** — picker UI. Distro packages older than 0.59 (notably
  Ubuntu 24.04's `0.44`) hard-error rather than draw a blank popup. Grab a
  recent build from
  [fzf releases](https://github.com/junegunn/fzf/releases), or
  `brew install fzf` on macOS.

Set `FZF_BIN=/path/to/fzf` if your fzf isn't on `PATH`.

## Uninstall

```sh
~/.tmux/plugins/tmux-coding-agents/bin/uninstall-hooks
# or `--restore` to roll back from the most recent .bak.* of settings.json
```

Then remove the `set -g @plugin` line and run TPM clean (`prefix + alt + u`).

## License

MIT — see [LICENSE](./LICENSE).
