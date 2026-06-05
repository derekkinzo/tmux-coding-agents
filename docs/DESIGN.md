

# tmux-coding-agents — Master Architecture

## 1. Overview

`tmux-coding-agents` is a tmux plugin whose single purpose is *attention management*: tell the user, at a glance and within one keystroke, which Claude Code REPL needs input now. It is not a session manager, not a dashboard, not a multiplexer-of-multiplexers. The plugin renders a tiny `NEED N WORK N` segment on the status bar and a `prefix + a` picker that lists tracked panes sorted waiting-first. State is sourced from Claude Code's own hook system (`PreToolUse`, `Stop`, `Notification`, `SessionEnd`) plus a PID-liveness check; nothing is inferred from terminal output. The MVP tracks Claude only, but the schema is provider-tagged so adding `kiro`, `aider`, `cursor`, etc. is additive.

The implementation is **pure bash 3.2+**, with **no long-running process** of any kind. Each Claude hook fires `bin/hook <event>` as a short-lived subprocess that takes a flock on a single TSV file, applies a state transition, and exits. Each tmux `status-interval` tick fires `bin/inbox-status` which reads the same TSV and prints a counter. The picker is tmux's native `choose-tree -Zw` with a filter — no fzf, no Go daemon, no Unix socket, no IPC server. This decision (locked in Decision 5/7/18 of the architecture log) trades the Go daemon's nice properties (typed events, single-writer concurrency model, structured logging) for radical operational simplicity: <10ms cold start, no install-time toolchain, no daemon to crash, three commands total to install.

## 2. Component diagram (ASCII)

```
                         ~/.claude/settings.json
                                  │
                                  │  hooks { PreToolUse|PostToolUse|Stop|Notification|SessionEnd }
                                  ▼
   ┌────────────────────────────────────────────────────┐
   │  Claude Code REPL (one per tracked tmux pane)      │
   └────────────────┬───────────────────────────────────┘
                    │ stdin = JSON payload, $TMUX_PANE in env
                    ▼
   ┌────────────────────────────────────────────────────┐  short-lived (<50 ms),
   │  bin/hook <event>           [bash, ~80 ms p99]     │  one process per event
   │   - parse JSON (pure-bash, jq if present)          │
   │   - source lib/transitions.sh → new_state          │
   │   - source lib/state.sh → flock+upsert TSV         │
   └────────────────┬───────────────────────────────────┘
                    │ flock LOCK_EX
                    ▼
        ┌─────────────────────────────────────┐
        │  $XDG_CACHE_HOME/tmux-coding-agents │
        │     /state.tsv  (truth, on disk)    │
        │     /state.lock (flock target)      │
        │     /log         (rotated, optional)│
        └─────────┬─────────────┬─────────────┘
                  │ LOCK_SH      │ LOCK_SH
        ┌─────────▼──────┐ ┌─────▼────────────┐
        │ bin/inbox-status│ │ bin/inbox-pick   │   ← prefix+a (display-popup)
        │ (status-interval│ │ choose-tree -Zw  │
        │  every Ns)      │ │  -f <filter>     │
        └─────────┬───────┘ └─────┬────────────┘
                  ▼               ▼
            tmux status bar   tmux popup → switch-client -t %ID
```

There is **no daemon box**. Every box on the diagram is a process that exists for milliseconds.

## 3. Bash module layout (with rationale)

```
tmux-coding-agents/
├── tmux-coding-agents.tmux        # TPM entrypoint: version-check, set-option @inbox-*, bind-key
├── bin/                           # user/tmux/Claude entry points (no .sh extension, executable)
│   ├── inbox-status               # called by status-interval; prints "NEED N WORK N" or ""
│   ├── inbox-pick                 # called by prefix+a; runs choose-tree in popup
│   ├── inbox-next                 # called by prefix+<next-key>; switch-client to next waiting
│   ├── hook                       # called by Claude Code; bin/hook <EventName>
│   ├── install-hooks              # one-shot wire-up of ~/.claude/settings.json
│   └── uninstall-hooks            # clean removal
├── lib/                           # sourceable bash (.sh), no shebang at top, set -u clean
│   ├── state.sh                   # state::upsert / state::remove / state::snapshot, flock guard
│   ├── detect.sh                  # detect::is_tracked_agent <pane_id> → kind|""
│   ├── transitions.sh             # transitions::next <kind> <current_state> <event> <payload> → new_state
│   ├── render.sh                  # render::row, render::status, render::scrub_ansi, color/icon
│   └── jsonpb.sh                  # JSON peeker (jq required — see Section 18)
├── tests/                         # bats-core + shellcheck targets
│   ├── test_state.bats            # contention, atomic rename, flock timeout
│   ├── test_transitions.bats      # table-driven: (kind, event, payload) → state
│   ├── test_render.bats           # ANSI/control-byte scrub, tmux #[] escaping
│   ├── test_install_hooks.bats    # idempotency, settings.json merge, backup
│   ├── test_plugin_load.bats      # set -u clean under tmux 3.2 / 3.3a / 3.4
│   └── fixtures/
│       ├── hook_payload_*.json    # Claude hook samples
│       └── settings_*.json        # pre-existing user settings to merge into
├── docs/
│   ├── ARCHITECTURE.md            # decision log (this is the canonical history)
│   ├── DESIGN.md                  # this document
│   └── HOOKS.md                   # Claude Code hook reference
├── .github/workflows/ci.yml       # bats + shellcheck + bash 3.2/5.1/5.2 matrix
├── .gitignore
├── LICENSE                        # MIT
└── README.md                      # ~50 lines: install, usage, options
```

**Rationale.** This is a flat, conventionally-shaped tmux plugin. `bin/` holds the four entry points; everything reusable is in `lib/`. There is no `cmd/`, no `internal/`, no Go module — those exist in the deferred GO ARCH proposal that this document supersedes. All shell modules use a `<modname>::<func>` naming convention (e.g., `state::upsert`) so that sourcing is namespaced even without bash 4.4 namespaces. Every executable in `bin/` does `set -euo pipefail` at the top; every file in `lib/` is `set -u`-clean (sourceable from a `set -u` caller).

## 4. State machine table

States: **`idle`**, **`working`**, **`waiting`**. Plus the implicit *untracked* (no row in TSV).

| Current state | Event                                                     | Trigger source            | Next state | Side effect                                     |
|---------------|-----------------------------------------------------------|---------------------------|------------|-------------------------------------------------|
| (untracked)   | first hook firing for a pane that passes `detect::is_tracked_agent` | any Claude hook           | working    | `state::upsert` row insert with `since=now`      |
| any           | `UserPromptSubmit`                                        | Claude hook               | working    | reset `since=now`                               |
| any           | `PreToolUse`                                              | Claude hook               | working    | reset `since=now`                               |
| any           | `PostToolUse`                                             | Claude hook               | working    | reset `since=now`                               |
| any           | `Notification` payload kind == `permission_prompt`         | Claude hook               | waiting    | reset `since=now`                               |
| any           | `Stop` with `last_assistant_message` trailing `?` and `@inbox-question-detect=on` | Claude hook | waiting    | reset `since=now`                               |
| any           | `Stop` with non-empty `background_tasks`                  | Claude hook               | working    | keep `since`                                    |
| any           | `Stop` (otherwise)                                        | Claude hook               | idle       | reset `since=now`                               |
| any           | `SessionEnd`                                              | Claude hook               | (untracked)| `state::remove` row                             |
| any           | PID-not-alive (`kill -0` fails) at *read* time            | `inbox-status` / `inbox-pick` | (untracked) | lazy garbage-collect: remove during read-then-rewrite |
| any           | tmux pane no longer exists                                | `inbox-pick` enumeration  | (untracked)| same lazy GC                                    |

Implementation lives in `lib/transitions.sh::transitions::next`. It is a pure function: inputs are `(kind, current_state, event_name, payload_json)`, output is `new_state` on stdout. All side effects are performed by the caller (`bin/hook`) under flock.

## 5. IPC "protocol" (file-based, since there is no socket)

There is no network IPC. The "wire format" is the **on-disk TSV** plus the hook **stdin JSON envelope**. Both are versioned.

### 5.1 Hook stdin envelope (Claude → `bin/hook`)

Claude Code passes the hook payload on stdin. We treat it as untrusted bytes (Section 15). Schema, post-normalization:

```
{
  "schema_version": 1,
  "hook_event": "PreToolUse" | "PostToolUse" | "UserPromptSubmit" | "Stop" | "Notification" | "SessionEnd",
  "session_id":   "<claude session uuid>",
  "transcript_path": "<absolute path string, never opened>",
  "cwd":          "<string>",
  "pid":          <int>,
  "last_assistant_message": "<string, optional, clamped to 4 KiB>",
  "background_tasks":        [<string,...>]   // optional
  "notification": { "kind": "permission_prompt", ... }   // present only for Notification
}
```

`$TMUX_PANE` is read from environment (Claude inherits it from the tmux pane). If absent, `bin/hook` exits 0 silently — we cannot attribute the event to a pane, and the hook MUST NOT fail Claude.

### 5.2 On-disk TSV (truth)

`$XDG_CACHE_HOME/tmux-coding-agents/state.tsv`. One line per tracked pane. Tab-separated, no embedded tabs in fields (validated on write — fields containing `\t` or `\n` are rejected and the row dropped).

```
# Header (line 1, version-pinned):
#v1  pane_id  kind    status   since_epoch  pid    project           transcript_path
%42        claude  waiting  1738358400   12345  tmux-coding-agents  /home/.../transcripts/abc.jsonl
%47        claude  working  1738358412   12377  blueprints          /home/.../transcripts/def.jsonl
```

Header line is `#v1<TAB>...`; bumping the schema bumps the version token. Old readers see `#v2` and skip rather than mis-parse. Status values not in the known set (`idle|working|waiting`) are treated as `idle` by readers, which is the additivity property we need to add states later (e.g., `crashed`, `pending-review`).

### 5.3 Versioning

Three independent version axes:
- **Hook envelope schema_version** — incremented if Claude's hook payload shape changes in a breaking way, or if our normalization changes.
- **TSV header version** (`#v1`) — incremented if columns change.
- **Plugin semver** — git tag, what TPM users pin to.

### 5.4 Errors

`bin/hook` MUST NEVER exit non-zero on a malformed payload (would surface as a confusing error to Claude). Failure modes and responses:

| Failure                          | Response                                                |
|----------------------------------|---------------------------------------------------------|
| Cannot acquire flock in 200 ms    | drop event, log to `$XDG_CACHE_HOME/.../log` if `@inbox-debug=on`, exit 0 |
| Payload exceeds 64 KiB            | drop event, log, exit 0                                  |
| Payload not valid JSON            | drop event, log, exit 0                                  |
| Payload nesting > 8 levels        | drop event, log, exit 0                                  |
| `$TMUX_PANE` unset                | exit 0 silently                                          |
| TSV write fails (ENOSPC, EROFS)   | log, exit 0                                              |
| Stale lockfile (>30s old)         | warn, attempt `flock -w 1` once more, otherwise drop    |

Readers (`inbox-status`, `inbox-pick`) treat a missing or unreadable TSV as the empty inbox (count = 0, picker shows "no tracked agents"); they NEVER block Claude or tmux.

## 6. Lifecycle

### 6.1 First plugin load (after TPM `prefix + I`)

1. tmux sources `tmux-coding-agents.tmux`.
2. Entrypoint runs version gate: if `tmux -V` < 3.2, displays a one-line message via `display-message` and returns 0.
3. Sets default `@inbox-*` options that are unset (`set-option -g @inbox-pick-key a` etc., guarded with `if-shell` to not overwrite user values).
4. Binds `prefix + <pick-key>` to `display-popup -E -h 70% -w 80% '<plugin>/bin/inbox-pick'`.
5. If `@inbox-next-key` is non-empty, binds `prefix + <next-key>` to `<plugin>/bin/inbox-next`.
6. Returns. **Nothing else happens.** No process is started, no socket is opened, no file is touched.

### 6.2 Hook installation (Step 3 of install — explicit user action)

`bin/install-hooks` is run once by the user. It:
1. Reads `~/.claude/settings.json` (creates the file if absent with `{}`).
2. Backs up to `~/.claude/settings.json.bak.<epoch>`.
3. Pure-bash JSON merge (or jq if `command -v jq`) that filters out any prior `tmux-coding-agents/bin/hook` entries (idempotent re-run) and adds new entries for `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`, `Notification`, `SessionEnd`.
4. Writes via `tmpfile + mv` (atomic).
5. Prints "installed; run `claude` again to pick up hooks; existing sessions catch up on next turn."

`bin/uninstall-hooks` does the inverse: restores the most recent `.bak` if present, else filters out our entries.

### 6.3 Steady-state event flow

1. User types in Claude pane → `UserPromptSubmit` → `bin/hook UserPromptSubmit` runs → flock state.tsv → upsert `working`.
2. Claude calls a tool → `PreToolUse` → state stays/becomes `working`.
3. Claude needs permission → `Notification {kind: permission_prompt}` → state becomes `waiting`.
4. Within ~`status-interval` seconds, `bin/inbox-status` runs, sees waiting=1, prints `NEED 1`.
5. User hits `prefix + a`, popup opens, sees the row at top, presses Enter → `switch-client -t %ID` → focused on the waiting pane.

### 6.4 Pane death / Claude crash / tmux death

| Scenario                                  | Detection                                       | Cleanup                                                    |
|-------------------------------------------|-------------------------------------------------|------------------------------------------------------------|
| Claude exits cleanly                      | `SessionEnd` hook fires                         | `state::remove pane_id`                                    |
| Claude crashes (no `SessionEnd`)          | next reader does `kill -0 $pid`, fails          | reader takes `LOCK_EX`, rewrites TSV without that row      |
| tmux pane killed mid-session              | next `inbox-pick` enumerates panes, row missing | reader rewrites TSV without that row                       |
| tmux server itself dies                   | state.tsv lingers; flock file deleted by next run | first call after tmux restart sees stale rows; `inbox-pick` enumerates panes (none match), GC's all rows |
| Host reboot                               | `$XDG_CACHE_HOME` survives; no PID matches      | first read GC's everything; clean state                    |
| flock contention / stuck lockfile         | `flock -w 0.2` timeout                          | drop event, log; lockfile is auto-released by kernel on process exit |

There is **no recovery path** because there is no daemon to recover. The TSV is the entire persisted state and is self-healing on read.

## 7. Concurrency model

There is no goroutine model, no event loop, no actor — there is one OS-level invariant:

> **At any moment, at most one process holds `LOCK_EX` on `state.lock`. All writers acquire `LOCK_EX`; all readers acquire `LOCK_SH`. flock(2) on the kernel is the only synchronization primitive.**

Properties:
- **Single-writer per fsync.** Writers do read-modify-write under `LOCK_EX` with a 200 ms timeout. The hook is short-lived (typical end-to-end <80 ms p99 per measured fixture), so contention is sub-millisecond in practice.
- **Multiple-reader.** `inbox-status` and `inbox-pick` take `LOCK_SH`. Concurrent readers do not block each other.
- **Atomic full rewrite.** When a reader GC's stale rows, it writes to `state.tsv.tmp` and `mv`s — POSIX rename is atomic on the same filesystem.
- **No async.** Every script returns before the next one runs; bash is the scheduler.
- **No shared mutable memory.** All state is on disk between processes.

This eliminates the entire class of concurrency bugs the GO ARCH spec was solving (event-loop ordering, channel coalescing, projector debounce, snapshot writer race). The trade-off is paid in process spawn cost, which is ~5 ms per invocation on the target hardware — well under tmux's own status-interval granularity.

## 8. Configuration surface

Configured via tmux user options (read by scripts via `tmux show-option -gv @inbox-<key>`):

| Option                    | Default     | Type        | Purpose                                                          |
|---------------------------|-------------|-------------|------------------------------------------------------------------|
| `@inbox-pick-key`         | `a`         | char        | Key after prefix to open picker                                  |
| `@inbox-next-key`         | `` (empty)  | char        | Key after prefix to jump to next waiting; empty = unbound        |
| `@inbox-status-format`    | `built-in`  | string      | Override status segment format string (uses `{NEED}` `{WORK}` placeholders) |
| `@inbox-question-detect`  | `on`        | `on`/`off`  | Whether `Stop` ending in `?` → `waiting`                         |
| `@inbox-debug`            | `off`       | `on`/`off`  | Write hook events + transitions to `$XDG_CACHE_HOME/.../log`     |

`@inbox-debug` is added (not in the original Decision 15) because the security and crash-recovery sections require an opt-in audit trail.

Environment variables (read by scripts):
- `$XDG_CACHE_HOME` (default `$HOME/.cache`) — TSV/lock/log location
- `$TMUX_PANE` — set by tmux/Claude; required by `bin/hook` to attribute events
- `$TMUX_CODING_AGENTS_DRY_RUN=1` — testing-only knob; hook parses payload, transitions, but does not write TSV

No options for cache-dir override, color overrides, popup geometry, or detection patterns. Adding one in v0.x requires a Decision-log entry.

## 9. Status bar projection

`bin/inbox-status` is invoked once per `status-interval` per attached client by tmux's `#(...)` substitution. It:
1. Takes `LOCK_SH` on `state.lock` (200 ms timeout; on timeout, prints last-known cached output if any, else empty).
2. Streams `state.tsv` line-by-line, counts statuses, GC's any row whose `pid` fails `kill -0`.
3. If GC happened, atomically rewrites TSV (drops `LOCK_SH`, takes `LOCK_EX`, writes tmpfile, renames).
4. Renders:
   - `NEED N` in `#[fg=#dc322f,bold]` if waiting > 0
   - `WORK N` in `#[fg=#cb4b16]` if working > 0
   - empty string when both are 0 (so the segment disappears entirely)
5. Output passes through `render::scrub_ansi` to ensure no LLM-derived bytes can reach tmux's renderer (Section 15).

User wires it themselves (Decision 10):

```tmux
set -ag status-right ' #(~/.tmux/plugins/tmux-coding-agents/bin/inbox-status)'
```

The README example uses `#()` not `#{}` because `#()` cache-key is the command string; tmux re-runs every `status-interval`, which is the cheapest correctness model.

## 10. Picker UX

`prefix + a` → `display-popup -E -h 70% -w 80% '<plugin>/bin/inbox-pick'`. The script:

1. Snapshots TSV (`LOCK_SH`).
2. Builds a filter expression for `choose-tree -Zw -f` matching only tracked pane IDs.
3. Sorts by status priority (waiting > working > idle) then by recency.
4. Sets format strings so each row reads: `<icon> <project> <age>` with CVD-safe colors.
5. `exec`s `tmux choose-tree -Zw -f "$filter" -F "<format>"` inside the popup.
6. Native preview is on; user toggles with `v`, scrolls with `<`/`>`, jumps with `Enter` (which causes choose-tree to call `switch-client -t %ID` automatically).

Edge cases:
- **Hooks not installed** — TSV missing or empty. The script prints a single tmux message: `"hooks not installed — run: <plugin>/bin/install-hooks"` via `display-message`, then exits without opening the popup. (Decision 16's "auto-detect missing hooks" wired correctly.)
- **No tracked agents** — TSV exists but is empty. Print `"no Claude sessions tracked yet"` and exit.
- **All rows stale** — readers GC them on this very pass; falls into the previous case naturally.

`prefix + n` (when `@inbox-next-key` is set) bypasses the popup and `switch-client`s to the most-recently-changed `waiting` pane. If none exists, prints a brief `display-message`.

## 11. Hook installation

Only done at v0.1.0. `bin/install-hooks`:

1. Locates `~/.claude/settings.json`, creating with `{}` if missing.
2. Saves `~/.claude/settings.json.bak.$(date +%s)`.
3. Builds the desired hook entries pointing at `<plugin>/bin/hook <EventName>`. Resolves `<plugin>` via `${BASH_SOURCE[0]}` so the path is absolute and stable across users.
4. Pure-bash JSON merge for the known shape (we own the schema). Falls back to jq if installed (faster, more robust on weirdly-shaped pre-existing settings).
5. Filter rule: any existing hook whose command contains `tmux-coding-agents/bin/hook` is dropped before insertion (idempotent).
6. Validates the result parses as JSON before swapping in (`python3 -c "import json,sys;json.load(open(sys.argv[1]))"` or jq parse) — refuses to overwrite a working settings.json with a broken one.
7. Atomic write: tmpfile + mv.

`bin/uninstall-hooks` is the inverse. Restoring the most recent `.bak` is preferred over filter-and-rewrite when a backup exists, because backup-restore preserves any settings the user added between install and uninstall. (Trade-off documented; user can pass `--filter` to force the filter-rewrite path.)

## 12. Distribution

Three install paths, all documented in README, all converging on the same on-disk layout.

**Path 1 — TPM (recommended).** Three steps:
1. Add `set -g @plugin 'derekkinzo/tmux-coding-agents'` to `~/.tmux.conf`.
2. `prefix + I` (TPM clones, sources entrypoint).
3. `~/.tmux/plugins/tmux-coding-agents/bin/install-hooks` (one-shot).

**Path 2 — Manual git clone (parallel to fzf's pattern).** Four lines:
```sh
git clone https://github.com/derekkinzo/tmux-coding-agents ~/.tmux/plugins/tmux-coding-agents
echo "run-shell ~/.tmux/plugins/tmux-coding-agents/tmux-coding-agents.tmux" >> ~/.tmux.conf
tmux source-file ~/.tmux.conf
~/.tmux/plugins/tmux-coding-agents/bin/install-hooks
```

**Path 3 — Distro/package managers.** Deferred to post-1.0.

Versioning is plain semver via git tags. TPM users pin with `set -g @plugin 'derekkinzo/tmux-coding-agents#v0.1.0'`. There is **no compiled artifact**, hence no checksums, no release binaries, no notarization, no signed releases needed for v0.1.0. Bumping `v0.x.y` requires updating the `# Version: 0.x.y` token at the top of `tmux-coding-agents.tmux` so `inbox-status --version` (debug) reports it.

## 13. Testing

**Frameworks.** `bats-core` driven by `bats-core/bats-action@4.0.0` (which transparently installs `bats-support`, `bats-assert`, `bats-file` and exports `BATS_LIB_PATH`). `shellcheck` via `ludeeus/action-shellcheck@2.0.0` at severity=warning. `shfmt -d -i 2 -ci -bn` for formatting.

**Layout.**
```
tests/
├── test_helper.bash           # bats_load_library 'bats-support' 'bats-assert' 'bats-file'
├── test_state.bats            # contention (50 parallel hooks), atomic rename, flock timeout
├── test_transitions.bats      # table-driven 30+ rows, every cell of Section 4 covered
├── test_render.bats           # control-byte scrub, tmux #[ ] escaping, color absence on N=0
├── test_install_hooks.bats    # idempotency, merge with pre-existing user hooks, backup
├── test_plugin_load.bats      # set -u clean under tmux 3.2/3.3a/3.4
├── mocks/
│   └── tmux                   # PATH-override stub recording invocations to $BATS_TEST_TMPDIR/tmux.calls
└── fixtures/
    ├── hook_payload_*.json
    └── settings_*.json
```

**Mocking strategy.** `tests/mocks/tmux` is an executable bash stub. Each test does `export PATH="$PWD/tests/mocks:$PATH"` in `setup()`. Stub records invocations and prints fixture replies for known subcommands (`display-message`, `set-option`, `show-option -gv`, `list-panes`). Tests assert against the recorded call file with `assert_file_contains`. Same approach as fzf's tmux integration tests, simpler because we only need command-shape assertions, not pty.

**Bash-version matrix.** GitHub Actions matrix over bash 3.2 (macOS default), 5.1, 5.2 via `docker run -v $PWD:/code bats/bats:bash-X.Y /code/tests`. Mirrors bats-core's own CI.

**Out of scope for automation.** Interactive picker UX (TTY-dependent). Tested manually before each release.

## 14. CI/CD

Single workflow `.github/workflows/ci.yml`, three jobs run in parallel on every push and PR:

| Job        | Runs                                                       | Blocks merge? |
|------------|-----------------------------------------------------------|---------------|
| `bats`     | bats-core action, matrix bash 3.2/5.1/5.2 in containers    | yes           |
| `shellcheck` | ludeeus/action-shellcheck severity=warning, scandir=`./bin ./lib ./tests` ignore=`tests/mocks` | yes |
| `shfmt`    | `shfmt -d -i 2 -ci -bn bin/* lib/*.sh`                     | yes           |

**Release flow.** A `v*` tag on `main` triggers a `release.yml` that:
1. Runs the same three jobs in `needs:`.
2. Generates GitHub Release notes from the conventional-commits log between the previous tag and HEAD.
3. Creates the release. **No artifact upload** — distribution is the git tag itself.

**Branch protection.** `main` requires the three CI jobs green plus one approving review (author can self-approve for a solo project; this is documented). No force-pushes.

## 15. Security

The threat surface is bytes flowing into the plugin from external sources, ranked:

| Surface                                  | Trust    | Threat                                                                |
|------------------------------------------|----------|-----------------------------------------------------------------------|
| Hook stdin payload from local Claude     | UNTRUSTED for `last_assistant_message` (LLM output); semi-trusted otherwise | log injection, terminal escape injection, JSON bombs, path traversal |
| Tmux pane metadata (cwd, command, PID)   | semi-trusted | command injection if interpolated unquoted into tmux/sh commands |
| `~/.claude/settings.json` on disk        | trusted-as-input but parsed adversarially | corrupted JSON could brick `claude`                          |
| `state.tsv` at rest                      | trusted (we wrote it) | round-tripping must not reintroduce control bytes if user manually edits |

**Hardening rules (every script must follow).**

1. **Payload size cap.** `bin/hook` reads at most 64 KiB from stdin (`head -c 65537 | wc -c`); over-cap → drop event.
2. **JSON depth cap.** Reject envelope nested deeper than 8 levels; drop event.
3. **`last_assistant_message` clamp.** Slice to the trailing 4 KiB before any inspection. The `?`-detect heuristic only needs the last byte.
4. **Control-byte scrub before terminal output.** `render::scrub_ansi` strips `[\x00-\x08\x0b-\x1f\x7f]` and rejects ESC (`\x1b`). All status-bar output and all picker rows pass through it. Defends against CWE-117/CWE-150 terminal-escape injection from LLM-controlled text.
5. **Tmux `#` escape.** Any user/LLM-derived string that reaches a tmux format string is doubled (`#` → `##`).
6. **No `eval` of any external bytes.** No `bash -c "$payload"`, no `command "$cwd"` interpolation. All exec uses arg-array form.
7. **Path safety.** `transcript_path` is treated as opaque; never `cat`'d, never `realpath`'d, never opened. Stored as a string in TSV for forensic value only.
8. **TSV field validation.** Tabs/newlines in `project` or `transcript_path` cause the row to be dropped (rejection at write).
9. **flock timeout.** 200 ms `flock -w` to prevent a DOS via a held lock.
10. **Backup before mutation of `~/.claude/settings.json`.** Always.
11. **No network.** Plugin makes zero network calls.
12. **No setuid, no sudo.** All operations run as the invoking user; `state.tsv` permissions are 0600.
13. **Symlink/path-traversal defense for cache dir.** On startup the cache dir is created with `mkdir -p; chmod 0700`; if it exists and is a symlink, the plugin refuses to write.

**What we explicitly do not defend against.** A user who has root on their own machine; an attacker who can write arbitrary bytes to `~/.claude/settings.json` (already game over for Claude Code itself); supply-chain compromise of bats/shellcheck (CI-only, not runtime).

## 16. Future extensibility

Each potential extension below has a documented seam *that already exists*; no speculative abstraction was added in MVP.

| Extension                      | Seam                                                                          | Cost to add                  |
|--------------------------------|-------------------------------------------------------------------------------|------------------------------|
| New agent kind (kiro/aider)    | `lib/detect.sh` kind-pattern table + `lib/transitions.sh` per-kind dispatch    | one detect entry + one transition fn |
| New state (e.g. `crashed`)     | TSV header `#v1` allows unknown statuses → readers bucket as `idle`; bump to `#v2` only if write-path changes | add row in transition table; render handles new icon |
| New hook event                 | `bin/hook <NewEvent>` is just another arg case; `lib/transitions.sh` adds entry | one case branch              |
| Rich UI replacement            | `bin/inbox-pick` is the entire picker; replaceable wholesale                  | rewrite one file             |
| Multi-host (remote panes)      | TSV path is `$XDG_CACHE_HOME` overridable; sync layer can write same format    | external concern             |
| Go daemon (if ever needed)     | Same TSV becomes the daemon's snapshot file; hooks become socket clients       | full rewrite of writers/readers, but TSV format stays |

Specifically rejected as MVP abstractions (reasoned in adversarial review): Effect sum types, multiplexer-neutral adapters, runtime plug-in registries, schema-validation libraries.

## 17. Open questions, accepted risks, adversarial concerns addressed

Each adversarial concern from review is enumerated here with the disposition.

**A1 (low) — Citing fzf for flat package layout was misleading; `internal/` enforces privacy at compile time.**
Disposition: **moot — Go layout deleted entirely.** This document supersedes the GO ARCH proposal. The plugin is bash. There is no Go module, no `internal/`, no flat-vs-nested debate. If a daemon is ever added (Section 16), it gets its own design doc.

**A2 (critical) — GO ARCH proposes a Go daemon; UX install_flow says no daemon. These are mutually exclusive.**
Disposition: **resolved by selecting bash + no daemon.** Decision 5/7/18 in `docs/ARCHITECTURE.md` already locks this. The GO ARCH spec was an exploratory parallel design; it is not implemented. Section 6 explicitly states "There is no daemon to recover" and Section 7 says "There is no goroutine model." Implementers ship from Sections 1–16 of this document; the Go proposal is archived in the design history.

**A3 (medium) — `Effect` sum-type is premature abstraction with no v0.2 user story.**
Disposition: **moot in bash architecture.** No effect type exists. Side effects in the bash design are direct script calls (`state::upsert`, `render::row`). If a Go daemon is added later, this concern is captured in its design review.

**A4 (low) — `Pane` value-vs-pointer size estimate was wrong; mutator semantics unspecified.**
Disposition: **moot in bash architecture.** "Records" are TSV rows. There is no Pane struct. Update semantics are: read TSV → compute new row → write TSV under flock.

**A5 (medium-implied) — Multiplexer-neutral adapter was extension theater.**
Disposition: **rejected for MVP.** `lib/detect.sh` and `lib/state.sh` know about tmux directly. Section 16 lists the cost to add a multiplexer adapter (rewrite both files); we accept that cost rather than design for hypothetical multiplexers we have no users for.

**A6 (testing) — bats-action tooling, mock tmux, bash-version matrix.**
Disposition: **adopted in full.** Section 13 reflects the recommendation verbatim.

**A7 (security) — log injection, ANSI escapes, JSON bombs, transcript_path traversal.**
Disposition: **all 13 hardening rules in Section 15.** Specifically: payload size cap (#1), depth cap (#2), `last_assistant_message` clamp (#3), control-byte scrub (#4), tmux `#` escape (#5), no eval (#6), transcript_path opaque (#7), TSV field validation (#8), flock timeout (#9), settings.json backup (#10), no network (#11), no setuid (#12), symlink-safe cache dir (#13).

**A8 (UX) — first-press of `prefix + a` before hooks installed.**
Disposition: **Section 10 edge case.** Picker shows a single `display-message` line pointing to `bin/install-hooks`; does not open an empty popup.

**A9 (UX) — `prefix + n` conflict with tmux's default next-window.**
Disposition: **Decision 9 + Section 8.** `@inbox-next-key` defaults to empty (unbound). User opts in.

**A10 (lifecycle) — what happens when tmux server dies mid-state-write?**
Disposition: **Section 6.4.** flock auto-releases on process death (kernel guarantee); on next read, all rows fail PID-liveness; lazy GC clears the TSV. The atomic tmpfile+rename pattern means a partial write leaves the previous TSV intact.

**A11 (concurrency) — hook spawn rate vs flock contention.**
Disposition: **accepted risk, instrumented.** With flock 200 ms timeout and ~80 ms p99 hook duration, contention requires >2.5 hooks/sec sustained per pane. Real Claude usage produces <1 hook/sec/pane in normal interactive use. If contention shows up in `@inbox-debug` logs, the next iteration adds a write-coalescing wrapper. Tracked as a v0.2 risk, not a v0.1.0 blocker.

**A12 (distribution) — TPM has no documented post-install hook.**
Disposition: **Section 11 + Section 12.** Confirmed the limitation; therefore install is genuinely 3 steps not 2. Auto-running `install-hooks` from the `.tmux` entrypoint was rejected because it mutates `~/.claude/settings.json` silently (trust violation). User-explicit Step 3 is the right trade.

**A13 (versioning) — three independent version axes (envelope, TSV, plugin semver) — over-engineered?**
Disposition: **accepted as documented complexity.** Each axis changes for a different reason; collapsing them would couple unrelated changes. The cost is one extra header line in the TSV and one field in the JSON envelope; benefit is forward-compatible additivity.

**A14 (open question) — when bash fallback JSON parsing meets a payload that jq would handle correctly, do we silently drop or surface?**
Disposition: **drop with `@inbox-debug` log.** Same policy as any malformed payload. The pure-bash parser only reads the keys we care about (`hook_event`, `pid`, `last_assistant_message`, `background_tasks`, `notification.kind`). Keys outside that set are ignored. If `jq` is available it is preferred. This is acceptable because the plugin is read-mostly; missing one event of state will be corrected by the next event, typically within seconds.

**A15 (open question) — multi-user / shared host: is one TSV per UID enough?**
Disposition: **accepted limitation.** `state.tsv` is in `$XDG_CACHE_HOME` which is per-user. If two users on the same host both run tmux + Claude they each get their own TSV; cross-user observation is not supported and not in scope.

**A16 (open question) — what happens if Claude Code changes its hook payload schema?**
Disposition: **bump `schema_version` and gate transitions on it.** `lib/transitions.sh` reads `schema_version`; unknown versions log + skip. The plugin will not break Claude even if Claude changes underneath us; the worst case is the plugin silently stops updating state until a release catches up.

---

Implementers ship from this document. If a daemon-based architecture is reintroduced in a future major version, it gets its own design review against this baseline. Companion document: `docs/ARCHITECTURE.md` (decision log, canonical).

