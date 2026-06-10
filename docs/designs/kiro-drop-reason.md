# Design: kiro auth/login failure → distinct review drop reason (INV-61, #215)

## Problem

When a `kiro` review fan-out member is dropped `unavailable` because its stored
OAuth/login token on the execution host has expired, the kiro CLI tries to open a
browser for device-flow re-auth. In the headless (SSM-spawned) shell that is
impossible, so kiro exits at launch with **no verdict comment**. The wrapper's
post-window sweep resolves kiro `unavailable` ([INV-40]). The drop-reason assembly
loop in `autonomous-review.sh` enriches reasons only for `agy` ([INV-58]) and
`codex` ([INV-59]) — so a dropped kiro gets an **empty** reason and the posted
"dropped (unavailable) agent(s)" comment / WARN log reads `kiro …` with no cause,
indistinguishable from a launch misconfig or a genuine no-verdict miss.

## The signal (verified, from the issue)

kiro's launch-failure lines land in its **generic per-agent log**
`/tmp/agent-${PROJECT_ID}-review-${ISSUE_NUMBER}-kiro.log` — the same `$_agent_log`
the kiro invocation writes to (NOT a separate `--log-file` like agy). Observed:

```
▰▱▱ Opening browser... | Press (^) + C to cancel
Failed to open browser for authentication.
Please try again with: kiro-cli login --use-device-flow
error: Failed to open URL
```

Actionable fixed substrings: `Failed to open browser for authentication`,
`kiro-cli login`, `--use-device-flow`, `Failed to open URL`.

## Approach (mirror the agy/codex detector pattern EXACTLY)

This is the **third** CLI-specific review-side drop-reason classifier. Keep the
layering identical to INV-58 (`lib-review-agy.sh`) and INV-59
(`lib-review-codex.sh`): a per-CLI lib + a branch in the `_dropped_reasons` loop +
a captured per-agent log array.

### New lib `scripts/lib-review-kiro.sh`

Two helpers, both **`return 0` ALWAYS** (fail-safe — they are called inside a
`$(…)` in a `_dropped_reasons` append that would abort the wrapper under
`set -euo pipefail` if non-zero, stranding the issue in `reviewing`):

- `_classify_kiro_drop_reason <log_file>` — single-pass `grep -F` (fixed
  substring, no jq) over the kiro per-agent log for the auth/login signal. Echoes
  `auth-failed` when present; empty otherwise (a signal-free / no-verdict kiro
  drop keeps the bare `unavailable`, no over-claim). Missing / empty / unreadable
  / empty-arg log → empty, rc 0.
- `_kiro_drop_reason_phrase <token>` — render `auth-failed` → a single human
  clause naming the remedy
  (`auth-failed (browser/device-flow login required on the execution host: kiro-cli login --use-device-flow)`).
  Empty token → empty phrase. rc 0 always.

### Wrapper wiring (`autonomous-review.sh`)

1. **Source** `lib-review-kiro.sh` next to the other `lib-review-*.sh` sources.
2. **Capture** `AGENT_KIRO_LOGS` in the fan-out loop (next to the codex
   `AGENT_CODEX_LOGS` capture): for a `kiro` member, record its `$_agent_log`
   (the SAME deterministic generic per-agent log; no sidecar needed — mirrors
   exactly how codex captures `$_agent_log`).
3. **Wire** the kiro branch into the `_dropped_reasons` assembly loop (next to the
   agy + codex branches): for a dropped agent whose name is `kiro`, call
   `_classify_kiro_drop_reason` then `_kiro_drop_reason_phrase`, appending the
   reason when non-empty. Same rc-0-always discipline as the agy/codex branches.
4. **CI**: add the new lib to the ShellCheck file list in `.github/workflows/ci.yml`.

## Out of scope (observability only)

- Does **NOT** change the [INV-40] vote: a kiro auth-failure stays a `unavailable`
  drop, never a deciding FAIL (an auth/token-expiry is an operational/infra
  condition, not a code rejection; promoting it to a veto would block merges
  whenever kiro's token expires on the host).
- Does **NOT** attempt to re-auth kiro — the root-cause remedy is operational
  (`kiro-cli login --use-device-flow` on the execution host). This issue is purely
  about REPORTING the cause so the bare `unavailable` becomes actionable.
- No change to `lib-agent.sh`, the dev side, the comment poller, or the INV-40
  aggregation.

## Cross-references

- [INV-58] — agy quota/auth → `quota-exhausted`/`auth-failed` (the immediate
  sibling for a quota wall; this borrows agy's `auth-failed` token shape but reads
  kiro's generic per-agent log, not a `--log-file`).
- [INV-59] — codex `turn.failed` 5xx → `stream-error` (the codex-shaped sibling).
- [INV-40] — the fan-out + `unavailable` definition this annotates; unchanged.

[INV-40]: ../pipeline/invariants.md
[INV-58]: ../pipeline/invariants.md
[INV-59]: ../pipeline/invariants.md
