# Design: Step 4a.5 same-HEAD park delegates to INV-35 routing (issue #351)

## Problem

After a review **FAIL**, the dispatcher never re-dispatches the dev side. Step 4's
PR-exists short-circuit (`handle_pending_dev_pr_exists`, the #106 stale-verdict park)
runs **before** Step 4b's completed-session routing, so the INV-35 / INV-85 verdict
routing table is unreachable whenever a PR exists — which is always the case after a
review FAIL.

Concretely, in `dispatcher-tick.sh` Step 4:

```
handle_pending_dev_pr_exists   # line ~418 — same-HEAD → park unconditionally, `continue`
extract_dev_session_id         # line ~423 — NEVER REACHED when a PR exists + same HEAD
is_session_completed → PTL / handle_completed_session_routing  # line ~438 — unreachable
```

`handle_pending_dev_pr_exists`'s same-HEAD branch (`lib-dispatch.sh:~2076`) posts an
idempotent `stale-verdict:<sha>` notice, keeps `pending-dev`, and returns 0 so the caller
`continue`s past ALL session routing. It does **not** consult the verdict class. This
kills the entire INV-35 verdict-routing table:

| verdict class | intended action (INV-35/INV-85/INV-92) | today, PR-exists + same HEAD |
|---|---|---|
| `failed-substantive`, first attempt this HEAD | one bounded `dev-new` | **parked** — findings never acted on |
| `failed-substantive`, second attempt same HEAD | `mark_stalled` (INV-85 bound) | parked |
| `failed-non-substantive`, under cap | re-review (`pending-review`) | parked |
| `failed-substantive` + `dev-actionable=false` | `mark_stalled` (INV-92) | parked |

The dev↔review iteration loop therefore terminates after ONE review round in every class.
Observed live on six issues (2026-06-30 → 07-01): each has ≥1 `stale-verdict:` park
notice after its review FAIL and ZERO post-FAIL dev dispatches.

## Spec contradiction (resolved here)

`dispatcher-flow.md` § Step 4a.5 table (“Same HEAD already reviewed → park, keep
pending-dev”) contradicts § Step 4b.5.1's `failed-substantive` row (“ONE dev-new per
unchanged HEAD”). Per **Pipeline Documentation Authority**, the INV-35/INV-85 routing is
the load-bearing design — it exists precisely to act on review feedback with a bounded
loop. The 4a.5 park row is re-scoped to the cases 4b cannot handle.

## Fix: delegate from 4a.5's same-HEAD branch (delegate-from-4a.5 shape)

Rather than reorder Step 4 (which would resurrect the #99 Bug 3 re-develop-after-crash
surface for *non-completed* sessions), we keep the PR-exists check first and make its
same-HEAD branch **delegate** completed-session routing to the existing router:

In `handle_pending_dev_pr_exists`'s same-HEAD branch (`current_head == last_reviewed_head`),
instead of parking unconditionally:

1. `extract_dev_session_id "$issue_num"`.
2. If a session id resolves **and** `is_session_completed "$issue_num" reason end_iso`
   returns 0 **and** `reason == completed` (i.e. `stop_reason=end_turn`, NOT
   `prompt_too_long`): call
   `handle_completed_session_routing "$issue_num" "$session_id" "$end_iso"` and return 0.
   That router already classifies the verdict via `classify_recent_review_verdict` and
   implements the full INV-35 + INV-85 + INV-92 table (bounded `dev-new` /
   non-substantive re-review / non-actionable stall, including the
   `no-progress-substantive-attempt:<head>` bound and the #298 non-actionable escalation).
3. Otherwise **residual park** — post the idempotent `stale-verdict:<sha>` notice and keep
   `pending-dev` (unchanged behavior), for the cases the router cannot handle:
   - **`prompt_too_long`** terminal reason — must NOT be silently routed through INV-35.
     We return **1** (not 0) so the caller falls through to Step 4b, where the tick's
     existing INV-12 PTL branch mints a fresh `dev-new`. (Returning 0 with a park would
     strand the PTL issue.) This preserves INV-12 PTL recovery semantics verbatim.
   - **no session id resolvable** — park (nothing to route on).
   - **session not completed** per `is_session_completed` — a **live or crashed** wrapper;
     Step 5 owns liveness. This is **log-based detection**: it needs a readable
     `/tmp/agent-${PROJECT_ID}-issue-N.log` with a `{"type":"result"}` line, which the
     claude adapter produces via `--output-format json`. For **non-claude** dev CLIs
     `is_session_completed` returns false **by design** (see its per-CLI scope block), so
     those park — a correct degradation (Step 5b stale-detection is the slower fallback).
   - **classification unavailable** — the router's own `none`/unknown arms fail-closed to
     an operator handoff; we never fail-open to a spurious dispatch.

The `stale-verdict:` notice remains only for the residual park cases; the delegated path
posts its own INV-35 markers (`INV-35-fresh-dev:`, `review-aware-flip:`,
`no-progress-substantive:`, the attempt marker, etc.).

### Why PTL returns 1 (fall-through), not a park

The tick's PTL branch lives at `dispatcher-tick.sh:439` — *after* `handle_pending_dev_pr_exists`.
Delegating PTL to `handle_completed_session_routing` would be wrong (that router assumes a
`completed` session and would truncate/dispatch under INV-35 semantics, not the INV-12 PTL
log-reset + `INV-12-prompt-too-long:<sid>` notice). So for the PTL case the helper returns
1, the caller runs `extract_dev_session_id` + `is_session_completed` again, hits the PTL
branch, and recovers exactly as before. `is_session_completed` is a cheap read (grep+jq on
one log line); calling it twice on the PTL path is acceptable and keeps the fix localized.

### Reachability / regression matrix

| PR-exists + same HEAD, session state | helper action | end state |
|---|---|---|
| completed + `failed-substantive`, 1st attempt this HEAD | delegate → Branch C | one `dev-new`, attempt marker recorded |
| completed + `failed-substantive`, attempt marker present | delegate → Branch B | `mark_stalled` (no 2nd dev-new) |
| completed + `failed-substantive` + `dev-actionable=false` | delegate → Branch B′ | `mark_stalled` (INV-92) |
| completed + `failed-non-substantive`, under cap | delegate → non-substantive arm | flip to `pending-review` |
| completed + verdict `none`/unknown | delegate → operator handoff | park via `INV-12-completed:` |
| `prompt_too_long` | return 1 → tick PTL branch | fresh `dev-new` via INV-12 PTL |
| no session id / not completed (live/crashed) | residual `stale-verdict:` park | `pending-dev` (Step 5 owns liveness) |
| non-claude dev CLI (no result line) | residual `stale-verdict:` park | `pending-dev` |
| `current_head != last_reviewed_head` (HEAD advanced) | unchanged Bug 3 flip | `pending-review` |

## Guards preserved

- **#99 Bug 3** (re-develop-after-crash): only the *same-HEAD* branch changes; the
  HEAD-advanced / no-prior-review / empty-head branches still flip to `pending-review`.
- **INV-12 PTL** (`dispatcher-tick.sh`): PTL falls through untouched (helper returns 1).
- **INV-85** (one dev-new per unchanged HEAD): enforced by the delegated router's Branch B
  attempt-marker check — a second same-HEAD tick escalates, never loops.
- **INV-68** (log retention): the router truncates only `…-N.log` on its Branch C path,
  exactly as today; the residual park never truncates.

## Provider-cutover (INV-91 / AC4)

The fix adds NO raw `gh`. The delegation calls existing functions that already route all
I/O through `itp_*`/`chp_*` verbs (`handle_completed_session_routing`,
`extract_dev_session_id` → `itp_list_comments`, `is_session_completed` reads a local log
file — no `gh`). The cutover baseline is unchanged.

## New invariant

**INV-98** — the Step 4a.5 same-HEAD PR-exists park is NOT terminal: for a `completed` dev
session it delegates to Step 4b.5.1 (`handle_completed_session_routing`); it parks only the
residual cases 4b.5.1 cannot handle (no session id, live/crashed session, non-claude CLI),
and it falls through (returns 1) for `prompt_too_long` so INV-12 PTL recovery still fires.
