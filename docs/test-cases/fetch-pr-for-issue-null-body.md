# Test Cases — `fetch_pr_for_issue` null-body resilience (issue #148)

Scope: `fetch_pr_for_issue()` in `skills/autonomous-dispatcher/scripts/lib-dispatch.sh`.

`gh pr list --json body` returns `body: null` for PRs created with an empty
description. Before the fix, the inline jq filter applied `.body | test(...)`
unconditionally — `null | test(...)` aborts the filter, jq prints to stderr,
and the function silently returns empty even when a matching PR exists.
Step 5a/5b stale-detection then loses visibility of the in-flight PR.

The fix adds a `.body != null` guard to the `select()` predicate so PRs with
null bodies are skipped instead of crashing the filter.

## Test scenarios

| ID | Scenario | Mocked `gh pr list` JSON | Expected `fetch_pr_for_issue 145 "number,body"` |
|----|----------|--------------------------|--------------------------------------------------|
| TC-FETCH-PR-001 | Null-body PR coexists with a matching PR — the matching PR is still returned (regression for #148). | `[{"number":1,"body":null},{"number":2,"body":"Closes #145 in this PR"}]` | JSON object with `.number == 2` |
| TC-FETCH-PR-002 | Null-body PR exists, no other PR matches — empty (no false positives). | `[{"number":1,"body":null}]` | empty string |
| TC-FETCH-PR-003 | All bodies non-null, one matches — baseline behavior preserved. | `[{"number":1,"body":"unrelated"},{"number":2,"body":"Fixes #145"}]` | JSON object with `.number == 2` |
| TC-FETCH-PR-004 | All bodies non-null, none match — empty. | `[{"number":1,"body":"unrelated"}]` | empty string |
| TC-FETCH-PR-005 | Trailing-`#NNN` body match (no character after the issue number) — exercises the `#NNN$` alternation branch alongside a null-body sibling. | `[{"number":1,"body":null},{"number":2,"body":"closes #145"}]` | JSON object with `.number == 2` |
| TC-FETCH-PR-006 | Substring guard — a PR mentioning `#1450` must NOT match issue #145, even when a null body is present. | `[{"number":1,"body":null},{"number":2,"body":"see #1450 for context"}]` | empty string |

## Acceptance

- All scenarios pass after the null-guard fix.
- TC-FETCH-PR-001 fails on `main` (current `lib-dispatch.sh:847`) with jq's
  `null (null) cannot be matched` error and an empty result, providing the
  regression signal.
- No E2E tests required — pure shell function behavior, exercised by mocked
  `gh pr list` output.
