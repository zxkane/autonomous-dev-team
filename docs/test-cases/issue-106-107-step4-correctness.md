# Test Cases: Step 4 correctness — fixes for #106 + #107

## #107 — `dispatch-local.sh` empty session_id tolerance

File: `tests/unit/test-dispatch-local-empty-session.sh`

### TC-EMPTY-RESUME-1: empty session_id → wrapper invoked without --session

**Setup**: sandboxed `$PROJECT_DIR/scripts/` with a stubbed
`autonomous-dev.sh` that records its argv. Sandboxed
`autonomous.conf` so `dispatch-local.sh` config-load passes.

**Action**: `bash dispatch-local.sh dev-resume 99 ""` (empty third arg).

**Expected (post-fix)**:
- exit code 0
- stub argv recorded contains `--issue 99 --mode resume`
- argv does NOT contain `--session`
- no "session_id required" message in stderr

**Pre-fix behavior** (proves the test is meaningful):
- exit code 1
- stderr contains `session_id required for dev-resume`

### TC-EMPTY-RESUME-2: real session_id → --session flag forwarded (regression)

**Setup**: same as TC-EMPTY-RESUME-1.

**Action**: `bash dispatch-local.sh dev-resume 99 abc-session-id-123`.

**Expected**:
- exit code 0
- stub argv contains `--issue 99 --mode resume --session abc-session-id-123`

### TC-EMPTY-RESUME-3: dev-new path unaffected

**Setup**: same as TC-EMPTY-RESUME-1.

**Action**: `bash dispatch-local.sh dev-new 99`.

**Expected**:
- exit code 0
- stub argv contains `--issue 99 --mode new`
- argv does NOT contain `--session`

---

## #106 — Step 4a.5 stale-verdict / `last_reviewed_head` check

File: `tests/unit/test-dispatcher-step4-stale-verdict.sh` (or extend
existing `test-dispatcher-reliability-99.sh`).

The Step 4a.5 logic is being extracted into a `lib-dispatch.sh` helper
function `handle_pending_dev_pr_exists` that takes an issue number,
returns 0 if the caller should `continue`, and produces the appropriate
side effects via `label_swap` and `gh issue comment`. Tests stub
`fetch_pr_for_issue`, `last_reviewed_head`, `label_swap`, and `gh`.

### TC-STALE-VERDICT-1: same HEAD already reviewed → keep pending-dev, post notice once

**Setup**:
- `fetch_pr_for_issue` returns `{"number":42,"headRefOid":"sha-A"}`
- `last_reviewed_head` returns `sha-A`
- mocked `gh issue view -q '...stale-verdict:sha-A...' | length` returns `0` (no prior notice)

**Action**: call `handle_pending_dev_pr_exists 99`.

**Expected**:
- function returns 0 (caller continues)
- `label_swap` NOT called
- `gh issue comment` called once with body containing
  `stale-verdict:sha-A` and `HEAD \`sha-A\` already reviewed`

### TC-STALE-VERDICT-2: HEAD differs from last review → flip to pending-review

**Setup**:
- `fetch_pr_for_issue` returns `{"number":42,"headRefOid":"sha-B"}`
- `last_reviewed_head` returns `sha-A`

**Action**: call `handle_pending_dev_pr_exists 99`.

**Expected**:
- function returns 0
- `label_swap 99 pending-dev pending-review` called
- `gh issue comment` body contains `transitioning to pending-review`
  (existing Bug 3 message)

### TC-STALE-VERDICT-3: no last_reviewed_head trailer → flip to pending-review

**Setup**:
- `fetch_pr_for_issue` returns `{"number":42,"headRefOid":"sha-A"}`
- `last_reviewed_head` returns `""` (no prior review)

**Action**: call `handle_pending_dev_pr_exists 99`.

**Expected**:
- function returns 0
- `label_swap 99 pending-dev pending-review` called
- `gh issue comment` body contains `transitioning to pending-review`

### TC-STALE-VERDICT-4: idempotency — notice already present → no duplicate

**Setup**:
- `fetch_pr_for_issue` returns `{"number":42,"headRefOid":"sha-A"}`
- `last_reviewed_head` returns `sha-A`
- mocked `gh issue view -q '...stale-verdict:sha-A...' | length` returns `1`

**Action**: call `handle_pending_dev_pr_exists 99`.

**Expected**:
- function returns 0
- `label_swap` NOT called
- `gh issue comment` NOT called

### TC-STALE-VERDICT-5: no PR → function returns 1 (fall through)

**Setup**:
- `fetch_pr_for_issue` returns `""` (no PR)

**Action**: call `handle_pending_dev_pr_exists 99`.

**Expected**:
- function returns 1 (caller does NOT continue, falls through to
  session-id / dispatch path)
- `label_swap` NOT called
- `gh issue comment` NOT called

---

## Regression coverage (must still pass after these changes)

- All 44+ tests in `tests/unit/*.sh` pre-existing pass
- `test-dispatcher-reliability-99.sh` — Bug 3 PR-exists short-circuit
  semantics preserved when HEAD differs / first review
- `test-dispatcher-tick-router.sh` — dispatch() router unchanged
- `test-symlink-resolution.sh` — dispatch-local.sh INV-14 chain unchanged
- `test-stale-alive-with-pr.sh` — Step 5b's `last_reviewed_head` check
  unchanged (we only mirror it, not modify it)
