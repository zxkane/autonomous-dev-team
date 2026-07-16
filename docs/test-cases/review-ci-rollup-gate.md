# Test Cases: Reviewed-HEAD CI-rollup hard gate (INV-134, issue #489)

Covers the new `chp_ci_rollup` verb (GitHub + GitLab leaves), the pure
`_classify_ci_rollup_gate` decision helper (`lib-review-ci-rollup.sh`), and
the wrapper-side gate wired into `autonomous-review.sh` immediately after
the INV-44 mergeable hard gate and before the `passed` trailer /
`chp_approve` call. Driven by `tests/unit/test-review-ci-rollup-gate.sh`
(decision-level + source-of-truth greps), `tests/unit/test-chp-gitlab-reads.sh`
(GitLab leaf), and `tests/provider-conformance/run-provider-conformance.sh`
(GitHub + GitLab + degraded/broken fixture conformance).

## Background

The review wrapper's pre-approve gate chain never read the CI check rollup:
INV-46 (E2E hard gate) fetches ONLY the dedicated E2E job's evidence, and
INV-44 (mergeable hard gate) is a merge-conflict gate (`mergeable` field),
not a CI-status gate. A PR whose fan-out agents passed and whose mergeable
gate was clean could reach `approved` while a configured GitHub Actions
check on the reviewed HEAD was red. `chp_ci_status` (the existing
normalized-token verb) cannot be reused as-is for this purpose — its
deliberate SKIPPED→`pending` mapping (used for green-corroboration
elsewhere, e.g. `_e2e_ci_green_precheck`) would permanently block approval
on any repo with a label-gated skipped check.

## D1 — `chp_ci_rollup` token derivation (provider-neutral contract)

Stdout: `{"token":"<green|pending|failed|none>","failed_checks":["<name>",...]}`.
rc≠0 on transport/parse failure with empty stdout.

| ID | Per-check state multiset | Expected token | Expected `failed_checks` |
|---|---|---|---|
| TC-CIR-D1-01 | all `SUCCESS` | `green` | `[]` |
| TC-CIR-D1-02 | all `SKIPPED` | `green` (divergence from `chp_ci_status`'s `pending`) | `[]` |
| TC-CIR-D1-03 | `SKIPPED` + `SUCCESS` mix | `green` | `[]` |
| TC-CIR-D1-04 | `[]` (zero checks) | `none` | `[]` |
| TC-CIR-D1-05 | `SUCCESS` + `FAILURE` | `failed` | `["<failing check name>"]` |
| TC-CIR-D1-06 | `PENDING`/`QUEUED`/`IN_PROGRESS`/`EXPECTED` present, no failure | `pending` | `[]` |
| TC-CIR-D1-07 | `FAILURE` + `PENDING` mix | `failed` (rule 1 beats rule 2) | `["<failing check name>"]` |
| TC-CIR-D1-08 | unrecognized future state, no failure | `pending` | `[]` |
| TC-CIR-D1-09 | rc-0 non-array/non-object payload (`{}`, error-shaped object, scalar) | leaf rc≠0, empty stdout | — |
| TC-CIR-D1-10 | transport failure (stub rc≠0, empty stdout) | leaf rc≠0, empty stdout | — |

`chp_ci_status` itself is asserted byte-unchanged for the same inputs
(TC-CIR-D1-01/03/04/05 driven again through `chp_ci_status` must still
yield its own historical tokens — `pending` for the all-SKIPPED and
SKIPPED+SUCCESS cases, `green`/`none`/`failed` for the rest).

## D1 — GitLab leaf (`chp_gitlab_ci_rollup`)

Two-call leaf: base MR view (for `.head_pipeline.id`), then a paginated
jobs fetch (`GET /pipelines/:id/jobs`) when `head_pipeline` is non-null.

| ID | Scenario | Expected |
|---|---|---|
| TC-CIR-GL-01 | `head_pipeline = null` | `{"token":"none","failed_checks":[]}`, exactly ONE `_gl_api` call (fetch-cost gate — no jobs fetch) |
| TC-CIR-GL-02 | jobs all `success` | `green` |
| TC-CIR-GL-03 | jobs `success` + `failed` | `failed`, `failed_checks` names only the failed job |
| TC-CIR-GL-04 | jobs all `skipped` | `green` |
| TC-CIR-GL-05 | jobs `success` + `running` | `pending` |
| TC-CIR-GL-06 | jobs `[]` (pipeline exists, zero jobs reported) | `none` |
| TC-CIR-GL-07 | first `_gl_api` call (MR view) fails | leaf rc≠0, empty stdout |
| TC-CIR-GL-08 | second `_gl_api` call (jobs fetch) fails | leaf rc≠0, empty stdout |
| TC-CIR-GL-09 | MR view missing `head_pipeline` key | leaf rc≠0, empty stdout |
| TC-CIR-GL-10 | non-array jobs payload (`{}`) | leaf rc≠0, empty stdout |
| TC-CIR-GL-11 | non-numeric `head_pipeline.id` | leaf rc≠0, empty stdout, exactly ONE `_gl_api` call (never dispatches a jobs fetch with a bad id) |
| TC-CIR-GL-12 | jobs `running` + `failed` (mixed) | `failed` (FAILURE beats PENDING — parity with GitHub rule 1) |
| TC-CIR-GL-13/14 | positional reject: empty / non-numeric PR | rc 2, ZERO `_gl_api` calls |

## D2 — Gate placement and head-pinning

| ID | Scenario | Expected |
|---|---|---|
| TC-CIR-D2-01 | Gate ordering pin | Source-of-truth grep: PR-open guard (INV-54) → mandatory-bot-review gate (INV-79) → mergeable hard gate (INV-44) → CI-rollup gate (INV-134) → `passed` trailer → `chp_approve`, in that order in the wrapper file |
| TC-CIR-D2-02 | `chp_pr_view ... headRefOid` re-confirmed BEFORE `chp_ci_rollup` | Head mismatch (or empty `PR_HEAD_SHA`) before the call → `head-changed`, gate exits without ever calling `chp_ci_rollup`/`chp_approve` |
| TC-CIR-D2-03 | `chp_pr_view ... headRefOid` re-confirmed AFTER `chp_ci_rollup` | Head mismatch after the call → `head-changed`, gate exits without calling `chp_approve` even though `chp_ci_rollup` already ran |
| TC-CIR-D2-04 | Head-changed routing | `failed-non-substantive` cause `head-changed`, INV-129 `round=0` marker posted, `reviewing → pending-review`, never approve |

## D3 — Outcome routing (full matrix)

| ID | Rollup result | Action |
|---|---|---|
| TC-CIR-D3-01 | `green` | proceed to `chp_approve` |
| TC-CIR-D3-02 | `none` | proceed to `chp_approve` (a repo with no CI must not block) |
| TC-CIR-D3-03 | `failed` | ONE `Review findings:` issue comment listing every name in `failed_checks`; `emit_verdict_trailer failed-substantive "" true`; `submit_request_changes` naming the checks; `reviewing → pending-dev`; `chp_approve` NEVER called |
| TC-CIR-D3-04 | `pending`, below `CI_ROLLUP_WAIT_MAX` | `failed-non-substantive` cause `awaiting-ci`; INV-129 `round=0` marker; `reviewing → pending-review` (NOT `pending-dev`); no approve, no request-changes |
| TC-CIR-D3-05 | `pending`, at `CI_ROLLUP_WAIT_MAX` | `failed-substantive` dev-actionable=true; finding names the still-pending checks; `reviewing → pending-dev` |
| TC-CIR-D3-06 | leaf rc≠0 (transport/parse failure), below cap | same bounded-wait routing as `pending`, cause `ci-status-unavailable`; `reviewing → pending-review` |
| TC-CIR-D3-07 | leaf rc≠0, at cap | `failed-substantive` dev-actionable=true; `reviewing → pending-dev` |
| TC-CIR-D3-08 | rc≠0 never treated as `none`/`green` | Regression: a leaf transport failure must route through the same bounded-wait/give-up path as `pending`, never silently proceed to approve |

### Bounded-wait mechanics

| ID | Scenario | Expected |
|---|---|---|
| TC-CIR-WAIT-01 | SHA-bound wait marker | `<!-- ci-rollup-wait: issue=<N> head=<sha> -->` appended to the hold comment |
| TC-CIR-WAIT-02 | Count markers matching current head | Only markers with the CURRENT `PR_HEAD_SHA` count toward the cap — a new head resets the count by construction |
| TC-CIR-WAIT-03 | `CI_ROLLUP_WAIT_MAX` validation | Default 3; non-numeric or `<1` falls back to default with a WARNING (mirrors `BOT_REVIEW_WAIT_MAX` / `GATE_FAIL_STALL_THRESHOLD` validation style) |

## D4 — Relationship to existing gates

| ID | Scenario | Expected |
|---|---|---|
| TC-CIR-D4-01 | INV-46 (E2E hard gate) unmodified | Source-of-truth grep: the E2E lane's own gate logic is byte-unchanged; runs BEFORE the fan-out, unaffected by the new gate |
| TC-CIR-D4-02 | INV-64 (agent-smoke gate) unmodified | Source-of-truth grep: unaffected by the new gate |
| TC-CIR-D4-03 | Defense-in-depth | The CI-rollup gate double-covering the E2E job's own check is intentional — a scenario where the E2E job is green but a DIFFERENT check is red must still block (regression test mirrors the original incident) |

## D5 — Provider neutrality

| ID | Scenario | Expected |
|---|---|---|
| TC-CIR-D5-01 | Zero raw `gh` calls added to the wrapper | Source-of-truth grep: the wrapper calls only `chp_ci_rollup` / `chp_pr_view` for this gate — no new raw `gh pr checks`/`gh api` line |
| TC-CIR-D5-02 | Both providers implement the verb | `chp_github_ci_rollup` and `chp_gitlab_ci_rollup` both defined; `tests/provider-conformance/coverage.conf` and `cap-map.conf` carry `chp_ci_rollup` entries (ungated, `-`) |

## Regression test (must FAIL before the fix, PASS after)

| ID | Scenario | Pre-fix | Post-fix |
|---|---|---|---|
| TC-CIR-REG-01 | aggregate PASS + PR OPEN + bot review present + `MERGEABLE` + CI rollup `failed` | Approval is reachable (`chp_approve` called) — the incident this issue documents | Approval is unreachable: the gate posts the `[BLOCKING]` finding naming the failed check and `chp_approve` is NEVER called |

## Acceptance criteria cross-reference

See issue #489's own Acceptance Criteria section — every row there maps to
one or more `TC-CIR-*` IDs above, and all are exercised by
`tests/unit/test-review-ci-rollup-gate.sh` in the `Hermetic / Unit +
conformance` CI job.
