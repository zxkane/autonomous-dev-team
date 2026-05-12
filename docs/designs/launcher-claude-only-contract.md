# AGENT_LAUNCHER claude-only contract + example pitfall doc

Follow-up to PR #101's AGENT_LAUNCHER feature. Two production bugs surfaced after deployment to a downstream consumer's quant-scorer dispatch path:

1. **Bug 1 — `exec cc` resolves to GCC.** The example value in `autonomous.conf.example` was `bash -c 'source ~/.bash_aliases && exec cc "$@"' --`. `exec` only runs external binaries; `cc` (the shell function) is never seen. Bash falls through to PATH lookup which finds `/usr/bin/cc` (GNU C compiler). The wrapper crashed with `cc: error: unrecognized command-line option '--resume'; did you mean '--ree'?` 5 seconds into every dispatch. Three retries → `stalled`.

2. **Bug 2 — wrapper-side `env -u CLAUDECODE claude` becomes claude args.** Once the operator dropped `exec` and used plain `cc "$@"`, claude itself launched, but with garbage argv:
   ```
   error: unknown option '-u'
   ```
   Root cause: lib-agent.sh's claude branch passed `env -u CLAUDECODE claude --session-id ...` to `_run_with_timeout`. With AGENT_LAUNCHER set, the launcher's `bash -c '... cc "$@"'` received those tokens as `$@`, and cc's terminal `$CLAUDE_CMD "$@"` invoked `claude env -u CLAUDECODE claude --session-id ...`. claude saw `env`, `-u`, and a second `claude` as positional args before the real flags.

Both bugs together meant the launcher feature was essentially broken for any user who copy-pasted the example. PR #101's TC-LCH tests passed because they used a synthetic launcher (`env LAUNCHER_FOO=bar`) that didn't end with `$CLAUDE_CMD "$@"` — the test setup assumed a transparent env-injecting prefix, which doesn't match how the canonical `cc` launcher actually works.

## Fix

### lib-agent.sh — branch claude path on AGENT_LAUNCHER state

`run_agent` and `resume_agent`'s claude branches now check `${#AGENT_LAUNCHER_ARGV[@]}`:

| AGENT_LAUNCHER | argv to `_run_with_timeout` | rationale |
|---|---|---|
| empty | `env -u CLAUDECODE claude --session-id <sid> ...` | wrapper drives claude directly, strips CLAUDECODE for safety |
| set | `--session-id <sid> ...` (flags only) | launcher invokes claude itself; CLAUDECODE handling delegated to launcher |

The codex / kiro / opencode branches are unchanged — they don't have `env -u CLAUDECODE` and their command shape is `$AGENT_CMD args...`.

### lib-agent.sh — refuse AGENT_LAUNCHER + AGENT_CMD≠claude

Hard-fail at config load if AGENT_LAUNCHER is set with non-claude AGENT_CMD. The canonical launcher form (cc shell function) is hardcoded to invoke claude — pointing it at codex would produce `claude codex ...`. Catching this at startup is better than crashing 5 seconds into the first dispatch.

### autonomous.conf.example — fix two doc bugs

1. Replace `exec cc "$@"` with plain `cc "$@"` in the worked example.
2. Comment the variable out by default (`# AGENT_LAUNCHER=''`) so users explicitly opt in. Setting `AGENT_LAUNCHER=""` works (lib-agent.sh checks `[[ -n "$AGENT_LAUNCHER" ]]`) but isn't conventional config style.
3. Document the `cc` shell-function-vs-alias trap. Bash non-interactive shells don't expand aliases by default, so a `cc` alias would silently fall through to PATH lookup and again find GCC.

### tests — TC-LCH-002/003 align with new contract

The pre-fix test launcher was `env LAUNCHER_FOO=bar` — a transparent env prefix that didn't match the canonical cc shape. Updated to use `bash -c 'LAUNCHER_FOO=bar exec claude "$@"' --` which mirrors how a real launcher (cc) works. Added a TC-LCH-002 anti-regression assertion: argv must NOT contain `-u` or the literal `claude` token under launcher mode.

### invariants.md — INV-22 updated

INV-22 now documents:
- claude-only scope (rejection at config load for non-claude)
- the flags-only contract for the launcher's `"$@"`
- the two operator pitfalls (exec, alias)

## Files touched

| File | Change |
|---|---|
| `skills/autonomous-dispatcher/scripts/lib-agent.sh` | claude branches in run_agent/resume_agent gate on `${#AGENT_LAUNCHER_ARGV[@]}`; config-load reject AGENT_LAUNCHER+non-claude |
| `skills/autonomous-dispatcher/scripts/autonomous.conf.example` | exec→cc, commented by default, shell-function-vs-alias note |
| `docs/pipeline/invariants.md` | INV-22 expanded with scope, contract, pitfalls |
| `tests/unit/test-autonomous-launcher-verdict-fresh.sh` | TC-LCH-002/003 use canonical launcher form; added TC-LCH-002 anti-regression |
| `docs/designs/launcher-claude-only-contract.md` | this doc |

## What I deliberately did NOT do

- Did not generalize the launcher contract to support codex/kiro/opencode. The canonical user case is "bridge into my interactive cc env"; cc only knows how to launch claude. A user who writes a codex-specific launcher today would have to fork lib-agent.sh anyway. Revisit if/when there's demand.
- Did not auto-fix the operator's `autonomous.conf` files. They're project-local, gitignored, and operator-owned. The example file is the reference; the fix doc travels through the README/CHANGELOG.

## Out of scope

- Vendored skill copies on already-deployed boxes (each project has its own `.agents/skills/.../lib-agent.sh` from `npx skills add`). Operators must re-run `npx skills update` after this PR merges to pick up the fix. There's no programmatic way for upstream to reach into downstream worktrees.
