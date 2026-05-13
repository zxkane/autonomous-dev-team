# Design: Step 4 correctness — fixes for #106 + #107

Two related but independent bugs in `dispatcher-tick.sh` Step 4 (the
`pending-dev` scan) and `dispatch-local.sh`'s `dev-resume` validation,
bundled into a single PR because they share the same code region and the
same failure surface (silent stalls in Step 4).

## Goal

- Stop the stale-verdict re-review loop on PRs whose HEAD has not changed
  since the last FAILED review (#106).
- Stop the silent first-tick stall when an issue lands in `pending-dev`
  with no prior `Dev Session ID:` (#107).

Non-goals: restructuring Step 4 control flow beyond the two specific
defects; modifying Step 5b (its symmetric `last_reviewed_head` logic is
the model we mirror).

---

## Bug 1 (#106) — Step 4a.5 PR-exists short-circuit ignores `last_reviewed_head`

### Current (broken) behavior

`dispatcher-tick.sh:236-247`:

```bash
pr_for_issue=$(fetch_pr_for_issue "$issue_num" "number")
if [ -n "$pr_for_issue" ]; then
  pr_num=$(jq -r '.number // empty' <<<"$pr_for_issue")
  pr_ref="${pr_num:+#${pr_num}}"
  log "  issue #${issue_num} has PR ${pr_ref} — transitioning to pending-review (Bug 3 fix)"
  gh issue comment "$issue_num" --repo "$REPO" \
    --body "PR ${pr_ref} exists for this issue; transitioning to pending-review instead of retrying dev (#99 Bug 3)."
  label_swap "$issue_num" "pending-dev" "pending-review"
  JUST_DISPATCHED+=("$issue_num")
  continue
fi
```

Problem: every tick, if a PR exists for the issue, route to
`pending-review` regardless of whether the current PR HEAD has already
been reviewed. After a legitimate FAILED verdict against
`<sha-A>`, the dev agent hasn't (yet) pushed new commits, so HEAD remains
`<sha-A>`. The re-route to `pending-review` makes the review wrapper run
Sonnet against the same code and produce the same FAILED verdict, looping
every ~5 minutes.

### Fix (mirrors Step 5b's `last_reviewed_head` check)

```bash
pr_info=$(fetch_pr_for_issue "$issue_num" "number,headRefOid")
if [ -n "$pr_info" ]; then
  pr_num=$(jq -r '.number // empty' <<<"$pr_info")
  current_head=$(jq -r '.headRefOid // empty' <<<"$pr_info")
  pr_ref="${pr_num:+#${pr_num}}"
  pr_ref="${pr_ref:-(number unknown)}"
  last_head=$(last_reviewed_head "$issue_num")

  if [ -n "$last_head" ] && [ -n "$current_head" ] && [ "$current_head" = "$last_head" ]; then
    # Same HEAD already reviewed — verdict was FAILED (otherwise we
    # wouldn't be in pending-dev). Don't redo review; surface the stale
    # verdict and keep pending-dev so the dev agent can act on feedback.
    notice_marker="stale-verdict:${current_head}"
    if gh issue view "$issue_num" --repo "$REPO" --json comments \
        -q "[.comments[].body | select(contains(\"${notice_marker}\"))] | length" \
        2>/dev/null | grep -q '^0$'; then
      gh issue comment "$issue_num" --repo "$REPO" \
        --body "PR ${pr_ref} HEAD \`${current_head}\` already reviewed with FAILED verdict; awaiting new commits before re-review. (\`${notice_marker}\`)"
    fi
    JUST_DISPATCHED+=("$issue_num")
    continue
  fi

  # New HEAD or first review — keep existing Bug 3 behavior.
  log "  issue #${issue_num} has PR ${pr_ref} — transitioning to pending-review (Bug 3 fix)"
  gh issue comment "$issue_num" --repo "$REPO" \
    --body "PR ${pr_ref} exists for this issue; transitioning to pending-review instead of retrying dev (#99 Bug 3)."
  label_swap "$issue_num" "pending-dev" "pending-review"
  JUST_DISPATCHED+=("$issue_num")
  continue
fi
```

Idempotency marker `stale-verdict:<sha>` follows the existing
`INV-12-completed:${session_id}` pattern. Same HEAD on subsequent ticks
finds the marker and skips posting again.

### State-machine summary

| State | Action |
|---|---|
| pending-dev + PR exists + HEAD == last_reviewed_head | stay pending-dev, post idempotent stale-verdict notice |
| pending-dev + PR exists + HEAD != last_reviewed_head | flip to pending-review (existing Bug 3 behavior) |
| pending-dev + PR exists + no last_reviewed_head | flip to pending-review (first review on fresh PR) |
| pending-dev + PR exists + last_reviewed_head matches + notice already present | no-op (idempotency) |

---

## Bug 2 (#107) — `dispatch-local.sh:155` rejects empty session_id

### Current (broken) behavior

`dispatch-local.sh:154-158`:

```bash
dev-resume)
  if [[ -z "$SESSION_ID" ]]; then
    echo "ERROR: session_id required for dev-resume" >&2
    exit 1
  fi
```

Problem: `dispatcher-tick.sh:314` always calls
`dispatch dev-resume "$issue_num" "$session_id"` from Step 4, even when
`$session_id` is empty (first-time pickup of a `pending-dev` issue with
no prior `Dev Session ID:` comment). The hard rejection here prevents the
wrapper — which has its own session-empty fallback at
`autonomous-dev.sh:257-260` — from ever running.

### Fix (Option A from issue body — drop the rejection)

Tolerate empty `SESSION_ID` in the `dev-resume` branch of BOTH transport
drivers (`dispatch-local.sh` and `dispatch-remote-aws-ssm.sh`). The
wrapper already falls back to `MODE=new` when invoked with `--mode
resume` and no `--session`, so passing empty session through is safe
and idempotent with the wrapper's own contract. Both backends must
honor the same contract — `dispatcher-tick.sh:314` calls
`dispatch dev-resume "$issue_num" "$session_id"` regardless of
`EXECUTION_BACKEND`, so a one-sided fix would leave SSM users still
hitting the original silent stall.

```bash
dev-resume)
  # Empty SESSION_ID is tolerated: dispatcher-tick.sh:314 dispatches
  # dev-resume on every Step 4 pending-dev pass, including first-time
  # pickup with no prior Dev Session ID. autonomous-dev.sh:257-260
  # falls back to MODE=new when --mode resume is invoked without
  # --session, so omitting the flag here is the canonical handoff.
  if [[ -n "$SESSION_ID" ]]; then
    nohup "${PROJECT_DIR}/scripts/autonomous-dev.sh" \
      --issue "$ISSUE_NUM" --mode resume --session "$SESSION_ID" \
      >> "/tmp/agent-${PROJECT_ID}-issue-${ISSUE_NUM}.log" 2>&1 &
  else
    nohup "${PROJECT_DIR}/scripts/autonomous-dev.sh" \
      --issue "$ISSUE_NUM" --mode resume \
      >> "/tmp/agent-${PROJECT_ID}-issue-${ISSUE_NUM}.log" 2>&1 &
  fi
  CHILD_PID=$!
  ;;
```

Why Option A and not Option B (`dispatcher-tick.sh:314` routes
`dev-new` when session empty)? Option A is a one-line behavioral change
in a single script; Option B requires touching two scripts and adds
branching logic to the dispatch path. Both work; Option A is the smaller
patch with less surface area, and it makes `dispatch-local.sh` a more
forgiving boundary: any future caller that legitimately needs empty
session resume (debugging, manual operator dispatch) gets the same
fallback for free.

---

## Tests

TDD: write tests first, watch them fail, then apply fixes.

### #107 — `dispatch-local.sh` + `dispatch-remote-aws-ssm.sh` empty session

New test file `tests/unit/test-dispatch-local-empty-session.sh`:

- TC-EMPTY-RESUME-1: `dispatch-local.sh dev-resume 99 ""` (empty session)
  spawns the wrapper without `exit 1` (post-fix expectation; pre-fix
  fails with stderr containing "session_id required").
- TC-EMPTY-RESUME-2: `dispatch-local.sh dev-resume 99 abc-123` still
  passes `--session abc-123` to the wrapper (regression).
- TC-EMPTY-RESUME-3: `dispatch-local.sh dev-new 99` unchanged.

Updated `tests/unit/test-dispatch-remote-aws-ssm.sh` (TC-EB-007b):
- Replaces the prior "rejects empty session_id" assertion with a
  positive assertion that empty session is tolerated. Validates the
  inner SSM command shape contains `dev-resume 99` (3-arg form).
- Regression: real session_id still gets forwarded as the 4th arg.

Strategy: stub `autonomous-dev.sh` in a sandboxed `$PROJECT_DIR/scripts/`
that records its argv to a file; invoke `dispatch-local.sh` with the
appropriate args; assert on the recorded argv.

### #106 — Step 4a.5 stale-verdict logic

Extend `tests/unit/test-dispatcher-reliability-99.sh` (it already
exercises lib-dispatch.sh helpers with mocked `gh`; the new tests reuse
that pattern but call a Step-4a.5 function we extract):

- TC-STALE-VERDICT-1: PR exists + last_reviewed_head matches current →
  stale-verdict notice posted, label NOT swapped.
- TC-STALE-VERDICT-2: PR exists + last_reviewed_head differs → label
  swapped to pending-review (existing Bug 3 behavior preserved).
- TC-STALE-VERDICT-3: PR exists + no Reviewed HEAD trailer → label
  swapped to pending-review (first review).
- TC-STALE-VERDICT-4: PR exists + matches + notice already present →
  no duplicate notice (idempotency).

Strategy: extract the Step 4a.5 block into a helper function, mock
`fetch_pr_for_issue`, `last_reviewed_head`, `label_swap`, `gh issue
view`, `gh issue comment`. Either expose this as a separate function in
`lib-dispatch.sh` or test it via awk-extraction harness like
`test-dispatcher-tick-router.sh`.

After review: extracting to a function in `lib-dispatch.sh` is cleaner
(testable surface, named, documented) and lets the dispatcher stay
readable. Function name: `handle_pending_dev_pr_exists`. Returns 0 if
the caller should `continue`, 1 otherwise (no PR, fall through to
session/dispatch logic).

---

## Acceptance Criteria

- [ ] `dispatch-local.sh dev-resume <N> ""` no longer exits 1; spawns
  wrapper which falls back to `--mode new` (#107)
- [ ] An issue labeled `autonomous` + `pending-dev` simultaneously
  progresses through one full dev cycle within one tick (#107)
- [ ] Step 4a.5 PR-exists path uses `last_reviewed_head` to decide
  between pending-review and stale-verdict-keep-pending-dev (#106)
- [ ] Stale-verdict path posts a one-time idempotent notice keyed on
  `stale-verdict:<sha>` (#106)
- [ ] Existing Step 5b "DEAD + in-progress + PR exists" branch unchanged
- [ ] All 44+ existing unit tests still pass
- [ ] New tests added for both fixes
- [ ] PR closes both #106 and #107
