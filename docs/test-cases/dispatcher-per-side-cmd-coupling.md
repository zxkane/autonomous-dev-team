# Test Cases: Dispatcher-Side `$AGENT_CMD` Coupling Under Per-Side Overrides

Tracks fixes for Findings 2 + 3 from the agy CLI review of PR #156
(https://github.com/zxkane/autonomous-dev-team/pull/156#issuecomment-4535743633).

After PR #156 introduced `AGENT_DEV_CMD` / `AGENT_REVIEW_CMD` per-side
overrides, two `lib-dispatch.sh` helpers still read the shared
`$AGENT_CMD` directly. Under split-CLI deployments the dispatcher's
`$AGENT_CMD` is the project default (e.g. `claude`), but each wrapper
runs with its side's override (e.g. review wrapper runs `agy`). The
shared-var read produces the wrong answer.

| Helper | Read site | Failure mode |
|---|---|---|
| `_pgid_has_agent_process` | `lib-dispatch.sh:1276` | False-negative liveness on review side under `AGENT_REVIEW_CMD=agy`. Dispatcher classifies live wrapper as DEAD. |
| `is_session_completed` | `lib-dispatch.sh:530` | claude-only JSON parser runs against codex log when `AGENT_DEV_CMD=codex AGENT_CMD=claude`. Misinterpretation of completion state. |

## Fixes

1. `_pgid_has_agent_process` accepts an optional second argument: the
   per-side CLI to match. Falls back to `$AGENT_CMD` when omitted
   (back-compat).
2. Callers pass the right per-side var:
   - `dev_near_success` → `${AGENT_DEV_CMD:-${AGENT_CMD:-claude}}`
   - `review_near_success` → `${AGENT_REVIEW_CMD:-${AGENT_CMD:-claude}}`
3. `is_session_completed` gates on `${AGENT_DEV_CMD:-${AGENT_CMD:-claude}}`
   (function is dev-side-only — parses dev wrapper's log).

## Test Cases

### TC-PSC-COUP-01: `_pgid_has_agent_process` accepts per-side CLI argument

**File**: `tests/unit/test-pgid-has-agent-process.sh` (new)

**Setup**: spawn a controlled child process with a known `comm`
(e.g. `bash -c 'exec -a fake-agy sleep 30 &'`), capture its PGID.

**Assertions**:
- `_pgid_has_agent_process <pgid>` (no second arg) → matches against
  `$AGENT_CMD` for back-compat.
- `_pgid_has_agent_process <pgid> "agy"` → matches the spawned `fake-agy` process.
- `_pgid_has_agent_process <pgid> "claude"` → doesn't match, returns 1.
- `_pgid_has_agent_process <pgid> ""` (empty string) → falls back to `$AGENT_CMD`.

**Why**: pins the new signature so a future refactor cannot silently
drop the per-side argument.

### TC-PSC-COUP-02: `dev_near_success` passes dev-side CLI

**File**: `tests/unit/test-dev-near-success.sh` (extend)

**Setup**: under split config (`AGENT_CMD=claude AGENT_DEV_CMD=codex`),
mock `_pgid_has_agent_process` and assert it receives `"codex"` as 2nd arg.

**Assertions**:
- Mock records 2nd argument; assert it equals `"codex"`.
- Default config (no override): mock receives `""` or `"claude"` (caller's choice).

### TC-PSC-COUP-03: `review_near_success` passes review-side CLI

**File**: `tests/unit/test-dispatcher-review-near-success.sh` (extend)

Mirror of TC-PSC-COUP-02 but for review wrapper:
- Under `AGENT_CMD=claude AGENT_REVIEW_CMD=agy`, mock receives `"agy"`.

### TC-PSC-COUP-04: `is_session_completed` gates on dev-side CLI

**File**: `tests/unit/test-is-session-completed.sh` (extend TC-WH-005 area)

**Assertions**:
- `AGENT_CMD=claude AGENT_DEV_CMD=codex` → `is_session_completed` returns 1
  (gate sees codex on dev side, refuses to parse).
- `AGENT_CMD=codex AGENT_DEV_CMD=claude` → returns 1 if log absent OR
  parses claude format if log valid (gate sees claude on dev side, proceeds).
- `AGENT_CMD=claude` (no AGENT_DEV_CMD) → fallback to current shared
  behavior, gate sees claude.

### TC-PSC-COUP-05: regression — default config preserves byte-for-byte behavior

**File**: existing `test-dev-near-success.sh`, `test-dispatcher-review-near-success.sh`,
`test-is-session-completed.sh` all still pass with default config (no per-side
overrides set). Validates back-compat.

## Acceptance Criteria

- [ ] All 5 test cases pass
- [ ] All existing peer test files (`test-dev-near-success.sh`,
  `test-dispatcher-review-near-success.sh`, `test-is-session-completed.sh`,
  `test-is-session-completed-end-ts.sh`) still pass
- [ ] `shellcheck -S error skills/autonomous-dispatcher/scripts/lib-dispatch.sh` clean
- [ ] Pipeline-docs gate satisfied (lib-dispatch.sh touched → docs/pipeline/ updated)

## Spec/Doc Updates

- [ ] `docs/pipeline/per-side-agent-cmd.md`: add §Dispatcher-side coupling section
- [ ] `docs/pipeline/invariants.md` INV-37: extend the Producer/Consumer fields
  to include the dispatcher-side reads
