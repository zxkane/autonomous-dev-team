# Design: `AGENT_REVIEW_TIMEOUT` (1h default) with browser-E2E exclusion + timeout-veto (INV-48)

Issue: #185

## Problem

`AGENT_TIMEOUT` (default `4h`, INV-13) is shared by the dev and review wrappers.
A review CLI that **silently hangs** (no output, no exit) holds a wrapper PID slot
for the full 4h. Observed: a 3-agent fan-out (`kiro agy codex`) where one review
CLI hung for ~3 h; the bounded `wait "${_fanout_pids[@]}"` (INV-40) correctly
blocked on the hung subshell, so the whole review stalled in `reviewing` (two
siblings' verdicts already posted) until the CLI's `timeout 4h` would eventually
fire. A 1h review cap reaps a hung review CLI ~3 h sooner.

## Goals

1. Cap **review-agent** CLIs at **1h by default**, operator-overridable via
   `AGENT_REVIEW_TIMEOUT`. The **dev side is untouched** (keeps 4h).
2. Make an aggressive review cap **safe**:
   - browser-mode E2E (a normal `run_agent` LLM lane that would otherwise inherit
     the 1h cap) gets its OWN cap `E2E_BROWSER_TIMEOUT_SECONDS`, default = the
     original 4h, so a slow preview deploy isn't killed at 1h;
   - a review agent **killed by the timeout** (rc `124`/`137`) with no posted
     verdict **vetoes** the merge (deciding FAIL), instead of being silently
     dropped from the unanimous-PASS vote as `unavailable`.
3. Fail loud at startup on an invalid / zero timeout value.

## Why a 1h literal default (not inherit `AGENT_TIMEOUT`)

Per operator instruction. The review prompt tells agents to rebase and
`gh pr checks --watch`, and code review itself is ~1–2 min; a healthy review run
is far under 1h. A hung CLI is the failure this caps — 4h is wasteful there.
The two ways a naive 1h cap mis-kills legitimate work — browser-mode E2E and a
CI queue >1h surfacing as a review timeout — are addressed by the browser cap
and the timeout-veto (a CI-queue timeout becomes a loud FAIL → dev re-dispatch,
not a silent drop).

## Mechanism

### Per-side review timeout rebind

`AGENT_TIMEOUT` is read live by `_run_with_timeout` (lib-agent.sh:252) at call
time, and by agy's `--print-timeout "$AGENT_TIMEOUT"` (lib-agent.sh:816/971). So
rebinding `AGENT_TIMEOUT` in the review wrapper **before the fan-out** applies to
every review fan-out agent, with no change to lib-agent.sh's invocation sites.

The rebind goes in the per-side override block, next to the INV-37 `AGENT_CMD`
rebind and INV-38 `AGENT_LAUNCHER_ARGV` rebind — i.e. **AFTER** `source
lib-auth.sh` (which transitively re-sources the conf's unconditional
`AGENT_TIMEOUT="4h"`), **BEFORE** the `: "${PROJECT_ID:?}"` validation:

```bash
_ORIG_AGENT_TIMEOUT="$AGENT_TIMEOUT"                       # conf's 4h (INV-13)
AGENT_TIMEOUT="${AGENT_REVIEW_TIMEOUT:-1h}"                # review cap, 1h default
E2E_BROWSER_TIMEOUT_SECONDS="${E2E_BROWSER_TIMEOUT_SECONDS:-$_ORIG_AGENT_TIMEOUT}"
```

The dev wrapper is **not** modified — it never reads `AGENT_REVIEW_TIMEOUT` and
keeps `AGENT_TIMEOUT=4h`.

### Browser-mode E2E exclusion

The browser-mode E2E lane is an LLM `run_agent` lane (autonomous-review.sh, INV-46
Phase A). It runs under a LOCAL rebind to the browser cap, restored after the
lane, so it is NOT shrunk to the 1h review cap:

```bash
_saved_for_e2e="$AGENT_TIMEOUT"
AGENT_TIMEOUT="$E2E_BROWSER_TIMEOUT_SECONDS"
( ... run_agent ... )
AGENT_TIMEOUT="$_saved_for_e2e"
```

Symmetric with command-mode's `E2E_COMMAND_TIMEOUT_SECONDS` (the command lane is
pure shell and already wraps the verify in `timeout … ${E2E_COMMAND_TIMEOUT_SECONDS}`
via `_run_command_e2e_verify`, so it is already independent of `AGENT_TIMEOUT`).

### Timeout-veto (INV-40 amendment)

INV-40's post-window sweep currently resolves any no-verdict agent to
`unavailable` (dropped). We split that terminal resolution by launch rc:

- rc `124` (timeout) or `137` (kill-after KILL) + no verdict → **`timed-out`**
- any other rc + no verdict → **`unavailable`** (unchanged)

`_aggregate_review_verdicts` counts `timed-out` as a **deciding FAIL** (veto).
A verdict the agent DID post still wins over the rc (INV-40 precedence), exactly
as for `unavailable` today.

Pure helper `_classify_noverdict_agent <rc>` (in lib-review-aggregate.sh) makes
the rc→state mapping unit-testable in isolation.

## Startup validation

`validate_review_timeout_config` (mirrors `validate_e2e_config`, fail-loud at
startup): rejects `AGENT_REVIEW_TIMEOUT` and `E2E_BROWSER_TIMEOUT_SECONDS` values
that aren't a positive coreutils-`timeout` value, and rejects `0` (GNU `timeout 0`
disables the cap). A valid value is `n` optionally followed by `s`/`m`/`h`/`d`,
with `n` a positive integer — e.g. `3600`, `90m`, `2h`. Pure predicate
`_is_positive_timeout_value` lives in lib-agent.sh alongside `AGENT_TIMEOUT`.

**Validate intent, not the resolved default.** Validation reads only what the
operator SUPPLIED: `AGENT_REVIEW_TIMEOUT` (the rebind leaves it unmodified) and
`_E2E_BROWSER_TIMEOUT_RAW` (the raw `E2E_BROWSER_TIMEOUT_SECONDS`, captured
*before* the default fold-in). The browser default is `_ORIG_AGENT_TIMEOUT` (the
conf's `AGENT_TIMEOUT`), which the dev side honors **unvalidated** and which GNU
`timeout` may accept in forms this stricter predicate rejects (fractional,
`infinity`). Re-validating the resolved browser default would hard-fail the
review wrapper on a conf the dev side runs fine (e.g. `AGENT_TIMEOUT="1.5h"`) — a
back-compat regression caught in review and pinned by `TC-RTO-VAL-11e/f`.

A startup log line reports the resolved review cap and browser-E2E cap.

## Backward compatibility

- Nothing set → review cap `1h`, browser-E2E cap `4h`, dev cap `4h`.
- `AGENT_REVIEW_AGENTS` empty/unset (N=1) → the rebind still applies (the lone
  review agent is capped at 1h); the aggregation truth table is unchanged except
  the new `timed-out` deciding-FAIL row.
- `E2E_MODE=none` → no E2E lane; the browser cap is computed but never used.
- INV-37/38/40/43/44/46 paths unchanged.

## Test plan

See `docs/test-cases/review-agent-timeout.md`.
