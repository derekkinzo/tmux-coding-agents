# Contributing

## Shell error-handling posture

Scripts in this repo follow one of three postures, chosen by what the script
does — not by author preference. New scripts and refactors must match the
posture of the tier they belong to.

### Tier 1 — never-fail (`set -u` only)

Scripts that Claude Code invokes via its hook system. They MUST always exit 0
so an internal error does not block Claude. `set -e` is unsafe here because
any fallible call would propagate to a non-zero exit.

- Exemplar: `bin/hook`
- Rules: explicit handling on every fallible call (`|| true`, `|| return 0`,
  case-statements on rc). No `pipefail` — pipelines like
  `state::read | awk ...` tolerate `state::read` returning rc=3 on lock
  timeout and treat the result as "no data".

### Tier 2 — hot-path read (`set -uo pipefail`, no `-e`)

User-triggered scripts that read state and render output. They run on every
status-bar tick or keypress; a partial result is better than a hard fail.

- Exemplars: `bin/inbox-pick`, `bin/inbox-popup`, `bin/inbox-preview`,
  `bin/inbox-status`, `bin/inbox-next`
- Rules: `pipefail` is on so a broken pipeline surfaces, but `-e` is off so
  one failed `tmux` call (e.g., orphaned client) doesn't abort the script
  before the user-facing error message lands. Each fallible call has an
  explicit handler or `|| true`.

### Tier 3 — mutator (`set -euo pipefail`)

Scripts that modify the user's settings or state on disk. Any unhandled
error must halt — partial edits are worse than no edits.

- Exemplars: `bin/install-hooks`, `bin/uninstall-hooks`
- Rules: full strict mode. Fallible calls that are *expected* to fail
  (e.g., probing for an optional file) get explicit `|| true` or
  conditional checks. Atomic mutations use tmpfile + `mv` so a mid-script
  failure leaves the original untouched.

## Tests

- `bats` for everything — `tests/` is the only acceptable home.
- Tests run on bash 3.2 (macOS default) and 5.x (Linux). No
  `local -A`, no `mapfile`, no `${var,,}`.
- Every public function in `lib/*.sh` SHOULD have at least one behavior
  test. The current public surface is documented in each lib's header
  comment; keep them in sync.

## Lint

- `shellcheck` clean (CI matrix enforces).
- `shfmt -i 2 -ci -bn` clean (CI matrix enforces).
