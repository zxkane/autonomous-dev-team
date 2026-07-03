# Design: raise the `SSM_COMMAND_TIMEOUT_SECONDS` default 10 → 30 (issue #369)

## Problem

`lib-ssm.sh::_ssm_run_remote_command` defaulted `--timeout-seconds` to `10` on
both the unset-env path and the non-numeric-guard fallback. AWS `ssm
send-command`'s hard API minimum for `--timeout-seconds` is `30` — any lower
value is rejected transport-side with `ParamValidation: valid min value: 30`,
**on every call**, not flakily.

Because [INV-30](../pipeline/invariants.md) biases a persistently-indeterminate
remote liveness verdict toward `ALIVE`, this produced a silent, non-recovering
deadlock: any `remote-aws-ssm` project that never overrode
`SSM_COMMAND_TIMEOUT_SECONDS` (none did) got a permanent transport failure on
every liveness/session-log probe, so `pid_alive` never returned a definitive
`DEAD` and `dispatcher-tick.sh`'s Step 5a/5b DEAD-branch label transitions
never fired. Reproduced live against a consumer project's dispatcher on
2026-07-03 — the dev wrapper had already exited and pushed a PR, but the
issue sat in `in-progress` for 16+ hours because every liveness probe
transport-failed.

## The fix

Both defaulting sites in `lib-ssm.sh` now reference a single shared
`_SSM_MIN_COMMAND_TIMEOUT_SECONDS` constant (value `30`) instead of repeating
the literal, so the two paths can't drift apart again.

```bash
_SSM_MIN_COMMAND_TIMEOUT_SECONDS=30
...
local cmd_timeout="${SSM_COMMAND_TIMEOUT_SECONDS:-$_SSM_MIN_COMMAND_TIMEOUT_SECONDS}"
[[ "$cmd_timeout" =~ ^[0-9]+$ ]] || cmd_timeout="$_SSM_MIN_COMMAND_TIMEOUT_SECONDS"
```

### Plain assignment, not `: "${VAR:=30}"` — explicit decision

The first implementation used the idempotent-resource-safe `:=` form
(`: "${_SSM_MIN_COMMAND_TIMEOUT_SECONDS:=30}"`), matching the pattern used
elsewhere in this file for genuinely operator-tunable defaults. Review caught
that this is wrong for an internal *minimum*: `:=` only assigns when the
variable is unset, so an inherited/exported
`_SSM_MIN_COMMAND_TIMEOUT_SECONDS` from the caller's environment (e.g. a
stale `export _SSM_MIN_COMMAND_TIMEOUT_SECONDS=20` left over from a prior
shell, or a future script that sets it for an unrelated reason) would win
over the constant — silently recreating #369's exact rejection via a
different variable.

**Decision: plain assignment** (`_SSM_MIN_COMMAND_TIMEOUT_SECONDS=30`).
Sourcing `lib-ssm.sh` always resets it to `30` regardless of what the
environment carries in. This is intentionally NOT `readonly` — `readonly`
errors on a second assignment, and this file is documented as safe to
re-source (multiple callers `source` it defensively); a plain assignment
stays idempotent across re-sourcing while still not being overridable from
outside the file.

This is a deliberate asymmetry with `SSM_COMMAND_TIMEOUT_SECONDS` itself
(the **operator-facing** env var), which stays a normal `${VAR:-default}`
expansion — an explicit operator override of the *timeout value* is
in-scope and intentional (see Out of Scope below); only the internal
minimum-floor *constant* must not be caller-overridable.

## Scope

**In scope**: the internal default (the `:-10` fallback when
`SSM_COMMAND_TIMEOUT_SECONDS` is unset, and the non-numeric-guard fallback)
across all four SSM transport scripts (`lib-ssm.sh`,
`liveness-check-remote-aws-ssm.sh`, `session-log-probe-remote-aws-ssm.sh`,
`dispatch-remote-aws-ssm.sh`).

**Out of scope** (per the issue):
- Validating/clamping/warning a **user-supplied** `SSM_COMMAND_TIMEOUT_SECONDS`
  value below 30 (e.g. an operator exporting `20`) — an explicit operator
  override keeps today's behavior (the native AWS API error).
- A separate consumer repo's lack of CI (a co-factor in the originally
  observed deadlock, but a different repo's config).
- INV-30's ALIVE-bias policy — unchanged, correct.
- Retroactively unblocking any other already-stuck issues beyond the one
  already manually unblocked.

## Testing

- `tests/unit/test-lib-ssm.sh`: TC-LSSM-007/008 pin the `>= 30` default on
  both defaulting paths; TC-LSSM-009 reproduces the real AWS
  `ParamValidation` rejection via a stubbed `aws` knob (and proves the
  pre-fix value of 10 DOES hit it); TC-LSSM-010 proves an
  inherited/exported `_SSM_MIN_COMMAND_TIMEOUT_SECONDS=20` does not lower
  the forwarded `--timeout-seconds` below 30 (regression for the `:=`
  review finding).
- `tests/unit/test-liveness-check-remote-aws-ssm.sh`: TC-LCS-011 pins the
  driver's default/override argv; TC-LCS-012 reproduces the real
  `ParamValidation` rejection through the actual driver entrypoint (not
  just the `lib-ssm.sh` helper), mirroring TC-LSSM-009's fixture.
- `tests/unit/test-ssm-timeout-sweep.sh`: TC-SWEEP-001..005 grep-sweep all
  four SSM transport scripts for any other sub-30 `--timeout-seconds`
  default/literal; TC-SWEEP-005c additionally pins that the shared constant
  is a plain assignment, not an overridable `:=` default.
