# Design Canvas — Wrapper Hangs Bundle (PR-6)

**Branch**: `feat/wrapper-hangs-bundle`
**Closes**: #59, #60, #67
**Pipeline-docs touched**: `docs/pipeline/invariants.md` (INV-12, INV-13, INV-15 → ENFORCED), `docs/pipeline/dev-agent-flow.md` (trap contract), `docs/pipeline/dispatcher-flow.md` (Step 4 session-completed gate).

---

## Why one PR

All three issues describe the same failure mode — a dev wrapper that holds an issue's PID slot indefinitely while making no progress — with three different roots:

| Issue | Root cause | Fix layer |
|-------|-----------|-----------|
| #59 (INV-12) | Dispatcher resumes a session that already ended with `terminal_reason=completed` | dispatcher Step 4 (pre-dispatch gate) |
| #60 (INV-13) | Agent CLI hangs forever in `epoll_wait` with no wall-clock bound | wrapper `lib-agent.sh::run_agent` / `resume_agent` |
| #67 (INV-15) | Step 5a SIGTERM races wrapper trap; trap routes to `pending-dev`, not `pending-review` | wrapper `autonomous-dev.sh::cleanup` |

They compose: #60 is the universal safety net, #59 prevents the most common trigger, #67 makes the rescue path (Step 5a) actually converge to the intended state. Bundling lets us extract one helper (`is_session_completed`) once and verify the three fixes don't conflict.

## Refactor-first

Two shared additions, both behavior-neutral on existing paths:

### 1. `lib-agent.sh`: timeout wrapper

Add a single helper that resolves the right `timeout` binary once at source time:

```bash
# Picks up GNU coreutils `timeout` (Linux) or `gtimeout` (macOS via brew).
# Empty string means "no timeout binary available" — caller falls through to
# unwrapped invocation with a one-time WARN log.
_AGENT_TIMEOUT_CMD="$(command -v timeout || command -v gtimeout || true)"
```

Then both `run_agent` and `resume_agent` route their CLI invocation through:

```bash
_run_with_timeout() {
  if [[ -n "$_AGENT_TIMEOUT_CMD" ]]; then
    "$_AGENT_TIMEOUT_CMD" --kill-after=30s --signal=TERM "${AGENT_TIMEOUT:-4h}" "$@"
  else
    "$@"
  fi
}
```

`AGENT_TIMEOUT` is overridable via `autonomous.conf` or env. Default `4h` (issue #60 recommendation). `--kill-after=30s` escalates to SIGKILL if the agent process group ignores SIGTERM. `--signal=TERM` lets the agent flush any final SSE bytes before dying.

This wraps **all four** AGENT_CMD branches uniformly. No branch-specific logic; the four `case` arms remain readable.

### 2. `lib-dispatch.sh`: `is_session_completed`

```bash
# is_session_completed <issue_num>
# Returns 0 (true) if the most recent agent JSON output for this issue indicates
# a normal end-of-turn (stop_reason=end_turn AND terminal_reason=completed).
# Returns 1 (false) for: missing log, no JSON object found, partial JSON,
# any non-claude AGENT_CMD (which doesn't emit this format), or any non-terminal
# stop reason.
is_session_completed() {
  local issue_num="$1"
  [[ "${AGENT_CMD:-claude}" = "claude" ]] || return 1   # only claude emits this

  local log_file="/tmp/agent-${PROJECT_ID}-issue-${issue_num}.log"
  [[ -r "$log_file" ]] || return 1

  # Pull last well-formed JSON object from the log. The wrapper's `run_agent
  # --output-format json` writes one final object on clean exit; on crash there
  # may be partial JSON, which jq -e rejects.
  local last_obj
  last_obj=$(grep -oE '\{"type":"result"[^}]*\}|\{"role":"assistant"[^}]*\}' "$log_file" 2>/dev/null | tail -1)
  [[ -n "$last_obj" ]] || return 1

  local stop terminal
  stop=$(jq -er '.stop_reason // empty' <<<"$last_obj" 2>/dev/null) || return 1
  terminal=$(jq -er '.terminal_reason // empty' <<<"$last_obj" 2>/dev/null) || return 1
  [[ "$stop" = "end_turn" && "$terminal" = "completed" ]]
}
```

Used by `dispatcher-tick.sh` Step 4 only. If the session is completed:

1. Skip the dispatch.
2. Comment on the issue: `Session \`${session_id}\` already ended (terminal_reason=completed). Resume would hang on idle SSE — skipping. Manually transition to \`pending-review\` if a PR exists, or close the issue if work is done.`
3. Move the issue to a sentinel label: **leave `pending-dev` in place** (do NOT auto-recover) so an operator notices and decides. (Auto-flipping to `pending-review` without a PR check would mask real failures.)

This is intentionally conservative — silent recovery would obscure the symptom. The wall-clock timeout (#60) is the safety net for the cases where the gate is wrong.

## Behavior changes

### #67 (INV-15) — SIGTERM-aware trap

In `autonomous-dev.sh`:

```bash
RECEIVED_SIGTERM=0
on_sigterm() { RECEIVED_SIGTERM=1; }
trap on_sigterm TERM
trap cleanup EXIT          # existing
```

In `cleanup()`, before the `if [[ $exit_code -eq 0 ]]` branch:

```bash
# SIGTERM from dispatcher Step 5a means "PR is ready, you're being killed
# politely so review can take over." Treat as PR-success even though bash
# reports exit_code=143.
if [[ "$RECEIVED_SIGTERM" -eq 1 ]]; then
  log "Caught SIGTERM (likely from dispatcher Step 5a). Inspecting PR state."
  PR_EXISTS=$(gh pr list --repo "$REPO" --state open --json body \
    -q "[.[] | select(.body | test(\"#${ISSUE_NUMBER}[^0-9]\") or test(\"#${ISSUE_NUMBER}$\"))] | length" 2>/dev/null || echo "0")
  if [[ "$PR_EXISTS" -gt 0 ]]; then
    exit_code=0   # route through the PR-found branch below
  fi
fi
```

After this, the existing `exit_code -eq 0 && PR_EXISTS>0` branch routes to `pending-review` — the convergent state. If SIGTERM fires with no PR, leave `exit_code=143` so we still go to `pending-dev` (genuine retry case).

**Why we don't simplify Step 5a to skip its own `gh issue edit`**: the dispatcher's edit is a belt-and-suspenders against the case where the wrapper is actually wedged so hard that even the EXIT trap doesn't fire (e.g., SIGKILL escalation). Two writers converging on the same target state is fine. The bug was that they diverged.

### Order of operations in cleanup()

The new `RECEIVED_SIGTERM` check sits between PID-file removal and label transitions. Sequence:

1. `rm -f $PID_FILE` (always)
2. Skip-if-agent-never-ran short circuit (existing)
3. Refresh GH token (existing)
4. **NEW**: if `RECEIVED_SIGTERM=1 && PR_EXISTS`, set `exit_code=0`
5. Post Session Report (existing)
6. Label transition based on `exit_code` (existing)

## Acceptance / behavior parity

| Scenario | Before | After |
|----------|--------|-------|
| Agent runs to clean exit, PR exists | `pending-review` | `pending-review` (unchanged) |
| Agent runs to clean exit, no PR | `pending-dev` + comment | unchanged |
| Agent crashes mid-turn | `pending-dev` | unchanged |
| Step 5a SIGTERM + PR exists | last-writer-wins (usually `pending-dev`) | **`pending-review`** (deterministic) |
| Step 5a SIGTERM + no PR | `pending-dev` | unchanged |
| Agent hangs > 4h | `in-progress` indefinitely | wrapper exits 124 → `pending-dev` |
| Resume against completed session | wrapper hangs 8h+ | dispatcher skips Step 4 with explanatory comment |

## Tests

1. `tests/unit/test-is-session-completed.sh` — fixture log files (clean exit / crash / non-claude / missing).
2. `tests/unit/test-agent-timeout-wrapper.sh` — verify `_run_with_timeout` invokes timeout binary when present, falls through when absent. Exercise with `sleep 5` against `AGENT_TIMEOUT=1s` to assert exit code 124.
3. `tests/unit/test-sigterm-trap.sh` — fork a wrapper-shaped script, send SIGTERM, assert `RECEIVED_SIGTERM` flow and that exit_code rewrites to 0 when PR_EXISTS>0.

## Out of scope

- Changing the review wrapper's invocation path. Review wrappers are bounded by their own internal polling (max 3 min for Q-review wait) — not the same hang surface. They get the timeout wrapper for free via `lib-agent.sh`, but no new SIGTERM handling.
- Auto-closing issues with completed sessions. INV-12 fix is "skip and notify"; closing requires human judgment about whether the work is actually done.
- Escalating retry logic for repeated timeouts. Existing crash-counter (Step 4a) handles this.
