# Fix: Symlink Resolution in Dispatcher Scripts

**Date:** 2026-03-28
**Issue:** #37
**Status:** Approved

## Problem

When scripts are installed via `npx skills add` and accessed through symlinks,
two path resolution failures occur:

1. `dispatch-local.sh` cannot find `autonomous.conf` because `SCRIPT_DIR` points
   to the installed skill location, not the project's `scripts/` directory.
2. `autonomous-dev.sh` and `autonomous-review.sh` use `readlink "$0"` which only
   resolves one level of symlink, failing on chained symlinks.
3. `lib-agent.sh` uses `BASH_SOURCE[0]` without resolving symlinks, so when
   sourced from a symlinked script, `_LIB_AGENT_DIR` points to the wrong location.

## Fix

### 1. `autonomous-dev.sh` and `autonomous-review.sh` (line 17)

Replace single-level `readlink` with `readlink -f` to fully resolve all symlinks:

```bash
# Before
SCRIPT_DIR="$(cd "$(dirname "$([ -L "$0" ] && readlink "$0" || echo "$0")")" && pwd)"

# After
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
```

### 2. `lib-agent.sh` (line 7)

Same fix for `BASH_SOURCE[0]`:

```bash
# Before
_LIB_AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# After
_LIB_AGENT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
```

### 3. `dispatch-local.sh` (lines 31-34)

Add fallback config loading from `$PROJECT_DIR/scripts/` when config is not in `$SCRIPT_DIR`:

```bash
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
if [[ -f "${SCRIPT_DIR}/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/autonomous.conf"
elif [[ -f "${SCRIPT_DIR}/../../../scripts/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/../../../scripts/autonomous.conf"
fi
```

## Portability

`readlink -f` is available on Linux (coreutils) and macOS (since Ventura / coreutils).
This project targets Linux (CI runners, SSM dispatch). macOS portability is not a concern
for the autonomous pipeline scripts.
