# Design: Two-token split + agent env scrubbing (issue #234)

## Problem

In App auth mode, the wrapper mints ONE full-write installation token
(`contents:write` + `issues:write` + `pull_requests:write`) and **exports** it
(`GH_TOKEN` / `GH_TOKEN_FILE` / `GITHUB_PERSONAL_ACCESS_TOKEN`) plus prepends a
per-run `gh` shim onto `PATH`. Every agent subprocess inherits all of that, so an
agent can call `gh pr review --approve` + `gh pr merge` itself, bypassing the
wrapper's INV-44 / INV-52 approve/merge gates (the #191 / #193 incident class).
PreToolUse hooks cannot contain this — they miss `gh api` and non-claude CLIs
have no hooks at all. **The credential is the real containment boundary.**

## Goal

Split the credential surface so the **agent process** receives a SECOND, narrower
installation token that *cannot* approve or merge, while the **wrapper** keeps the
full-write token for label flips, approve, merge, and verdict posting.

| Actor | Token | contents | issues | pull_requests |
|-------|-------|----------|--------|---------------|
| Wrapper | full-write (existing) | write | write | **write** |
| Agent (dev + review + E2E) | scoped (new) | write | write | **read** |

## Scope choice — `pull_requests: read` (the containment target is approve/merge)

The whole point (#234 Motivation) is that an agent's token **cannot** `gh pr
review --approve` or `gh pr merge` — both are `pull_requests:write` operations. So
the scoped token gets `pull_requests: read`. This is exactly the issue's stated
scope set.

`gh pr create` ALSO requires `pull_requests:write`, so a `pull_requests:read`
agent token cannot itself open the PR. We resolve that **without** widening the
agent's scope (which would re-enable approve/merge) via a narrow **PR-create
broker**: the dev agent, when the scoped token is active, writes a `branch:
<head>` line + the PR title+body to `$AGENT_PR_CREATE_FILE` and the **wrapper**
(full-write) runs `gh pr create --head <branch>`. The explicit `--head` is
load-bearing: the wrapper runs from `PROJECT_DIR` (checked out on the BASE
branch), so a bare `gh pr create` would infer head=base and fail. The broker
takes the agent's `branch:` line, else derives the pushed `*issue-<N>*` branch
from origin (the [INV-45] glob), and skips with a WARN if neither yields a branch.
This is symmetric with the E2E-report and verdict-artifact broker direction and
is intentionally NARROW — it brokers exactly one operation (`pr create`), distinct
from the out-of-scope "allow-list shim for *arbitrary* agent-requested writes."

> The dev agent's existing `gh pr create` call (autonomous-dev SKILL Step 7) keeps
> working unchanged in PAT mode and in app-mode-without-scoping. When scoping is
> active, the dev prompt instructs the agent to use the broker file; the wrapper
> drains it post-run and opens the PR if the agent didn't. The fallback chain
> means a missed broker write never strands the PR: the wrapper's post-run drain
> creates it.

Review-side agents only ever READ the PR + post issue/PR comments and (for the
E2E lane) post a report — none need `pull_requests:write`, so the same scoped
profile fits both sides. Per-side narrowing (review → `contents:read`) is deferred
to metrics (#234 Design Considerations).

## Containment boundary (defense-in-depth, NOT isolation)

Same OS user → an agent could still read the wrapper's token file off disk if it
went looking. This is **not** a sandbox. What it buys: the token the agent's `gh`
*actually uses* cannot approve/merge, so an agent that "just runs `gh pr merge`"
(the #191 path) gets a deterministic **403**, with no reliance on hooks.
OS-user / container isolation is explicitly out of scope (#234).

## Architecture

### 1. `setup_agent_token` (lib-auth.sh, app mode)

After `setup_github_auth` mints the full-write token + daemon, `setup_agent_token`
mints the scoped token into a SEPARATE file `AGENT_GH_TOKEN_FILE` and starts a
second refresh daemon (same INV-31 lifecycle: parent-pid-watched, 45-min refresh,
killed in `cleanup_github_auth`). The scoped daemon passes a `--permissions` JSON
to `get_gh_app_scoped_token`.

- PAT mode: `setup_agent_token` is a **no-op** that logs a one-time WARN
  (`enforcement degraded to convention in PAT mode`) and leaves the agent on the
  shared PAT — byte-identical to today's behavior.
- App-mode mint failure: WARN + no scrub (agent keeps full-write rather than
  losing GitHub access mid-run — availability over the defense-in-depth bonus).

### 2. Env scrub — CLI-agnostic, applied in `_run_with_timeout`

A new lib-auth helper `build_agent_env_argv` emits an `env`-prefix argv that
`_run_with_timeout` (lib-agent.sh) — through which **every** adapter routes —
prepends to the agent command. Uniformly for claude/codex/gemini/kiro/opencode/
agy/generic the agent subtree gets:

- `GH_TOKEN_FILE` = the **scoped** token file (`AGENT_GH_TOKEN_FILE`) — NOT unset,
  NOT the wrapper's full-write file. This makes the agent's `gh` **refresh-aware**
  (#234 review [P1]): the shim re-reads the scoped file each call and the scoped
  daemon keeps it fresh past the 1h App-token TTL (a one-time `GH_TOKEN` snapshot
  went stale on long runs and started failing pushes/comments/ticks).
- `GH_TOKEN` = the scoped token as a snapshot fallback (the shim re-reads the file
  and overrides it, so the fresh file wins).
- `GITHUB_PERSONAL_ACCESS_TOKEN` / `GH_USER_PAT` **unset** (no full-write/PAT leak)
- `PATH` **kept intact** (#234 review [P1]): the agent's bare `gh` (review prompt,
  vendored helpers like `mark-issue-checkbox.sh`) must keep resolving the per-run
  `gh-with-token-refresh.sh` shim — its only resolvable `gh` on `REAL_GH` hosts
  (#92). The shim reads the scoped `GH_TOKEN_FILE` and execs real `gh` with the
  fresh scoped token, so bare `gh` works, stays fresh, AND authenticates scoped.

Scrub fires ONLY when a scoped token is armed (`AGENT_GH_TOKEN_FILE` non-empty +
readable). PAT mode / app-mode-without-scoping → empty prefix → no behavior change.

### 3. E2E report broker (browser lane)

The browser E2E agent writes its `## E2E Verification Report` to `$E2E_REPORT_FILE`;
the **wrapper posts** it on the PR after the lane exits, then stamps the SHA
evidence marker (`_stamp_browser_evidence_marker`) exactly as before. The agent's
direct `bash scripts/gh pr comment` remains a fallback (issues:write is retained),
so a broker write-miss does not lose the report.

### 4. PAT mode

`GH_AUTH_MODE=token`: no second token possible (a PAT cannot be down-scoped at
mint). `setup_agent_token` logs ONE WARN and returns; no scrub; no broker. Behavior
is byte-identical to today.

## Invariant

**INV-77 — credential split contract.** In app mode the agent process is launched
with ONLY a scoped installation token (`contents:write`, `issues:write`,
`pull_requests:read`): its `GH_TOKEN_FILE` points at the SCOPED token file (kept
fresh by the scoped daemon — refresh-aware, not a stale one-time snapshot), and
`GITHUB_PERSONAL_ACCESS_TOKEN` / `GH_USER_PAT` are unset. The wrapper's full-write
token file (a different path) is never exposed. PATH is kept intact so the agent's
bare `gh` still resolves the per-run shim, which reads the scoped `GH_TOKEN_FILE`
and execs real `gh` with the fresh scoped token. The wrapper retains the full-write
token and is the SOLE approve/merge/label/PR-create path
(complements INV-44 / INV-52). In PAT mode this degrades to convention with a
one-time WARN. Verify-by-construction: a conformance fixture dumps the agent env
and asserts no full-write credential is present.

## Files

- `gh-app-token.sh` — `get_gh_app_scoped_token` (permissions + repositories body).
- `gh-token-refresh-daemon.sh` — accept optional `--permissions <json>` so the same
  daemon refreshes the scoped token.
- `lib-auth.sh` — `AGENT_GH_TOKEN_FILE`; `setup_agent_token`; `build_agent_env_argv`;
  second daemon; cleanup; PAT WARN.
- `lib-agent.sh` — `_run_with_timeout` prepends `build_agent_env_argv` prefix.
- `autonomous-dev.sh` — call `setup_agent_token`; drain `$AGENT_PR_CREATE_FILE`.
- `autonomous-review.sh` — call `setup_agent_token`; E2E broker post.
- `lib-review-e2e.sh` — broker instruction in `build_browser_e2e_prompt`.
- docs: `github-app-setup.md` (scope set + attack-surface note),
  `invariants.md` (INV-77), `dev-agent-flow.md` + `review-agent-flow.md` env tables.

## Test plan

See `docs/test-cases/token-split-234.md` (TC-TOKEN-SPLIT-NNN).
</content>
