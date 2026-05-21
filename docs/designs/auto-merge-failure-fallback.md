# Auto-merge failure fallback (issue #145)

## Problem

When the review wrapper (`autonomous-review.sh`) reaches a PASSED verdict but the auto-merge step fails (merge conflict against `main`, branch behind, transient API failure, required check missing), the wrapper today does the wrong thing on three counts:

1. **It directly closes the linked issue** with `gh issue close --reason completed` (autonomous-review.sh:710), even though the PR is still `OPEN` and unmerged.
2. **It posts a "Please merge PR #N manually" comment** (autonomous-review.sh:705-706), handing the work back to a human and silently terminating the autonomous pipeline.
3. **It flips the issue label to `approved`** (autonomous-review.sh:711-713) — terminal state — so the dispatcher will never pick the issue up again.

The pre-condition for legitimate issue closure is "PR merged to default branch with `Closes #N` keyword resolving the link". The wrapper code path violates that contract.

Live reproduction (downstream consumer, 2026-05-20T12:17:35–12:17:37Z): review wrapper PASSED, posted "Reviewed HEAD" trailer, attempted auto-merge, auto-merge failed, wrapper posted "please merge manually", and within 2 seconds the issue closed with `stateReason=COMPLETED` and the PR still `OPEN`.

## Goal

On auto-merge failure inside the review wrapper:

1. **Never call `gh issue close`** from the review wrapper (or any helper). The only sanctioned issue-closure path is GitHub's own `Closes #N` keyword resolving once the PR merges into `main`.
2. **Post the merge error as a comment on the PR** (not just on the issue), so the dev re-dispatch has the failure reason in PR context where the rebase work happens.
3. **Flip the issue label to `pending-dev`** (not `approved`) and keep the `autonomous` label. The next dispatcher tick re-dispatches dev to rebase + push.
4. **Dev resume** must detect the auto-merge-failure marker comment and rebase onto latest `main` before re-attempting any other work.

The successful auto-merge path is also brought into compliance: the explicit `gh issue close` call is removed there too (success now relies entirely on GitHub's `Closes #N` resolution at merge time).

## Architecture

### Marker comment format

The review wrapper posts an auto-merge failure marker to the **PR** with this exact prefix on line 1, so the dev wrapper's resume path can detect it deterministically:

```
Auto-merge failed: <error excerpt>. Re-dispatching dev agent to rebase onto main.
```

The first 500 characters of `gh pr merge`'s stderr are appended after the prefix (truncated for safety). The dev resume prompt searches PR comments for `^Auto-merge failed:` and, when found, includes a `## Pre-implementation: rebase` section in the resume prompt that instructs the agent to fetch + rebase + push before doing anything else.

### Label flow

| Path | Label transition (issue) | PR action |
|---|---|---|
| Verdict PASS, no `no-auto-close`, merge succeeds | `−reviewing −autonomous +approved` (issue auto-closes via `Closes #N`) | merge --squash --delete-branch |
| Verdict PASS, no `no-auto-close`, **merge fails (NEW)** | `−reviewing +pending-dev` (`autonomous` kept) | comment "Auto-merge failed: …" on PR |
| Verdict PASS, `no-auto-close` set | `−reviewing +approved` (`autonomous` kept) | no merge attempt |
| Approval API call fails | `−reviewing +approved` (`autonomous` kept) | no merge attempt |
| Verdict FAIL or missing | `−reviewing +pending-dev` | — |

The "merge fails → +approved" edge is **removed** from the state machine. The new edge is "merge fails → +pending-dev with autonomous kept", isomorphic to the verdict-FAIL edge, so the dispatcher's existing Step 4 picks it up in the next tick.

### Why keep `autonomous`

`pending-dev` without `autonomous` is invisible to the dispatcher's `list_pending_dev` selector. Keeping `autonomous` ensures the next tick re-dispatches dev. This matches the existing verdict-FAIL behavior — the wrapper there also leaves `autonomous` intact.

## Code changes

### 1. `skills/autonomous-dispatcher/scripts/autonomous-review.sh`

Replace the auto-close branch (current lines ~698-716) with:

```bash
log "Merging PR #${PR_NUMBER}..."

# Capture stderr so the merge error can be surfaced in the PR comment
# below for dev re-dispatch context.
MERGE_ERR=$(gh pr merge "$PR_NUMBER" --repo "$REPO" --squash --delete-branch 2>&1 >/dev/null) && MERGE_OK=true || MERGE_OK=false

if [[ "$MERGE_OK" == "true" ]]; then
  log "PR #${PR_NUMBER} merged successfully."
  # Issue auto-closes via GitHub's `Closes #N` resolution. Do NOT call gh issue close.
  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
    --remove-label "reviewing" --remove-label "autonomous" \
    --add-label "approved" 2>/dev/null || true
  log "Issue #${ISSUE_NUMBER} marked approved; auto-close handled by GitHub."
else
  # Truncate stderr to 500 chars so a runaway gh stderr can't blow up the comment.
  _err_excerpt="${MERGE_ERR:0:500}"
  log "WARNING: Auto-merge failed: ${_err_excerpt}"

  # Post failure marker on the PR (not the issue) — this is what dev resume
  # detects to trigger pre-implementation rebase.
  gh pr comment "$PR_NUMBER" --repo "$REPO" \
    --body "Auto-merge failed: ${_err_excerpt}

Re-dispatching dev agent to rebase onto main." 2>/dev/null || \
    log "WARNING: Failed to post auto-merge-failure marker on PR #${PR_NUMBER} (non-fatal)"

  # Flip issue back to pending-dev so dispatcher Step 4 picks it up.
  # `autonomous` label is preserved so the selector matches.
  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
    --remove-label "reviewing" \
    --add-label "pending-dev" 2>/dev/null || true
  log "Issue #${ISSUE_NUMBER} flipped to pending-dev for rebase re-dispatch."
fi
```

The `gh issue close` call is **removed** — the PASS-success path also no longer closes the issue directly. Closure is handled by GitHub when the merge resolves the `Closes #N` keyword.

### 2. `skills/autonomous-dispatcher/scripts/autonomous-dev.sh`

In the `MODE=resume` branch, add an additional fetch for PR comments to detect the auto-merge marker. When detected, prepend a `## Pre-implementation: rebase` section to the resume prompt that instructs the agent to fetch + rebase + force-push before continuing.

Marker detection (jq selector against PR comments):
```bash
gh api "repos/${REPO}/pulls/${PR_NUM}/comments" \
  --jq '[.[] | select(.body | startswith("Auto-merge failed:"))] | last | .body'
```

Fallback also queries issue comments (in case ops manually posts the marker on the issue rather than the PR). The agent's pre-implementation block is prepended only when a marker is found.

### 3. State-machine doc (`docs/pipeline/state-machine.md`)

- Replace the "Verdict PASS, auto-merge failed (best effort)" row in the transition table with two new rows: one for merge-success (no explicit `gh issue close`, GitHub resolves) and one for merge-failure (`reviewing → pending-dev`, `autonomous` retained).
- Update the mermaid diagram to add `reviewing --> pending_dev: Review wrapper PASS but auto-merge failed`.
- Update the "Note on `+approved`" footnote to remove the auto-merge-failure case from the `+approved` group.

### 4. Review-agent-flow doc (`docs/pipeline/review-agent-flow.md`)

Update the "Verdict = PASS path" section to document the new merge-failure branch.

### 5. Invariants doc (`docs/pipeline/invariants.md`)

Add INV-33: "Review wrapper MUST NOT close the linked issue directly."

### 6. Tests

- `tests/unit/test-autonomous-review-auto-merge-failure.sh` — source-of-truth grep tests on the wrapper:
  - **No `gh issue close` calls remain** anywhere in the wrapper (regression pin for the entire bug class).
  - Auto-merge failure branch posts `gh pr comment` with `Auto-merge failed:` body.
  - Auto-merge failure branch sets `--add-label pending-dev` on the issue.
  - Auto-merge failure branch does NOT add `approved` label.
  - Auto-merge failure branch keeps `autonomous` label (no `--remove-label autonomous`).
  - Auto-merge success branch removes `autonomous` and adds `approved` (regression pin for happy path).
  - Wrapper passes `bash -n` syntax check.
- `tests/unit/test-autonomous-dev-rebase-marker.sh` — source-of-truth grep:
  - Resume branch fetches PR comments for `startswith("Auto-merge failed:")` selector.
  - Resume prompt conditionally includes a "rebase first" instruction when marker found.
  - Wrapper passes `bash -n`.

### 7. Test cases doc (`docs/test-cases/auto-merge-failure-fallback.md`)

Documents:
- TC-AMF-001: successful auto-merge → PR merges → linked issue auto-closes via `Closes #N` (regression).
- TC-AMF-002: auto-merge failure → linked issue stays open, label flipped to `pending-dev` with `autonomous` retained.
- TC-AMF-003: auto-merge failure → PR comment posted with merge error.
- TC-AMF-004: dev re-dispatch detects marker → rebase succeeds → next review pass merges → issue auto-closes via GitHub.
- TC-AMF-005: dev re-dispatch detects marker → rebase has unresolvable conflicts → dev posts `needs human` comment, exits cleanly.
- TC-AMF-006: regression — successful path no longer calls `gh issue close`.

## Risks

| Risk | Mitigation |
|---|---|
| GitHub doesn't auto-close the issue on merge if `Closes #N` got renamed/missed in the PR body | Existing PR template + create-issue skill enforce the keyword. PR-discovery code already checks for the keyword (autonomous-review.sh:200). The success branch logs "auto-close handled by GitHub" so an operator monitoring the log can spot a missing close within seconds of merge. |
| Infinite loop: auto-merge fails → dev rebases → review re-runs → auto-merge fails again (e.g. branch protection requiring an external check that never runs) | The dispatcher's MAX_RETRIES counter caps re-dispatches. After MAX_RETRIES the issue transitions to `stalled` and operator intervention is required. INV-26 ensures stall fires only when the wrapper is genuinely dead. |
| Dev wrapper crashes after detecting marker but before rebase completes | Existing INV-23 / INV-27 / INV-29 already handle wrapper crash recovery. Marker is a comment, not a label, so it persists across dev runs and is re-detected by every subsequent resume. |
| `gh pr comment` itself fails (token expired, rate limit) | Wrapper logs WARNING but continues label transition to `pending-dev`. Dev re-dispatch happens regardless; agent re-detects merge state via `gh pr view --json mergeable` from the existing Step 0 in the dev/review prompts. |

## Out of scope

- Automatic rebase from the review wrapper itself. Rebase is a code-changing operation — it belongs to the dev wrapper's prompted flow, not the review wrapper.
- Smarter merge-conflict resolution heuristics (semantic merging). The dev agent's existing prompt already covers `git rebase` + conflict resolution on simple conflicts, and falls back to "needs human" on complex ones.
