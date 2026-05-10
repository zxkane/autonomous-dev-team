# Fix: dispatcher-tick uses user gh auth when GH_AUTH_MODE=app

**Date:** 2026-05-10
**Issue:** #91
**Status:** Approved

## Problem

`dispatcher-tick.sh` calls `gh` directly (issue list / comment / label) but
never generates a GitHub App token — even when `GH_AUTH_MODE=app`,
`DISPATCHER_APP_ID`, and `DISPATCHER_APP_PEM` are all set. All dispatcher-side
`gh` calls fall back to the user's `gh auth login` token, so issue comments
and label changes appear under the **user's identity** instead of the bot
app.

Root cause: `lib-auth.sh::setup_github_auth` and `gh-app-token.sh` are only
sourced from the agent wrappers (`autonomous-dev.sh`, `autonomous-review.sh`).
The dispatcher tick never consumes `DISPATCHER_APP_ID` / `DISPATCHER_APP_PEM`
to produce a `GH_TOKEN`. The original SKILL.md-based dispatcher (pre-refactor)
called `get_gh_app_token` per project explicitly — the shell-script refactor
did not carry this over.

## Fix

Generate the App installation token **inside `dispatcher-tick.sh`** (not in
`dispatcher-multi-tick.sh`). This keeps the auth setup adjacent to the `gh`
calls it protects, and handles all three invocation paths uniformly:

1. **Inline remote projects** — vars come from `eval "$block"` in the subshell
   set up by `tick_inline_project()`.
2. **Path-entry local projects** — vars come from `load_autonomous_conf`
   sourcing the per-project `autonomous.conf`.
3. **Direct invocation** (single-project deployments) — vars come from
   `load_autonomous_conf` finding `autonomous.conf` via the script-local or
   `PROJECT_DIR` fallback.

In all three cases, by the time we reach the App-token block, `GH_AUTH_MODE`,
`DISPATCHER_APP_ID`, `DISPATCHER_APP_PEM`, `REPO_OWNER`, and `REPO_NAME`
are already resolved.

### Placement

The block sits in `dispatcher-tick.sh` immediately after `lib-dispatch.sh` is
sourced (which validates `REPO_OWNER`) and **before** any `gh` call. The
upfront `EXECUTION_BACKEND` and `REVIEW_BOTS` validators stay where they are —
they don't make `gh` calls, so they don't need the App token.

### Behavior

```bash
if [[ "${GH_AUTH_MODE:-token}" == "app" ]]; then
  if [[ -z "${DISPATCHER_APP_ID:-}" || -z "${DISPATCHER_APP_PEM:-}" ]]; then
    echo "[dispatcher-tick] FATAL: GH_AUTH_MODE=app requires DISPATCHER_APP_ID and DISPATCHER_APP_PEM" >&2
    exit 1
  fi
  source "${SCRIPT_DIR}/gh-app-token.sh"
  _token=$(get_gh_app_token "$DISPATCHER_APP_ID" "$DISPATCHER_APP_PEM" "$REPO_OWNER" "$REPO_NAME") || {
    echo "[dispatcher-tick] FATAL: failed to generate GitHub App token for $REPO_OWNER/$REPO_NAME" >&2
    exit 1
  }
  if [[ -z "$_token" ]]; then
    echo "[dispatcher-tick] FATAL: empty GitHub App token for $REPO_OWNER/$REPO_NAME" >&2
    exit 1
  fi
  export GH_TOKEN="$_token"
  unset _token
fi
```

The token is valid for 1 hour and scoped to the target repo only;
`dispatcher-tick.sh` typically completes in well under a minute, so a single
token covers the whole tick. We do NOT use the background refresh daemon
(`gh-token-refresh-daemon.sh`) here — that's only needed for long-running
agent wrappers.

### Why fail-fast on misconfig

The previous behavior silently fell back to user auth, which is precisely the
bug being reported. If an operator declares `GH_AUTH_MODE=app` they expect
bot identity; failing the tick is more correct than silently impersonating
the user.

### Files to change

- `skills/autonomous-dispatcher/scripts/dispatcher-tick.sh` — add token-gen
  block after lib-dispatch.sh source.
- `tests/unit/test-dispatcher-tick-app-auth.sh` — new test file.

### What we deliberately do NOT change

- `tick_inline_project()` in `dispatcher-multi-tick.sh` — the issue's
  proposed fix put the block there, but doing it in `dispatcher-tick.sh` is
  strictly more general and avoids duplicating logic across the inline +
  path-entry branches.
- `lib-auth.sh::setup_github_auth` — this orchestrates the token-refresh
  daemon for long-lived agent processes. The dispatcher tick is short-lived
  (<1 min), so a single token call is simpler and avoids the daemon-fork
  cleanup path.
- The existing wrappers' auth — they continue to use their own
  `DEV_AGENT_APP_*` / `REVIEW_AGENT_APP_*` identities.

## Test cases

See `docs/test-cases/fix-dispatcher-app-token.md`.

## Acceptance

- `GH_AUTH_MODE=app` + valid `DISPATCHER_APP_ID` + valid `DISPATCHER_APP_PEM`:
  the tick exports a non-empty `GH_TOKEN` before any `gh` call.
- `GH_AUTH_MODE=app` + missing app id or pem: the tick exits 1 with a clear
  FATAL message; no `gh` calls are made.
- `GH_AUTH_MODE=token` (or unset): no token-gen attempted; existing
  `gh auth`/`GH_TOKEN` flow preserved.
- All three invocation paths (inline, path-entry, direct) reach the same
  token-gen block.
