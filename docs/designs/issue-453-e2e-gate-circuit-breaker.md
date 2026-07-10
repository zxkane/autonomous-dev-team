# Design — same-HEAD E2E-gate circuit breaker (issue #453)

> Halt a repeated INV-46 E2E-gate `fail` against an unchanged PR head/rc pair
> instead of re-dispatching review indefinitely. Motivated by a downstream
> consumer project burning **21 review rounds** against one commit before an
> operator intervened, when the PR's preview deploy 403'd on a missing
> out-of-band deploy-role grant.

## 1. Problem

The INV-46 E2E hard gate (`autonomous-review.sh`'s `E2E_GATE == "fail"` branch)
intercepts BEFORE the review fan-out and BEFORE any verdict is produced. Every
non-zero `_e2e_lane_rc` takes the same route: post a generic finding,
`emit_verdict_trailer failed-substantive`, `submit_request_changes`,
`itp_transition_state reviewing pending-dev`. The dispatcher's INV-98 guard then
sees a PR with no dev-actionable work and bounces the issue back toward
`pending-review`/`reviewing`. Nothing in the system detects "we already failed
this exact way on this exact HEAD" — this is a **fixed-point repetition**, not
divergent findings (contrast with #449's convergence-rules issue, which handles
a *different* non-convergence mode: each round producing *new* findings).

## 2. Where (single insertion point)

Inside `autonomous-review.sh`'s existing `if [[ "$E2E_GATE" == "fail" ]]; then`
block, **before** the existing `itp_post_comment` / `emit_verdict_trailer` /
`submit_request_changes` / `itp_transition_state "reviewing" "pending-dev"`
sequence. This intercepts the loop at its source, inside the review wrapper
that owns the E2E gate — no `dispatcher-tick.sh` / `lib-dispatch.sh` changes.

This mirrors INV-105's convergence breaker (same shared-helper reuse pattern:
`may_stall_now` pre-gate, `stalled` label reuse, one structured report,
transition-then-report atomicity ordering) but for a **different trigger** —
INV-105 fires from the *dispatcher* side on a *completed dev session*; this
breaker fires from the *review wrapper* side on a *repeated gate failure*, and
therefore performs a **different label movement**: `reviewing → stalled`
(INV-105's is `pending_dev → stalled`).

## 3. Fingerprint and counter

Key: `(head_sha, e2e_lane_rc)` — not SHA alone (an outside-voice codex pass on
the issue itself flagged that pure-SHA counting would misclassify a genuinely
new bug following an unrelated transient failure on the same untouched HEAD as
"stuck in a loop").

- Same SHA + same rc as the immediately-prior marker → increment count.
- Same SHA + different rc → reset to count=1 under the new rc.
- Different SHA (new commit pushed) → reset to count=1 under the new SHA/rc pair.

State is a structured HTML-comment marker posted by `autonomous-review.sh`,
following the `dispatcher-convergence-breaker` marker convention
(`lib-dispatch.sh` INV-105):

```
<!-- dispatcher-gate-fail-breaker: issue=<N> head=<sha> rc=<e2e_lane_rc> count=<n> -->
```

Not a label (avoids a new state-machine label-vocabulary row + dispatcher
scan-predicate exclusions everywhere), not run-artifacts (wrapper-side only,
dispatcher can't read it cross-tick). Marker scan is **unbounded** full comment
history (`itp_list_comments`, which already paginates the full history) — this
breaker cannot tolerate a miss the way `_fetch_sha_evidence` can, since losing
the marker on a comment-heavy issue would silently re-enable the exact loop
this issue exists to stop.

## 4. Threshold

New env var `GATE_FAIL_STALL_THRESHOLD` (default `2`), read the same
regex-then-fallback shape as INV-105's `CONVERGENCE_STALL_THRESHOLD` read
(`lib-dispatch.sh:1802`), with one added clause: reject `<2` as well as
non-numeric, and log a warning on fallback (a stricter posture than INV-105's
silent fallback, per this issue's own testing requirements).

## 5. Trip behavior

When the incremented count reaches `GATE_FAIL_STALL_THRESHOLD`:

1. Check current issue labels for `stalled` FIRST — if already stalled (e.g.
   INV-105 tripped first), do not re-trip or post a competing report.
2. Gate behind the shared `may_stall_now` pre-gate (live-PID check).
3. `itp_transition_state "$ISSUE_NUMBER" "reviewing" "stalled"` — lands FIRST,
   atomically, before the report (mirrors INV-105's TOCTOU fix: a failed
   transition aborts under `set -euo pipefail` before any orphan marker posts).
4. Post exactly ONE structured report (marker + human-readable body), reason
   tag `reason=same-head-gate-failure` — the structured body, not the label,
   is what distinguishes this trigger from INV-105's `reason=non-convergence`
   (same reuse tradeoff INV-105 itself accepted).
5. Skip the normal `pending-dev` routing entirely — return before it runs.

Concurrency: no new locking — the existing `reviewing`-label single-writer
invariant (flock-guarded PID-file guard) already rules out two concurrent
writers to the same issue's marker.

## 6. Environment-class awareness (thin slice)

No new error-envelope `class` — reuse the existing `transient` class
(`lib-error.sh`'s case-statement already allows `config|auth|quota|transient`).
Register `ADT_TRANSIENT_E2E_DEPLOY_FAIL` in `docs/pipeline/errors.md`.

**Wrinkle found during implementation research**: `errors.md`'s own header
rule states `class: transient` envelopes are log-only and are NOT registered
in the table (they're auto-retried, no operator action) — and `error_surface`
with `class=transient` is unconditionally log-only (never posts), regardless of
any surface override. So: call `error_envelope` directly (not `error_surface`)
to render the canonical envelope text, splice it into the breaker's own
`itp_post_comment` report, and add a **prose note** (not a formal table row
under the config/auth headings) to `errors.md` documenting this one transient
code for discoverability. `TC-ERR-ENVELOPE-020`'s drift-guard is a pure
literal-substring grep with no class-awareness, so a prose mention containing
the literal code string satisfies both its forward and reverse checks.

Classification signal is local-only: `_e2e_evidence_present == 0` at the
`E2E_GATE == "fail"` branch is the only available "E2E never ran" discriminator
— `_classify_e2e_gate` already collapses every non-zero rc to `fail` without
preserving *why*, so no rc-value-based heuristic is possible without changing
that classifier (out of scope). No new GitHub Actions API call.

## 7. Spec-drift implications (state-machine.md / transitions.json)

The issue's own text frames "reuse `stalled`, not a new label" as avoiding a
`state-machine.md` edit. That conflates *label vocabulary* with *movement*.
`check-spec-drift.sh` Check C.2 requires every label WRITE SITE's movement
(remove-set + add-set) to be declared by some `transitions.json` entry — and
**no existing entry declares `reviewing → stalled`** (every existing `→
stalled` transition is `pending_dev → stalled`). This IS a new, distinct
movement and requires:

1. A new `transitions.json` entry (id `review-e2e-gate-fail-breaker`, `from:
   "reviewing"`, `to: "stalled"`), modeled directly on the sibling
   `review-e2e-gate-fail` entry (same `from`/code-site file) and
   `dispatch-stalled-convergence` (same target label + report-only action
   shape).
2. Regenerate `state-machine.md`'s mermaid block via `gen-state-machine.sh`.
3. A new prose "Label transitions" table row (reviewing section).
4. `spec-guard-map.json` entries for any new guard tokens (`same-head-same-rc-
   threshold-reached`, mirroring `convergence-threshold-reached`).
5. `spec-codesite-map.json` `code_sites` entry (forward/reverse C.3) + a
   `sites[]` entry (C.4/C.5 per-site anchor adjacency).

## 8. New invariant

Documented as a new `INV-<next>` entry in `docs/pipeline/invariants.md`,
cross-referencing INV-46 (the gate this breaker sits inside), INV-105 (the
sibling breaker whose marker/pre-gate/`stalled`-reuse pattern this mirrors for
a different trigger), and #449 (the complementary divergent-findings mode).

## 9. Testing strategy

The hook point lives inside `autonomous-review.sh` (a heavy wrapper sourcing
~15 libs), not `lib-dispatch.sh`. Per the sibling INV-105 test's own
recommendation, the breaker's core logic (fingerprint construction, marker
parse/round-trip, threshold bounds, already-stalled skip) is factored into pure
helper functions in `lib-review-e2e.sh` and unit-tested directly by mocking
`itp_list_comments` / `itp_read_task` / `may_stall_now` / `itp_transition_state`
/ `itp_post_comment`, mirroring `test-convergence-breaker.sh`'s mock style. A
thin source-of-truth grep test (mirroring
`test-autonomous-review-e2e-gate-open-guard.sh`) pins that the wrapper wires
the helper in at the correct point, before the existing `pending-dev` routing.

## Out of scope (per issue #453)

- Auto-remediation of the underlying environment problem.
- A manual `/retry`-without-new-commit command.
- #449's severity-ratchet/round-cap rules.
- Retro-detection of historical stuck loops.
- A general reason-aware `pending-dev`/`pending-review` routing model.
