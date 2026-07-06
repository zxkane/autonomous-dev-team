# Test Cases — Issue #429: agent-facing `gh` guidance sweep

Follow-up named by #421 (P3-6, #414 W-F) AC6: after the dispatcher-tree prompt
fragments were parameterized via `provider_prompt_fragment`, agent-facing `gh`
guidance still lived in hook message strings and skill markdown outside the
[INV-91] cutover checker's tree. This sweep neutralizes / scope-notes those
sites so a GitLab-lane agent doesn't get GitHub-CLI instructions from them.

**Doc-shape**: this file is the R3 inventory (per-file table below) AND the TC
doc that pairs with `tests/unit/test-gh-guidance-sweep.sh`. The lint test
pins the post-sweep `gh` word-boundary token count per swept file so
unintentional regrowth is caught in CI `unit`.

**Detection**: `grep -cE '(^|[^A-Za-z_-])gh ' <file>` — the same RE2-safe
consuming-boundary matcher `check-provider-cutover.sh` uses. It counts every
`gh ` token that is preceded by start-of-line or a non-word/non-hyphen
character (so `LIGHT`, `high`, `Fabgh` don't match, and `bash scripts/gh `
does — the `/` is a non-word/non-hyphen character).

## Inventory (R3)

Post-sweep token count is the pin the lint test enforces. "Kept" means the
site is deliberately preserved (either it's inside a scope-note that names
`gh` for illustrative purposes, or it's a load-bearing operational rule for
the GitHub lane); "Neutralized" means the wording was rewritten to be
provider-neutral or paired with a GitLab example; "Clean" means the file had
zero sites both before and after.

### Swept files (nonzero before OR after)

| File | Before | After | Action | Reason |
|------|-------:|------:|--------|--------|
| `skills/autonomous-common/hooks/block-push-to-main.sh` | 1 | 1 | Neutralized | R1 — one-line block message rewritten to `Open a pull/merge request via your platform CLI or the wrapper — e.g. \`gh pr create\` on GitHub, \`glab mr create\` on GitLab, or the pipeline's provider seam (\`chp_create_pr\`)`. Kept `gh pr create` inside as one of two concrete examples. Hooks stay provider-agnostic surfaces — no `CODE_HOST` branching in the message. |
| `skills/autonomous-dev/SKILL.md` | 6 | 6 | Scope-noted + GitLab examples | Step 7 (`gh pr create`), Step 7 update-PR (`gh pr view`/`edit`), Step 9 (`gh pr checks`): each command example now sits under a "GitHub lane (`CODE_HOST=github`)" note with a paired `glab mr …` example or the seam name (`chp_create_pr` / `chp_ci_status`). Step 12 (`bash scripts/gh issue comment` + "do NOT bare gh" rule): kept as a load-bearing operational rule for the GitHub lane per R2, with an added blockquote noting the GitLab-lane equivalent (`itp_post_comment` seam, agents don't hand-roll `glab issue note`). |
| `skills/autonomous-dev/references/review-commands.md` | 26 | 26 | Kept + scope-note header | Per R2's do-not-churn rule: this file is explicitly a "Complete reference for GitHub CLI and GraphQL commands." Rewriting 26 commands would churn prose that's GitHub-topology-specific by design. Added a prominent header pointing GitLab-lane agents at the `chp_*` / `itp_*` provider seams and `providers/chp-gitlab.sh` leaf-header docstrings for the REST equivalents. |
| `skills/autonomous-dev/references/review-threads.md` | 9 | 9 | Kept + scope-note header | Same treatment as review-commands.md. The WRONG-approach warning (`gh pr comment {pr} --body "Fixed all issues"` doesn't close threads) and the GraphQL `resolveReviewThread` flow are GitHub mechanics; the GitLab lane manages MR discussions through the wrapper + `chp_list_inline_comments` / `chp_reply_review_comment` seams. |
| `skills/autonomous-dev/references/autonomous-mode.md` | 9 | 12 | Scope-noted per section | Three sections carry `gh` references: "Posting Issue/PR Comments" (the two-wrapper split — GitHub-lane operational rule, kept, scope-note added), "Resume Awareness" (`gh issue view` / `gh pr list` / `gh api …/pulls/…/comments` — placeholders for `itp_read_task` / `chp_find_pr_for_issue` / `chp_list_inline_comments` seams on GitLab, scope-note added), "Bot Review Integration" (`bash scripts/gh-as-user.sh` + `gh api …/reviews` polling — GitHub App bot mechanics; scope-note added pointing at `docs/gitlab-setup.md`). Post-count went up because each scope note itself names `gh …` verbatim as the placeholder token — the lint test pins the new count. |
| `skills/autonomous-review/SKILL.md` | 12 | 13 | Scope-noted at top | Every `gh pr …` in this skill (the INV-52 rules about the wrapper owning `--approve` / `--request-changes` / `gh pr merge`, the merge-conflict mergeable check, the PR-diff / CI-status reads, the issue-comments read) is a wrapper-side or agent-facing GitHub-lane form. One top-of-file scope note declares that all `gh` examples are placeholders for the corresponding `chp_*` seams on GitLab (`chp_approve` / `chp_merge` / `chp_mergeable` / `chp_ci_status` / `chp_pr_view`) and that the INV-52 / INV-44 rules apply verbatim across lanes. |
| `skills/autonomous-review/references/decision-gate.md` | 8 | 9 | Scope-noted at top | Same treatment as the review SKILL. Every reference to `gh pr review …` and `gh pr merge` is a description of what the wrapper does — provider-agnostic behavior, GitHub-concrete form. The lint pin includes the +1 from the scope-note's own placeholder mention. |
| `skills/autonomous-review/references/merge-conflict-resolution.md` | 3 | 4 | Scope-noted at top | The `gh pr view … --json mergeable` and `gh pr checks --watch` calls are GitHub-CLI concrete forms of `chp_mergeable` / `chp_ci_status`. Scope-note added; the rebase+force-push procedure itself is git-native and provider-agnostic (unchanged). |
| `skills/autonomous-dispatcher/SKILL.md` | 1 | 1 | Neutralized | The `gh auth login` reference in the token-auth explanation was widened to also name `GITLAB_TOKEN` / `glab auth login` for the GitLab lane, plus a sentence noting the `chp_*` / `itp_*` seams route through whichever is present. `gh auth login` kept as a concrete GitHub example. |
| `skills/create-issue/SKILL.md` | 1 | 1 | Neutralized | `gh repo view --json nameWithOwner` was widened to a two-example block: GitHub uses `gh repo view`, GitLab uses `glab repo view -F json`. Both split into `OWNER`/`REPO_NAME` (or `NAMESPACE`/`PROJECT` on GitLab). |

### Clean files (verified 0 both before and after — no action needed)

| File | Count |
|------|------:|
| `skills/autonomous-common/SKILL.md` | 0 |
| `skills/autonomous-review/references/e2e-verification.md` | 0 |
| `skills/autonomous-dev/references/commit-conventions.md` | 0 |
| `skills/create-issue/references/issue-templates.md` | 0 |
| `skills/create-issue/references/workspace-changes.md` | 0 |

The other autonomous-review references file (`e2e-verification.md`) was
verified clean, satisfying the teammate's ask to spot-check the wider skill
markdown tree. The `create-issue/references/*.md` files were both clean, so
R2's "explicit inventory" table records them as zero-site.

## Deliberately-kept sites (R3 accountability)

The counts above are "deliberately kept" — every remaining `gh` mention in a
swept file falls into one of:

1. **Load-bearing GitHub-lane operational rule** (autonomous-dev/SKILL.md
   Step 12; autonomous-mode.md Posting Issue/PR Comments). The rule is
   correct for the GitHub lane; the paired scope-note directs GitLab-lane
   agents to the equivalent seam.
2. **Scope-noted reference file** (review-commands.md, review-threads.md).
   The whole file is a GitHub CLI/GraphQL cookbook; rewriting it would churn
   prose deliberately kept per R2. Header directs GitLab-lane agents at the
   seams.
3. **Placeholder-form INV-52 / INV-44 statement** (autonomous-review/SKILL.md,
   decision-gate.md, merge-conflict-resolution.md). Provider-agnostic rule
   about wrapper-vs-agent responsibility, written in GitHub-CLI terms because
   the rule was originally written for the GitHub lane. Scope-note at top
   flags the `gh …` calls as placeholders for `chp_*` seams.
4. **Two-example command block** (create-issue/SKILL.md, autonomous-dev/SKILL.md
   commands, autonomous-dispatcher/SKILL.md token-source). Both GitHub and
   GitLab concrete forms shown; agent picks by `CODE_HOST`.

## Test Cases

| ID | Scenario | Expected |
|---|---|---|
| TC-GHSWEEP-001 | `block-push-to-main.sh` message contains `merge request` | present |
| TC-GHSWEEP-002 | `block-push-to-main.sh` bash -n | rc=0 |
| TC-GHSWEEP-003 | `block-push-to-main.sh` `gh ` token count | 1 |
| TC-GHSWEEP-004 | `skills/autonomous-dev/SKILL.md` `gh ` token count | 6 |
| TC-GHSWEEP-005 | `skills/autonomous-dev/references/review-commands.md` `gh ` token count | 26 |
| TC-GHSWEEP-006 | `skills/autonomous-dev/references/review-threads.md` `gh ` token count | 9 |
| TC-GHSWEEP-007 | `skills/autonomous-dev/references/autonomous-mode.md` `gh ` token count | 12 |
| TC-GHSWEEP-008 | `skills/autonomous-review/SKILL.md` `gh ` token count | 13 |
| TC-GHSWEEP-009 | `skills/autonomous-review/references/decision-gate.md` `gh ` token count | 9 |
| TC-GHSWEEP-010 | `skills/autonomous-review/references/merge-conflict-resolution.md` `gh ` token count | 4 |
| TC-GHSWEEP-011 | `skills/autonomous-dispatcher/SKILL.md` `gh ` token count | 1 |
| TC-GHSWEEP-012 | `skills/create-issue/SKILL.md` `gh ` token count | 1 |
| TC-GHSWEEP-013 | Every swept file mentions `CODE_HOST` or `GitLab` (proof each carries at least one scope-note reference) | present |

## Non-scope

- The dispatcher-tree prompt fragments (`autonomous-dev.sh` /
  `autonomous-review.sh` / `lib-review-bots.sh`): #421, shipped.
- `docs/github-app-setup.md` and other GitHub-topology-specific docs:
  correctly GitHub-specific by design.
- The [INV-91] cutover checker's tree scope: unchanged — every file in the
  inventory above is OUTSIDE `skills/autonomous-dispatcher/scripts/`, so the
  checker is not affected by this sweep.
