# Test cases: authoritative PR↔issue linkage (issue #277, INV-86)

Unit suite: `tests/unit/test-pr-issue-linkage-277.sh`
E2E: `tests/e2e/run-pr-linkage-e2e.sh`

The dispatcher mocking strategy (jq-fixture style) mirrors
`tests/unit/test-fetch-pr-for-issue-null-body.sh`: a shell `gh()` stub replays a
fixture JSON through jq with the captured `-q` expression. The fixture set always
contains two open PRs: PR-A closing issue A, PR-B closing issue B with a body
that mentions `#A`.

## Unit

| ID | Scenario | Expected |
|---|---|---|
| **TC-XWIRE-001** | Discovery for issue A with two open PRs: PR-A `closingIssuesReferences=[A]`, PR-B `closingIssuesReferences=[B]` and body mentions `#A`. | `resolve_pr_for_issue A` returns **PR-A** (the one whose close linkage contains A), NOT PR-B. Fails before fix (loose `#N` body match picks `.[0]` = PR-B). |
| **TC-XWIRE-002** | Linkage guard: resolved PR's `closingIssuesReferences` does NOT contain the issue under review (and branch name does not match). | `verify_pr_closes_issue` returns non-zero (rc-tested). The wrapper structurally asserts the guard before any mutation — it `exit 1`s on guard failure through the existing no-valid-PR abort (diagnostic + `failed-non-substantive`), so no `submit_request_changes` / `gh pr review` / `gh pr merge` / label flip is reachable on the no-linkage path. The unit test pins the guard call's presence + rc; the E2E (TC-XWIRE-E2E-001) asserts no mutation verb is issued during discovery/guard. |
| **TC-XWIRE-003** | `fetch_pr_for_issue` (shared helper) with the same TC-XWIRE-001 fixture. | Returns PR-A — both sites exhibit the same correct binding. |
| **TC-XWIRE-004** | Close-keyword-less PRs: no PR has `closingIssuesReferences`; PR-A `headRefName=fix/issue-A-…`, PR-B `headRefName=fix/issue-B-…` whose body mentions `#A`. | Branch-name fallback resolves **PR-A** deterministically; bare `.[0]` body mention never decides. Tie (two `issue-A` branches) → lowest PR number. |
| **TC-XWIRE-005** | `.body == null` PR in the candidate set (parity with #148 guard), across both `resolve_pr_for_issue` and `fetch_pr_for_issue`. | Discovery does not crash; the matching PR is still resolved by close linkage. |

### Supporting cases

| ID | Scenario | Expected |
|---|---|---|
| TC-XWIRE-006 | Single-PR-per-issue happy path: one open PR closing issue A. | Resolves that PR (legitimate flow unaffected). |
| TC-XWIRE-007 | No open PR closes issue A and no branch matches. | Empty result → wrapper's no-valid-PR branch. |
| TC-XWIRE-008 | Boundary: PR closes `#A0` (e.g. A=27, PR closes 270) and body mentions `#270`. | Issue 27 does NOT resolve to the `#270` PR (no `closingIssuesReferences=27`, no `issue-27` branch). |
| TC-XWIRE-009 | `fetch_pr_for_issue` field-subset contract: caller requests `number,headRefOid,body`. | Echoed object carries exactly the requested fields for the close-linked PR (INV-85's `body` field preserved). |
| TC-XWIRE-010 | Close linkage takes precedence over branch name when both exist and point at different PRs. | Close-linked PR wins. |

### #277 review [P1] regressions (round 2)

| ID | Scenario | Expected |
|---|---|---|
| **TC-XWIRE-011** | Finding 1: PR #10 on a `fix/issue-273-*` branch that actually `Closes #999`, alongside PR #11 (the real close-keyword-less partial-fix PR for #273, empty close-linkage). #10 is first by number. | `resolve_pr_for_issue 273` returns **#11** — the branch tier excludes #10 (it has close linkage to a different issue), so it never shadows the real PR and forces a spurious guard-reject abort. **Fails before the fix** (returned #10). |
| **TC-XWIRE-011b** | Only candidate is the `fix/issue-273-*` branch closing #999, no real #273 PR. | Empty (the foreign PR is bound to ITS OWN issue's close-linkage tier, never to #273). |
| **TC-XWIRE-012** | resolve↔verify consistency across all fixtures. | Whatever `resolve_pr_for_issue` returns, `verify_pr_closes_issue` accepts (rc 0) — discovery never yields a PR the guard rejects (no spurious abort). |
| **TC-XWIRE-013** | Finding 2: `_review_abort_no_valid_pr` must mark the run handled before exiting. | Source-pin: the helper sets `RESULT_PARSED=true` and does **not** `exit 1` — so the EXIT trap's crash branch does not double-post a "Review process crashed" comment or emit a `failed-substantive` trailer that overrides the intended `failed-non-substantive`/`no-pr-found` verdict. |

## Integration / E2E

| ID | Scenario | Expected |
|---|---|---|
| **TC-XWIRE-E2E-001** | Two concurrent open PRs where PR-B cross-references issue A; drive the real `resolve_pr_for_issue` against a stub `gh`. Assert each issue's review binds to its own PR and no foreign PR's review state is mutated. | issue A → PR-A, issue B → PR-B; no `gh pr review`/`gh pr merge` issued against the other issue's PR. |

## Regression

- Existing `tests/unit/test-fetch-pr-for-issue-null-body.sh` (TC-FETCH-PR-001..006)
  still passes — `fetch_pr_for_issue` keeps its echo-JSON-object contract and the
  null-body resilience.
- A legitimate single-PR-per-issue flow (PR closes the issue) still resolves and
  reviews normally (TC-XWIRE-006).
- `tests/unit/test-spec-drift.sh` still passes — guard/code-site anchors keep
  resolving (`fetch_pr_for_issue` name unchanged).
