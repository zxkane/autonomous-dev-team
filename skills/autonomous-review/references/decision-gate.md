# Findings -> Decision Gate — MANDATORY

> **This gate is NON-NEGOTIABLE. Execute this self-check BEFORE submitting any PR review (APPROVE or REQUEST_CHANGES) and BEFORE posting the verdict comment on the issue. If this gate is skipped, the review is invalid.**

After completing steps 1-11, all findings across checklist categories will have been collected. Before making the PASS/FAIL decision, execute the following self-check:

## Gate Procedure

1. **Enumerate all findings** — list every issue identified during steps 3-11, no matter how minor. Include:
   - Process compliance gaps (missing docs, missing tests, unchecked PR items)
   - Code quality issues
   - CI check failures or pending checks
   - E2E test failures
   - Acceptance criteria that could not be verified
   - **Requirement drift** (issue comments show requirement changes not reflected in PR code)

2. **Classify each finding** as BLOCKING or NON-BLOCKING:
   | Category | Blocking? | Examples |
   |----------|-----------|--------|
   | Missing design doc | BLOCKING | No `docs/plans/` or `docs/designs/` file |
   | Missing test case doc | BLOCKING | No `docs/test-cases/` file |
   | Missing unit tests for new code | BLOCKING | New hook/component with 0 tests |
   | CI check not passing (including pending) | BLOCKING | Deploy Preview still pending |
   | E2E test failure | BLOCKING | Any happy path or feature test fails |
   | Acceptance criteria not verified | BLOCKING | Any AC checkbox left unchecked |
   | Security vulnerability | BLOCKING | Credentials, injection, etc. |
   | Merge conflict with base | BLOCKING | PR `mergeable` is `CONFLICTING` — also wrapper-enforced ([INV-44](../../../docs/pipeline/invariants.md)) |
   | PR checklist item unchecked | BLOCKING | Required items not marked |
   | Requirement drift | BLOCKING | Issue comments show requirement changes (e.g. scope reduction, feature removal, new constraints) not reflected in PR code |
   | Minor style suggestion | NON-BLOCKING | Naming preference, optional refactor |
   | Bot review missing (after timeout) | NON-BLOCKING | Best-effort per existing policy |

3. **Apply the hard rule**:
   - **If ANY finding is BLOCKING -> verdict MUST be FAIL**. Do NOT post "Review PASSED". Post "Review findings:" with all issues. (The wrapper then submits `--request-changes` — you do not.)
   - **If ZERO findings are BLOCKING -> verdict is PASS**. Post "Review PASSED". (The wrapper then submits `--approve` and merges, after its gates — you do not.)
   - **There is NO middle ground.** Posting a "Review findings:" comment with blocking items and posting "Review PASSED" are mutually exclusive.
   - **You post a verdict COMMENT only — never a GitHub PR review or merge.** The wrapper owns the GitHub-native action (`--approve` / `--request-changes` / `gh pr merge`) — see [Who submits the GitHub-native PR action](#who-submits-the-github-native-pr-action-inv-52) below.

4. **Self-check questions** — answer each before proceeding:
   - "Did I list any missing documents, tests, or CI failures above?" -> If YES -> FAIL
   - "Are all CI checks in 'pass' state (not 'pending', not 'fail')?" -> If NO -> FAIL
   - "Is the PR `mergeable`? (`gh pr view <PR> --json mergeable -q .mergeable`)" -> If `CONFLICTING` -> that is a blocking finding -> FAIL (and the wrapper enforces this independently — INV-44 — so approving a CONFLICTING PR is impossible regardless)
   - "Did I successfully mark ALL Acceptance Criteria checkboxes?" -> If NO -> FAIL
   - "Did I write the phrase 'must be resolved before this PR can be approved' or similar in my findings?" -> If YES -> that means I found blocking issues -> FAIL
   - "Did I find any requirement changes in issue comments that are NOT reflected in the PR code?" -> If YES -> FAIL

## Why This Gate Exists

In a previous review, the review agent posted multiple blocking findings (missing design doc, missing test cases, missing unit tests, CI pending, PR checklist unchecked) and then immediately approved the PR anyway. The E2E pass "felt" sufficient, but the skill explicitly requires ALL checklist items to be satisfied. This gate prevents that disconnect by forcing the agent to reconcile findings with the verdict before acting.

In another incident, the repo owner posted a requirement change ("remove PDF support") as an issue comment after the PR was already implemented. The review agent approved the PR without reading the comment, because it only checked the issue body and PR diff — not the comment thread. The "requirement drift" category was added to catch this class of bugs.

## Multi-agent review (INV-40)

When the project runs more than one verdict-reaching review agent against the same PR (`AGENT_REVIEW_AGENTS` lists ≥2 CLIs), **each agent runs this gate independently** and posts its own verdict comment. You reach your own PASS/FAIL from your own findings — you cannot see the other agents' verdicts and must not try to coordinate. The wrapper then aggregates all agents' verdicts under a **unanimous-PASS** rule: the wrapper approves+merges only if every available agent passed; any single FAIL makes the wrapper submit `--request-changes` and send it back to dev. Post your verdict via `bash scripts/post-verdict.sh` ([INV-56](../../../docs/pipeline/invariants.md)); the helper appends the `Review Session: \`<id>\`` trailer AND the `Review Agent: <name>` discriminator line from the args you pass (do NOT hand-write them) — the discriminator is how the wrapper attributes your verdict among N agents posting under the same identity. With the optional 6th `<model>` arg the helper folds your model into that line as `Review Agent: <name> (model: <model>)` so the operator can tell which model each parallel reviewer used ([INV-60](../../../docs/pipeline/invariants.md)) — the `Review Agent: <name>` prefix is unchanged, so attribution still works. The unanimous rule is the cross-agent expression of this gate's own "any blocking finding → FAIL" philosophy.

## Who submits the GitHub-native PR action (INV-52)

> **The review WRAPPER — not the agent — owns the GitHub-native PR review/merge action.** The agent's only output is the verdict **comment** on the issue (posted via `post-verdict.sh`, [INV-56](../../../docs/pipeline/invariants.md)). The wrapper reads it and acts:
>
> | Agent posts (issue comment) | Wrapper submits (GitHub-native, after its gates) |
> |---|---|
> | `Review PASSED` | `gh pr review --approve` then `gh pr merge` (unless `no-auto-close`), after the [INV-44](../../../docs/pipeline/invariants.md) mergeable gate |
> | `Review findings:` (blocking) | `gh pr review --request-changes` → `reviewDecision = CHANGES_REQUESTED` |
>
> **The agent MUST NEVER run `gh pr review --approve`, `gh pr review --request-changes`, `gh pr merge`, or the MCP merge tools.** An agent that self-approves/merges RACES the wrapper's mergeable hard gate and `no-auto-close` skip-merge — it can merge an `UNKNOWN`-mergeable PR or a `no-auto-close` PR before the gates run (the PR #191 incident that motivated [INV-52](../../../docs/pipeline/invariants.md)). The agent issuing any GitHub PR review or merge is a **defect**.

## Decision Criteria

### PASS (post "Review PASSED" — the WRAPPER then submits the APPROVE review + merge)

**ALL of the following must be true** — if even ONE is false, the verdict is FAIL:

- All review checklist items (sections 1-5) are satisfied
- At least one happy path test case passes (from docs or smoke test)
- Code quality is acceptable
- No security concerns
- **All CI checks are in "pass" state** (not "pending", not "queued", not "fail")
- **The PR is `mergeable`** (not `CONFLICTING`; also wrapper-enforced — INV-44)
- E2E verification passes (if configured)
- **All Acceptance Criteria checkboxes marked as checked in the issue body**
- **No requirement drift detected** (issue comments don't contain unaddressed requirement changes)
- **The Findings->Decision Gate produced ZERO blocking findings**

### FAIL (post "Review findings:" — the WRAPPER then submits REQUEST_CHANGES)

**If ANY of the following is true**, the verdict is FAIL — post "Review findings:" and do NOT post "Review PASSED" (and never submit any GitHub PR review yourself):

- Any checklist item is not satisfied
- Security vulnerability found
- Significant code quality issues
- **Any CI check is not in "pass" state** (pending counts as not passing)
- **The PR is `CONFLICTING`** (merge conflict with base — the wrapper's mergeable gate forces FAIL here even if you miss it, INV-44)
- **Any E2E test case fails** (if E2E configured)
- **Any happy path test case fails** (if E2E configured)
- **Preview URL is not available** (if E2E configured)
- **Any Acceptance Criteria checkbox remains unchecked**
- **Requirement drift detected** (issue comments contain requirement changes not reflected in PR)
- **The Findings->Decision Gate produced one or more blocking findings**

When failing, provide SPECIFIC and ACTIONABLE feedback:
- Quote the problematic code
- Explain why it's an issue
- Suggest the fix
- Include E2E failure screenshots as evidence (if available)
- **For requirement drift: quote the issue comment that changed the requirement and list specific files/code that need updating**

## Output Format

> **The Findings->Decision Gate MUST be executed before posting any output. If it has not yet been run, STOP and run it now.**

Post the review result as a comment on the issue (NOT the PR), **only** via the deterministic helper — never a bare `gh issue comment` for the verdict ([INV-56](../../../docs/pipeline/invariants.md)). **The comment is your ONLY output** — the wrapper performs the GitHub-native PR action (see [Who submits the GitHub-native PR action](#who-submits-the-github-native-pr-action-inv-52)).

```bash
# Write your verdict BODY to a file (a FILE avoids shell-quoting mangling of a
# multi-line body with backticks/quotes), then post it. The helper prepends the
# canonical "Review PASSED" / "Review findings:" first line and appends the
# `Review Session:` / `Review Agent:` trailer for you (the ids + model are in
# your prompt). The optional 6th <model> arg is folded into the agent line as
# `Review Agent: <name> (model: <model>)` so the verdict records the model that
# produced it ([INV-60](../../../docs/pipeline/invariants.md)):
bash scripts/post-verdict.sh <issue-number> <pass|fail> <body-file> <agent-name> <session-id> [<model>]
```

**Action pairing — these MUST match:**
| Verdict | Your action (the agent, via `post-verdict.sh`) | The wrapper's action (GitHub-native, after its gates) |
|---------|--------------|------------------|
| PASS | `post-verdict.sh … pass …` on the issue | Submit `--approve` + `gh pr merge` (unless `no-auto-close`) |
| FAIL | `post-verdict.sh … fail …` on the issue | Submit `--request-changes` → `reviewDecision = CHANGES_REQUESTED` |

**It is FORBIDDEN to produce a "Review findings:" verdict with blocking items AND treat it as a pass. These are mutually exclusive.** It is also FORBIDDEN for the agent to submit ANY GitHub PR review (`gh pr review --approve` / `--request-changes`) or `gh pr merge` — that is the wrapper's job ([INV-52](../../../docs/pipeline/invariants.md)).

The body you write to the file (the helper guarantees the first line + trailer around it):

For PASS:
```
All checklist items verified, code quality good. E2E verification completed.

Findings->Decision Gate: 0 blocking findings.

Summary:
- Design: docs/plans/xxx.md
- Tests: X unit tests, Y E2E tests
- CI: All checks passing
- Code: Clean, follows project conventions
- E2E: All N test cases passed (including M happy path), K regression checks passed
- Happy path: TC-HP-XXX executed, plan generation verified
- Requirement drift: None detected
```

For FAIL:
```
Findings->Decision Gate: N blocking finding(s) — FAIL.

1. **[BLOCKING] E2E test failure** - TC-HP-001 failed
   - Expected: Plan with 7 days of Python videos
   - Actual: Plan generated with only 3 days
   - Evidence: [inline screenshot in PR E2E report comment]
   - Action: Fix plan generation to respect duration requirements

2. **[BLOCKING] Requirement drift** - PDF support removal not implemented
   - Issue comment by @owner (2026-03-18): "移除 PDF 支持，转换效果不好"
   - PR still contains PDF upload, conversion, and test code
   - Action: Remove .pdf from frontend accept, backend API, Lambda handler, and tests

3. **[BLOCKING] CI check pending** - Deploy Preview not yet passed
   - Action: Wait for deployment to complete before requesting review
```
