# Test cases — `pid_alive` remote-aware liveness (#137, INV-30)

Closes the structural false-DEAD bug under `EXECUTION_BACKEND=remote-aws-ssm`
where `lib-dispatch.sh::pid_alive` runs on the dispatcher box and consults
its own filesystem / PID space — but the wrapper runs on a different box
(reproduced on a downstream consumer's #182, 2026-05-16 02:15–04:10 UTC).

## Architecture (one round-trip per tick-per-issue)

```
lib-dispatch.sh::pid_alive
  ├── EXECUTION_BACKEND=local    → existing 3-tier (kill -0 / mtime / heartbeat sibling)
  └── EXECUTION_BACKEND=remote-aws-ssm
       └── _remote_pid_alive_query
            └── liveness-check-remote-aws-ssm.sh   (new)
                 └── lib-ssm.sh::_ssm_run_remote_command   (new shared helper)
                      └── aws ssm send-command + poll get-command-invocation
                           └── remote snippet on box B prints ALIVE / DEAD
```

User-driven decision: **indeterminate (rc=2 / empty / weird stdout)
biases toward ALIVE** so transport faults never produce false crash
declarations.

Tests run via:

```bash
bash tests/unit/test-lib-ssm.sh
bash tests/unit/test-liveness-check-remote-aws-ssm.sh
bash tests/unit/test-pid-alive-remote-aws-ssm.sh
bash tests/unit/test-dev-near-success.sh   # signal-4 parity
```

## TC-LSSM-001..006 — `lib-ssm.sh` (extracted from `dispatch-remote-aws-ssm.sh`)

### TC-LSSM-001 — `_has_shell_metachar` truth table
**Intent**: pin the CWE-78 validator so a refactor extraction doesn't
silently change which characters are rejected.

**Setup**: source `lib-ssm.sh`; call `_has_shell_metachar` on each value.

**Expected**:
- Accepts: `valid`, `valid-with-dashes`, `valid_with_underscores`,
  `/abs/path/ok`, `1234`.
- Rejects: each of `$`, backtick, `;`, `&`, `|`, `<`, `>`, `*`, `?`,
  single-quote, double-quote, newline (`$'\n'`), carriage-return (`$'\r'`)
  embedded anywhere in the string.

### TC-LSSM-002 — `_ssm_run_remote_command` happy path
**Intent**: end-to-end — send-command + poll → returns rc=0 + stdout.

**Setup**: stub `aws` to emit `Command.CommandId=stub-1` on send-command
and `Status=Success` + `StandardOutputContent="ALIVE\n"` on
get-command-invocation.

**Expected**: helper returns rc=0; stdout contains `ALIVE`.

### TC-LSSM-003 — send-command failure → rc=2
**Intent**: SSM transport faults must surface as indeterminate, not as a
spurious "DEAD" verdict (per INV-30 conservative-bias rule).

**Setup**: stub `aws` such that `send-command` exits 1.

**Expected**: helper returns rc=2; stdout empty.

### TC-LSSM-004 — argv carries `--timeout-seconds` from env override
**Intent**: pin Finding 1.B from plan-eng-review — operator-overridable
SSM-side cap.

**Setup**: `SSM_COMMAND_TIMEOUT_SECONDS=15`; stub `aws` records argv.

**Expected**: recorded send-command argv contains `--timeout-seconds 15`.

### TC-LSSM-005 — `Status: TimedOut` → rc=2
**Setup**: stub get-command-invocation returns `Status: TimedOut`.

**Expected**: helper returns rc=2; stdout empty.

### TC-LSSM-006 — poll-loop wall-clock cap
**Intent**: helper-side bound on synchronous polling so a stuck
`InProgress` can't tie up the dispatcher tick.

**Setup**: stub get-command-invocation always returns `Status: InProgress`;
`REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS=2`.

**Expected**: helper returns rc=2 within ~2-3s wall-clock.

## TC-LCS-001..011 — `liveness-check-remote-aws-ssm.sh`

### TC-LCS-001 — missing `SSM_INSTANCE_ID` → rc=1, no aws invocation
**Setup**: unset `SSM_INSTANCE_ID`; valid other env.

**Expected**: rc=1; stub `aws` record file empty.

### TC-LCS-002 — bad `kind` → rc=1
**Setup**: pass `kind=garbage`.

**Expected**: rc=1; aws not invoked.

### TC-LCS-003 — ALIVE happy path → stdout `ALIVE`, rc=0
**Setup**: stub returns `Status: Success` + `StandardOutputContent: "ALIVE\n"`.

**Expected**: rc=0; stdout = `ALIVE`.

### TC-LCS-004 — DEAD happy path → stdout `DEAD`, rc=0
**Setup**: same as TC-LCS-003 with `StandardOutputContent: "DEAD\n"`.

**Expected**: rc=0; stdout = `DEAD`.

### TC-LCS-005 — send-command failure → rc=2
**Expected**: rc=2; stdout empty.

### TC-LCS-006 — `Status: Failed` → rc=2

### TC-LCS-007 — poll loop wall-clock timeout → rc=2

### TC-LCS-008 — garbage stdout (e.g. `weird`) → rc=2
**Intent**: anything other than `ALIVE`/`DEAD` is indeterminate. Pin so
a future remote snippet can't accidentally introduce a third token.

### TC-LCS-009 — shell-metachar reject (parity with `_has_shell_metachar`)
**Setup**: `SSM_REMOTE_PROJECT_DIR='/data/git/test;rm -rf /'`.

**Expected**: rc=1; aws not invoked.

### TC-LCS-010 — argv to `aws ssm send-command` carries expected args
**Expected**: argv contains `--region <SSM_REGION>`,
`--instance-ids <SSM_INSTANCE_ID>`, JSON-escaped `commands` payload
referencing `${KIND}-${ISSUE_NUM}.pid` path.

### TC-LCS-011 — argv carries `--timeout-seconds 10` by default
**Intent**: Finding 1.B from plan-eng-review.

## TC-RPA-001..010 — `pid_alive` remote-backend integration

### TC-RPA-001 — ALIVE verdict → `pid_alive` returns 0
### TC-RPA-002 — DEAD verdict → `pid_alive` returns 1
### TC-RPA-003 — indeterminate (rc=2 / empty / weird stdout) → returns **0**
**Intent**: load-bearing. Conservative-bias decision is the whole point
of the fix.
### TC-RPA-004 — `EXECUTION_BACKEND=local` → driver MUST NOT be invoked
**Intent**: regression-pin — local backend behavior unchanged.
**Setup**: stub driver via PATH override; record file must remain empty.
### TC-RPA-005 — `REMOTE_LIVENESS_CHECK_DISABLE=true` → driver NOT invoked
### TC-RPA-006 — missing `SSM_INSTANCE_ID` → driver rc=2 → ALIVE-bias
### TC-RPA-007 — `mark_stalled` under remote backend with ALIVE → defers
**Intent**: INV-26 inheritance.
### TC-RPA-008 — `_REMOTE_LIVENESS_DEGRADED_COUNT` reaches 1 on first indeterminate
**Setup**: trigger 1 indeterminate verdict.
**Expected**: counter = 1; WARN line on stderr.
### TC-RPA-009 — WARN log emitted on **first** + **10th** indeterminate; NOT on ticks 2-9
**Setup**: 11 consecutive indeterminate verdicts.
**Expected**: WARN appears for tick 1 and tick 10 only (modulo-10 cadence).
Counter reset at test setup to avoid cross-test pollution
(Finding 3.A from plan-eng-review).
### TC-RPA-010 — Source-of-truth grep
**Intent**: a future cleanup PR cannot silently change the
indeterminate→ALIVE behavior.

`grep -E '\\*\\) +return 0' lib-dispatch.sh` after the
`EXECUTION_BACKEND.*remote-aws-ssm` line must match — the indeterminate
case in the case-statement is a literal `return 0`, NOT `return 1`.

## TC-DNS-010..012 — `dev_near_success` signal 4 (process-group walk)

Mirror TC-RNS-007/008/009 from `test-dispatcher-review-near-success.sh`.

### TC-DNS-010 — pgrep finds AGENT_CMD child → returns 0
**Setup**: all 3 legacy signals negative; mock `_pgid_has_agent_process` returns 0.

**Expected**: `dev_near_success` returns 0.

### TC-DNS-011 — pgrep finds nothing AND all signals negative → returns 1
**Expected**: `dev_near_success` returns 1; the dispatcher proceeds to
declare crashed (existing path).

### TC-DNS-012 — earlier signal positive → signal 4 not consulted (ordering pin)
**Intent**: pgrep is the most expensive signal; positive earlier signal
must short-circuit before it runs. Mirror TC-RNS-009.

**Setup**: signal 2 (Session ID comment within window) positive; mock
`_pgid_has_agent_process` records call count.

**Expected**: `dev_near_success` returns 0; mock call count = 0.

## Out of scope

- Real SSM round-trip against live Singapore cloud-station (manual
  smoke test post-merge, documented in PR description, not a unit test).
- `_ssm_run_remote_command` test for retries on transient SSM throttling
  (current design: any non-2xx → rc=2 → ALIVE-bias on next tick is the
  retry mechanism). If throttling becomes a real-world hot spot, file
  follow-up issue.
