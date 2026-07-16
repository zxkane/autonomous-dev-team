# Test Cases — Step 5a progress-gated SIGTERM (#485)

Frozen clock + stubs/fixtures, no real sleeps. Drives the REAL production
decision surfaces: `dev_progress_snapshot` (`lib-dispatch.sh`) and the REAL
Step 5a control-flow block extracted from `dispatcher-tick.sh` (awk-range
extraction, same technique as `test-lane-gc-p6-gate.sh`'s `STEP5_BODY`) — never
a reimplemented test-only decision.

## Snapshot probe (`dev_progress_snapshot`, local backend)

- TC-DPS-001: valid current-run lease, age 0 → `state=FRESH`.
- TC-DPS-002: valid current-run lease, age 1799 → `state=FRESH` (boundary).
- TC-DPS-003: valid current-run lease, age exactly 1800 → `state=FRESH` (`<=` inclusive).
- TC-DPS-004: valid current-run lease, age 1801 → `state=STALE`, `pid`/`run_id` populated and correct.
- TC-DPS-005: `issue-N.progress.json` missing → UNKNOWN.
- TC-DPS-006: `issue-N.run-id` missing → UNKNOWN.
- TC-DPS-007: `issue-N.progress.json` is a symlink → UNKNOWN.
- TC-DPS-008: `issue-N.progress.json` mode 0644 (not 0600) → UNKNOWN.
- TC-DPS-009: malformed JSON → UNKNOWN.
- TC-DPS-010: JSON missing a required field (`pid`, `updated_at_epoch`, `run_id`, `schema_version`) → UNKNOWN.
- TC-DPS-011: `schema_version` != 1 → UNKNOWN.
- TC-DPS-012: `pid` non-numeric → UNKNOWN.
- TC-DPS-013: `updated_at_epoch` non-numeric → UNKNOWN.
- TC-DPS-014: `updated_at_epoch` negative → UNKNOWN.
- TC-DPS-015: `updated_at_epoch` in the future (relative to frozen "now") → UNKNOWN.
- TC-DPS-016: lease `pid` != current `issue-N.pid` content → UNKNOWN.
- TC-DPS-017: lease `run_id` != current `issue-N.run-id` content (a FRESH lease from a PRIOR run) → UNKNOWN, never FRESH.
- TC-DPS-018: `issue-N.run-id` is a symlink → UNKNOWN.
- TC-DPS-019: `pid_dir_for_project` itself fails (e.g. unset `PROJECT_ID`) → UNKNOWN, no crash.
- Every UNKNOWN row above: assert `state=UNKNOWN` and a `reason` matching `[a-z0-9-]+`; NEVER assert on the specific reason spelling. Assert no side effects (no file writes, no signal).

## Snapshot probe (remote backend)

- TC-DPS-030: same fixtures as TC-DPS-001..004 run through the remote driver (stubbed `aws`/SSM transport, real remote shell snippet executed locally) → identical `state` to the local probe for the same inputs.
- TC-DPS-031: SSM transport failure (send-command error) → UNKNOWN, never STALE.
- TC-DPS-032: SSM timeout (poll deadline exceeded) → UNKNOWN, never STALE.
- TC-DPS-033: remote stdout is not valid single-line JSON / doesn't match any of the three shapes → UNKNOWN, never STALE.
- TC-DPS-034: remote driver computes age using the REMOTE host's clock, not the controller's (proven by injecting a controller-side clock skew and asserting the remote-computed age is unaffected).

## Step 5a decision matrix (extracted real control-flow block)

- TC-S5A-001: pr_idle=301, CI green, PID alive, progress age=0 (FRESH) → no action (no comment, no label change, no signal).
- TC-S5A-002: pr_idle=301, CI green, PID alive, progress age=1800 (FRESH boundary) → no action.
- TC-S5A-003: pr_idle=301, CI green, PID alive, progress age=1801 (STALE) → SIGTERM sent, new handoff comment posted, `in-progress → pending-review`.
- TC-S5A-004: pr_idle exactly 300 + progress STALE → no action (INV-10 strict `>` still gates first).
- TC-S5A-005: pr_idle=301, CI green, PID alive, snapshot UNKNOWN (any family) → no action + WARN logged; never falls back to idle-only.
- TC-S5A-006: initial snapshot STALE, but the final pre-kill recheck's fresh snapshot reports FRESH → abort, no comment, no transition.
- TC-S5A-007: initial snapshot STALE, but the final recheck's `issue-N.pid` content changed (PID rotated) → abort, no comment, no transition.
- TC-S5A-008: initial snapshot STALE, final recheck's snapshot reports STALE but with a DIFFERENT `run_id` → abort (treated as a different run, not the one that was observed stale).
- TC-S5A-009: initial snapshot STALE, but `kill -0 $pid` fails on the final recheck (process exited between checks) → abort, no comment, no transition (existing behavior preserved).
- TC-S5A-010: all gates pass, `kill "$pid"` itself fails (process gone at the exact signal instant) → no comment, no transition (next tick owns it) — mirrors existing "PID already gone" handling but now gated additionally on the snapshot.
- TC-S5A-011: no PR / CI not green / pr_idle<=300 → unchanged short-circuits (regression guard that the new gate didn't disturb the pre-existing gates' ordering).
- TC-S5A-020 (regression): a frozen literal copy of the PRE-FIX ALIVE branch (captured once from `dispatcher-tick.sh` immediately before this fix — a string constant in the test file, not a dynamic `git show <sha>`/checkout, since CI runners are shallow/single-ref and a commit lookup can 404 there even when the pinned content is correct) is driven with a FRESH-progress fixture (`pr_idle=301`, CI green): it FAILS by SIGTERMing anyway, pinning the exact regression this issue closes. A counter-proof drives the REAL post-fix Step 5a block through the identical inputs and asserts it does NOT.

## Backend parity (remote path, valid-stale path both backends)

- TC-S5A-030: local backend, all gates pass including STALE snapshot + passing recheck → SIGTERM + comment + transition (same as TC-S5A-003, pinned again end-to-end through the real backend switch).
- TC-S5A-031: remote backend, all gates pass including STALE snapshot + passing compare-and-signal round-trip → SIGTERM + comment + transition. The atomic recheck+kill property (ONE SSM round-trip, no gap between recheck and kill) is proven separately and more strongly at the driver level (a real backgrounded process, the real `agent-progress-snapshot-remote-aws-ssm.sh --compare-and-signal`, asserting the process is actually terminated) — not by counting invocations through the Step 5a harness, which stubs the wrapper function wholesale.
- TC-S5A-032: remote backend, compare-and-signal transport returns `ABORTED:*` (mismatch found host-side) → no comment, no transition.
- TC-S5A-033: remote backend, compare-and-signal SSM round-trip itself fails (transport fault) → no comment, no transition.

## Wording / retry-regex exclusion

- TC-S5A-040: the new comment (`... no agent progress for <progress-age>s ...`) does NOT match the `count_agent_failures` retry regex (`Agent Session Report (Dev)` shape) — pinned directly against `count_agent_failures`, not by re-deriving the exclusion from wording alone.
- TC-S5A-041: the new comment is still distinguishable from `Dev process exited (...)` (Step 5b DEAD-branch wording) — no substring collision.

## Acceptance-criteria cross-check

- No state-machine label edge changes: `in-progress → pending-review` is the only transition this issue's Step 5a code path produces, same as before.
- Step 5b DEAD-PID behavior, SIGTERM trap convergence, `JUST_DISPATCHED`/cold-start graces, heartbeat, `AGENT_TIMEOUT`: untouched — pinned by running the existing Step 5b / grace-period / heartbeat test suites unmodified and green.
