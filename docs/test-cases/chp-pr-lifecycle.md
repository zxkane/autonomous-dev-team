# Test Cases — CHP PR-lifecycle leaf migration (#282)

Test file: `tests/unit/test-chp-pr-lifecycle.sh` (hermetic; stubs `gh`).
Mirrors `tests/unit/test-itp-read-leaves.sh` (#281).

## 1. Golden-trace — byte-identical `gh` argv (the no-behavior-change proof)

A recording `gh` stub captures the exact argv each migrated leaf emits; the test
asserts it matches the pre-refactor call.

| ID | Verb / leaf | Assertion |
|---|---|---|
| TC-CHP-CI | `chp_github_ci_status PR` | argv == `pr checks <PR> --repo <REPO> --json state -q [.[].state]` (anchors `ci_is_green`) |
| TC-CHP-FINDPR | `chp_github_find_pr_for_issue ISSUE FIELDS` | argv == `pr list --repo <REPO> --state open --json <FIELDS> -q <q>`; FIELDS forwarded byte-identically (#148 — `body` must survive in FIELDS; #274) |
| TC-CHP-FINDPR-FIELDS-REQUIRED | `chp_github_find_pr_for_issue` w/o FIELDS | errors / non-zero (FIELDS is REQUIRED, M1) |
| TC-CHP-MERGEABLE | `chp_github_mergeable PR` | argv == `pr view <PR> --repo <REPO> --json mergeable -q .mergeable`; returns raw token |
| TC-CHP-APPROVE | `chp_github_approve PR BODY` | argv == `pr review <PR> --repo <REPO> --approve --body <BODY>` |
| TC-CHP-REQCHANGES | `chp_github_request_changes PR BODY` | argv == `pr review <PR> --repo <REPO> --request-changes --body <BODY>` |
| TC-CHP-MERGE | `chp_github_merge PR` | argv == `pr merge <PR> --repo <REPO> --squash --delete-branch` |
| TC-CHP-THREADS | `chp_github_review_threads PR` | `gh api graphql` argv carries `reviewThreads(first: 100)` + the `-F owner/repo/prNumber` vars |
| TC-CHP-RESOLVE | `chp_github_resolve_thread THREAD_ID` | `gh api graphql` argv carries `resolveReviewThread(input: {threadId: $threadId})` + `-F threadId=` |

## 2. M8 thread shape

| ID | Assertion |
|---|---|
| TC-CHP-THREAD-SHAPE | `chp_github_review_threads` returns `{thread_id, resolved, comments:[{id,path,line,author,body,createdAt}]}` — inline `.path`/`.line` present (CHP-owned), distinct from the ITP issue-comment shape |

## 3. `chp_close_keyword`

| ID | Assertion |
|---|---|
| TC-CHP-CLOSEKW-GH | `chp_github_close_keyword 282` → `Closes #282` (GitHub, `merge_closes_issue=1`) |
| TC-CHP-CLOSEKW-CALLER | `autonomous-dev.sh` interpolates `chp_close_keyword`'s output, not a hardcoded literal |
| TC-CHP-CLOSEKW-DEGRADED | degraded fake (`merge_closes_issue=0`) → empty string |

## 4. Dispatch routing + `.caps` parse (already covered by `test-provider-dispatch.sh` #280)

| ID | Assertion |
|---|---|
| TC-CHP-ROUTE (#280) | each `chp_<verb>` routes to `chp_github_<verb>` under default `CODE_HOST=github` |
| TC-CHP-CAPS (#280) | `chp_caps` parses `chp-github.caps` to `native_issue_pr_link=0`, `rest_request_changes=1`, `review_bots=1`, `merge_closes_issue=1` |

## 5. Capability-branch via the degraded fake provider (§7.4)

Uses the existing `tests/unit/fixtures/provider-degraded/chp-degraded.caps`
(`rest_request_changes=0`, `review_bots=0`, `merge_closes_issue=0`) through the
PUBLIC seam (`CODE_HOST=degraded` + `AUTONOMOUS_PROVIDERS_DIR`).

| ID | Assertion |
|---|---|
| TC-CHP-CAP-REQCHG0 | degraded: `chp_caps rest_request_changes` → 0 (the emulation/no-op branch) |
| TC-CHP-CAP-BOTS0 | degraded: `chp_caps review_bots` → 0 (the `chp_trigger_bot` no-op branch) |
| TC-CHP-CAP-MCI0 | degraded: `chp_caps merge_closes_issue` → 0 (caller MUST `itp_transition_state` after `chp_merge`; `chp_close_keyword` returns empty) |

## 6. Function-mock shim audit (§7.3 m3)

| ID | Assertion |
|---|---|
| TC-CHP-SHIM-NORENAME | `fetch_pr_for_issue` keeps its exact name after the refactor (the 5 mocking test files bind) |
| TC-CHP-SHIM-DELEGATES | `fetch_pr_for_issue` / `resolve_pr_for_issue` reach `chp_find_pr_for_issue` |
| TC-CHP-MOCKFILES-PASS | the 5 function-mock test files pass UNEDITED (proven by running them in CI; enumerated in PR body) |

## 7. Conformance fixture rule (INV-75)

| ID | Assertion |
|---|---|
| TC-CHP-FIXTURE-CPR | the fake-skill-tree fixture (`test-entry-point-startup-e2e.sh`) carries `cp -r …/providers` (already true as of #280) |

## 8. Regression gate

The existing unit suite + the conformance suite pass unchanged (§7.3 gate 1).
