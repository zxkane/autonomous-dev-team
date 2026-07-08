# Test Cases: state-manager.sh BSD date TZ Fix

**Date:** 2026-07-08
**Issue:** #446
**Feature:** fix-state-manager-bsd-date-tz

## Test IDs and Scenarios

All cases force the BSD `date -j -f` branch via a PATH-shimmed fake `date`
binary (this repo's CI has no macOS runner, and GNU `date -d` already
handles the `Z` suffix correctly, so a real-`date` TZ-only test would pass
before the fix and prove nothing). State is isolated under a `mktemp -d`
project root (`CLAUDE_PROJECT_DIR`) so the test never touches this repo's
own `.agents/state/`.

### TC-SMTZ-001: Positive-offset freshness (Asia/Shanghai, UTC+8)

- Force BSD branch (shim rejects `-d`).
- `TZ=Asia/Shanghai`.
- `mark <action>` then immediately `check <action>`.
- Expect: exit 0 (fresh) with the fix applied.
- Pre-fix: fails (exit 1) — age is inflated by ~+28800s past the 1800s
  expiry, proving the bug.

### TC-SMTZ-002: Negative-offset staleness (America/New_York, UTC-5)

- Force BSD branch (shim rejects `-d`).
- `TZ=America/New_York`.
- `mark <action>`, then backdate the stored timestamp by ~45 minutes
  (past the 30-minute expiry).
- `check <action>`.
- Expect: exit 1 (stale) with the fix applied.
- Pre-fix: fails (exit 0, falsely "fresh") — age is deflated by the
  negative offset, masking real staleness.

### TC-SMTZ-003: GNU `date -d` branch unaffected (regression guard)

- Do NOT force the BSD branch (real `date -d` available, as on this
  Linux dev/CI host).
- `TZ=Asia/Shanghai`.
- `mark <action>` then immediately `check <action>`.
- Expect: exit 0. Confirms the fix is scoped to the BSD fallback and does
  not alter GNU `date -d` behavior.

### TC-SMTZ-004: State isolation

- Every case above asserts the test's `mktemp -d` state directory is used
  (`CLAUDE_PROJECT_DIR` points there) and that this repo's own
  `.agents/state/` / `.claude/state` / `.kiro/state` directories are
  untouched (no new/modified files there after the test run).

## Shim Contract (`fake date` binary)

Placed ahead of the real `date` in `PATH` for TC-SMTZ-001/002 only. See
the shim's contract comment in
`tests/unit/test-state-manager-bsd-date-tz.sh` for the exact emulated
semantics (passthrough for write/now calls, `-d` rejection to force the
BSD fallthrough, and pre-fix vs post-fix `-j -f` emulation).
