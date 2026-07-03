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
bash tests/unit/test-ssm-timeout-sweep.sh  # #369 grep-sweep
```

## TC-LSSM-001..010 — `lib-ssm.sh` (extracted from `dispatch-remote-aws-ssm.sh`)

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

### TC-LSSM-007 — default `cmd_timeout` (env unset) is `>= 30` (#369)
**Intent**: AWS ssm send-command's hard API minimum for `--timeout-seconds`
is 30; the prior default of 10 guaranteed a transport-side
`ParamValidation` rejection on every unset-env call.

**Setup**: `SSM_COMMAND_TIMEOUT_SECONDS` unset; stub `aws` records argv.

**Expected**: recorded send-command argv contains `--timeout-seconds 30`.

### TC-LSSM-008 — non-numeric `SSM_COMMAND_TIMEOUT_SECONDS` guard fallback is `>= 30` (#369)
**Intent**: `lib-ssm.sh`'s non-numeric guard has its own literal fallback,
separate from the unset-env default. Both must be `>= 30` or a garbage
env value still produces the rejected value.

**Setup**: `SSM_COMMAND_TIMEOUT_SECONDS=not-a-number`; stub `aws` records
argv.

**Expected**: recorded send-command argv contains `--timeout-seconds 30`.

### TC-LSSM-009 — stubbed real AWS `ParamValidation` rejection for `--timeout-seconds < 30` (#369)
**Intent**: reproduce the actual AWS CLI rejection observed in #369
(`ParamValidation: valid min value: 30`) rather than a generic stub
failure, and prove the fixed default never hits it — while proving the
pre-fix value of 10 DOES hit it against the same stub (so the stub is
faithful and this test would have failed before the fix).

**Setup**: stub `aws send-command` to inspect the `--timeout-seconds`
value in argv and emit the real `ParamValidation` error text + a
non-`Command.CommandId`-bearing failure when it is `< 30`.

**Expected**: fixed default (env unset) → rc=0, no `ParamValidation` in
stderr. Pre-fix value (`SSM_COMMAND_TIMEOUT_SECONDS=10`) → rc=2.

### TC-LSSM-010 — inherited/exported `_SSM_MIN_COMMAND_TIMEOUT_SECONDS` below 30 does NOT win (2026-07-03 review)
**Intent**: codex review finding on #369 — the constant was originally
`: "${_SSM_MIN_COMMAND_TIMEOUT_SECONDS:=30}"` (default-if-unset), which
lets an inherited/exported value from the caller's environment win over
the constant, silently recreating the rejection via a different
variable. Fixed by making it a plain assignment, always reset on source.

**Setup**: `_SSM_MIN_COMMAND_TIMEOUT_SECONDS=20` exported into the
sourcing shell BEFORE `lib-ssm.sh` is sourced; `SSM_COMMAND_TIMEOUT_SECONDS`
unset.

**Expected**: recorded send-command argv still contains
`--timeout-seconds 30` (the inherited `20` does not win).

## TC-SWEEP-001..005 — `test-ssm-timeout-sweep.sh` (repo-wide grep-sweep, #369)

Sweeps all four SSM transport files
(`lib-ssm.sh`, `liveness-check-remote-aws-ssm.sh`,
`session-log-probe-remote-aws-ssm.sh`, `dispatch-remote-aws-ssm.sh`) for
any OTHER hardcoded or defaulted `--timeout-seconds` value below 30, per
the issue's explicit testing requirement. Out of scope (per the issue):
a user-supplied env override below 30 — only internal defaults are
checked.

### TC-SWEEP-001 — all four transport files exist
### TC-SWEEP-002 — no `${SSM_COMMAND_TIMEOUT_SECONDS:-N}` default below 30
### TC-SWEEP-003 — no `cmd_timeout` non-numeric-guard fallback below 30
**Scope note**: deliberately excludes the sibling `poll_timeout` fallback
(`REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS`) — that is a dispatcher-side
wall-clock polling cap, unrelated to AWS's `--timeout-seconds` API
minimum.
### TC-SWEEP-004 — no hardcoded `--timeout-seconds` literal below 30 in argv
### TC-SWEEP-005 — `lib-ssm.sh` source-of-truth pin (load-bearing, mirrors TC-RPA-010's style)
### TC-SWEEP-005c — constant is a plain assignment, not an overridable `:=` default (2026-07-03 review)
**Intent**: pins the codex review finding's fix at the static level —
a reflexive cleanup PR reintroducing `: "${_SSM_MIN_COMMAND_TIMEOUT_SECONDS:=30}"`
is caught by grep even without running the runtime TC-LSSM-010 case.

## TC-LCS-001..012 — `liveness-check-remote-aws-ssm.sh`

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

### TC-LCS-011 — argv carries `--timeout-seconds 30` by default
**Intent**: Finding 1.B from plan-eng-review; raised from 10 to 30 in #369
(AWS ssm send-command's hard API minimum for `--timeout-seconds` — any
value below 30 is rejected transport-side with `ParamValidation` on
every call, producing a permanent indeterminate liveness verdict).

### TC-LCS-012 — driver-level fixture reproduces the real `ParamValidation` rejection (2026-07-03 review)
**Intent**: TC-LSSM-009 (`test-lib-ssm.sh`) already proves this at the
`lib-ssm.sh` helper level; this reproduces it through the ACTUAL
`liveness-check-remote-aws-ssm.sh` driver entrypoint, per the 2026-07-03
review finding that only a helper-level regression existed.

**Setup**: stub `aws send-command` inspects `--timeout-seconds` in argv
and emits the real `ParamValidation` error text when it is `< 30`.

**Expected**: fixed default (env unset) → rc=0, definitive `ALIVE`
verdict, no `ParamValidation` in stderr. Pre-fix value
(`SSM_COMMAND_TIMEOUT_SECONDS=10`) → rc=2.

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
