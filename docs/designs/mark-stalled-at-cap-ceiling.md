# Design: bound `mark_stalled`'s liveness defer at MAX_RETRIES via an opt-in `--at-cap` flag (#263)

## Problem

`mark_stalled()` (`lib-dispatch.sh`) defers the stall decision whenever `pid_alive`
reports ALIVE ([INV-26] rule 2). Under `EXECUTION_BACKEND=remote-aws-ssm`,
`pid_alive` delegates to the SSM liveness transport; when that transport is
persistently **indeterminate** (transport fault, timeout, garbled stdout,
instance offline), [INV-30]'s conservative bias maps indeterminate → ALIVE.

That ALIVE-bias is correct while retry budget is intact (losing one tick is
cheap and recoverable). It is **wrong once retries are exhausted**: `mark_stalled`
is reached from the dispatcher's Step 4 retry-cap branch only when
`count_retries >= MAX_RETRIES`, and at that point the wrapper has no remaining
claim to the one-tick deference INV-30 normally grants. The pre-fix behavior is
an **unbounded defer loop** — every tick the SSM query stays indeterminate,
`pid_alive` returns ALIVE, `mark_stalled` defers again, the `stalled` label is
never written, and the issue hangs in `pending-dev` indefinitely (reproduced as
a downstream consumer's ~40h hang). The deferral comment shows
`INV-26-stall-deferral:pid=` (empty PID — the dispatcher box doesn't host the
wrapper's PID file under remote backend), which is the tell that no real wrapper
is being deferred to.

## Fix

Two layers, both keyed on the principle that **the policy must change only for the
call path that has already proven retry budget is exhausted** — not for all
`pid_alive` callers and not for all `mark_stalled` callers.

### (i) `pid_alive` gains an opt-in `--at-cap` positional flag

`pid_alive` accepts an optional leading positional `--at-cap`. When set, the
remote-backend **indeterminate** verdict returns 1 (DEAD) instead of biasing
ALIVE. All definite ALIVE/DEAD verdicts and every non-`--at-cap` caller are
unchanged. The guard is placed **before** the `case "$_verdict"` so the `*)`
indeterminate branch keeps its exact `return 0` form — `TC-RPA-010` greps that
branch body as a source-of-truth assertion that the default ALIVE-bias is
preserved.

The flag is **positional, not an exported env var**. An exported knob would leak
into unrelated `pid_alive` calls across the bash test harness's exported
functions; a positional flag is visible only to the call that passes it.

### (ii) `mark_stalled` gains its own opt-in `--at-cap`, propagated to `pid_alive` — and the two callers split

This is the load-bearing part of the design, and the reason it needs a recorded
rationale: **`mark_stalled` has TWO callers, and only one of them is the
retry-budget-exhausted state.**

| Caller | Site | State | Passes `--at-cap`? |
|---|---|---|---|
| Retry-cap | `dispatcher-tick.sh` Step 4 (`count_retries >= MAX_RETRIES`) | retry budget exhausted | **YES** — `mark_stalled --at-cap` |
| Review-retry-cap | `lib-dispatch.sh::handle_completed_session_routing`, `failed-non-substantive` + `REVIEW_RETRY_LIMIT` branch | review bounced too many times; dev retry budget is **not** exhausted | **NO** — plain `mark_stalled` |

`mark_stalled` therefore accepts its own optional leading positional `--at-cap`
flag and propagates it to `pid_alive` **only when present**:

```bash
if [ "$at_cap" = true ]; then
  pid_alive --at-cap issue "$issue_num" && _alive=0 || _alive=1
else
  pid_alive issue "$issue_num" && _alive=0 || _alive=1
fi
```

- The **retry-cap caller** passes `--at-cap` → a persistently-indeterminate
  remote verdict resolves to DEAD, bounding the defer loop to ONE tick and
  writing `stalled`.
- The **review-retry-cap caller** omits the flag → its liveness probe keeps
  [INV-30]'s indeterminate→ALIVE bias. This path is *not* the retry-budget
  exhausted state: the dev wrapper may still be doing legitimate work, just
  bouncing through review; stalling it on a transient SSM blip would be a false
  stall.

> A blanket `--at-cap` inside `mark_stalled` (the first cut of this PR) applied
> the DEAD bias to **both** callers and was flagged BLOCKING in the #263 review:
> it broke INV-30's ALIVE-bias for the review-retry-cap path. The opt-in-per-caller
> split is the fix. Recording it here so a future dispatcher change does not
> "unify the two call sites" and silently re-introduce the regression.

### (iii) Empty-PID = DEAD shortcut, narrowed to local backend

Independent of `--at-cap`: when the backend is `local` (or unset = local default)
AND `get_pid` returns empty AND `pid_alive` returned ALIVE (reachable only via the
tier-2 PID-file-mtime or tier-3 heartbeat-mtime fallbacks, where the PID file
*content* can be empty while its mtime is fresh), `mark_stalled` treats the empty
PID as DEAD: it skips the deferral comment and writes `stalled` — an empty PID
under local backend genuinely means no wrapper holds the file.

This shortcut MUST NOT apply under `remote-aws-ssm`: there the PID file lives on
the wrapper box and dispatcher-side `get_pid` is **always** empty regardless of
wrapper state, so empty-PID is the steady state, not a DEAD signal — under the
remote backend the `--at-cap` flag handles the indeterminate case instead.
Applying the shortcut under the remote backend would resurrect the #121 /
downstream-consumer false-stall bug. The shortcut is correct for *both*
`mark_stalled` callers because it keys on the (local-only) empty-PID fact, not on
the retry-cap state.

## Policy framing

**At-cap indeterminate means "stop waiting", NOT "proved dead".** The fix is
scoped to indeterminate verdicts only. Stall marking is therefore **not
guaranteed**: a hung SSM driver, a failing `gh issue edit`, or the transport
returning ALIVE for a stale/wrong wrapper still won't write `stalled` — those are
out of scope.

`_REMOTE_LIVENESS_DEGRADED_COUNT` is **per-process / per-tick** (it resets each
cron tick) and is NOT cross-tick memory — it cannot serve as the stall ceiling.
The durable ceiling is the dispatcher's retry counter (`count_retries >=
MAX_RETRIES`), which is exactly the gate that decides whether `mark_stalled` is
called at all and therefore whether `--at-cap` is passed.

Accepted residual trade-off (documented, not fixed): at MAX_RETRIES a
genuinely-alive remote wrapper CAN be stalled if SSM is temporarily broken and
returns indeterminate. This is the protection INV-30 normally provides; once
retry budget is exhausted the policy deliberately stops deferring on
indeterminate. Recovery is a manual `gh issue edit --remove-label stalled` — the
same cost as any other false stall.

## Out of scope

The original issue Requirements proposed a per-issue "stall-defer count" tracked
via GitHub issue comments. Cross-model review surfaced three persistence-fragility
modes (write-failure rewinds the count; operators deleting deferral comments
rewinds it; `gh issue view` paginates at 100 so old deferrals fall off the
window). The `--at-cap` flag dissolves all three because there is no per-issue
counter to maintain — the dispatcher's already-authoritative retry counter is the
only ceiling. See the issue body's "Why NOT the original ceiling approach".

## Invariants

No new `INV-NN`. This change amends two existing invariants (same PR, per the
Pipeline Documentation Authority rule):

- **[INV-26]** (stall decision excludes dispatcher-induced terminations and defers
  on live wrappers): rule 2 now documents the opt-in `--at-cap` propagation (only
  the MAX_RETRIES caller passes it; the review-retry-cap caller does not) and the
  local-backend-only empty-PID = DEAD shortcut.
- **[INV-30]** (`pid_alive` is authoritative under all execution backends): the
  default `*) return 0` ALIVE-bias is unchanged and remains source-of-truth for
  normal-budget callers; the new **at-cap exception** flips indeterminate → DEAD
  only for the call path that has proven retry budget is exhausted, framed as
  "stop waiting, not proved dead", with the per-tick (not cross-tick) nature of
  `_REMOTE_LIVENESS_DEGRADED_COUNT` stated explicitly.

No `transitions.json` / `state-machine.md` change: the fix reuses the existing
`pending_dev → stalled` transition (`dispatch-stalled-retries`) and only makes it
*reachable* under persistent remote-indeterminate; it adds no new label
transition.

## Test plan

See `docs/test-cases/mark-stalled-at-cap.md`. Unit tests extend
`tests/unit/test-mark-stalled-liveness.sh`:

- **TC-MSL-006** (CRITICAL): remote backend, retry exhausted, SSM indeterminate;
  `mark_stalled --at-cap` writes `stalled` on the SAME tick. Asserts BOTH the
  label write AND the absence of the deferral comment (a return-code-only
  assertion passes before the fix and proves nothing). This is the
  downstream-consumer ~40h-hang regression.
- **TC-MSL-007**: local backend, empty PID + fresh mtime → DEAD, `stalled`
  written, no deferral comment.
- **TC-MSL-008**: genuine alive (non-empty PID, real spawned process) → existing
  [INV-26] deferral preserved.
- **TC-MSL-009**: `pid_alive` WITHOUT `--at-cap` under remote indeterminate still
  returns 0 (ALIVE-bias); WITH `--at-cap` returns 1 (DEAD). Pins TC-RPA-010's
  default form.
- **TC-MSL-010** (CRITICAL — the #263-review BLOCKING-finding regression):
  `mark_stalled <N>` WITHOUT `--at-cap` (the review-retry-cap caller) under remote
  indeterminate → DEFERS (deferral comment posted, NO `stalled` label edit).
  Confirms the review-retry-cap caller retains [INV-30]'s ALIVE-bias.

Backward-compat gate (must stay green): `test-pid-alive-remote-aws-ssm.sh`
(TC-RPA-007 no-flag `mark_stalled` defers; TC-RPA-010 default `*) return 0`),
`test-handle-completed-session-routing.sh` (the review-retry-cap caller),
`test-lib-dispatch.sh`, `test-spec-drift.sh`.
