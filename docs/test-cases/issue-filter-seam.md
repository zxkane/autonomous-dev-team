# Test Cases: issue-filter provider seam widening (#435, PR-A)

Covers the additive-safe `assignees` field on `itp_list_by_state` and the
widened `itp_list_forbidden_combos` shape (`number,labels,assignees`), plus
the new `assignees=1` capability bit on both in-tree providers
(`providers/itp-github.sh`, `providers/itp-gitlab.sh`,
`providers/itp-github.caps`, `providers/itp-gitlab.caps`). This is PR-A of
the `ISSUE_FILTER` two-PR delivery (`docs/designs/issue-filter.md`) — **zero
behavior change**: no selector/wrapper/dispatcher caller reads `assignees`
yet.

Driven by `tests/provider-conformance/run-provider-conformance.sh`
(exact-key assertions) and `tests/unit/test-w1a-state-read-contracts.sh` /
`tests/unit/test-itp-gitlab.sh` (leaf-level unit coverage).

## `itp_list_by_state` — `assignees` field (both providers)

| ID | Scenario | Expected |
|---|---|---|
| TC-IFSEAM-001 | GitHub leaf: `itp_list_by_state open autonomous 100 "number,labels,assignees"` against a fixture with two assignees on one issue | `assignees` present as `["alice","bob"]` — array of login strings, not `{login}` objects |
| TC-IFSEAM-002 | GitLab leaf: same call against a fixture issue with `assignees:[{"username":"alice"}]` | `assignees` present as `["alice"]` — array of username strings, not objects |
| TC-IFSEAM-003 | GitHub leaf: `FIELDS_CSV` does NOT include `assignees` (e.g. `number,labels`) | output rows carry no `assignees` key at all (projection honesty — `_itp_github_project_fields` only emits requested keys) |
| TC-IFSEAM-004 | GitLab leaf: same omission | output rows carry no `assignees` key |
| TC-IFSEAM-005 | GitHub leaf: an issue with an empty `assignees` array in the fixture, requested via `FIELDS_CSV` | normalizes to `assignees: []`, never `null` |
| TC-IFSEAM-006 | GitLab leaf: same, unassigned issue | normalizes to `assignees: []`, never `null` |

## `itp_list_forbidden_combos` — widened shape (both providers)

| ID | Scenario | Expected |
|---|---|---|
| TC-IFSEAM-010 | GitHub leaf: `itp_list_forbidden_combos open autonomous 100` against a fixture matching the forbidden combo | each row's keys are EXACTLY `number,labels,assignees` (no more, no fewer) — unconditional widening, no `FIELDS_CSV` arg on this verb |
| TC-IFSEAM-011 | GitLab leaf: same call | each row's keys are EXACTLY `number,labels,assignees` |
| TC-IFSEAM-012 | GitHub leaf: forbidden-combo issue with no assignees | row's `assignees` is `[]`, never `null`/missing |
| TC-IFSEAM-013 | GitLab leaf: same | row's `assignees` is `[]`, never `null`/missing |

## Caps bit

| ID | Scenario | Expected |
|---|---|---|
| TC-IFSEAM-020 | `providers/itp-github.caps` | declares `assignees=1` |
| TC-IFSEAM-021 | `providers/itp-gitlab.caps` | declares `assignees=1` |
| TC-IFSEAM-022 | `itp_caps assignees` through the public seam, `ISSUE_PROVIDER=github` | emits `1` |
| TC-IFSEAM-023 | `itp_caps assignees` through the public seam, `ISSUE_PROVIDER=gitlab` | emits `1` |

## Zero-behavior-change regression (AC-A6)

| ID | Scenario | Expected |
|---|---|---|
| TC-IFSEAM-030 | Every existing `itp_list_by_state` caller in `lib-dispatch.sh` (`list_new_issues`, `list_pending_review`, `list_pending_dev`, `list_stale_candidates`) — none request `assignees` | no caller-side code changes; output unaffected (projection honesty makes the new field invisible to callers that don't ask) |
| TC-IFSEAM-031 | Full existing unit + conformance suites | pass unmodified except forbidden-combos fixtures/assertions UPDATED to the widened `number,labels,assignees` shape (not deleted, not weakened) |

## Conformance-runner exact-key assertions (both providers, both verbs)

| ID | Scenario | Expected |
|---|---|---|
| TC-IFSEAM-040 | `run-provider-conformance.sh --itp github` — `itp_list_by_state` with `assignees` requested | exact-key + array-of-strings + `[]`-when-unassigned assertions all PASS (not just is-array/sort) |
| TC-IFSEAM-041 | `run-provider-conformance.sh --itp gitlab` — `itp_list_by_state` with `assignees` requested | same exact-key assertions PASS |
| TC-IFSEAM-042 | `run-provider-conformance.sh --itp github` — `itp_list_by_state` WITHOUT `assignees` requested | assertion that `assignees` key is ABSENT from every row PASSes |
| TC-IFSEAM-043 | `run-provider-conformance.sh --itp gitlab` — same omission | assertion PASSes |
| TC-IFSEAM-044 | `run-provider-conformance.sh --itp github` — `itp_list_forbidden_combos` | exact-key assertion (`number,labels,assignees`) PASSes |
| TC-IFSEAM-045 | `run-provider-conformance.sh --itp gitlab` — `itp_list_forbidden_combos` | exact-key assertion PASSes |
| TC-IFSEAM-046 | `run-provider-conformance.sh --itp github --chp github` and `--itp gitlab --chp github` full runs | exit 0; `CONFORMANCE-SUMMARY` `fail=0` |
