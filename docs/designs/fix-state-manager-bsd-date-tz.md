# Fix: state-manager.sh Mark Age Miscomputed on BSD `date` in Non-UTC Timezones

**Date:** 2026-07-08
**Issue:** #446
**Status:** Approved (see issue #446 pre-implementation review comment)

## Problem

`state-manager.sh::check_action()` (line ~148) parses a mark's stored UTC
timestamp back into epoch seconds to compute its age:

```sh
state_time=$(date -d "$timestamp" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null || echo "0")
```

GNU `date -d` (Linux) correctly interprets the trailing `Z` as UTC. BSD
`date -j -f` (macOS, no GNU `date -d`) does not — it **ignores** the `Z`
and parses the string as local time under the machine's ambient `$TZ`.
Since the mark is *written* in UTC (`date -u +"%Y-%m-%dT%H:%M:%SZ"`, line
74, unchanged), the BSD parse silently reinterprets a UTC instant as a
local one, skewing the computed age by the machine's UTC offset:

- **Positive offset (UTC+8):** age is inflated by +28800s. A fresh mark
  reads as already older than the 1800s expiry → `check` deletes it and
  returns 1. The pre-push `check pr-review` gate becomes unpassable
  without `--no-verify`.
- **Negative offset (UTC-5):** age is deflated (can go negative). A mark
  that is actually >30 minutes stale still reads as fresh → `check`
  incorrectly returns 0, silently extending the review window.

Linux/GNU `date -d` and machines already in UTC are unaffected — this is
why CI (Linux runners) never caught it.

## Fix

Force UTC interpretation in the BSD fallback branch only, matching the
existing precedent for this exact bug class in
`skills/autonomous-dispatcher/scripts/lib-dispatch.sh::_iso_age_seconds`
(which already uses `date -u -j -f` for the identical reason):

```sh
state_time=$(date -d "$timestamp" +%s 2>/dev/null \
  || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null \
  || echo "0")
```

`date -d` already handles the `Z` correctly on GNU, so only the BSD
fallback needs `-u`. No change to the write side (line 74).

## Tests

Since this repo's CI has no macOS runner and GNU `date -d` handles `Z`
correctly, a plain `TZ=...` test would pass before the fix too — it
wouldn't exercise the buggy branch at all. The regression test forces the
BSD branch via a PATH-shimmed fake `date` binary; see the shim's contract
comment in `tests/unit/test-state-manager-bsd-date-tz.sh` for the exact
emulated semantics.

Two directions, each under a forced non-UTC `TZ`:
1. Positive offset (`Asia/Shanghai`, UTC+8): mark then immediately
   check — must return 0 (fresh).
2. Negative offset (`America/New_York`, UTC-5): mark with a timestamp
   backdated ~45 minutes, then check — must return 1 (stale).

State is isolated under a `mktemp -d` project root (`CLAUDE_PROJECT_DIR`)
so the test never touches this repo's own `.agents/state/`.

See `docs/test-cases/fix-state-manager-bsd-date-tz.md` and
`tests/unit/test-state-manager-bsd-date-tz.sh`.

## Impact

- **Backward compatibility:** no CLI change. `check <action>` behavior on
  Linux/GNU `date` and on machines already in UTC is unchanged (GNU
  branch untouched; BSD-branch-but-UTC machines compute the same age
  since UTC offset is 0).
- **Scope:** confined to the parse path (line 148). The write format
  (line 74) is unchanged, so no migration is needed for existing state
  files.

## Risk

Low. One-line change, aligned with an existing precedent in this same
repo (`_iso_age_seconds`). The only behavior change is on BSD `date` in a
non-UTC timezone — previously miscomputed, now correct.
