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

Right after the token refresh (and before the now-earlier session-report
post), detect a vanished `GH_WRAPPER_DIR` (`[[ ! -x
"${GH_WRAPPER_DIR}/gh" ]]`), drop bash's stale command hash (`hash -d gh`),
and strip the dead entry from `PATH` (reusing `_strip_path_entry`, already
defined in `lib-auth.sh`). PATH search skips nonexistent directories, so
resolution falls back to the system `gh` — using the `GH_TOKEN` the refresh
step just exported. This protects every subsequent `gh`-touching write in
`cleanup()` (report, brokers, PR-exists lookup, label flip), not just the
first one.

### Layer 3 — dispatcher self-heal (INV-98/INV-35 extension)

In `handle_pending_dev_pr_exists`'s same-HEAD residual-park branch: when
`extract_dev_session_id` returns empty (no session id resolvable at all —
the exact symptom of a lost session report) AND no dev wrapper is alive for
the issue (`may_stall_now`, the shared [INV-24]/[INV-26]-style
`pid_alive`-miss + no-fresh-heartbeat predicate), dispatch ONE fresh
`dev-new` instead of parking. Bounded per-HEAD via a persistent marker
comment (`self-heal-lost-session:<head>`, INV-85 pattern) so a dev-new that
itself crashes before posting its own session id cannot hot-loop. Gated
behind `acquire_dispatch_marker`/`dispatch_marker_confirm_launched`/
`release_dispatch_marker` ([INV-108]) like every other dev-new dispatch site
in this router, so a concurrent tick can't double-dispatch.

A live wrapper ([INV-24]-style liveness) always wins — the self-heal never
fires while a wrapper might still post its own session report.

## Non-goals

- Identifying the external deleter of the auth dir (fix is deleter-agnostic).
- The `GH_USER_PAT`-unset bot-trigger WARN (separate per-project config gap).
- The wall-clock duration of cleanup (out of scope; file separately if it
  recurs).
