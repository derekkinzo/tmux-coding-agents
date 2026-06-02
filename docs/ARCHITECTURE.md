# tmux plugin — architecture decisions log

Decisions made during the interview, in order. Each is locked unless explicitly revisited.

> **Final architecture: pure bash + flock + TSV.** The Go-daemon proposal in
> Decisions 7/6/10/19 (revised) was reverted on 2026-06-02 after a deep design
> workflow + adversarial review demonstrated that (a) bash is idiomatic for the
> tmux plugin ecosystem, (b) the bugs that motivated the daemon weren't actually
> bash-caused, (c) at our scale (3 states × ~10 panes × ~1 hook/sec) bash is
> *more* reliable than a daemon (no zombie processes, no socket cleanup, kernel-
> enforced flock semantics). See `docs/DESIGN.md` for the implementation-ready
> design. The Go proposal is preserved below as design history.

## Decision 1 — Core purpose
**Attention manager.** Tell me which agent needs my input. Waiting/working/done badges + jump-to-next.
NOT a dashboard, NOT a session manager.

## Decision 2 — Scope (single vs multi-agent)
**Claude-only first.** Architecture stays generalizable (provider-tagged state files later) but MVP is single-agent.
Kiro-cli hook system not yet investigated; revisit if/when needed.

## Decision 3 — What counts as a tracked agent
**Interactive REPL Claude only.** Skip `--print`, subagents (Agent tool), background runs.
**`claude agents` TUI excluded** — meta-tool, not a session.

## Decision 4 — State model (REVISED to 3 states)
**3 states: `idle / working / waiting`.**
- **idle** — no active turn, dormant. Tracked but not actionable.
- **working** — doing something autonomously (tool call, generation, thinking, background subagent/workflow active).
- **waiting** — needs user input NOW. Either permission prompt OR Claude ended with a question.

Rationale: an open Claude session is never truly "done" while the pane is alive. Past output is visible in the pane itself; the inbox shows present state only.

## Decision 5 — Transition triggers (REVISED)
**Claude hooks for state, PID liveness for cleanup. NO `pane-focus-in` hook needed.**

| Event | New state | Notes |
|---|---|---|
| `UserPromptSubmit` / `PreToolUse` / `PostToolUse` | working | autonomous activity |
| `Notification: permission_prompt` | waiting | permission needed |
| `Stop` with `last_assistant_message` ending in `?` | **waiting** | question heuristic |
| `Stop` with `background_tasks` non-empty | working | parent idle, children active |
| `Stop` (otherwise) | idle | turn finished |
| `SessionEnd` | (state file removed) | session closed |
| PID dead (liveness check on read) | (state file removed) | process gone |

- **No transcript file reconciliation.** Use `last_assistant_message` field from the Stop payload itself.
- **No `pane-focus-in` tmux hook.** No more done state to clear.
- Question detection heuristic: trim trailing whitespace, check if last char is `?`. Configurable via `@inbox-question-detect on|off` (default on).

## Decision 7 — Implementation language
**Bash 3.2+.** Plugin ecosystem norm, macOS compat, fast cold start (<10ms), no build step.

## Decision 8 — Picker UI
**Native tmux `choose-tree`. NO fzf.**
- `prefix + a` → `choose-tree -Zw -f '<filter on tracked panes>'` in popup
- Picker shows **ALL tracked panes** (waiting + working + idle), sorted: waiting first by recency, then working by recency, then idle by recency. User scans top of list for actionable rows.
- `prefix + n` (opt-in) → jump to next waiting pane (no popup)
- **Preview: NATIVE choose-tree preview is ON by default.** Press `v` to toggle, `<`/`>` to scroll. Live capture of the highlighted pane's content. We get this FREE — choose-tree builds it in.
Drops: fzf dependency, version-pinning, --with-nth bugs, --footer bugs, transform: bugs, --disabled vs filter mode complexity. Trade-off: no type-to-filter (≤10 panes makes this fine).

## Decision 9 — Keybind ergonomics (REVISED)
**Two simple keybinds. No prefix-table.**
- `prefix + a` → opens `choose-tree` popup filtered to tracked panes. Native preview on. Native vi keys (j/k/Enter/q/Esc/v/etc).
- `prefix + n` (configurable) → cycles to next *waiting* pane without opening picker. Skips tmux's default `next-window` for users who want this.
- **NOTE: Conflict with user's existing `prefix + n` = next-window.** Default this binding to OFF (`@inbox-next-key=''`); user opts in by setting `@inbox-next-key 'n'` if they want. Document the conflict.

## Decision 11 — Name & hosting
- **Name: `tmux-coding-agents`**
- **Host: public GitHub from day 1** (commit hygiene matters)
- Local dev: `~/Projects/tmux-coding-agents`
- Repo URL TBD (whatever your github username is — `github.com/<user>/tmux-coding-agents`)
- License: MIT
- Public-from-day-1 means: README must be solid, LICENSE present, no embarrassing first commits, semver tags

## Decision 12 — License & identity
- **License: MIT**
- **LICENSE file copyright line:** `Copyright (c) 2026 dkinzo`  (project handle, no email)
- **Git commit author:** uses global personal git config (Derek Kinzo / derekkinzo@gmail.com via `~/.gitconfig-personal` for `gitdir:~/Projects/`)
- **GitHub username (repo owner):** derekkinzo
- **Repo URL:** `github.com/derekkinzo/tmux-coding-agents`
- README will not include any author block / email
- LICENSE name `dkinzo` is intentional — it's the project handle, distinct from real-name git author

## Decision 16 — Hook installation (UX-considered)
- **`bin/install-hooks`** — explicit user-run script (NOT auto-install)
  - **No jq dependency.** Pure-bash JSON merge for our known shape. Falls back to jq if available for safety.
  - Idempotent (filters previous installs of our hook before re-adding)
  - Backs up `~/.claude/settings.json.bak.<epoch>` before every modification
  - Preserves user's existing hooks
- **`bin/uninstall-hooks`** — clean removal counterpart
- **README fallback** — manual JSON snippet for users who prefer it
- **Auto-detect missing hooks**: when `prefix + a` shows the picker on a fresh install, display a one-line setup notice instead of an empty list ("hooks not installed; run: bash <plugin>/bin/install-hooks")
- The hook script lives at `bin/hook` and dispatches by `$1` event name (`bin/hook PreToolUse`, `bin/hook Stop`, etc.)
- Hooks reload fresh on next `claude` invocation — existing sessions catch up on their next turn

## Decision 17 — Minimum tmux version
**tmux 3.2+.** Covers Ubuntu 22.04 LTS. `display-popup` and `choose-tree -f filter` both work. `.tmux` entrypoint checks version and bails with a clear message if too old.

## Decision 21 — README structure
**Minimal README.** Just install + usage. ~50 lines.

Sections:
1. **Tagline** — one line: "tmux plugin to surface which Claude Code session needs your input."
2. **Install** — TPM line + `prefix + I` + one-time `install-hooks` command. 3 lines.
3. **Usage** — `prefix + a` opens picker; status bar shows `NEED N WORK N`. ~5 lines.
4. **Options** — table of the 4 tmux options (from Decision 15).
5. **Requirements** — tmux 3.2+, bash 3.2+, Claude Code with hooks.
6. **License** — MIT.

Skip for v0.1.0: GIF (add later if posting it for visibility), troubleshooting, why-explanation, FAQ. Architecture details live in `docs/ARCHITECTURE.md`.

## Decision 20 — Versioning & release
- **Semver from v0.1.0**, tagged in git
- Pre-1.0 signals "still figuring it out, expect breaking changes" but core works
- v1.0.0 commits to tmux-option API stability
- TPM users pin via `set -g @plugin 'derekkinzo/tmux-coding-agents#v0.1.0'`
- **v0.1.0 release bar:** picker opens, hooks fire, state updates, status bar shows count, install-hooks works, README installable. Tested by author for one week before tagging.
- Pre-tag commits are scaffold; users install via `main` until v0.1.0

## Decision 19 — Picker row format
**Minimal: icon + project + age. Three columns.**
- Icon: `!` (red) waiting, `▶` (orange) working, `·` (dim) idle
- Project: derived from pane's cwd (e.g., `~/Projects/foo` → `foo`)
- Age: time since last state-file update (`2m`, `15s`, `1h`)
- choose-tree's native preview shows the pane content — provides title/context for free

Sort order (within picker): waiting (recency descending) → working (recency descending) → idle (recency descending).

CVD-safe colors (red/orange/grey axis — distinguishable for all common color blindness):
- waiting = `#dc322f` (red)
- working = `#cb4b16` (orange/peach)
- idle = `#586e75` (grey/dim)

## Decision 18 — Dependency philosophy (UX priority)
- **Required:** bash 3.2+, tmux 3.2+, claude-code (the whole point)
- **Soft-required:** none (no jq, no fzf, no python, no node)
- **Optional fallback:** jq (used if present, pure-bash if not)
- **Test-only:** bats, shellcheck (CI; not runtime)
- Rationale: minimum install friction. `git clone + tmux source-file` should produce a working plugin.

## Decision 15 — Configuration / tmux options (REVISED)
**4 MVP options. With 3-state model and PID-liveness cleanup, no stale-secs needed.**

| Option | Default | Purpose |
|---|---|---|
| `@inbox-pick-key` | `a` | Key to open picker (after prefix) |
| `@inbox-next-key` | (empty) | Key to jump-to-next-waiting; empty = disabled (avoid prefix+n conflict) |
| `@inbox-status-format` | (built-in default) | Override status segment format string |
| `@inbox-question-detect` | `on` | Whether `Stop` with `?` at end → waiting |

**Explicitly NOT shipping in MVP:**
- Preview toggle (use tmux's native `v` key)
- Refresh-interval (use tmux `status-interval`)
- Popup width/height (let choose-tree default)
- Color/icon overrides (bikeshed risk; add if asked)
- Cache-dir override (advanced; add if asked)
- Custom process detection patterns

## Decision 14 — Repository layout
```
tmux-coding-agents/
├── tmux-coding-agents.tmux       # TPM entrypoint
├── bin/                          # user-invokable scripts (no .sh extension)
│   ├── inbox-status              # status-bar segment
│   ├── inbox-pick                # choose-tree picker
│   ├── inbox-next                # jump-to-next-waiting
│   ├── hook                      # claude code hook target
│   └── install-hooks             # one-shot: wires up ~/.claude/settings.json
├── lib/                          # sourceable shell (.sh extension)
│   ├── state.sh                  # state.tsv read/write + flock
│   ├── detect.sh                 # claude pane detection (process tree walker)
│   ├── transitions.sh            # state machine (event → new_state)
│   └── render.sh                 # color/format helpers
├── tests/
│   ├── test_state.bats
│   ├── test_transitions.bats
│   ├── test_render.bats
│   └── fixtures/
│       └── hook_payload_*.json
├── docs/
│   ├── ARCHITECTURE.md           # this decision log + design rationale
│   └── HOOKS.md                  # claude code hook event reference
├── .github/workflows/ci.yml
├── .gitignore
├── LICENSE                       # MIT, "Copyright (c) 2026 dkinzo"
└── README.md                     # screenshots, install, options, keybinds
```

## Decision 13 — Testing
- **bats** (Bash Automated Testing System) for unit + integration
- **shellcheck** for static analysis
- **GitHub Actions CI** runs both on every push/PR
- Test coverage: state-file read/write under contention, state transitions per hook event, status-segment formatting, full hook→state→segment integration
- Mock-Claude pattern: shipped JSON payloads under `tests/fixtures/`
- Skipped from automated tests: interactive picker UX (TTY-dependent)

## Decision 10 — Status bar integration (REVISED)
**Plugin provides `bin/inbox-status` script. User references it themselves.**
Format (default, with `@inbox-status-format` override):
- `NEED N` (red, bright) when waiting > 0
- `WORK N` (orange) when working > 0
- (skip `idle` count — implies "tracked but dormant", not actionable)
- Categories with N=0 hidden (renders to empty string when nothing actionable)
- CVD-safe palette (red/orange axis is colorblind-distinguishable)
- Single shell invocation per status-interval (cheap)
- README shows exactly: `set -ag status-right ' #(<path>/bin/inbox-status)'`

## Decision 6 — State store
**Single TSV file with flock.** `$XDG_CACHE_HOME/<plugin>/state.tsv`.
Format: `pane_id\tstatus\tepoch\ttranscript_path\tproject`. One row per tracked pane.
- Atomic snapshot reads (no glob races)
- flock-protected writes (sub-ms contention; hook is short-lived)
- tmp+rename for atomicity on the rare full rewrite
- Debuggable with `cat`
