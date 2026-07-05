# Design: session-report comment must survive auth-dir teardown (#402)

## Problem

`autonomous-dev.sh`'s `cleanup()` posts the `Agent Session Report (Dev)`
comment (carrying the load-bearing `Dev Session ID:` marker) and performs the
success-path label flip **late** in the cleanup sequence — after the INV-79
brokers (`drain_agent_pr_create`, `drain_agent_bot_triggers`) and the
PR-exists lookup. If the per-run auth shim dir (`GH_WRAPPER_DIR`,
`/tmp/agent-auth-XXXXXX/`) vanishes mid-cleanup, bash's command hash for `gh`
still points at the dead path (bash does not re-search `PATH` when a hashed
file disappears) and every subsequent `gh` call in the wrapper's shell fails
rc=127. Both the session report and the label flip are lost.

Downstream effect: with no `Dev Session ID:` comment ever posted, a later
review-FAIL against the same PR HEAD lands in
`handle_pending_dev_pr_exists`'s same-HEAD branch, where
`extract_dev_session_id` returns empty. The [INV-98]/[INV-35] delegation to
`handle_completed_session_routing` is unreachable (it requires a resolvable
session id), so the issue parks in the `stale-verdict:<sha>` residual branch
forever — every 5-minute tick is a no-op.

## Fix — three independent layers

### Layer 1 — reorder `cleanup()`

Post the Agent Session Report immediately after the cleanup-time token
refresh, **before** `drain_agent_pr_create` / `drain_agent_bot_triggers` /
the `PR_EXISTS` lookup. The report only needs `itp_post_comment` +
`$SESSION_ID` + the exit code as known at cleanup entry — none of that is
produced by the broker steps below it.

The label flip is NOT moved: it structurally depends on `PR_EXISTS`, which
depends on the broker steps. Its resilience against a vanished shim comes
from Layer 2, not from reordering.

Side effect: the session report's `Exit code:` now reflects the value at
cleanup entry, before the SIGTERM+PR_EXISTS convergence rewrite
([INV-15]) that only fires when `RECEIVED_SIGTERM=1 && PR_EXISTS>0` (rewrites
143→0). `count_agent_failures` already excludes exit codes 0/143/137
unconditionally, so this loses no failure-counting signal; the label-flip
decision itself still uses the rewritten `$exit_code`.

### Layer 2 — `gh` resolution resilience

A shared `rearm_gh_resolution` helper (`lib-auth.sh`) is called immediately
before EACH load-bearing `gh`-touching write in `cleanup()` — the report
post, `drain_agent_pr_create`, the `PR_EXISTS` lookup, `drain_agent_bot_triggers`,
and the label flip — not once at cleanup entry. The incident proved the
vanish can happen at ANY point mid-cleanup (the shim dir was alive at a
token-daemon refresh and gone nine minutes later); an entry-time-only probe
can pass and never re-arm for a write further down the same function.

The helper: unconditionally drops bash's stale command hash (`hash -d gh`,
cheap and harmless even when the shim is alive — the next call just
re-resolves and re-hashes the same path), then — only when
`${GH_WRAPPER_DIR}/gh` is actually missing — strips the dead `PATH` entry
(reusing `_strip_path_entry`, already defined in `lib-auth.sh`). PATH search
skips nonexistent directories, so resolution falls back to the system `gh`
using the `GH_TOKEN` the refresh step just exported. `autonomous-review.sh`'s
own cleanup path can adopt the same helper for its `drain_agent_bot_triggers`
call site as a follow-up (this PR ships the shared helper; review-wrapper
wiring is out of scope here).

### Layer 3 — dispatcher self-heal (INV-98/INV-35 extension)

In `handle_pending_dev_pr_exists`'s same-HEAD residual-park branch: when
`extract_dev_session_id` returns empty (no session id resolvable at all —
the exact symptom of a lost session report) AND no dev wrapper is alive for
the issue (`may_stall_now`, the shared [INV-24]/[INV-26]-style
`pid_alive`-miss + no-fresh-heartbeat predicate), classify the newest
post-review verdict comment (`classify_recent_review_verdict`, the SAME
classifier `handle_completed_session_routing` uses — called with an empty
`session_end_iso`, since there is no session to anchor to; every ISO-8601
timestamp sorts greater than `""`, so the classifier still returns the
newest qualifying trailer) BEFORE deciding what to dispatch:

- `passed` (race) → no-op, let Step 0 hygiene reconcile.
- `failed-non-substantive` → label-flip to `pending-review` (re-review, not
  a dev-new), bounded per-HEAD via `self-heal-non-substantive:<head>`.
- `dev-actionable=false` ([INV-92]) → `mark_stalled` with an operator
  @-mention, bounded per-HEAD via `self-heal-non-actionable:<head>`.
- `failed-substantive` (dev-actionable=true) or `none` (no classifiable
  verdict found — fail-open, same posture as the classifier's own
  legacy-no-trailer fallback) → dispatch ONE fresh `dev-new`, bounded
  per-HEAD via `self-heal-lost-session:<head>` (INV-85 pattern), so a
  dev-new that itself crashes before posting its own session id cannot
  hot-loop.

Without this classification step, a `failed-non-substantive` (bot/CI
transport hiccup — the code is fine) or a `dev-actionable=false` (every
blocking finding requires a human/privileged token) verdict would be treated
exactly like a genuine substantive code failure, wasting a `dev-new` the
agent can never use to satisfy either.

Every dispatch-bearing branch is gated behind
`acquire_dispatch_marker`/`dispatch_marker_confirm_launched`/
`release_dispatch_marker` ([INV-108]) like every other dev-new dispatch site
in this router, so a concurrent tick can't double-dispatch.

A live wrapper ([INV-24]-style liveness) always wins — the self-heal never
fires while a wrapper might still post its own session report.

## Non-goals

- Identifying the external deleter of the auth dir (fix is deleter-agnostic).
- The `GH_USER_PAT`-unset bot-trigger WARN (separate per-project config gap).
- The wall-clock duration of cleanup (out of scope; file separately if it
  recurs).
