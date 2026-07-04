# Test Cases: W1d chp_ci_status + chp_mergeable normalized-token contracts (#399, #347 phase-2)

Covers the conversion of `chp_ci_status` from a byte-identical `gh`-argv
passthrough ([INV-87], #282) to an abstract normalized-token contract, and
the sibling normalization of `chp_mergeable` (which absorbs `-q '.mergeable'`
into the leaf, keeping its raw-GitHub-token shape). See
`docs/pipeline/provider-spec.md` §3.2. Driven by
`tests/unit/test-w1d-ci-status-mergeable-parity.sh` (decision-level, per R4),
`tests/unit/test-chp-pr-lifecycle.sh` (leaf-level argv), and
`tests/provider-conformance/run-provider-conformance.sh` (W2 conformance).

## Decision-level behavior parity (R4) — `test-w1d-ci-status-mergeable-parity.sh`

For every fixture class the pre-#399 caller exercised, the NEW `ci_is_green`
returns the same rc as the OLD gate; for every classifier input the FULL
TC-MG-CLS table exercised, the classifier gate result is unchanged. Golden
values captured in `tests/unit/fixtures/w1d-parity/` (provenance in the
sidecar `.meta` files).

### `chp_ci_status` + `ci_is_green` (`TC-W1D-PARITY-CI`)

| ID | Fixture class | `gh` stdout | `gh` rc | New token | `ci_is_green` rc |
|---|---|---|---|---|---|
| TC-W1D-PARITY-CI-001 | `all_success_one` | `[{"state":"SUCCESS"}]` | 0 | `green` | 0 |
| TC-W1D-PARITY-CI-002 | `all_success_many` | 3× `{"state":"SUCCESS"}` | 0 | `green` | 0 |
| TC-W1D-PARITY-CI-003 | `mixed_pending` | `SUCCESS` + `PENDING` | 1 | `pending` | 1 |
| TC-W1D-PARITY-CI-004 | `mixed_failure` | `SUCCESS` + `FAILURE` | 1 | `failed` | 1 |
| TC-W1D-PARITY-CI-005 | `skipped_success` | `SKIPPED` + `SUCCESS` | 0 | `pending` | 1 (SKIPPED ≠ SUCCESS) |
| TC-W1D-PARITY-CI-006 | `empty_array` | `[]` | 0 | `none` | 1 |
| TC-W1D-PARITY-CI-007 | `transport_error` | `""` (empty) | 1 | `""` (leaf rc≠0) | 1 (WARN preserved) |
| TC-W1D-PARITY-CI-008 | `failure_and_skipped` | `FAILURE` + `SKIPPED` | 1 | `failed` (rule 2 beats rule 3) | 1 |
| TC-W1D-PARITY-CI-009 | `cancelled_and_pending` | `CANCELLED` + `PENDING` | 1 | `failed` | 1 |
| TC-W1D-PARITY-CI-010 | `in_progress_only` | `[{"state":"IN_PROGRESS"}]` | 1 | `pending` | 1 |
| TC-W1D-PARITY-CI-011 | `rc_nonzero_valid_json_success` | `[{"state":"SUCCESS"}]` | 1 (gh rc-quirk) | `green` | 0 |
| TC-W1D-PARITY-CI-012 | `rc_nonzero_garbage_stdout` | non-JSON | 1 | `""` (leaf rc≠0) | 1 |

TC-W1D-PARITY-CI-011 is the R2 gh-rc-quirk case: `gh pr checks` exits
non-zero for failing/pending/no-check cases even with a parseable JSON
payload — the leaf inspects stdout, not gh's rc, so a valid all-success
payload under gh-rc≠0 STILL yields `green`.

### `_classify_mergeable_gate` byte-unchanged (`TC-W1D-PARITY-MG`)

| ID | Input | Gate |
|---|---|---|
| TC-W1D-PARITY-MG-01 | `MERGEABLE` | `proceed` |
| TC-W1D-PARITY-MG-02 | `mergeable` | `proceed` |
| TC-W1D-PARITY-MG-03 | `CONFLICTING` | `block-substantive` |
| TC-W1D-PARITY-MG-04 | `conflicting` | `block-substantive` |
| TC-W1D-PARITY-MG-05 | `UNKNOWN` | `block-nonsubstantive` |
| TC-W1D-PARITY-MG-06 | `""` (empty) | `block-nonsubstantive` |
| TC-W1D-PARITY-MG-07 | `garbage` | `block-nonsubstantive` |
| TC-W1D-PARITY-MG-08 | `CLEAN` | `block-nonsubstantive` |
| TC-W1D-PARITY-MG-09 | `BEHIND` | `block-nonsubstantive` |

Only `MERGEABLE`/`mergeable` proceed (2/9), matching TC-MG-CLS-08's pinned
stale-UNKNOWN-closed contract.

## Leaf-level argv / shape / fail-closed — `test-chp-pr-lifecycle.sh`

### AC2 — zero gh flags / jq programs cross the seam

| ID | Scenario | Expected |
|---|---|---|
| TC-W1D-ARGV-CI | Seam-trace: invoke `chp_ci_status 42`, record argv `gh` received | `pr checks 42 --repo $REPO --json state` — no `-q`, no `--jq`, no jq program in the received argv |
| TC-W1D-ARGV-MG | Seam-trace: invoke `chp_mergeable 42`, record argv `gh` received | `pr view 42 --repo $REPO --json mergeable -q .mergeable` — the caller passes only the PR |
| Secondary guard | Source grep over `lib-dispatch.sh` / `autonomous-review.sh` | zero `--json`/`-q` tokens on the `chp_ci_status`/`chp_mergeable` caller lines (outside `providers/`) |

### Token-set membership + green predicate + fail-closed (R5)

`tests/provider-conformance/run-provider-conformance.sh` asserts the runner
contract:

| ID | Scenario | Expected |
|---|---|---|
| TC-PCONF-014 (chp_ci_status all-success) | Stub gh serves `[{"state":"SUCCESS"},{"state":"SUCCESS"}]` | Output is exactly `green` |
| TC-PCONF-014 (chp_ci_status mixed-failure) | Stub gh serves `[{"state":"SUCCESS"},{"state":"FAILURE"}]` | Output is exactly `failed` (rule 2 over rule 3) |
| TC-PCONF-014 (chp_ci_status empty) | Stub gh serves `[]` | Output is exactly `none` |
| TC-PCONF-014 (chp_ci_status fail-closed) | Stub gh fails (rc≠0 + empty stdout) | Leaf rc≠0 OR empty stdout — never rc 0 with non-empty output |
| TC-PCONF-015 (chp_mergeable MERGEABLE) | Stub gh serves `{"mergeable":"MERGEABLE"}` under the leaf's `-q '.mergeable'` filter | Output is exactly `MERGEABLE` |
| TC-PCONF-015 (chp_mergeable fail-closed) | Stub gh fails | Leaf rc≠0 (caller's `\|\| echo ""` fallback maps to classifier's empty-string→block-nonsubstantive branch) |

## Caller-line pins — `test-autonomous-review-mergeable-gate.sh`

| ID | Scenario | Expected |
|---|---|---|
| TC-MG-SRC-02 | Grep for the mergeable-poll caller line | `chp_mergeable "$PR_NUMBER" 2>/dev/null \|\| echo ""` — positional PR only, no `-q '.mergeable'` at the caller |
| TC-MG-CLS-01..08 + line-order pins | `_classify_mergeable_gate` / `_pr_open_gate` behavior across the full input space | PASSES UNCHANGED — `lib-review-mergeable.sh` byte-unchanged |
| `test-autonomous-review-fail-branch-open-guard.sh` + `test-autonomous-review-e2e-gate-open-guard.sh` open-guard line-order pins | Line-order structure of the PASS/fail branches | PASSES UNCHANGED |

## Migrated DSAP suite pin — `test-stale-alive-with-pr.sh`

| ID | Scenario | Expected |
|---|---|---|
| TC-DSAP-004 | The historical jq-predicate parity table (`[]`, `["SUCCESS"]`, `["SUCCESS","SUCCESS","SUCCESS"]`, `["SUCCESS","PENDING"]`, `["SUCCESS","FAILURE"]`, `["SKIPPED","SUCCESS"]`) migrated to leaf-token assertions | Each state array maps to `none`/`green`/`green`/`pending`/`failed`/`pending` respectively — the leaf-owned decision order, tested through the same jq body that ships inside the leaf |
| TC-DSAP-014 / TC-DSAP-015 | WARN-on-transport-failure text + mktemp discipline | PASSES UNCHANGED — `ci_is_green` still captures stderr to a mktemp file and emits `WARN: CI-status query (chp_ci_status) failed for PR #N: …` |

## Provider-conformance runner counts

The runner emits `CONFORMANCE-SUMMARY total=30 pass=27 fail=0 skip=0 pending=3`
on `--itp github --chp github` (post-rebase onto main with
W1a/W1b/W1c1/W1c2 already landed; `pass=27` = 22 pre-#399 PASS lines
(20 pre-W1c2 + 2 for chp_pr_view/chp_list_inline_comments emits) + the
5 new W1d assertion emits (3 chp_ci_status token + 1 chp_mergeable token
+ 1 chp_ci_status payload-type-gate — the review-round fix that rejects
rc-0 non-array payloads); `pending=3` = 10 pre-W1 pending set − 3 by
W1a − 1 by W1b − 2 by W1c1 − 2 by W1c2 − 2 by W1d = the residual
`chp_create_pr`, `chp_approve`, `chp_merge` (CHP PR-lifecycle write
verbs). `total` counts one emit line per asserted-verb-check plus one
per pending verb — the `CONFORMANCE-COVERAGE PASS` line does NOT
increment total, so `total = pass + skip + pending` when there are zero
fails.
Degraded/degraded: `total=30 pass=24 fail=0 skip=3 pending=3`.
Broken/broken: `total=30 pass=22 fail=5 pending=3` (the 5 pre-existing
broken-fixture violations; the new W1d asserted verbs stay PASS because
the broken fixture ships correct `chp_broken_ci_status` /
`chp_broken_mergeable`).
Runner README's example output block is updated in the same PR (R5 SAME-PR
tripwire).
