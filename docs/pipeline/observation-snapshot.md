# ObservationSnapshot — the typed read surface of the state machine

> **Status: spec / CI-checked contract (issue #236).** This document is the
> **hard half** of the executable-spec pillar: a typed enumeration of *every*
> input the dispatcher and the dev/review wrappers **consult** to decide a label
> transition. The label transitions themselves live in
> [`transitions.json`](transitions.json); each `guard` token there is grounded
> in a field of the ObservationSnapshot defined here. The JSON Schema is
> [`schemas/observation-snapshot.schema.json`](schemas/observation-snapshot.schema.json).
>
> A label-only transition table would be performative — the snapshot contract is
> what makes the table *mean* something. The (gated, stop-ruled) runtime
> reconciler, if it is ever built, assembles exactly this object before
> evaluating guards; it consumes this schema unchanged. **Nothing here executes
> at dispatch time today** — this documents the read surface so the spec is
> grounded in real code.

Each field below cites the `file:line` + function that READS it today, under
`skills/autonomous-dispatcher/scripts/`. Line numbers are documentation (re-verify
on change); the `spec-drift` CI checker keys on **function names + greppable
predicates** in [`spec-guard-map.json`](spec-guard-map.json), never on line
numbers, so it does not go stale on unrelated edits.

> ⚠️ Line numbers below are accurate as of the commit that introduced this doc.
> They drift as code moves; the **function names** are the durable anchor (and
> are what the checker asserts). When a citation's line number is stale but the
> function still exists, that is expected — fix the number opportunistically.

---

## 1. Label set → `labels`

The current label set, partitioned into the pipeline-meaningful members. An
issue carries `autonomous` plus **at most one** active/terminal state label.

| Field | Source | How read |
|---|---|---|
| `labels.all` / `labels.active_state` | `lib-dispatch.sh` `list_new_issues`; `list_pending_review`; `list_pending_dev`; `list_stale_candidates` | `itp_list_by_state` (abstract state-read contract, #371 W1a) + jq `any(...)` membership filters over the normalized name-string `labels` array |
| `labels.active_state` (Step 5 branch) | `dispatcher-tick.sh` | `grep -q "^in-progress$"` / `grep -q "^reviewing$"` over the label list |
| (active count) | `lib-dispatch.sh` `count_active` | `itp_count_by_state` (abstract any-of-labels count, #371 W1a) |
| `labels.no_auto_close` | `autonomous-review.sh` (PASS branch) | reads `no-auto-close` membership to gate auto-merge skip |

Guards grounded here: `only-autonomous-label`, `still-reviewing`,
`no-auto-close-present`/`absent`, `terminal-with-transitional-residue`
(Step 0 hygiene, `lib-dispatch.sh:163` `hygiene_strip_residual_labels`).

## 2. Dependency resolution → `dependencies` (INV-11, INV-39, INV-83)

| Field | Source | How read |
|---|---|---|
| `dependencies.resolved` | `lib-dispatch.sh` `check_deps_resolved` | `itp_read_task … body \| jq -r '.body'` (GitHub leaf `itp_github_read_task` → `gh issue view … --json title,body,state,labels,comments`, normalized then projected to `.body` caller-side — the ABSTRACT contract since [W1b] #396; routed through the verb since #296/B2) → `sed -n '/^## Dependencies/,/^## /p'` → per-ref state lookup; resolved iff every ref is `CLOSED` or `MERGED` ([INV-11](invariants.md#inv-11-dependency-state-includes-merged)). Same-repo `#N` uses the ambient token; cross-repo `owner/repo#N` uses a per-dep-repo scoped read token minted by the `itp_resolve_dep` verb (GitHub leaf `itp_github_resolve_dep`; `resolve_dep_state` is a thin caller-side wrapper since #284) ([INV-83](invariants.md#inv-83-cross-repo-dependency-lookups-use-a-per-dep-repo-scoped-read-token-the-app-must-be-installed-on-the-dep-repo)) — the ambient dispatcher token covers the dispatching repo only |
| `dependencies.unresolved_refs` | same | the refs whose state is not yet terminal (or whose cross-repo lookup failed because the App is not installed on the dep repo, [INV-83]) |

Guard grounded here: `deps-resolved` (precondition for `dispatch-new`).

## 3. PR existence + reviewDecision + mergeable → `pr` (INV-44, INV-52, INV-54)

| Field | Source | How read |
|---|---|---|
| `pr.exists` / `pr.number` | `lib-dispatch.sh:1125-1131` `fetch_pr_for_issue` | `gh pr list --state open --json …` + jq filter: PR body references `#N` |
| `pr.state` | `autonomous-review.sh` `_pr_open_gate` (INV-54) | `gh pr view --json state`; ≠ OPEN ⇒ silent `−reviewing` |
| `pr.review_decision` | `autonomous-review.sh` (INV-52, wrapper-owned `--approve`/`--request-changes`) | `gh pr view --json reviewDecision` |
| `pr.mergeable` | `autonomous-review.sh:2480-2493` (PASS branch) | `gh pr view --json mergeable`; retried up to `MERGEABLE_RETRIES` (default 3) while `UNKNOWN`; classified by `lib-review-mergeable.sh::_classify_mergeable_gate` ([INV-44](invariants.md#inv-44-mergeable-hard-gate--a-conflicting-pr-can-never-reach-approved)) |
| `pr.ci_state` | `dispatcher-tick.sh` Step 5a | aggregate of `gh pr checks`; all `SUCCESS` required for the ALIVE+PR-ready transition |
| `pr.updated_at` | `dispatcher-tick.sh` Step 5a | `fetch_pr_for_issue … updatedAt`; the 5-minute idle gate ([INV-10](invariants.md#inv-10-5-minute-idle-gate-before-sigterm)) — necessary but, since [INV-137](invariants.md#inv-137-step-5a-gates-sigterm-on-a-current-run-agent-progress-lease-not-pr-updatedat-age-alone), no longer sufficient alone |
| `dev_progress.state`/`age`/`pid`/`run_id` | `dispatcher-tick.sh` Step 5a | `dev_progress_snapshot` (local) / `_remote_dev_progress_snapshot_query` (remote-aws-ssm); classifies [INV-135]'s current-run lease as FRESH/STALE/UNKNOWN — the [INV-137](invariants.md#inv-137-step-5a-gates-sigterm-on-a-current-run-agent-progress-lease-not-pr-updatedat-age-alone) gate that must also report STALE before SIGTERM |

Guards grounded here: `pr-exists-for-issue`, `no-pr-for-issue`,
`mergeable-conflicting`, `mergeable-unknown`, `pr-still-open`, `pr-not-open`,
`pr-merge-succeeded`/`failed`, `pr-approval-failed`, `ci-all-success`,
`pr-idle-5min`.

## 4. Reviewed-HEAD vs PR head → `pr.reviewed_head` / `pr.head_ref_oid` (INV-04, INV-07)

| Field | Source | How read |
|---|---|---|
| `pr.reviewed_head` | `lib-dispatch.sh:1162-1169` `last_reviewed_head` | `gh issue view --json comments` + jq capture of the `Reviewed HEAD: <sha>` trailer; last element ([INV-04](invariants.md#inv-04-reviewed-head-trailer-format)) |
| `pr.head_ref_oid` | `dispatcher-tick.sh:596` (Step 5b) | `jq -r .headRefOid` from `fetch_pr_for_issue` |
| (comparison) | `dispatcher-tick.sh:599-612` | `head_ref_oid == reviewed_head` → no-new-commits → `pending-dev`; differs → `pending-review` ([INV-07](invariants.md#inv-07-empty-reviewed-head-trailer-routes-to-pending-review)) |

Guards grounded here: `head-differs-from-reviewed`, `head-equals-reviewed`.

## 5. Retry-count → `retries` (INV-05, INV-19)

| Field | Source | How read |
|---|---|---|
| `retries.count` | `lib-dispatch.sh:365-380` `count_retries` | `count_agent_failures` + `count_dispatcher_crashes`, gated by `_agent_started_since_stall` ([INV-19](invariants.md#inv-19-retry-counter-requires-confirmed-agent-startup)); counts only since the latest `Marking as stalled` cutoff ([INV-05](invariants.md#inv-05-retry-counter-cutoff-rule)) |
| `retries.max` | `dispatcher-tick.sh` Step 4 | `MAX_RETRIES` (default 3) |
| `retries.review_flip_count` | `lib-dispatch.sh:710-717` `count_review_aware_flips` | `gh issue view --json comments` + jq counts `review-aware-flip:non-substantive session=<id>` markers ([INV-35](invariants.md#inv-35-review-aware-resume-routing-for-completed-sessions)) |
| `retries.review_flip_limit` | `lib-dispatch.sh` `handle_completed_session_routing` | `REVIEW_RETRY_LIMIT` (default 2) |

Guards grounded here: `retries-below-max`, `retries-at-max`,
`review-flips-below-limit`, `review-flips-at-limit`.

## 6. Session-completed reason → `session` (INV-12, INV-35)

| Field | Source | How read |
|---|---|---|
| `session.id` | `lib-dispatch.sh:512-516` `extract_dev_session_id` | jq capture of `Dev Session ID: <id>` from issue comments ([INV-03](invariants.md#inv-03-dev-session-report-comment-format)) |
| `session.completed` / `session.terminal_reason` | `lib-dispatch.sh:567-598` `is_session_completed` | reads the per-issue log `…/agent-${PROJECT_ID}-issue-${N}.log`, `grep '^{"type":"result"'` | tail -1, parses `stop_reason`/`terminal_reason`; completed iff `end_turn\|completed` or `prompt_too_long` ([INV-12](invariants.md#inv-12-resume-only-against-unfinished-sessions)) |
| `session.ended_at` | `lib-dispatch.sh:600-610` | `date -u -r <log-file>` (log mtime) — the window boundary for INV-35 verdict-newer-than-session-end |

Guards grounded here: `session-resumable` (INV-12 unfinished),
`session-completed` (INV-35 terminal).

## 7. Verdict cause → `verdict` (INV-20, INV-35)

| Field | Source | How read |
|---|---|---|
| `verdict.state` | `lib-dispatch.sh:634-705` `classify_recent_review_verdict` | filters issue comments by **actor** (`BOT_LOGIN`, or the `FALLBACK_SESSION_ID` binding when `gh api user` 403s) AND `createdAt > session_end`; parses the `<!-- review-verdict: <state> [cause=<x>] -->` trailer ([INV-20](invariants.md#inv-20-verdict-authenticity-binding-actor--window--trailer-presence)) |
| `verdict.cause` | same, `:692` | `sed -nE 's/.*cause=([a-zA-Z0-9_-]+).*/\1/p'` — `mergeable-unknown` / `e2e-evidence-missing` / `smoke-config-error` / `unavailable` |
| `verdict.created_at` | same | the verdict comment `createdAt` (orders against `session.ended_at`) |

Guards grounded here: `verdict-pass`, `verdict-fail`,
`verdict-fail-substantive`, `verdict-fail-nonsubstantive`.

## 8. Near-success signals → `liveness.near_success` (INV-24)

DEAD detection is **not** a bare `pid_alive` miss. INV-24 requires `pid_alive`
miss **AND** no near-success PR/comment signal **AND** no fresh heartbeat.

| Signal | Source | How read |
|---|---|---|
| dev: latest success/session-id comment age | `lib-dispatch.sh:1188-1210` `latest_dev_success_age_seconds`, `latest_dev_session_id_age_seconds` | `gh issue view --json comments` + jq `Agent Session Report (Dev)` `Exit code: 0` / `Dev Session ID:` → `createdAt` within `DEV_NEAR_SUCCESS_WINDOW_SECONDS` (300) |
| dev: live PID / PGID | `lib-dispatch.sh:1272-1283` `dev_near_success` | `kill -0 $pid`; `_pgid_has_agent_process` ([INV-37](invariants.md#inv-37-pgid-membership-check-uses-the-resolved-per-side-agent-command)) |
| review: merged PR / APPROVED review | `lib-dispatch.sh:1393-1409` `review_near_success` | `fetch_pr_for_issue … mergedAt,reviews` + jq APPROVED `submittedAt` |
| review: verdict comment age / live PID | `lib-dispatch.sh:1176-1183, 1421-1434` | `^Review (PASSED\|findings)` comment age; `kill -0`; `_pgid_has_agent_process` |

Guard grounded here: `no-near-success`.

## 9. Lease / PID liveness → `liveness` (INV-01, INV-18, INV-29, INV-30)

PID liveness is **tiered**, and the remote-SSM path is **TRI-STATE**.

| Field | Source | How read |
|---|---|---|
| `liveness.pid_file_present` | `lib-dispatch.sh:938-942` `_pid_file_for` | `pid_dir_for_project` (lib-config.sh) + `${kind}-${N}.pid` ([INV-01](invariants.md#inv-01-pid-file-naming)) |
| `liveness.state` (local) | `lib-dispatch.sh:1077-1108` `pid_alive` | tier 1 `kill -0 $(cat pidfile)`; tier 2 PID-file mtime; tier 3 `.heartbeat` sibling mtime (threshold `HEARTBEAT_INTERVAL_SECONDS*3`, [INV-29](invariants.md#inv-29-heartbeat-file-is-the-liveness-of-record)) |
| `liveness.state` (remote, **tri-state**) | `lib-dispatch.sh:985-1070` + `liveness-check-remote-aws-ssm.sh` | `aws ssm send-command` runs `kill -0` + `pgrep -g` + heartbeat on the cloud station. Result is **ALIVE → alive (rc 0)**, **DEAD → dead (rc 1)**, **anything else → indeterminate**. `indeterminate` (SSM API failed / timed out / instance unreachable) **biases ALIVE** so the dispatcher never kills a wrapper it cannot see; a degraded-counter WARNs on the 1st and every 10th occurrence ([INV-30](invariants.md#inv-30-remote-liveness-indeterminate-third-state-biases-alive)) |
| `liveness.heartbeat_fresh` | `lib-dispatch.sh:1103-1108` | `.heartbeat` mtime within threshold |
| `liveness.within_grace` | `lib-dispatch.sh:865-902` `is_within_grace_period` | `<!-- dispatcher-token: … at <ts> -->` comment age < `DISPATCH_GRACE_PERIOD_SECONDS` (600) ([INV-17](invariants.md#inv-17-trunk-protection-requires-defense-in-depth-across-3-layers), [INV-18](invariants.md#inv-18-cold-start-grace-period-before-stale-detection)) |

Guards grounded here: `pid-alive`, `pid-dead`.

> **The indeterminate third state is load-bearing.** A two-valued liveness
> (alive/dead) would let a transient SSM hiccup masquerade as DEAD and SIGTERM a
> healthy remote wrapper mid-run — exactly the failure the bias-ALIVE rule
> (INV-30) prevents. Any future reconciler that collapses liveness to a boolean
> reintroduces that bug.

---

## How the snapshot grounds the transition table

Every `guards[]` token in [`transitions.json`](transitions.json) reads one or
more fields above. [`spec-guard-map.json`](spec-guard-map.json) records, per
token, the **function or greppable predicate** that implements the read, and the
`spec-drift` CI job fails if that anchor ever stops resolving — so the snapshot
contract, the transition table, and the code can never silently diverge.

## Cross-references

- [`transitions.json`](transitions.json) — the legal transitions whose guards read this snapshot.
- [`state-machine.md`](state-machine.md) — the prose contract + generated diagram.
- [`spec-guard-map.json`](spec-guard-map.json) — guard/action → code anchor mapping (CI-checked).
- [`invariants.md`](invariants.md) — the rules each field enforces.
- [`dispatcher-flow.md`](dispatcher-flow.md) — the per-step read sequence up close.
