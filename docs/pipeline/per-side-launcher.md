# Per-Side `AGENT_LAUNCHER` Override

Spec for `AGENT_DEV_LAUNCHER` / `AGENT_REVIEW_LAUNCHER` — two new
operator knobs in `skills/autonomous-dispatcher/scripts/lib-agent.sh`
that let dev and review wrappers each have their own launcher prefix.

This doc is the authoritative contract. Implementation: lib-agent.sh
init block + the two wrappers' entry blocks. Invariant: [INV-38].

Pairs with [INV-37](invariants.md#inv-37-per-side-agent_cmd-precedence)
(per-side `AGENT_CMD` overrides, PR #156).

## Why

PR #156 introduced `AGENT_DEV_CMD` / `AGENT_REVIEW_CMD`. The
[INV-37] guard refuses `AGENT_LAUNCHER` whenever **either** per-side
CLI is non-claude — because the canonical launcher (a `cc` shell
function) is claude-specific.

That guard blocks the natural mixed-CLI deployment: claude for dev
with the Bedrock-bridge `cc` launcher, kiro/agy for review without
any launcher. The launcher's claude-specific environment
(`ANTHROPIC_DEFAULT_*`, `AWS_PROFILE=cc-tracked`,
`CLAUDE_CODE_USE_BEDROCK=1`) doesn't apply to non-claude CLIs and
would harm them if forced through.

The model knobs (`AGENT_DEV_MODEL` / `AGENT_REVIEW_MODEL`), CLI
knobs (`AGENT_DEV_CMD` / `AGENT_REVIEW_CMD`), and flag knobs
(`AGENT_DEV_EXTRA_ARGS` / `AGENT_REVIEW_EXTRA_ARGS`) already split
per side. The launcher knob is the conspicuous holdout — INV-38
closes it.

## Resolution order

```
AGENT_LAUNCHER                                  (existing project default; default empty)
  │
  ├─ AGENT_DEV_LAUNCHER     = ${AGENT_DEV_LAUNCHER:-$AGENT_LAUNCHER}
  └─ AGENT_REVIEW_LAUNCHER  = ${AGENT_REVIEW_LAUNCHER:-$AGENT_LAUNCHER}

Each side's value is tokenized into its own argv array via the same
`eval` trust model the existing AGENT_LAUNCHER tokenization uses:
  AGENT_DEV_LAUNCHER_ARGV=( ... )
  AGENT_REVIEW_LAUNCHER_ARGV=( ... )
```

After tokenization, each wrapper rebinds the existing
`AGENT_LAUNCHER_ARGV` (the array `_run_with_timeout` already reads)
to its side's array:

- `autonomous-dev.sh`     → `AGENT_LAUNCHER_ARGV=("${AGENT_DEV_LAUNCHER_ARGV[@]}")`
- `autonomous-review.sh`  → `AGENT_LAUNCHER_ARGV=("${AGENT_REVIEW_LAUNCHER_ARGV[@]}")`

This rebind happens AFTER `source lib-auth.sh` (and any other
conf-touching lib), paired with the existing `AGENT_CMD="$AGENT_DEV_CMD"` /
`"$AGENT_REVIEW_CMD"` rebind from [INV-37]. After both rebinds,
`run_agent` / `resume_agent` continue to read `$AGENT_CMD` and
`AGENT_LAUNCHER_ARGV[@]` exactly as they do today — no signature
change, no caller change, no per-CLI branch change.

> **Why "after lib-auth.sh"**: `lib-auth.sh` transitively sources
> `lib-config.sh::load_autonomous_conf` which re-sources
> `autonomous.conf`. If the rebind happened earlier, the conf's
> unconditional `AGENT_CMD="claude"` (and the per-side launcher
> defaults inside `lib-agent.sh`'s `:-` resolution) would silently
> overwrite the wrapper-level override. See INV-37 in
> `invariants.md` for the full bug narrative (discovered 2026-05-26
> via a podcast-curation review wrapper that kept invoking claude
> despite `AGENT_REVIEW_CMD=kiro`).

`:-` (not `:=`) means an explicit empty string in the conf falls
back to `AGENT_LAUNCHER`. That matches the existing semantics of
all other per-side overrides.

## Backwards compatibility

Existing deployments do not set `AGENT_DEV_LAUNCHER` /
`AGENT_REVIEW_LAUNCHER`. The defaults make both equal to the
existing `AGENT_LAUNCHER`. Each side's tokenized argv array equals
the existing `AGENT_LAUNCHER_ARGV`. The wrapper rebind is a copy
into the same variable. Result: behavior is byte-for-byte identical
to pre-change. No conf migration is required for any operator who
does not want the per-side split.

## Guard semantics

The pre-INV-38 guard ([INV-37] form) was:

```bash
if launcher non-empty AND (DEV_CMD != claude OR REVIEW_CMD != claude):
  fail
```

The post-INV-38 guard splits into two independent per-side checks:

```bash
if AGENT_DEV_LAUNCHER_ARGV non-empty AND AGENT_DEV_CMD != claude:
  fail loud, error names AGENT_DEV_LAUNCHER + AGENT_DEV_CMD
if AGENT_REVIEW_LAUNCHER_ARGV non-empty AND AGENT_REVIEW_CMD != claude:
  fail loud, error names AGENT_REVIEW_LAUNCHER + AGENT_REVIEW_CMD
```

This is **strictly more permissive** than [INV-37]'s guard — every
operator config that passed before still passes. The new "freed"
configurations are exactly the ones where one side has no launcher
and the other side runs claude with a launcher: e.g.

```
AGENT_CMD=claude
AGENT_DEV_LAUNCHER='cc...'   # claude dev with Bedrock bridge
# AGENT_REVIEW_LAUNCHER unset → defaults to AGENT_LAUNCHER (empty)
AGENT_REVIEW_CMD=kiro        # kiro review with no launcher
```

Pre-INV-38: rejected (REVIEW_CMD != claude AND launcher non-empty).
Post-INV-38: passes (REVIEW_LAUNCHER is empty, so its guard is
inert; DEV_LAUNCHER is non-empty AND DEV_CMD=claude, so its guard
passes).

The error messages are now per-side, naming both the offending
launcher and the offending CLI on that side. An operator who sets
`AGENT_DEV_LAUNCHER='cc'` while leaving `AGENT_DEV_CMD=kiro` in
place sees exactly which side broke the contract.

## What is NOT covered

- **`AGENT_LAUNCHER` (the original)** stays as the default-fallback
  source for both sides. No deprecation: operators who set just
  `AGENT_LAUNCHER` continue to work unchanged.
- **Tokenization model** is unchanged — `eval` (same trust as
  `autonomous.conf` itself), with WARN on empty-tokenize and ERROR
  on parse failure. Mirrors the existing AGENT_LAUNCHER handling.
- **Three-way split** (e.g. a separate launcher for `resume_agent`
  vs `run_agent`) is out of scope. The naming follows the side
  axis (DEV/REVIEW), not the stage axis (RUN/RESUME). The agy
  review's Finding 1 (which observes that `AGENT_*_EXTRA_ARGS` is
  mistakenly mapped by stage instead of side) is a separate
  upstream issue with a different fix shape.

## Operator-facing config

`autonomous.conf.example` gets a new comment block above the per-CLI
blocks, between the per-side `AGENT_*_EXTRA_ARGS` defaults and the
`AGENT_DEV_CMD` / `AGENT_REVIEW_CMD` block:

```bash
# AGENT_DEV_LAUNCHER / AGENT_REVIEW_LAUNCHER: per-side override of
# AGENT_LAUNCHER. Default to AGENT_LAUNCHER when unset/empty so
# existing single-launcher deployments are unaffected. Set them when
# dev and review run on different CLIs and need different launcher
# treatment — for example, claude for dev with a Bedrock-bridge
# launcher, kiro for review with no launcher:
#
#   AGENT_CMD="claude"
#   AGENT_DEV_LAUNCHER='bash -c '\''source ~/.bash_aliases && cc "$@"'\'' --'
#   AGENT_REVIEW_CMD="kiro"
#   AGENT_DEV_EXTRA_ARGS="--trust-all-tools"   # see kiro block
#
# Per-side guard (INV-38): each side's launcher is gated against
# THAT side's AGENT_CMD. AGENT_DEV_LAUNCHER non-empty requires
# AGENT_DEV_CMD=claude; AGENT_REVIEW_LAUNCHER non-empty requires
# AGENT_REVIEW_CMD=claude. Side that has no launcher is unconstrained.
# AGENT_DEV_LAUNCHER=""
# AGENT_REVIEW_LAUNCHER=""
```

## Failure modes

| Failure | Behavior |
|---|---|
| Neither override set | Both sides default to `AGENT_LAUNCHER`. Pre-change behavior. |
| Only `AGENT_DEV_LAUNCHER='cc'` set, `AGENT_REVIEW_LAUNCHER` unset, `AGENT_REVIEW_CMD=kiro` | Dev gets cc, review gets nothing. The motivating use case. |
| Only `AGENT_REVIEW_LAUNCHER` set | Symmetric — review gets the launcher, dev runs naked. |
| Both set with different values | Each side runs its declared launcher. |
| `AGENT_DEV_LAUNCHER=""` (explicit empty) | `:-` falls back to `AGENT_LAUNCHER`. Same as unset. |
| `AGENT_DEV_LAUNCHER='cc'` + `AGENT_DEV_CMD=kiro` | Per-side guard fails loud at source time, naming both `AGENT_DEV_LAUNCHER` and `AGENT_DEV_CMD=kiro`. |
| `AGENT_DEV_LAUNCHER` parses to zero argv elements (operator typo) | WARN logged (mirrors existing `AGENT_LAUNCHER` handling), treated as unset for that side. |
| `AGENT_DEV_LAUNCHER` malformed shell (eval error) | ERROR logged, exit 1 (mirrors existing `AGENT_LAUNCHER` handling). |

## Cross-references

- [INV-37](invariants.md#inv-37-per-side-agent_cmd-precedence) — per-side `AGENT_CMD`. INV-38 builds on it: the launcher guard now keys on per-side CLIs.
- [INV-31](invariants.md#inv-31-operator-tunable-per-cli-flags-live-in-conf-not-in-lib-agentsh) — operator-tunable flags live in `autonomous.conf`. The new vars follow that contract.
- [INV-13](invariants.md#inv-13-wall-clock-cap-on-agent-invocations) — wall-clock cap. Unaffected: each side's launcher still runs inside `_run_with_timeout` exactly as before.
- [`docs/pipeline/per-side-agent-cmd.md`](per-side-agent-cmd.md) — sister spec for [INV-37].

## Test coverage

New file `tests/unit/test-lib-agent-per-side-launcher.sh` covers:

| Test | Asserts |
|---|---|
| PSL-S1 | Default — neither override set, AGENT_LAUNCHER unset → both `AGENT_*_LAUNCHER_ARGV` empty |
| PSL-S2 | Back-compat — only `AGENT_LAUNCHER='cc'` set → `AGENT_DEV_LAUNCHER_ARGV == AGENT_REVIEW_LAUNCHER_ARGV == AGENT_LAUNCHER_ARGV` byte-identical |
| PSL-S3 | Only `AGENT_DEV_LAUNCHER='cc'` set → DEV ARGV=cc, REVIEW ARGV empty |
| PSL-S4 | Only `AGENT_REVIEW_LAUNCHER='cc'` set → DEV ARGV empty, REVIEW ARGV=cc |
| PSL-S5 | Both set with different values → each side runs its declared launcher |
| PSL-S6 | `AGENT_DEV_LAUNCHER` non-empty + `AGENT_DEV_CMD=claude` → source succeeds (per-side guard pass) |
| PSL-S7 | `AGENT_DEV_LAUNCHER` non-empty + `AGENT_DEV_CMD=kiro` → source fails, error names `AGENT_DEV_LAUNCHER` and `AGENT_DEV_CMD=kiro` |
| PSL-S8 | `AGENT_REVIEW_LAUNCHER` non-empty + `AGENT_REVIEW_CMD=agy` → source fails, error names `AGENT_REVIEW_LAUNCHER` and `AGENT_REVIEW_CMD=agy` |
| PSL-S9 | Structural — `autonomous-dev.sh` rebinds `AGENT_LAUNCHER_ARGV=("${AGENT_DEV_LAUNCHER_ARGV[@]}")` AFTER `source lib-auth.sh` (the position that survives the conf re-source, post-INV-37 fix on 2026-05-26) |
| PSL-S10 | Structural — `autonomous-review.sh` rebinds `AGENT_LAUNCHER_ARGV=("${AGENT_REVIEW_LAUNCHER_ARGV[@]}")` AFTER `source lib-auth.sh` (same reason as PSL-S9) |
| (test-wrapper-rebind-order) | Behavioral regression in `tests/unit/test-wrapper-rebind-order.sh` — simulates wrapper source order with a sandbox conf and asserts both `AGENT_CMD` and `AGENT_LAUNCHER_ARGV` survive lib-auth's conf re-source. T1 dev / T2 review. T2 is the direct repro of podcast-curation #333/#334. |

PSL-S9/S10 are structural greps — same approach as PSC-S9/S10
([INV-37]'s structural tests), with widened windows to accommodate
the additional rebind line.

## Existing-test impact

PR #156 added PSC-S6/S7/S8/S11 in `tests/unit/test-lib-agent-per-side-cmd.sh`
that exercise the [INV-37] launcher guard's "both sides claude" form.
After this PR, those tests still pass — but their assertion-message
text needs updating to match the new per-side error format.
Specifically:

- PSC-S7 currently asserts `AGENT_LAUNCHER` + `AGENT_REVIEW_CMD=agy`
  → error contains `AGENT_REVIEW_CMD=agy`. Post-INV-38 the guard
  still fires on that combination (because `AGENT_REVIEW_LAUNCHER`
  defaults to `AGENT_LAUNCHER`, which is non-empty), and the error
  message now mentions `AGENT_REVIEW_LAUNCHER` instead of
  `AGENT_LAUNCHER`. Update the assertion needle.
- PSC-S8 / PSC-S11 same pattern.
- PSC-S6 (both sides claude) still passes verbatim.

## Implementation order

1. lib-agent.sh: add `AGENT_DEV_LAUNCHER` / `AGENT_REVIEW_LAUNCHER`
   init + tokenization after the existing `AGENT_LAUNCHER` block;
   replace the [INV-37] guard with two per-side guards.
2. autonomous-dev.sh: add `AGENT_LAUNCHER_ARGV=("${AGENT_DEV_LAUNCHER_ARGV[@]}")`
   immediately after the existing `AGENT_CMD="$AGENT_DEV_CMD"` line —
   which itself sits AFTER `source lib-auth.sh` (per the INV-37 fix
   on 2026-05-26). PSL-S9 asserts placement structurally.
3. autonomous-review.sh: symmetric, using `AGENT_REVIEW_LAUNCHER_ARGV`,
   after `source lib-auth.sh` + `lib-review-bots.sh` + `lib-review-verdict.sh`.
   PSL-S10 asserts placement structurally.
4. autonomous.conf.example: add the operator-facing comment block.
5. tests/unit/test-lib-agent-per-side-launcher.sh: ten test cases.
6. tests/unit/test-lib-agent-per-side-cmd.sh: update PSC-S7/S8/S11
   assertion needles to match the new per-side error messages.
7. invariants.md: add INV-38; INV-37 cross-reference updated.
