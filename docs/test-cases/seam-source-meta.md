# Test Cases — Seam-source LANE meta-check (#342)

Covers `tests/unit/test-seam-source-meta.sh` (new) and the R1 edit to
`tests/unit/test-reply-review-comment.sh` (TC-RRC-033b/c removal).

## Background

Two tests-only CI traps sent every concurrent #296 second-tier migration PR red
for reasons unrelated to the PR's own change:

- **(a) Absolute cutover-baseline totals** pinned in `test-reply-review-comment.sh`
  (TC-RRC-033b/c) moved with every sibling migration that shrinks
  `providers/cutover-baseline.json` — removed in R1 (see
  [`reply-review-comment.md`](reply-review-comment.md) for the updated TC-RRC-033 rows).
- **(b) Seam-source LANE hazard.** When a raw `gh` call inside a shared lib
  migrates behind an `itp_*`/`chp_*` verb, any test harness that sources that
  lib **without the seam in the same shell context** has the verb undefined:
  the call dies rc=127 or fail-softs to empty, and the harness's `gh` stub
  silently stops intercepting. R2 adds a meta-check that catches this in the
  same PR's CI instead of in review round N.

## Consumer-lib set (derived, never hardcoded)

A **consumer lib** is any `skills/autonomous-dispatcher/scripts/lib-*.sh` that
makes executable (non-comment) calls to `itp_*`/`chp_*` verbs of a family whose
seam it does **not** itself source. The seam libs (`lib-issue-provider.sh`,
`lib-code-host.sh`) and everything under `providers/` are excluded (their shim
definitions are not consumption). On today's main the set is exactly
`lib-review-e2e.sh → CHP` (it calls `chp_pr_view` and self-sources only the ITP
seam). The check derives this from the tree so a future lib gaining a
non-self-sourced family is caught automatically.

| ID | Scenario | Expected |
|----|----------|----------|
| `TC-SEAMSRC-001` | `lib-review-e2e.sh` calls `chp_*` and does NOT self-source `lib-code-host.sh` | derived as `lib-review-e2e.sh chp` consumer |
| `TC-SEAMSRC-002` | the seam libs (`lib-issue-provider.sh` / `lib-code-host.sh`) | NEVER in the consumer set (shim defs ≠ consumption) |
| `TC-SEAMSRC-003` | a lib self-sourcing the family it calls (`lib-auth.sh`→CHP, `lib-review-poll.sh`→ITP, …) | NOT a consumer for that family |

## Harness rule (same-shell-context)

For every `tests/unit/test-*.sh` with an executable `source` of a consumer lib,
EACH sourcing shell context must, BEFORE the lib source, either (i) source the
matching seam lib, (ii) define/stub every verb of the missing family the lib
calls, or (iii) be waived. A "shell context" = the top-level test script OR one
`bash -c` / `env … bash -c` string. A top-level seam source does NOT satisfy a
`bash -c` sandbox that re-sources the lib (the TC-TOKEN-SPLIT-072 shape).

Source-target matching recognizes a lib source by basename: literal
`lib-<name>.sh`, or `$VAR`/`${VAR}` where a same-file assignment of `VAR`
contains the basename (covers `source "$E2E_LIB"` / `source "'"$E2E_LIB"'"`).
Comment lines (leading-whitespace `#`) never count — same classifier convention
as `check-provider-cutover.sh`.

| ID | Scenario | Expected |
|----|----------|----------|
| `TC-SEAMSRC-010` | live run: every non-waived harness context sourcing a consumer lib has the seam/stub first | green (offending contexts all waived-or-none) |
| `TC-SEAMSRC-030` | (mode i) a lib gains a new non-self-sourced verb family while a bare-sourcing harness exists | offender flagged |
| `TC-SEAMSRC-031` | (mode ii) seam-then-lib is compliant; a harness DROPPING its seam source | offender flagged |
| `TC-SEAMSRC-032` | (mode iii) a `bash -c` sandbox sources the lib without the seam while the top level HAS it | offender flagged **in the sandbox context** (top-level seam does not cover it) |
| `TC-SEAMSRC-033` | positive control: a sandbox sourcing the seam before the lib AND a sandbox stubbing the called verb before the lib | both compliant (no offender) |
| `TC-SEAMSRC-034` | the scratch seam lib (its `chp_pr_view` shim def) | NOT a consumer |
| `TC-SEAMSRC-035` | a compliant harness: top-level seam, then an inline single-line `x=$(bash -c "…")`, then a top-level lib source AFTER it | NO offender — the inline `bash -c` opens AND closes on its own line, so it must not open a phantom multi-line context that mis-attributes the later top-level source |
| `TC-SEAMSRC-036` | the mirror: an inline single-line `bash -c` that itself sources the lib without a seam (top level has the seam) | offender flagged in the INLINE sandbox context (top-level seam does not cover it) |

Negative-path fixtures mirror `test-provider-cutover.sh`'s scratch-tree pattern:
the checker's core is a bash function driven against scratch scripts+tests dirs,
so the three failure modes are injected without touching the committed tree, and
the SAME detector logic that gates CI is exercised.

## Waivers + hygiene

Waivers are an in-test bash array of `"<harness>:<lib>:<reason>"` (same
self-accounting style as `test-provider-caps-branches.sh`'s LIVE/WAIVED split).

Seed waivers:
- `test-issue-308-b3b4-chp-reads.sh:lib-review-e2e.sh` — **permanent**: its
  FAIL-SOFT section (issue #308 AC4) deliberately sources the lib with NO CHP
  seam to prove `chp_pr_view` degrades to empty (rc=0) rather than crashing.
- `test-autonomous-review-sequential-e2e.sh` / `test-autonomous-review-structured-ac.sh`
  — owned by open PR #337 (adds sandbox-level seam repairs); waivers removed in a
  post-#337 cleanup.

| ID | Scenario | Expected |
|----|----------|----------|
| `TC-SEAMSRC-020` | a waived harness no longer sources the lib at all (dead entry) | FAIL — delete the waiver |
| `TC-SEAMSRC-021` | a waived harness now satisfies the rule in every context | informational **NOTE**, NOT a failure — a sibling PR fixing a waived harness merges without flipping this red (the exact absolute-pin disease #342 removes) |

## R3 repairs (unowned offenders on main)

Offender set derived by running the meta-check against main; every context NOT
owned by an open PR is repaired, owned ones are waived.

- `tests/unit/test-token-split-234.sh` — TC-TOKEN-SPLIT-072's two `bash -c`
  sandboxes (~1100/~1122): added `source lib-code-host.sh` BEFORE the
  `lib-review-e2e.sh` source, mirroring `autonomous-review.sh`'s
  lib-code-host→lib-review-e2e order. Backward-compatible today (seam inert while
  `_post_brokered_e2e_report` still posts via raw `gh pr comment`);
  forward-compatible with #337. PR #326 edits a non-overlapping region (~line 833).
- `tests/unit/test-itp-write-leaves.sh` — its two `_stamp_browser_evidence_marker`
  `bash -c` sandboxes source `lib-review-e2e.sh` without the CHP seam; added
  `CHP_LIB` + a seam source before each lib source. Not owned by any open PR.

## Anti-recurrence proof (AC3)

Simulate the #337 migration in a scratch copy — add a `chp_pr_comment` shim to
the scratch `lib-code-host.sh`, a leaf to the scratch `providers/chp-github.sh`,
and switch `_post_brokered_e2e_report`'s `gh pr comment` to `chp_pr_comment` in
the scratch `lib-review-e2e.sh` (the verb does NOT exist on main — the sim
creates seam+leaf, not just the caller edit). Then the R3-repaired
TC-TOKEN-SPLIT-072 run against the scratch tree passes; the un-repaired shape
fails (post never lands because `chp_pr_comment` is undefined inside the
sandbox). Evidence is in the PR description.

## E2E

Not applicable — tests-only change, no runtime behavior. The CI `unit` job is the
verification surface; the meta-check is hermetic (no `gh`, network, or fixtures
beyond scratch copies).
