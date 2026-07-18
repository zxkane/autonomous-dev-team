# Design: crash-consistent token-accounting store (`lib-accounting.sh`)

Issue #505 (parent tracking issue #450). Revision 2 spec, operator-verified.

## Problem

`lib-metrics.sh` is deliberately observe-only (INV-70): every `metrics_emit`
call swallows internal errors, and `metrics_prune` age-drops lines after 90
days. Resource hard gates (future #506) cannot be built on a best-effort,
prunable log. This issue builds the authoritative store those gates will
read — **inert**: nothing in production calls it yet.

## Non-goals (out of scope for #505)

- Terminal-intent markers, owner-aware stalled transitions → sibling issue #515.
- Any enforcement/admission gate/process termination → #506/#507.
- Retention pruning of the accounting store (none added).
- Backend/instance migration of the store.

## D1 — Separate library, separate store

New file `skills/autonomous-dispatcher/scripts/lib-accounting.sh`. Owns a
mandatory-lock store under `<state_dir>/accounting/<issue>/`, a **sibling**
directory of the existing metrics dir (both live under
`${XDG_STATE_HOME:-$HOME/.local/state}/autonomous-<project>/`). `lib-metrics.sh`
ships byte-unchanged. A guard test proves `metrics_prune` cannot reach
`accounting/` (isolation, not retention — see Out of Scope).

## D2 — Storage model

One atomic JSON document per invocation, no cursors:

```
<state_dir>/accounting/<issue>/<invocation_id>.json
<state_dir>/accounting/<issue>/.lock
<state_dir>/accounting/<issue>/projection.json   (optional, rebuildable cache)
```

- Writes: `mktemp` in the same directory, write + sync the temporary file,
  `mv -fT` into place, then sync the parent-directory filesystem. The
  no-target-directory rename both stays on one filesystem and rejects a
  directory target instead of moving the record inside it.
- All mutation (`accounting_start`, `accounting_commit_usage`,
  `accounting_commit_unknown`, `accounting_reconcile`, `accounting_ack_unknown`)
  and query happen under one exclusive `flock` on `<issue>/.lock`
  (`flock -w`, bounded wait — mirrors `_agent_progress_lock_acquire`). Unlike
  `lib-metrics.sh`'s best-effort posture, **this lock is mandatory**: if
  `flock` is unavailable or the wait times out, the operation fails loudly
  (rc≠0) rather than proceeding unlocked — D5's strict-commit contract
  requires it.
- Query = locked full scan of `<issue>/*.json` (excluding `projection.json`
  and `.lock`). `projection.json` (`{total_tokens, source_invocation_ids[],
  digest}`) is a discardable cache: missing/stale (digest mismatch against
  the current file set) → rebuilt inline during query; corrupt (fails to
  parse) → discarded and rebuilt. No cursors, no journals, no sqlite.

## D3 — Identity

```
invocation_id = "inv-v1-" + first 24 hex chars of
                 sha256(canonical_json({run_id, side, member_id, attempt}))
```

- `run_id` — the wrapper's existing INV-81 `RUN_ID`.
- `side` — `dev` or `review`.
- `member_id` — literal `dev` on the dev side; the review fan-out member's
  `_agent_session_id` (a `uuidgen` UUID minted per member in
  `autonomous-review.sh`, existing code) on the review side. Agent NAME is
  metadata only — two members can share a name, the UUID is what
  distinguishes them.
- `attempt` — positive ordinal the CALLER allocates before each accounted CLI
  launch (dev retries increment it within one run).

`accounting_invocation_id` is pure (no I/O): same tuple → same id; any field
differing → a different id (verified via sha256 collision-resistance, not
enumeration).

## D4 — Lifecycle

```
started ──► usage-committed   (terminal)
   └──────► usage-unknown      (terminal, via explicit commit or proven-dead reconcile)
```

- A live `started` record is query-state `incomplete` — never sticky, never
  `usage-unknown` — until D6 reconciliation proves the owning wrapper dead.
- `unavailable` (lock held past wait / store unwritable) and `corrupt`
  (malformed/conflicting on-disk JSON) are **query outcomes**, not record
  states — they never mutate stored history.

## D5 — Strict idempotent commit

`accounting_commit_usage <issue> <invocation_id> <total> [input|-] [output|-]`:

- A valid existing `started` record is required; a missing, malformed, or
  tuple-mismatched record is rejected without synthesizing terminal history.
- Existing terminal record, byte-identical payload → rc 0, **no write**
  (idempotent replay/restart).
- Existing terminal record, differing payload → rc≠0, no mutation, loud
  stderr (never silently altered).
- Counts use canonical decimal spelling and are bounded at
  `9007199254740991`, the largest integer represented exactly by the JSON
  tooling. A full-scan sum beyond that bound reports `corrupt`, never wraps.
- Any write failure (lock timeout, disk full, temporary-file write/sync,
  no-target-directory rename, or parent-directory sync) → rc≠0. No failure
  is swallowed here, unlike `metrics_emit`.

## D6 — Reconciliation (proof-of-death)

`accounting_reconcile <issue>` scans `started` records and promotes to
terminal `usage-unknown` ONLY when existing INV-135 evidence proves the
owning wrapper dead for that `run_id`:

- the run-id sidecar (`issue-<N>.run-id`) now names a DIFFERENT run_id
  (superseded), OR
- the validated run-id sidecar and progress lease name the same current run,
  and that lease's validated `pid` is no longer alive (`kill -0` fails) on
  the execution host.

An issue being closed is **not** proof — closing performs no accounting
mutation. `accounting_ack_unknown <issue> <invocation_id...>` is an explicit,
audited operator verb: it appends an ack record, it never deletes the
`usage-unknown` record. Re-arm (re-running reconcile) never deletes known
totals.

## D7 — Remote topology

Canonical store lives on the **wrapper execution host** (same host that
parses usage into `metrics.jsonl` today). Local backend: dispatcher and
wrapper share a filesystem, so dispatcher-side query/reconcile just calls the
library directly. `EXECUTION_BACKEND=remote-aws-ssm`: a dispatcher-side
caller runs the SAME library synchronously on the SSM target (mirrors the
existing `session-log-probe-remote-aws-ssm.sh` pattern) and returns the
normalized JSON. Any SSM/transport failure → `unavailable` — **never** a
fallback to dispatcher-local state (that would silently substitute a
different host's view for the authoritative one). Backend/instance migration
of the store is unsupported (documented operator note in the invariant).

## D8 — API (pinned)

```
accounting_invocation_id RUN_ID SIDE MEMBER_ID ATTEMPT
accounting_start        ISSUE INVOCATION_ID SIDE RUN_ID MEMBER_ID ATTEMPT
accounting_commit_usage ISSUE INVOCATION_ID TOTAL [INPUT|-] [OUTPUT|-]
accounting_commit_unknown ISSUE INVOCATION_ID REASON
accounting_reconcile    ISSUE
accounting_ack_unknown  ISSUE INVOCATION_ID...
accounting_admission_query ISSUE
```

`accounting_admission_query` echoes one JSON object:

```json
{"status":"complete|incomplete|usage-unknown|unavailable|corrupt",
 "total_tokens":N,"source_digest":"...",
 "open_invocations":[...],"unknown_invocations":[...]}
```

Every function: rc 0 on success, rc≠0 loud on failure, safe under
`set -euo pipefail`, no GitHub API calls (host-local + flock only).

## Why no cursors / journals / sqlite

An issue accumulates tens of invocations across its dev+review lifetime, not
millions. Per-invocation atomic files + a per-issue flock + full-scan query
is the simplest shape that is crash-consistent by construction (a crash mid
`accounting_commit_usage` leaves either the prior authoritative file or the
complete renamed replacement, never a torn record; an orphan `.acct.*`
temporary file can remain before rename but is outside the `*.json` scan).
A cursor/checkpoint design adds a second, cursor-vs-data consistency problem
this scale doesn't need.
