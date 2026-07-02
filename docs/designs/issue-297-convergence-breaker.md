# Design — dispatcher convergence circuit-breaker (issue #297)

> Halt a non-converging dev↔review loop (CI-green but review repeatedly FAILs on
> the same finding against an unchanged PR head) automatically instead of
> burning tokens in an infinite `dev-resume` loop. Motivated by the #286
> deadlock (CI-green-but-`failed-substantive` for 6+ rounds against a
> self-contradictory acceptance spec).

This design implements the **AUTHORITATIVE IMPLEMENTATION SPEC** consolidated in
issue #297 after four rounds of standard review (the `llm-team` 6-model panel +
independent codex + plan-eng EM lens). The original fuzzy-similarity plan was
UNANIMOUS-BLOCKED; the corrections C1–C9 below are what actually ships.

---

## 1. Problem

`handle_completed_session_routing`'s `failed-substantive` branch already bounds
the loop to **one `dev-new` per unchanged HEAD** via the [INV-85] per-HEAD
attempt marker, and #298/[INV-92] proactively escalates a `dev-actionable=false`
verdict. But a verdict that is genuinely `dev-actionable=true`, where the dev
agent *completes* each round yet makes **zero commits** because the spec is
un-satisfiable (the #286 case), still cycles: `dev-new` completes → same review
FAIL against the same head → another `dev-new`. INV-85 Branch B catches the
*second* same-head round via its attempt marker; but that marker's presence
check is itself a single-shot heuristic that a redispatch or a truncated log can
reset. #297 adds a **deterministic, count-based** breaker that trips after
**≥3** completed zero-commit rounds on a frozen head — the belt to INV-85's
suspenders, and the specific fix for the #286 shape.

The flat `MAX_RETRIES` counter *does* eventually trip, but slowly, without
diagnosing *why*, and without surfacing the deadlock root cause (malformed AC,
missing permission) to a human. #297 detects non-convergence precisely and posts
a structured, actionable report.

## 2. Where (single insertion point — C6/R8)

Inside `handle_completed_session_routing`'s `failed-substantive` case, **AFTER**
Branch B′ ([INV-92] `dev-actionable=false` → #298 owns it) and **BEFORE** Branch
C (dev-new). This is the single existing SHA-comparison site; scan-pending-dev
merely skips an already-`stalled` issue (Step 0 hygiene + label gating).

Precedence (C6): `classify_recent_review_verdict` runs first (already does, at
the top of the case). Branches A / B / B′ run first. Only a
`failed-substantive` + `dev-actionable=true` verdict that survives A/B/B′ reaches
the breaker. A `dev-actionable=false` round returns via Branch B′ and never
accretes #297 history.

## 3. Trip signal

### Primary (C1): frozen head across ≥3 completed zero-commit dev-resume rounds

The PR head SHA is **unchanged** across **≥3** rounds in which a dev session
actually ran, reached a terminal state, and produced **zero commits** — i.e. the
dev is stuck (can't act), which is the #286 deadlock regardless of whether the
review's wording changes round-to-round.

### Count source (C9a): the pre-existing per-round "no new commits" comment

The dispatcher already emits, once per completed zero-commit round, the comment
at `dispatcher-tick.sh` Step 5b:

```
Dev process exited (no new commits since last review at `<head>`). Moving to pending-dev for retry.
```

`<head>` is the frozen head (`last_head`, which equals `current_head` in that
branch). #297 derives its convergence count by scanning these **already-emitted**
comments, filtered to `head == current_head` (the head last advanced), and
**verdict-joined** so only `failed-substantive` + `dev-actionable=true` rounds
count (C6 — a `dev-actionable=false` round is excluded).

#297 writes **NO** per-round breadcrumb — only the terminal marker (§6). A new
per-round breadcrumb would be a write on a non-trip round, reintroducing the C7
orphan-artifact TOCTOU. The count is a **distinct convergence signal**, NOT the
`MAX_RETRIES` `retry_count` (C8: `retry_count` also counts agent-failures and
dispatcher-crashes and is moved by `dev-actionable=false` rounds).

Reset: the count naturally resets when the head advances (the comment filter is
`head == current_head`) OR when the trailer-hash changes (see secondary gate).

### Preceding-verdict authenticity (round-11 [BLOCKING] [P1])

The round comment is authenticated (round-7 — `authorKind != "human"` +
`startswith`, see the implementation), but the CANDIDATE VERDICT it is joined
against was not: `_frozen_convergence_rounds_json` picked the newest PRIOR
comment whose body merely contained a `<!-- review-verdict: … -->`-shaped
string, regardless of who posted it. A maintainer/reviewer comment quoting a
past trailer for discussion, posted between the genuine bot verdict and the
Step-5b round comment, would win that unauthenticated `last` selection over the
real trailer — letting an arbitrary discussion comment trip OR suppress the
breaker (reproduced: `count_frozen_convergence_rounds` returned 1 with only a
genuine `failed-non-substantive` verdict preceding, because a quoted
`failed-substantive` trailer in a human comment won the selection).

Fix: gate the candidate-verdict set with the SAME [INV-20]-style actor binding
used elsewhere (`classify_recent_review_verdict`, `recent_review_verdict_body`)
— `.author == BOT_LOGIN` when set (exact match, stricter than authorKind — a
different bot/App is still rejected), else the coarse `authorKind != "human"`
fallback (mirrors the round-comment side's own BOT_LOGIN-empty branching). A
round whose only candidate verdict fails this gate has no authenticated
preceding verdict and is excluded (fail-closed toward MISS, R4).

### Secondary gate (C1/C2): identical trailer-hash

`trailer-hash` = a hash of the canonical string `{verdict}|{cause}|{dev-actionable}`
(pipe-delimited, empty string for absent fields), derived from the
`classify_recent_review_verdict` out-vars — **NOT** body text. All counted rounds
must be `failed-substantive` + `dev-actionable=true`, so the hash is stable
across them by construction; the hash is primarily the **report / idempotency
key** (C5). `review-comment-id`, `dev-session-id`, and per-round timestamps are
**evidence rows** for the report, never the match key (C2).

Match key = `{head, trailer-hash}` ONLY.

## 4. Eligibility pre-gate (C4′/C7/C9b) — `may_stall_now`

`label_swap` is a plain `itp_transition_state` wrapper with **NO** live-PID
deferral (the INV-26 deferral lives inside `mark_stalled`). Routing through
`mark_stalled` would dual-post its "retry exhausted @owner" comment alongside the
#297 report (C4). Resolution:

1. Extract the INV-26 **liveness predicate only** from `mark_stalled` into a
   shared `may_stall_now <issue>` helper — the `pid_alive` call + the
   local-backend empty-PID→DEAD narrowing, returning eligible (0) / not (1),
   with **NO comment side-effect**. The "Stall decision deferred" comment STAYS
   inside `mark_stalled` (else INV-26 regresses — C9b).
2. `mark_stalled` is refactored to call `may_stall_now` for its liveness gate; a
   characterization test asserts its deferral-comment behavior is byte-identical
   before/after.
3. #297 calls `may_stall_now` **WITHOUT** `--at-cap` (it is not retry-exhausted;
   indeterminate remote liveness biases ALIVE → defer = MISS, per R4).

Ordering (C7 TOCTOU fix): the breaker runs the eligibility gate FIRST. Only if
the terminal transition WILL proceed this tick do we post the report + marker +
do the label transition — one eligibility-gated unit. If a dev PID is ALIVE →
post NOTHING, mark NOTHING, defer to next tick (no orphan report).

## 5. Terminal action (C4′/C5/C7)

Once ≥3-frozen-completed + identical-trailer-hash + `dev-actionable=true` +
#298-precedence hold AND `may_stall_now` says eligible:

**Owner correction (round-10): the resume path is REMOVE `stalled`, not
re-add `autonomous`.** `autonomous` is never removed by this pipeline except on
a successful review-close (`state-machine.md`'s label table) — `mark_stalled`
does not remove it, and neither does this breaker's `label_swap`. So the issue
sitting in `stalled` still carries `autonomous`; the maintainer's actual re-arm
action (`stalled-rearm` in `transitions.json`) is to **remove the `stalled`
label**, which re-enters via dispatcher Step 2 (`autonomous → in_progress`) and
resets the retry counter (INV-05). "Re-add `autonomous`" is a no-op on this
pipeline and must not appear in the report or docs.

1. Post ONE structured `reason=non-convergence` report carrying:
   - the PR ref + frozen head SHA (R7),
   - the round timestamps (evidence rows, C2),
   - the verbatim repeated finding (the classified verdict body excerpt),
   - the `cause=` / `dev-actionable` hint (routes the human toward malformed-AC
     vs missing-permission vs genuine),
   - the dispatcher actions taken,
   - a **"To resume: fix per the checklist, then REMOVE the `stalled` label
     (`autonomous` is retained; removal re-arms the pipeline via Step 2 and
     resets the retry counter, INV-05)."** instruction (R7, corrected round-10),
   - the idempotency marker
     `<!-- dispatcher-convergence-breaker: issue=<N> head=<sha> trailer=<hash> -->`.
2. Then the terminal transition via plain `label_swap`: `pending-dev → stalled`
   (the SAME declared movement `mark_stalled` uses — `autonomous` is retained
   throughout, never part of this movement). Exactly ONE terminal comment (the
   #297 report — NOT `mark_stalled`'s "@owner retry exhausted").
3. **Atomicity (round-10 [P1]):** the marker (step 1) and the transition (step
   2) MUST land as one atomic unit from the perspective of the idempotency
   check — persist the marker into the SAME comment payload that also embeds
   proof the transition landed, or perform the transition FIRST and have the
   report's post-transition write be the operation the idempotency check keys
   on. If the label transition fails after the marker is posted, the next tick
   must not see a "reported" marker on an issue that is still `pending-dev` — it
   must retry the transition rather than silently no-op. See `lib-dispatch.sh`
   for the concrete ordering (transition-then-report, with the marker read
   scoped to bot comments AND the current `stalled` label state).

Reuse `stalled` — no new `deadlocked` label (R5): the recovery action is "read
report, fix, remove `stalled`". No `state-machine.md` label edit (the
`pending-dev → stalled` movement is already declared).

## 6. Idempotency (C5/R6)

Before doing anything, grep bot-authored comments for the exact marker
`<!-- dispatcher-convergence-breaker: issue=<N> head=<sha> trailer=<hash> -->`.
Keying on `{issue, head, trailer-hash}` means a genuinely NEW non-convergence
case (a new trailer on the same frozen head) produces a different marker and is
re-evaluated, while a re-run on the SAME case is suppressed.

**Ordering vs. the terminal transition (round-10 [P1] finding 1):** the
idempotency check runs BEFORE the transition, and the transition itself runs
BEFORE the marker is posted (§5). So the marker being present is proof the
transition ALREADY landed (transition-first) — checking for the marker is
equivalent to checking "has this exact case already been fully handled",
never "is a report queued for a transition that might still fail". A
`label_swap` failure aborts the whole routing call under `set -euo pipefail`
before any marker write, so no partially-handled state is ever observable —
the next tick simply re-evaluates and retries from scratch.

## 7. Bias to MISS (R4)

< 3 rounds, any head advance, any trailer-hash change, or a live dev PID → do
NOT trip. `MAX_RETRIES` → `mark_stalled` remains the cheap backstop for
everything the breaker misses. A false-trip discards a converging loop's work +
removes `autonomous` (expensive on an unattended pipeline); a missed trip is
caught by `MAX_RETRIES` (cheap).

## 8. Threshold

`CONVERGENCE_STALL_THRESHOLD` (default `3`, conf-overridable). The trip requires
`>= CONVERGENCE_STALL_THRESHOLD` counted rounds. Independent of `MAX_RETRIES`.

## 9. Docs / INV

Mint **INV-97** (INV-93/95/96 taken on main; INV-94 reserved by in-flight #324)
— renumbered to **INV-102**, then **INV-103** (second collision, #337) on rebases after main independently claimed INV-97
through INV-100 (and #337 claimed INV-101 in flight); see the provenance note
under the INV-103 heading in `invariants.md`. Carry
the heading-adjacent `_Triage (issue #236): [machine-checked:
tests/unit/test-convergence-breaker.sh]_` marker (TC-SPEC-GATE-040/041). Update
`docs/pipeline/dispatcher-flow.md` (a new row + subsection in Step 4b.5.1). No
`state-machine.md` label edit (reusing `stalled`).

## 10. Test plan

Fixture-driven, mirroring `test-handle-completed-session-routing.sh` +
`test-mark-stalled-liveness.sh`, under `env -u PROJECT_DIR`:

- **CB-TRIP-001** — 3 frozen-head completed zero-commit rounds,
  `dev-actionable=true`, identical trailer-hash, eligible (no live PID) → ONE
  `reason=non-convergence` report + marker, `stalled` added, `autonomous` +
  `pending-dev` removed, NO dev-new.
- **CB-MISS-002** — head ADVANCES on the latest round → does NOT trip (Branch C
  dev-new, converging).
- **CB-MISS-003** — only 2 frozen rounds (< threshold) → does NOT trip
  (Branch C).
- **CB-PRECEDENCE-004** — `dev-actionable=false` round → Branch B′ ([INV-92])
  runs, breaker does NOT run and does NOT count it.
- **CB-LIVE-005** — ≥3 frozen rounds BUT `may_stall_now` reports a live dev PID →
  posts NOTHING, marks NOTHING, defers (no orphan report/marker).
- **CB-IDEM-006** — second tick, same `{issue, head, trailer-hash}`, marker
  already present → nothing posted, nothing dispatched.
- **CB-IDEM-007** — a NEW trailer-hash on the same frozen head → re-evaluates
  (different marker).
- **CB-REPORT-008** — the report contains the PR ref + frozen SHA + the resume
  instruction + `reason=non-convergence`.
- **CB-COUNT-009** — the count excludes `dev-actionable=false` rounds and
  dispatcher-crash rounds (C8): a mixed comment set counts only the
  frozen-head `failed-substantive` + `dev-actionable=true` rounds.
- **CB-SHARED-010** (source-of-truth) — both `mark_stalled` and the breaker call
  the shared `may_stall_now`; no duplicated `pid_alive` block.
- **CB-DUAL-011** — exactly ONE terminal comment on a trip (no `mark_stalled`
  "@owner retry exhausted" dual-post).
- **MSL characterization** — `mark_stalled`'s deferral-comment behavior is
  byte-identical before/after the `may_stall_now` factoring (extends
  `test-mark-stalled-liveness.sh`).

## 11. Out of scope

- No change to the review agent's verdict content (#298 sibling).
- No change to normal pass/fail routing for converging loops.
- No new label; `stalled` is reused.
