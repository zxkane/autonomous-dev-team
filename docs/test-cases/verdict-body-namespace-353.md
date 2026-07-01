# Test Cases: verdict body-file namespacing (#353)

## Background

`build_review_prompt` told every review agent to write its comment-fallback
verdict body to `/tmp/verdict-<agent-name>.md` — unique only within one
fan-out, but a GLOBAL `/tmp` path shared by every concurrent review on the
host (all projects, all issues, all sessions). Two overlapping reviews raced
on the file; the later writer's findings were posted under the earlier
issue's own valid `Review Session:` trailer, passing INV-20/INV-40
attribution checks (observed twice against #342 on 2026-07-01).

Fix: the body path is namespaced by agent name + issue number + the agent's
own session id: `/tmp/verdict-${_agent_name}-${ISSUE_NUMBER}-${_agent_session_id}.md`.

## Test Cases (`tests/unit/test-issue-353-verdict-body-namespace.sh`)

| ID | Scenario | Expected Result |
|----|----------|------------------|
| TC-VBN-01 | Source grep: bare `/tmp/verdict-${_agent_name}.md` form in `autonomous-review.sh` | Absent |
| TC-VBN-02 | Source grep: a namespaced path variable declares agent + `ISSUE_NUMBER` + `_agent_session_id` tokens | Present |
| TC-VBN-03 | Source grep: the namespaced variable is used at every verdict-post call site (generic example, PASS branch, FAIL branch) | Used ≥3 times |
| TC-VBN-04 | Source grep: `post-verdict.sh`'s own usage-example doc string | No longer shows the bare `/tmp/verdict.md` global form |
| TC-VBN-05/06 | Render `build_review_prompt` for two distinct `(issue, session)` pairs | Each resolves its own namespaced path |
| TC-VBN-07 | Compare the two resolved paths | Distinct — no collision |
| TC-VBN-08..10 | Two-writer race simulation: write body A to issue 1's resolved path, body B to issue 2's resolved path, invoke the real `post-verdict.sh` for issue 1 against a stub `gh` | Posted body is body A verbatim; body B (foreign) never appears |

## Regression baseline

Verified against pre-fix `autonomous-review.sh`/`post-verdict.sh` (current
`origin/main`): TC-VBN-01 and TC-VBN-04 fail as expected (the bare forms are
present), confirming this is a genuine regression test, not a tautology.

## Existing coverage updated

- `tests/unit/test-autonomous-review-verdict-via-helper.sh` (TC-PVP-12):
  updated its hardcoded `/tmp/verdict-agy.md` expectation to the namespaced
  `/tmp/verdict-agy-202-sid-agy.md` form used by the sandbox's fixed
  `ISSUE_NUMBER=202` / session id `sid-agy`.

## Out of scope

- The typed INV-77/INV-78 artifact channel (already per-run, race-free —
  unaffected by this fix).
- Symbol-vs-diff sanity gating of finding text (separate hardening,
  deliberately deferred per the issue).
