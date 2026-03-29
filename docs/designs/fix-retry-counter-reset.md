# Fix: Retry counter resets after stalled→unstalled transition

**Date:** 2026-03-29
**Issue:** #41
**Status:** Approved

## Problem

Dispatcher retry counting in SKILL.md Step 4 counts ALL crash comments ever
posted on an issue. After removing `stalled` label, old crashes still count,
causing immediate re-stalling.

## Fix

Use the timestamp of the last "Marking as stalled" comment as a cutoff.
Only count crashes that occurred AFTER that timestamp. If no stalled comment
exists, count all crashes (backward compatible).

The jq filter finds the last stalled comment's `createdAt`, then filters
crash/failure comments to only those created after that timestamp.

## Files changed

- `skills/autonomous-dispatcher/SKILL.md` — Step 4 retry counting logic
