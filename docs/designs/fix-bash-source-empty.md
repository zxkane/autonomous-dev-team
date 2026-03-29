# Fix: BASH_SOURCE[0] empty in bash -c contexts

**Date:** 2026-03-29
**Issue:** #39
**Status:** Approved

## Problem

When `autonomous-dev.sh` is invoked via `bash -c '...'` (SSM dispatch, subprocess
spawning), `BASH_SOURCE[0]` is an empty string in sourced scripts (`lib-agent.sh`,
`lib-auth.sh`). This causes `readlink -f ""` to resolve to the caller's working
directory, failing to find `autonomous.conf`.

## Fix

### 1. Add `AUTONOMOUS_CONF` env var as highest-priority config source

Callers can set `AUTONOMOUS_CONF=/path/to/autonomous.conf` before invoking the
scripts. This bypasses all path resolution and works in any invocation context.

### 2. Fall back to `${BASH_SOURCE[0]:-$0}` when `BASH_SOURCE[0]` is empty

When `BASH_SOURCE[0]` is empty (bash -c), `$0` still has a valid value (the
script path passed to `bash`). Using `${BASH_SOURCE[0]:-$0}` handles both
normal sourcing and bash -c contexts.

### Files to change

- `lib-agent.sh` — config loading block (lines 6-15)
- `lib-auth.sh` — config loading block (lines 8-16)

### Config loading priority (after fix)

1. `AUTONOMOUS_CONF` env var (explicit path)
2. `${_LIB_DIR}/autonomous.conf` (local to script)
3. `${_LIB_DIR}/../../../scripts/autonomous.conf` (project root fallback)
