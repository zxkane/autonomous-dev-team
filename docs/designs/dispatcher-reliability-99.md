# Dispatcher Reliability — Closes #99

## Context

Issue #99 reports five bugs causing false crash detection, incorrect retry counting, and wasted re-development of already-completed issues. Bugs 1, 3, and 5 were the direct cause of the observed incident; Bug 2 is the structural reliability fix that pairs with Bug 1; Bug 4 was already addressed in #97/#98.

## Scope

- **In scope**: Bugs 1, 2, 3, 5. Wrappers (`autonomous-dev.sh`, `autonomous-review.sh`) and dispatcher (`dispatcher-tick.sh` + `lib-dispatch.sh`).
- **Out of scope**: Bug 4 — already shipped in #97/#98 (`chmod +x` self-heal at the top of `dispatcher-tick.sh`).

## Root Causes

| Bug | Root cause |
|-----|-----------|
| 1   | Step 5 (stale detection) treats a wrapper that hasn't yet written its PID file as DEAD. Cold-start (session spawn + model first call) can take 1–3 minutes, but the dispatcher polls `pid_alive` immediately on the next tick and posts "Task appears to have crashed". |
| 2   | `extract_dev_session_id` reads the session ID from the agent's EXIT-trap session report. If the agent crashes before that trap fires, no session ID exists, and resume falls back to a full re-dispatch. |
| 3   | Step 4 (scan-pending-dev) dispatches dev-resume without checking whether a PR already exists. Any crash AFTER `gh pr create` (e.g. cleanup-time failure with non-zero exit) lands the issue in `pending-dev` with a PR — and the next tick re-runs the full dev cycle. |
| 5   | `count_retries` adds dispatcher-detected crashes (Step 5 DEAD branch comments) to agent-reported failures. Dispatcher false positives (Bug 1) thus consume `MAX_RETRIES` even when the agent never actually failed. |

## Design

### Fix 1 + 2 — Dispatch token + grace period

At dispatch time the dispatcher writes a structured marker comment to the issue: `Dispatch token: <uuid> at <ISO-8601>`. This serves two roles:

1. **Grace period probe (Fix 1).** Step 5 reads the most recent dispatch token's timestamp before classifying any in-progress / reviewing issue. If `now - dispatch_time < DISPATCH_GRACE_PERIOD_SECONDS` (default 1800 = 30 min), skip stale detection for this issue this tick. JUST_DISPATCHED already covers the current-tick case; this extends protection across the cold-start window.
2. **Dispatcher-side dispatch identity (Fix 2).** The token does NOT replace the agent's session report (which is needed for `--resume <session-id>`), but it gives the dispatcher a marker it controls — used by Fix 5 below to distinguish "agent never started" from "agent ran and failed".

Marker format:

    <!-- dispatcher-token: a1b2c3d4 at 2026-05-11T14:30:00Z mode=dev-new -->
    Dispatching autonomous development...

The HTML comment carries machine-parseable fields (token, timestamp, mode); the human-readable body matches the existing wording for backward compat.

`mode` is one of `dev-new`, `dev-resume`, `review` so Fix 5 can filter by the kind of dispatch.

A new helper `latest_dispatch_token_age_seconds` extracts the latest token's age. `is_within_grace_period` returns 0 if `age < DISPATCH_GRACE_PERIOD_SECONDS`. Step 5 calls it after the JUST_DISPATCHED check and before the DEAD/ALIVE branching. Returning 0 means "leave alone, still in grace period".

`DISPATCH_GRACE_PERIOD_SECONDS` defaults to 600 (10 min) and is configurable in `autonomous.conf`. Default chosen empirically: real-world wrapper startup → first agent activity is 1–7 seconds across 10 sampled runs on a real dev box; 10 min leaves 90× headroom while still catching genuinely-dead wrappers within ~2 ticks.

### Fix 3 — Step 4 PR-exists short-circuit

Before dispatching dev-resume, check `fetch_pr_for_issue` (the same helper Step 5 uses). If a PR exists, transition `pending-dev` → `pending-review` and post a comment: `PR #N exists for this issue; transitioning to pending-review instead of retrying dev.` Do NOT count this as a retry.

This catches the "crash after PR creation" path: the agent published a PR, then any error (token expiry, network, bash trap quirk) caused a non-zero exit → cleanup() routed to pending-dev → next tick would re-develop. Now it goes to review.

### Fix 5 — Distinguish agent failures from dispatcher false positives

`count_retries` is split into two counters:

- `agent_failures` — agent session reports with `Exit code: <non-zero>`. **Counts** toward `MAX_RETRIES`.
- `dispatcher_crashes` — Step 5 "Task appears to have crashed" comments. **Only counts** when at least one Dev Session ID exists in the issue comments (i.e., the agent had confirmed startup at some point in this retry cycle). Otherwise treat as a dispatcher false positive — don't consume a retry.

A separate read-only counter `dispatcher_false_positives` is reported in the `Marking as stalled` comment for operator visibility.

Concretely, `count_retries` becomes:

    agent_failures + (session_id_ever_seen ? dispatcher_crashes : 0)

Where `session_id_ever_seen` looks for any "Dev Session ID: \`...\`" comment AFTER the most recent stalled-cutoff. This is the same cutoff already used for the failure counters, so the semantics compose cleanly.

## Impact on Invariants

- **[INV-05] stalled-cutoff rule**: extended — dispatcher crashes are now gated on session-id-ever-seen. Pre-stall-cutoff session IDs do NOT carry over (same as failure counts).
- **[INV-06] dispatcher-crash keyword regex**: unchanged.
- **[INV-09] JUST_DISPATCHED skip**: unchanged. Grace period is a longer-window superset.
- New invariant **[INV-17] Dispatch-token grace**: every dispatch in Steps 2/3/4 writes a token comment; Step 5 must defer judgement on issues whose latest token is younger than `DISPATCH_GRACE_PERIOD_SECONDS`.

## Backward Compatibility

- Existing issues without dispatch-token markers: `latest_dispatch_token_age_seconds` returns empty → grace period not applied → existing behavior preserved.
- `count_retries` for issues without any session-id comments: dispatcher_crashes is now ignored. This is intentional — those are exactly the false-positive cases. If the operator wants the old behavior, they can set `DISPATCH_GRACE_PERIOD_SECONDS=0` and accept retries from cold-start crashes (but the false-positive filter on count_retries still applies; this is the correct fix for Bug 5).

## Test Plan

See `docs/test-cases/dispatcher-reliability-99.md`.
