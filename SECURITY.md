# Security Policy

## Threat model

`tmux-coding-agents` runs in the same trust context as the user's tmux server
and Claude Code session. We treat **hook payload data** as adversarial:
fields like `cwd`, `transcript_path`, `last_assistant_message`, and the
`pid` value originate (in part) from an LLM and can be influenced by
prompt-injection, malicious MCP servers, or hostile tool outputs.

We do NOT treat the local filesystem, `~/.cache/tmux-coding-agents/`,
`~/.claude/settings.json`, or the user's tmux server as adversarial — a
co-tenant who can already write to those paths has already escalated.

## Confirmed defenses (review wwbo2gfgl)

| Vector | Mitigation |
|---|---|
| TSV row injection via `awk -v` escape expansion | Field validator rejects backslash; awk uses `ENVIRON` |
| Pane-id shell interpolation in picker popup | Strict `^%[0-9]+$` validation + argv-form `display-popup -E` |
| Symlink redirection on state.tsv / lock / log / settings.json | All open paths reject symlinks via `[ -L "$p" ]` |
| Permissive cache dir mode (CWE-732) | `state::cache_dir` chmods to 0700 on every read |
| Hostile log via NOFOLLOW symlink | `hook_log` refuses to write through symlink |
| Hook-payload DoS | 64 KiB byte cap + JSON depth ≤ 8 |
| TOCTOU on settings.json | flock on sidecar lock file |
| Backup race (same-second collision) | Backup suffix includes `$$` PID |

## Reporting a vulnerability

If you believe you've found a security issue, please:

1. **Do not** open a public issue.
2. Email the maintainer (see git log `--format='%an <%ae>'`) with
   subject `[security] tmux-coding-agents: <short summary>`.
3. Include reproduction steps, impact, and (if possible) a suggested fix.

We aim to acknowledge within 7 days and ship a fix within 30 days for any
issue with practical exploitability.

## Disclosure history

None yet (pre-1.0). The plugin underwent two adversarial review workflows
before public release; findings are tracked in commit messages.
