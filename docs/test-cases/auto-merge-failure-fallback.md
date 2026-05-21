# Test cases — auto-merge failure fallback (issue #145)

Tracks the auto-merge-failure → dev re-dispatch behavior added in fix(review).

## TC-AMF-001: Successful auto-merge — issue closes via `Closes #N` (regression)

**Setup**: Review wrapper has parsed a PASS verdict for an open PR. PR is mergeable. Issue has `reviewing` + `autonomous` labels and the PR body contains `Closes #N`.

**Action**: Wrapper runs `gh pr merge --squash --delete-branch` and the call returns 0.

**Expected**:
- Wrapper does NOT call `gh issue close`.
- Wrapper removes `reviewing` and `autonomous` from issue, adds `approved`.
- GitHub resolves the `Closes #N` keyword and closes the issue (verified at the PR-merge level, not by the wrapper).
- Wrapper logs `auto-close handled by GitHub`.

## TC-AMF-002: Auto-merge failure — issue stays open, label flips to `pending-dev`

**Setup**: Same as TC-AMF-001 but `gh pr merge` returns non-zero (e.g., merge conflict, branch protection blocking, branch not up to date).

**Action**: Wrapper captures stderr, runs the failure branch.

**Expected**:
- Wrapper does NOT call `gh issue close`.
- Wrapper does NOT add `approved` label.
- Wrapper removes `reviewing` and adds `pending-dev` on the issue.
- Wrapper does NOT remove `autonomous` (so the dispatcher selector still matches).
- Issue state is `OPEN`.

## TC-AMF-003: Auto-merge failure posts merge error on PR

**Setup**: Same as TC-AMF-002.

**Action**: Wrapper attempts to post a comment via `gh pr comment <PR>`.

**Expected**:
- Comment body starts with `Auto-merge failed:`.
- Comment body contains an excerpt of the captured stderr (truncated to 500 chars).
- Comment body ends with `Re-dispatching dev agent to rebase onto main.`
- Comment is posted on the PR (not the issue).
- If `gh pr comment` itself fails, wrapper logs a WARNING and continues — label transition still happens.

## TC-AMF-004: Dev re-dispatch detects marker, rebases cleanly, full happy path

**Setup**: A PR has the auto-merge-failure marker comment posted by the review wrapper. Dev wrapper runs in resume mode.

**Action**:
1. Dev wrapper fetches PR comments and finds the marker.
2. Resume prompt includes a `## Pre-implementation: rebase` section with `git fetch origin && git rebase origin/main` instructions.
3. Dev agent rebases (clean rebase, no conflicts).
4. Dev pushes the rebased branch.
5. Wrapper trap transitions issue to `pending-review`.
6. Next dispatcher tick dispatches review.
7. Review PASSED → auto-merge succeeds → GitHub closes issue via `Closes #N`.

**Expected**:
- Marker detection grep against PR comments matches.
- Resume prompt contains the rebase instruction.
- Final issue state: CLOSED via GitHub PR-merge resolution (not via `gh issue close`).
- Throughout the flow, no path inside the autonomous wrappers calls `gh issue close`.

## TC-AMF-005: Dev re-dispatch detects marker, rebase has unresolvable conflicts

**Setup**: Same as TC-AMF-004, but the rebase produces semantic conflicts the agent cannot auto-resolve.

**Action**: Agent attempts rebase, conflicts appear. Per existing dev-skill flow, agent posts a `needs human` comment, runs `git rebase --abort`, exits cleanly.

**Expected**:
- No infinite loop — the dev wrapper exits with code 0 and trap transitions to `pending-dev` once.
- Issue stays OPEN with `pending-dev` + `autonomous` labels (next tick will retry, eventually hitting MAX_RETRIES → `stalled`).
- No false `approved` transition.
- The dispatcher's retry counter (INV-05, INV-19) governs eventual stall.

## TC-AMF-006: Regression — successful merge path no longer calls `gh issue close`

**Setup**: Source-of-truth grep against `skills/autonomous-dispatcher/scripts/autonomous-review.sh`.

**Expected**:
- Zero occurrences of `gh issue close` (or any equivalent `--state closed` mutation) in the wrapper.
- The phrase "Please merge PR #N manually" no longer appears in the auto-merge-failure path (only the formal-approval-failure and `no-auto-close` paths still post manual-merge guidance, and those are documented as legitimate human-handoff cases).

## TC-AMF-007: Source-of-truth pin — auto-merge failure branch is structurally distinct

**Setup**: Source-of-truth grep against the wrapper.

**Expected**:
- The auto-merge failure branch is implemented as a distinct `if/else` (not a fall-through), so a future refactor that rearranges the success branch can't accidentally re-introduce the close call.
- The branch posts to `gh pr comment` (not `gh issue comment`).
- The branch flips to `pending-dev` (string match `--add-label pending-dev`).

## TC-AMF-008: Dev wrapper exposes the marker to the resume prompt

**Setup**: Source-of-truth grep against `skills/autonomous-dispatcher/scripts/autonomous-dev.sh`.

**Expected**:
- The MODE=resume branch fetches PR comments and selects on `startswith("Auto-merge failed:")`.
- When the marker is detected, the resume prompt body includes a string fragment instructing rebase before implementation.
