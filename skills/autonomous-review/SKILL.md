---
name: autonomous-review
description: >
  Use to perform an end-to-end PR review and reach an approve/request-changes
  verdict — including verifying acceptance criteria, running E2E tests via
  browser automation, resolving merge conflicts, and (when verdict passes)
  merging the PR. Triggers on phrases like "review this PR", "decide whether
  to approve and merge", "run E2E verification", "resolve merge conflicts on
  PR #N", or when the dispatcher hands off a PR labeled `pending-review` /
  `reviewing` for autonomous review. Distinct from in-flight dev-side
  self-review (that lives in autonomous-dev's pr-review step).
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/block-push-to-main.sh"
          timeout: 5
  Stop:
    - hooks:
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/verify-completion.sh"
          timeout: 10
---

# Autonomous Review Mode

Review PRs created by autonomous development sessions thoroughly and objectively, then **post a verdict comment** (`Review PASSED` or `Review findings:`). The review **wrapper** owns the GitHub-native action: it submits `--approve` and merges on a PASS (after its mergeable + `no-auto-close` gates) and submits `--request-changes` on a blocking FAIL. You never run `gh pr review` or `gh pr merge` yourself — see [Who submits the GitHub-native PR action (INV-52)](#who-submits-the-github-native-pr-action-inv-52).

## When to Use

| Use this skill | Use a different skill |
|---|---|
| Final verdict on a completed PR (post the verdict comment; the wrapper approves+merges or requests changes) | In-flight dev-side self-review during implementation → use `autonomous-dev` Step 8 (pr-review) |
| Dispatcher handed off a PR labeled `pending-review` or `reviewing` | Manual partial review of a draft PR → use the `pr-review-toolkit` agents directly |
| Run E2E verification + check acceptance criteria + resolve merge conflicts | Just check CI status → use `gh pr checks` directly |

## Cross-Platform Notes

This skill works with any IDE/CLI that supports skills. Browser automation
steps use Chrome DevTools MCP — ensure your IDE has this MCP server configured
for E2E verification.

### Hooks (Optional)
If your IDE supports hooks (Claude Code, Kiro CLI), workflow enforcement
hooks in `hooks/` provide automatic gate checks. Without hooks, follow
each step manually.

## Review Checklist

Verify ALL of the following:

### 1. Process Compliance
- [ ] Design canvas exists in `docs/designs/` or `docs/plans/`
- [ ] Branch follows naming convention (`feat/`, `fix/`, `refactor/`, etc.)
- [ ] Test cases documented in `docs/test-cases/`
- [ ] PR description follows template (Summary, Design, Test Plan, Checklist sections)
- [ ] PR references the issue (`Closes #N` or `Fixes #N`)

### 2. Code Quality
- [ ] No security issues (no credentials, no injection vulnerabilities)
- [ ] TypeScript types are correct (no `any` abuse)
- [ ] Error handling is appropriate
- [ ] Code follows existing patterns in the codebase
- [ ] No obvious performance regressions

### 3. Testing
- [ ] Unit tests exist for new functionality
- [ ] Unit test coverage is reasonable for new code
- [ ] E2E tests updated if UI changes were made
- [ ] All CI checks are passing

### 4. Infrastructure (if applicable)
- [ ] Infrastructure-as-Code changes are safe
- [ ] No accidental resource deletions
- [ ] IAM permissions follow least privilege

### 5. Optional: Bot Reviewer Verification
- [ ] If configured bot reviewers have posted reviews, verify their findings are addressed
- [ ] All bot review threads are resolved
- [ ] If bot review is missing and configured, trigger it using `scripts/gh-as-user.sh` (see "Triggering Bot Reviewers" below)

#### Triggering Bot Reviewers

The set of mandatory bots is determined by `REVIEW_BOTS` in the project's `autonomous.conf`. Empty `REVIEW_BOTS` skips this section entirely; otherwise trigger each configured bot.

**`scripts/gh-as-user.sh` is required.** All built-in bots (Amazon Q, Codex, Claude) reject trigger comments posted by GitHub App bot accounts; the wrapper posts as a real user.

Built-in bot triggers:

```bash
# When q ∈ REVIEW_BOTS:
bash scripts/gh-as-user.sh pr comment {pr_number} --body "/q review"

# When codex ∈ REVIEW_BOTS:
bash scripts/gh-as-user.sh pr comment {pr_number} --body "/codex review"

# When claude ∈ REVIEW_BOTS (note: @claude, not /claude):
bash scripts/gh-as-user.sh pr comment {pr_number} --body "@claude review"
```

For custom bots declared via `REVIEW_BOTS_<NAME>_TRIGGER`, use the configured trigger.

Do NOT use the default `gh pr comment` for bot review triggers — it authenticates as a bot. If `scripts/gh-as-user.sh` is not available in your project, fall back to `gh pr comment` and accept that some bots may ignore the trigger.

### 6. E2E Verification

> **If E2E verification is configured, this section is MANDATORY.** The wrapper injects one of two procedures based on `E2E_MODE`. If neither appears in the prompt, skip this section.

**Browser mode** (`E2E_MODE=browser`, for SaaS web apps):
- [ ] Preview URL extracted from PR comments
- [ ] Preview URL navigated successfully via Chrome DevTools MCP
- [ ] Test user login verified on preview environment
- [ ] Happy path test cases selected and executed (see section below)
- [ ] Feature test cases executed against live preview
- [ ] Regression tests executed (auth, navigation, console errors)
- [ ] Screenshots captured, uploaded, and linked as evidence
- [ ] E2E verification report posted as PR comment with screenshot links

**Command mode** (`E2E_MODE=command`, for backend pipelines / CLI / libraries):
- [ ] Pre-hooks executed (if configured) — exit 0
- [ ] Verify command executed within timeout — exit 0 (or recoverable timeout)
- [ ] Evidence parser produced a markdown block ending with `<!-- e2e-evidence: complete sha="${PR_HEAD_SHA}" -->`
- [ ] Evidence block posted as a PR comment
- [ ] Every issue-body acceptance criterion that names a verifiable artifact is covered by the evidence block

## Merge Conflict Resolution — MANDATORY Pre-Review Step

Before starting the review, check whether the PR branch has merge conflicts with main. If it does, rebase the branch so the PR is mergeable. For the complete rebase procedure, conflict handling, and failure protocol, consult **`references/merge-conflict-resolution.md`**.

Quick check:
```bash
MERGEABLE=$(gh pr view <PR_NUMBER> --repo <REPO> --json mergeable -q '.mergeable')
```
- **MERGEABLE** — proceed to Review Process
- **CONFLICTING** — follow rebase procedure in references; this is a **blocking finding** (FAIL)
- **UNKNOWN** — wait and retry (up to 3 times); if still UNKNOWN, do NOT treat as MERGEABLE — leave the review un-finalized for the next tick

> This step is best-effort prompt guidance; the review **wrapper enforces the same rule mechanically** after aggregating verdicts (the mergeable hard gate, INV-44). A `CONFLICTING` PR can never be approved even if you skip this step, and a persistently-`UNKNOWN` PR is re-queued rather than auto-approved.

## Review Process

1. **Read the issue** to understand requirements
2. **Read ALL issue comments** to detect requirement changes (see "Requirement Drift Detection" below)
3. **Read the PR diff** thoroughly (`gh pr diff <number>`)
4. **Check CI status** (`gh pr checks <number>`)
5. **Read the files** for design docs, test cases, etc. to verify they exist
6. **Assess code quality** against the checklist above
7. **Verify bot reviewer findings** (if configured — see checklist section 5)
8. **Select happy path test cases** based on PR diff analysis (see below)
9. **Perform E2E verification** (if configured — see procedure below)
10. **Mark acceptance criteria** — for each verified criterion, mark its checkbox in the issue body (see "Marking Acceptance Criteria")
11. **MANDATORY SELF-CHECK GATE** — execute the Findings->Decision Gate (see below) BEFORE submitting any review verdict

## Requirement Drift Detection — MANDATORY

> **This step MUST be performed BEFORE reading the PR diff. Requirements can change after implementation via issue comments from the repo owner or maintainers.**

Read ALL comments on the issue (not just the body) and look for:
- Scope changes ("remove", "no longer", "drop", "don't support", "instead of")
- New requirements added after the original issue was created
- Corrections or clarifications from the repo owner
- Explicit instructions to the dev agent that may not yet be reflected in the PR code

```bash
# Read all issue comments to check for requirement changes
gh issue view <ISSUE_NUMBER> --repo <REPO> --json comments \
  -q '.comments[] | "\(.author.login) [\(.createdAt)]: \(.body[0:500])"'
```

If any requirement change is found that the PR code does **NOT** reflect:
- This is a **[BLOCKING] Requirement drift** finding
- The PR must be sent back to dev with specific instructions about what changed
- Quote the comment that changed the requirement
- List the specific code/files that need to be updated

## Happy Path Test Cases

Happy path test cases are project-specific. The review agent selects cases based on:

1. Read `docs/test-cases/` directory for available test case documents
2. Analyze the PR diff to determine which areas changed
3. Select the most relevant test cases covering changed functionality
4. Execute at least one happy path test case per review

If no test case documents exist, execute a basic smoke test:
- Navigate to the application root URL
- Verify the page loads without errors
- Check browser console for JavaScript errors

## E2E Verification Procedure

> **This section applies only when E2E verification is configured.** The review wrapper script (`autonomous-review.sh`) will inject one of two E2E procedures into your prompt depending on the project's `E2E_MODE` setting in `autonomous.conf`:
>
> - **`E2E_MODE=browser`** — Chrome DevTools MCP UI smoke test (login, navigate, screenshot). For SaaS web apps with a per-PR preview URL.
> - **`E2E_MODE=command`** — invoke a project-supplied verify command, validate its evidence output. For backend pipelines, CLI tools, libraries, infra-as-code, or ML pipelines.

If neither block appears in your prompt, the project has E2E disabled (`E2E_MODE=none` or unset). Skip this section.

### Browser mode

For the complete step-by-step browser-mode procedure (browser automation, screenshot upload, test execution, report format), consult **`references/e2e-verification.md`**.

Key steps:
1. Verify preview URL is available
2. Open browser and navigate via Chrome DevTools MCP
3. Login with test user credentials
4. Execute happy path and feature test cases
5. Run regression checks (auth, navigation, console errors)
6. Post structured E2E report on the PR with screenshot evidence

### Command mode

For the complete contract (project-side script requirements, evidence-block format, exit-code semantics, onboarding example), consult **`references/e2e-command-mode.md`**.

Key steps:
1. Run pre-hooks if configured (e.g. seed test data into the per-PR stage)
2. Run the verify command with timeout
3. Inspect exit code (0 = pass; 124 = timeout; other = fail)
4. Run the evidence parser to extract a structured markdown block
5. Validate the block ends with the SHA-bound marker `<!-- e2e-evidence: complete sha="${PR_HEAD_SHA}" -->` (SHA is required to prevent stale evidence from a prior commit reusing the comment)
6. Post the evidence block as a PR comment
7. Decide PASS/FAIL based on exit code + evidence-vs-AC coverage

## Marking Acceptance Criteria

During E2E verification, mark each acceptance criterion checkbox in the issue body as you verify it.

### Procedure

1. Read the issue body and identify the `## Acceptance Criteria` section
2. For each criterion:
   a. Verify it via Chrome DevTools MCP, code inspection, or CI check results
   b. If it **passes**, mark the checkbox:
      ```bash
      bash scripts/mark-issue-checkbox.sh <ISSUE_NUMBER> "<criterion text>"
      ```
   c. If it **fails**, STOP marking — record the failure and proceed to "Review findings"
3. The script uses `gh` (which picks up the active App token via `GH_TOKEN_FILE`), so edits appear as the configured review bot

### Important Rules

- Mark criteria **only after verifying them** — do not pre-mark
- If ANY criterion fails, do NOT mark it — post "Review findings:" instead
- Do NOT mark Requirements checkboxes — those are for the dev agent
- ALL acceptance criteria must be checked (`- [x]`) before approving the PR

## Findings -> Decision Gate — MANDATORY

> **This gate is NON-NEGOTIABLE. Execute this self-check BEFORE submitting any PR review (APPROVE or REQUEST_CHANGES) and BEFORE posting the verdict comment on the issue.**

For the complete gate procedure (finding classification, blocking vs non-blocking rules, self-check questions, decision criteria, and output format), consult **`references/decision-gate.md`**.

Summary of the hard rule:
- **ANY blocking finding -> verdict MUST be FAIL** — post `Review findings:` (the wrapper then submits `--request-changes`).
- **ZERO blocking findings -> verdict is PASS** — post `Review PASSED` (the wrapper then submits `--approve` and merges, after its gates).
- **There is NO middle ground** — a `Review findings:` comment with blocking items and a `Review PASSED` comment are mutually exclusive.

Post the review result as a comment on the **issue** (NOT the PR), **only** via the deterministic helper `bash scripts/post-verdict.sh <issue> <pass|fail> <body-file> <agent-name> <session-id> [<model>]` — do NOT use a bare `gh issue comment` for the verdict ([INV-56](../../docs/pipeline/invariants.md)). The helper guarantees the "Review PASSED" / "Review findings:" first line the wrapper polls for and appends the `Review Session: \`<id>\`` + `Review Agent: <name>` trailer itself, so you never hand-write it. When the optional 6th `<model>` arg is supplied the helper folds it into the agent line as `Review Agent: <name> (model: <model>)` so the verdict comment records which model produced it ([INV-60](../../docs/pipeline/invariants.md)). Pass a body **file** (not an argv string) so a multi-line findings body with backticks/quotes can't be mangled; the wrapper supplies `<id>`, `<name>`, and `<model>` in your prompt — pass them exactly. **Your only output is the verdict comment** — the wrapper performs the GitHub-native PR action (see below).

### Who submits the GitHub-native PR action (INV-52)

> **The review WRAPPER — not you — owns the GitHub-native PR review/merge action.** You post a verdict **comment** (via `post-verdict.sh`); the wrapper reads it and acts.

- On **PASS**, the wrapper submits `gh pr review --approve` and (unless the issue has `no-auto-close`) `gh pr merge`, **after** its mechanical mergeable hard gate ([INV-44](../../docs/pipeline/invariants.md)) and the `no-auto-close` skip-merge check.
- On a blocking **FAIL**, the wrapper submits `gh pr review --request-changes` so the PR's `reviewDecision` becomes `CHANGES_REQUESTED` — authoritative for humans, branch protection, and the dev-resume agent ([INV-52](../../docs/pipeline/invariants.md)).
- **You MUST NEVER run `gh pr review --approve`, `gh pr review --request-changes`, `gh pr merge`, or the MCP merge tools yourself.** Doing so RACES the wrapper's gates: a self-approve+merge can merge a PR whose mergeability is still `UNKNOWN` ([INV-44](../../docs/pipeline/invariants.md)) or a PR on a `no-auto-close` issue — exactly the PR #191 incident that motivated INV-52. The agent issuing any GitHub PR review or merge is a **defect**, not a shortcut.

### Multi-agent review (when configured)

When the project sets `AGENT_REVIEW_AGENTS` to more than one CLI, several review agents run **in parallel against the same PR**, each as a fully independent reviewer. If you are one of them:

- Run the Findings -> Decision Gate **independently** — reach your own PASS/FAIL based on your own findings. Do NOT try to coordinate with or defer to the other agents; you cannot see their verdicts.
- Post your own verdict via `bash scripts/post-verdict.sh` with your assigned agent name + session id (both are in your prompt) — never a bare `gh issue comment` ([INV-56](../../docs/pipeline/invariants.md)). The helper writes your `Review Agent: <name>` discriminator line from the argument you pass, so it is always correct; that line is how the wrapper attributes your verdict among the parallel reviewers ([INV-40](../../docs/pipeline/invariants.md)).
- The wrapper aggregates all agents' verdicts under a **unanimous-PASS** rule: the wrapper approves+merges only if **every** available agent passed; any single FAIL makes the wrapper submit `--request-changes` and send the PR back to dev. This mirrors the gate's own "any blocking finding → FAIL" philosophy, applied across agents. As above, **no agent submits the GitHub-native action** — the wrapper does, once, after aggregating.

---

## References

For detailed procedures, consult:
- **`references/merge-conflict-resolution.md`** -- Complete rebase procedure, conflict handling, and failure protocol
- **`references/e2e-verification.md`** -- Browser automation steps, screenshot upload, test execution, E2E report format (`E2E_MODE=browser`)
- **`references/e2e-command-mode.md`** -- Project-supplied verify command contract, evidence-block format, onboarding example (`E2E_MODE=command`)
- **`references/decision-gate.md`** -- Finding classification, blocking rules, decision criteria, and output format
