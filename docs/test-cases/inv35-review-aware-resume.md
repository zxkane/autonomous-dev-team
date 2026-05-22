# Test cases — INV-35 review-aware Step 4 routing (issue #149)

Tracks the dispatcher Step 4b.5.1 routing for `pending-dev` issues whose prior dev session reached `end_turn|completed`. See [`docs/designs/inv35-review-aware-resume.md`](../designs/inv35-review-aware-resume.md) for the design canvas and [`docs/pipeline/invariants.md` § INV-35](../pipeline/invariants.md#inv-35-review-aware-resume-routing-for-completed-sessions) for the spec.

All Step-4 cases use a fixture that prepares: (a) a per-issue agent log at `/tmp/agent-${PROJECT_ID}-issue-N.log` whose final `{"type":"result"}` line is the named terminal state, (b) a `gh` mock that returns scripted issue comments for `gh issue view`, and (c) a `BOT_LOGIN` set to `kane-coding-agent[bot]` (the standard fixture login).

## A. `classify_recent_review_verdict` helper

### TC-INV35-CL-001: No comments after session-end → `none`

**Setup**: Issue has 3 comments, all with `createdAt` ≤ session-end timestamp.

**Action**: `classify_recent_review_verdict 100 "2026-05-21T03:18:00Z" v c`

**Expected**: `v=none`, `c=""`, exit 0.

### TC-INV35-CL-002: Newest matching comment carries `failed-non-substantive` trailer

**Setup**: Three post-session comments by `BOT_LOGIN`. Newest body contains `<!-- review-verdict: failed-non-substantive cause=bot-timeout -->\nReview FAILED ...`. Older two are unrelated bot comments.

**Action**: helper called as above.

**Expected**: `v=failed-non-substantive`, `c=bot-timeout`.

### TC-INV35-CL-003: Newest by `createdAt`, not by source order

**Setup**: gh returns comments out of order (oldest first). Two have trailers — `passed` (older) and `failed-substantive` (newer).

**Expected**: `v=failed-substantive`. (Helper sorts by `createdAt` before picking.)

### TC-INV35-CL-004: Newest comment has no trailer → `failed-substantive` fallback

**Setup**: Newest post-session comment by `BOT_LOGIN` is "Review FAILED ..." with no `<!-- review-verdict: ... -->` trailer.

**Expected**: `v=failed-substantive`, `c=""`. (Pre-INV-35 verdict-comment compatibility.)

### TC-INV35-CL-005: Newest comment is from a non-bot author → ignored, fallback to next

**Setup**: Newest post-session comment is from `@operator-user`. Older comment from `BOT_LOGIN` carries `<!-- review-verdict: passed -->`.

**Expected**: `v=passed`. (Filter applied before pick-newest.)

### TC-INV35-CL-006: `BOT_LOGIN` empty → session-id binding fallback used

**Setup**: `BOT_LOGIN=""` (gh api user 403 case). Comment body contains `Review Session: <fixture-session-uuid>` matching the session in `Dev Session ID:` and the trailer `<!-- review-verdict: failed-non-substantive cause=ci-transport -->`.

**Expected**: `v=failed-non-substantive`, `c=ci-transport`.

### TC-INV35-CL-007: Multiple trailers in one body → first match wins

**Setup**: Bot pasted a quoted prior verdict into a new comment, so the body contains both `<!-- review-verdict: passed -->` (older quote) and `<!-- review-verdict: failed-substantive -->` (the actual current verdict, posted second).

**Expected**: design accepts whichever the regex matches first; the test pins current behavior to `passed` (textually first) and is allowed to be revisited if real-world verdict comments produce false-passes — see design §7. *(If revisited, the rule becomes "match the LAST trailer in body" with a corresponding regex change.)*

### TC-INV35-CL-008: Trailer with unknown cause token → still `failed-non-substantive`

**Setup**: Trailer is `<!-- review-verdict: failed-non-substantive cause=newly-invented-token -->`.

**Expected**: `v=failed-non-substantive`, `c=newly-invented-token`. Forward-compat with new cause tokens added by the review wrapper.

## B. Step 4 dispatcher routing — completed session, no review

### TC-INV35-RT-001: `completed` + no post-session verdict → INV-12 operator notice (regression)

**Setup**: Log ends `end_turn|completed`. No comments by `BOT_LOGIN` after session-end.

**Action**: One dispatcher tick.

**Expected**:
- Issue receives one `INV-12-completed:<sid>` comment (idempotent — re-running tick does NOT post a second).
- Labels unchanged (still `pending-dev`).
- Issue is added to `JUST_DISPATCHED`.
- No `INV-35-fresh-dev` marker, no `<!-- review-aware-flip -->` marker.
- This is the original INV-12 behavior, preserved.

## C. Step 4 dispatcher routing — completed + non-substantive

### TC-INV35-RT-010: First non-substantive failure → flip to `pending-review`

**Setup**: Log ends `end_turn|completed`. Newest post-session comment by `BOT_LOGIN` carries `<!-- review-verdict: failed-non-substantive cause=bot-timeout -->`. Issue currently `pending-dev`. No prior `<!-- review-aware-flip -->` markers.

**Action**: One dispatcher tick.

**Expected**:
- Issue labels become `pending-review` (atomic edit removes `pending-dev` / adds `pending-review`).
- New comment posted: body contains `<!-- review-aware-flip:non-substantive cause=bot-timeout -->` and a human-readable line "Re-routing to review (last review failed for non-substantive reason: bot-timeout)."
- No `INV-12-completed`, no `INV-35-fresh-dev` posted.
- Retry-comment count for `MAX_RETRIES` is unchanged.
- Issue added to `JUST_DISPATCHED`.

### TC-INV35-RT-011: Second non-substantive failure → flip again (under cap)

**Setup**: Same as RT-010 but the issue already has ONE prior `<!-- review-aware-flip:non-substantive cause=bot-timeout -->` marker scoped to the same `Dev Session ID:`. `REVIEW_RETRY_LIMIT=2` (default).

**Expected**: Same as RT-010 — second flip allowed, marker count goes from 1 to 2.

### TC-INV35-RT-012: Third non-substantive failure → mark stalled

**Setup**: Same as RT-011 but two prior flips already exist for this session.

**Expected**:
- Issue gets `+stalled` (and `−pending-dev`).
- Operator-actionable comment posted citing the persistent non-substantive cause and the marker count.
- No new `<!-- review-aware-flip -->` marker added (we're stalling, not flipping).

### TC-INV35-RT-013: New session resets the flip counter

**Setup**: Issue has two prior `<!-- review-aware-flip:non-substantive -->` markers, but they were scoped to a DIFFERENT (older) `Dev Session ID:`. The current session is fresh.

**Expected**: First flip for the new session is allowed (treated as TC-INV35-RT-010 case). The counter is per-session-id.

### TC-INV35-RT-014: `REVIEW_RETRY_LIMIT=0` disables the cap

**Setup**: Operator set `REVIEW_RETRY_LIMIT=0` in `autonomous.conf`. Issue has 5 prior flips for the current session.

**Expected**: Sixth flip still allowed. Bounce-forever behavior, by operator opt-in.

## D. Step 4 dispatcher routing — completed + substantive

### TC-INV35-RT-020: Substantive failure → fresh dev-new (PTL pattern)

**Setup**: Log ends `end_turn|completed`. Newest post-session comment by `BOT_LOGIN` carries `<!-- review-verdict: failed-substantive -->`. Log file is writable.

**Expected**:
- Issue receives one `INV-35-fresh-dev:<sid>` comment (idempotent).
- Per-issue log file truncated to zero bytes.
- Labels: `−pending-dev +in-progress` (atomic).
- `<!-- dispatcher-token: <id> at <iso> mode=dev-new -->` marker posted.
- `dispatch dev-new <issue>` invoked.
- Retry-comment count incremented (`MAX_RETRIES` consumed).
- Issue added to `JUST_DISPATCHED`.

### TC-INV35-RT-021: Substantive failure with truncate-fail → fail-closed

**Setup**: Same as RT-020 but the per-issue log file is read-only (chmod 444 in fixture).

**Expected**:
- `: > $log` returns non-zero.
- Operator-actionable comment posted naming the log path + permission/disk hint.
- NO labels changed, NO dev-new dispatched.
- Issue stays `pending-dev` so the operator notices via stale-detection / retry accumulation.
- Same fail-closed pattern as the INV-12 PTL branch.

### TC-INV35-RT-022: Missing trailer → treated as substantive (back-compat)

**Setup**: Log ends `end_turn|completed`. Newest comment by `BOT_LOGIN` is `Review FAILED — found 3 issues with the implementation` (no trailer — pre-INV-35 verdict).

**Expected**: Same as RT-020. The classifier defaults missing trailers to `failed-substantive`, the safest of the four outcomes.

## E. Step 4 dispatcher routing — completed + passed (race)

### TC-INV35-RT-030: `passed` verdict on `pending-dev` issue → no-op

**Setup**: Log ends `end_turn|completed`. Newest comment by `BOT_LOGIN` carries `<!-- review-verdict: passed -->` but the issue is somehow `pending-dev` (impossible-to-construct race; preserves dispatcher safety).

**Expected**:
- WARN line in dispatcher log.
- No comment posted, no labels changed, no dispatch called.
- Issue is added to `JUST_DISPATCHED` (so Step 5 doesn't second-guess this tick).
- Step 0 hygiene on the next tick reconciles based on whatever state has actually arrived.

## F. Composition with neighboring invariants

### TC-INV35-CMP-001: PTL still wins over INV-35

**Setup**: Log ends `*|prompt_too_long`. Issue also has a post-session `<!-- review-verdict: failed-non-substantive ... -->` comment.

**Expected**: PTL branch fires (Step 4b.5 PTL row), NOT the INV-35 routing. INV-35 only triggers on `end_turn|completed`.

### TC-INV35-CMP-002: Auto-merge-failure rebase prepend layers on dev-new

**Setup**: `failed-substantive` branch → dev-new fired. The PR's most recent comment matches `Auto-merge failed:` (from #146).

**Expected**: dev-new prompt includes the `## Pre-implementation: rebase onto main` block — i.e., the resume-prompt-prepend logic in `lib-agent.sh::resume_agent` (or its dev-new analog) reads PR comments regardless of `--mode new` vs `--mode resume`. (See design §8.)

### TC-INV35-CMP-003: INV-30 — same routing under `EXECUTION_BACKEND=remote-aws-ssm`

**Setup**: Same as RT-010 but the dispatcher's tick runs with `EXECUTION_BACKEND=remote-aws-ssm`.

**Expected**: Routing decision is identical. The helper reads issue comments via `gh` and the log file via the dispatcher's local filesystem (where the wrapper writes via SSM-side mount or sync — same as today's PTL handling).

## G. Regression — the 2026-05-21 #144 / #145 sequence

### TC-INV35-REG-001: dev complete → q-bot timeout review → dispatcher tick (the bug)

**Setup**: Replays the 2026-05-21 03:18 → 05:34 UTC sequence:
1. Dev wrapper finished cleanly: log ends `end_turn|completed`, PR opened.
2. Review wrapper ran 2h11m later, configured `REVIEW_BOTS=q`, q-bot did not respond in 3 min.
3. Review wrapper posted FAILED verdict comment with the new trailer `<!-- review-verdict: failed-non-substantive cause=bot-timeout -->`.
4. Review wrapper flipped issue to `pending-dev`.
5. Dispatcher tick fires.

**Pre-fix expected (current behavior — must FAIL with INV-35 in place)**: dispatcher posts `INV-12-completed:<sid>`, leaves issue `pending-dev`. Test asserts THIS fails.

**Post-fix expected**:
- Issue flipped to `pending-review`.
- Marker comment with `<!-- review-aware-flip:non-substantive cause=bot-timeout -->`.
- No `INV-12-completed` comment posted.
- Retry-comment count unchanged (`MAX_RETRIES` not consumed).

This is the gating regression test for the issue and must fail on `dispatcher-tick.sh:277-323` pre-fix and pass post-fix per #149 acceptance criteria.

### TC-INV35-REG-002: same sequence with no trailer (pre-INV-35 review wrapper deployed mid-fix)

**Setup**: Same as REG-001 but step 3's verdict comment lacks the trailer (operator deployed dispatcher fix before review wrapper fix).

**Post-fix expected**: classifier defaults to `failed-substantive`, dispatcher dispatches dev-new with truncate. Acceptable degradation — the dev session retries fresh, MAX_RETRIES consumes one slot, but no infinite stall. Once the review wrapper update lands, subsequent verdicts get the trailer and the optimal `failed-non-substantive` routing.

## Acceptance mapping (per issue #149)

| #149 acceptance criterion | Covered by |
|---|---|
| Design canvas at `docs/designs/inv35-review-aware-resume.md` reviewed and decision recorded | PR #151 (design-only) |
| `docs/pipeline/invariants.md` updated: INV-12 paired with new INV-35 | PR #151 (design) — INV-35 status updated to ENFORCED in this PR |
| `docs/pipeline/dispatcher-flow.md` Step 4 updated to reflect new branching | PR #151 (design) |
| `dispatcher-tick.sh` Step 4 implements the chosen routing | This PR — `handle_completed_session_routing` in `lib-dispatch.sh` invoked from `dispatcher-tick.sh` Step 4b.5.1 |
| Test-case doc + unit tests written and passing | This doc + `tests/unit/test-classify-recent-review-verdict.sh` (16 PASS) + `tests/unit/test-handle-completed-session-routing.sh` (47 PASS) + `tests/unit/test-is-session-completed-end-ts.sh` (8 PASS) + `tests/unit/test-autonomous-review-verdict-trailer.sh` (9 PASS) |
| Regression test for the 2026-05-21 fixture | `tests/unit/test-inv35-regression-2026-05-21.sh` — TC-INV35-REG-001/002 (16 PASS) |
| No silent retry loops introduced (preserve INV-12-PTL fail-closed pattern for new write-side behavior) | TC-INV35-RT-021 in `test-handle-completed-session-routing.sh` (truncate-fails-closed assertion) |
