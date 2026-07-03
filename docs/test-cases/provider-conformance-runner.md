# Test Cases: provider-parameterized conformance runner (#370)

Covers `tests/provider-conformance/run-provider-conformance.sh` and its
helper library `tests/provider-conformance/lib-provider-conformance.sh`.
Driven by `tests/unit/test-provider-conformance-runner.sh`
([INV-106](../pipeline/invariants.md#inv-106-provider-conformance-is-spec-defined-and-regression-pinned-by-a-hermetic-provider-parameterized-runner--any-itp-namesh-chp-namesh--caps-pair-must-clear-it)).

## Happy path — github/github

| ID | Scenario | Expected |
|---|---|---|
| TC-PCONF-001 | `--itp github --chp github` runs `itp_list_comments` against a valid canned comment payload | PASS; shape `[{id,author,authorKind,body,createdAt}]`, ascending `createdAt` |
| TC-PCONF-002 | `itp_transition_state` with the stub `gh` set to succeed | PASS; recorded argv matches `gh issue edit … --remove-label … --add-label …` |
| TC-PCONF-003 | `itp_post_comment` with the stub `gh` set to succeed | PASS; recorded argv matches `gh issue comment … --body …` |
| TC-PCONF-004 | `itp_edit_comment` (github, `edit_comment=1`) with the stub set to succeed | PASS; recorded argv matches `gh api -X PATCH …` |
| TC-PCONF-005 | `itp_mark_checkbox` (github, `body_checkbox=1`) with the stub set to succeed | PASS; recorded argv matches `gh api … --method PATCH …` |
| TC-PCONF-006 | `itp_provision_states` with the stub set to succeed | PASS; recorded argv matches `gh label create … --color …` |
| TC-PCONF-007 | `itp_resolve_dep` (same-repo arm) with the stub set to succeed | PASS; out-var carries the stub's state |
| TC-PCONF-008 | `itp_label_event_ts` with the stub set to succeed | PASS; stdout is the stub's timestamp |
| TC-PCONF-009 | `chp_review_threads` with a valid canned GraphQL payload | PASS; shape `[{thread_id,resolved,comments:[…]}]` |
| TC-PCONF-010 | `chp_resolve_thread` with the stub set to succeed | PASS; recorded argv matches the `resolveReviewThread` mutation |
| TC-PCONF-011 | `chp_request_changes` (github, `rest_request_changes=1`) with the stub set to succeed | PASS; recorded argv matches `gh pr review … --request-changes` |
| TC-PCONF-012 | `chp_reply_review_comment` with the stub set to succeed | PASS; recorded argv matches `gh api … -X POST …`, echoes `{id,url}` |
| TC-PCONF-013 | `chp_close_keyword` render eval, `merge_closes_issue=1` | `Closes #<n>` |
| TC-PCONF-013b | `chp_close_keyword` render eval, `merge_closes_issue=0`+`native_issue_pr_link=0` | `Related to #<n>` |
| TC-PCONF-013c | `chp_close_keyword` render eval, `merge_closes_issue=0`+`native_issue_pr_link=1` | empty |
| TC-PCONF-014 | Full `--itp github --chp github` run | exits 0; `CONFORMANCE-SUMMARY` line with `fail=0` |

## Fail-closed write verbs — rc propagation (github)

| ID | Scenario | Expected |
|---|---|---|
| TC-PCONF-015 | `itp_transition_state`/`itp_post_comment`/`itp_provision_states`/`chp_resolve_thread`/`chp_reply_review_comment` invoked with the stub `gh` set to FAIL | rc≠0, no partial/garbage stdout — PASS on the fail-closed assertion |
| TC-PCONF-016 | `itp_edit_comment`/`itp_mark_checkbox`/`chp_request_changes` (github) invoked with the stub failing | rc≠0 — PASS |

## Fail-soft observe/lookup verbs (github)

| ID | Scenario | Expected |
|---|---|---|
| TC-PCONF-017 | `itp_resolve_dep` (same-repo) invoked with the stub `gh` set to FAIL | rc **0**, out-var empty — asserting fail-closed here would be a FALSE finding |
| TC-PCONF-018 | `itp_label_event_ts` invoked with the stub `gh`/`jq` set to FAIL | rc **0**, empty stdout |

## Shape + malformed-JSON handling

| ID | Scenario | Expected |
|---|---|---|
| TC-PCONF-019 | `itp_list_comments` / `chp_review_threads` invoked with a malformed-JSON canned payload | leaf fails gracefully (empty output); runner does not crash on an uncaught `jq` parse error |

## Deliberately-broken fixture (AC2)

| ID | Scenario | Expected |
|---|---|---|
| TC-PCONF-020 | `--itp broken --chp broken`: `itp_broken_list_comments` returns a bare object, not an array | one `FAIL itp_list_comments … wrong-shape` line |
| TC-PCONF-021 | `itp_broken_transition_state` always exits 0 even when the stub `gh` fails | one `FAIL itp_transition_state … rc-0-on-error` line |
| TC-PCONF-022 | `chp_broken_resolve_thread` is not defined | one `FAIL chp_resolve_thread … missing-verb-function` line |
| TC-PCONF-023 | `chp_broken_review_threads` returns a bare object, not an array | one `FAIL chp_review_threads … non-array-output` line |
| TC-PCONF-024 | Full `--itp broken --chp broken` run | exits non-zero; `CONFORMANCE-SUMMARY` `fail>0`; exactly one FAIL line per violated clause above (no duplicate/missing FAILs) |

## Degraded provider — caps-conditioned SKIP (AC per R4)

| ID | Scenario | Expected |
|---|---|---|
| TC-PCONF-030 | `--itp degraded --chp degraded`: `itp_edit_comment` (governing cap `edit_comment=0`) | `SKIP itp_edit_comment (cap: edit_comment)` — never FAIL |
| TC-PCONF-031 | `itp_mark_checkbox` (governing cap `body_checkbox=0`) | `SKIP itp_mark_checkbox (cap: body_checkbox)` |
| TC-PCONF-032 | `chp_request_changes` (governing cap `rest_request_changes=0`) | `SKIP chp_request_changes (cap: rest_request_changes)` |
| TC-PCONF-033 | The 10 remaining ASSERTED verbs (`-`-governed, incl. `chp_close_keyword`'s render-only path) against the degraded leaf bodies | PASS — zero unexpected FAILs |
| TC-PCONF-034 | Full `--itp degraded --chp degraded` run | exits 0; every SKIP line is annotated with its governing cap; no FAIL |

## CONTRACT-PENDING tripwire (R3)

| ID | Scenario | Expected |
|---|---|---|
| TC-PCONF-040 | `coverage.conf`'s `pending` set vs. `provider-spec.md`'s `CONTRACT-PENDING`-tokened verb rows, both extracted by grep | set-diff is empty — PASS |
| TC-PCONF-041 | A `pending` verb in `coverage.conf` whose spec row does NOT carry the token (simulated via a scratch copy) | FAIL naming the verb |
| TC-PCONF-042 | A spec row carrying `CONTRACT-PENDING` whose verb is NOT `pending` in `coverage.conf` (simulated) | FAIL naming the verb |

## Unit tests — `lib-provider-conformance.sh` helpers

| ID | Scenario | Expected |
|---|---|---|
| TC-PCONF-050 | `pcf_conf_value`/`pcf_conf_keys` against `coverage.conf`/`cap-map.conf` | correct value/key extraction, comments+blank lines ignored |
| TC-PCONF-051 | `pcf_resolve_provider_dir` for `github`/`degraded`/`broken`/an unknown name | correct dir for the first three; rc 1 for unknown |
| TC-PCONF-052 | `pcf_materialize_scratch` with two different provider names per seam | scratch dir contains exactly `itp-<itp_name>.{sh,caps}` + `chp-<chp_name>.{sh,caps}`, no cross-seam collision |
| TC-PCONF-053 | `pcf_isolated_path` | includes the stub dir + resolvable `bash`/coreutils/`jq`/`grep`/`sed` dirs, no duplicates |
| TC-PCONF-054 | `pcf_is_json_array` against an array, an object, and empty text | true/false/false |
| TC-PCONF-055 | `pcf_is_ascending_by_created_at` against an ascending, a descending, and an empty array | true/false/true |

## E2E

None pre-merge (hermetic test infra) — per the issue's Testing Requirements,
the label-gated live agent-smoke lane is a post-merge operator release gate,
not an AC here.
