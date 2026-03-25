# Fix: Dispatcher Stale Detection Crash Loop

**Date:** 2026-03-25
**Issue:** #32
**Status:** Approved

## Problem

When multiple autonomous issues are dispatched in the same cron cycle, Step 5 (stale detection) immediately marks just-dispatched processes as DEAD because PID files haven't been written yet. This creates a crash loop that wastes hours.

## Root Causes

1. **Step 5 runs in same cycle as dispatch** — PID files aren't written yet when stale check runs
2. **Crash transition ignores PR existence** — sends `in-progress` → `pending-review` even without a PR, causing review agent to fail immediately
3. **Retry counter misses dispatcher crashes** — only counts Agent Session Report comments, not dispatcher-detected crashes
4. **No duplicate-dispatch guard** — wrapper scripts don't check for existing running instances

## Fixes

### Fix 1: Skip stale detection for freshly dispatched issues (SKILL.md)

Track issues dispatched in Steps 2/3/4 in a `JUST_DISPATCHED` array. Step 5 skips any issue in that array.

### Fix 2: Smarter crash transition with PR existence check (SKILL.md)

When `in-progress` is DEAD, check if a PR exists:
- PR exists → `pending-review` (review can assess)
- No PR → `pending-dev` (dev didn't finish, retry dev)

### Fix 3: Count dispatcher crashes toward stalled threshold (SKILL.md)

Combine Agent Session Report failures AND dispatcher crash comments (`"Task appears to have crashed"`) in the retry count for Step 4.

### Fix 4: PID guard in wrapper scripts (autonomous-dev.sh, autonomous-review.sh)

Before writing PID, check if another instance for the same issue is already running. If so, exit 0 gracefully.

## Affected Files

| File | Changes |
|------|---------|
| `skills/autonomous-dispatcher/SKILL.md` | Fixes 1, 2, 3 |
| `skills/autonomous-dispatcher/scripts/autonomous-dev.sh` | Fix 4 |
| `skills/autonomous-dispatcher/scripts/autonomous-review.sh` | Fix 4 |
