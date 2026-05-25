# Per-Side `AGENT_CMD` Override

Spec for `AGENT_DEV_CMD` and `AGENT_REVIEW_CMD` — two new operator
knobs in `skills/autonomous-dispatcher/scripts/lib-agent.sh` that
let the dev wrapper and the review wrapper run on different agent
CLIs in the same project.

This doc is the authoritative contract. Implementation: lib-agent.sh
init block, autonomous-dev.sh / autonomous-review.sh entry blocks.
Invariant: [INV-37](invariants.md#inv-37-per-side-agent_cmd-precedence).

## Why

Today `AGENT_CMD` is a single project-wide value: dev and review use
the same CLI. The model knobs already split (`AGENT_DEV_MODEL` /
`AGENT_REVIEW_MODEL`); the CLI knob does not. That blocks deployments
that want to use one CLI for the heavy dev work and a cheaper or
specialized CLI for review — for example, claude (Opus, expensive)
for dev, agy (cheaper, smaller-context) for review.

Adding a per-side override is mechanically small (the seam is one
variable read in two case statements) and naming follows the
existing `AGENT_DEV_*` / `AGENT_REVIEW_*` precedent.

## Resolution order

```
AGENT_CMD                                       (project default; default "claude")
  │
  ├─ AGENT_DEV_CMD     = ${AGENT_DEV_CMD:-$AGENT_CMD}
  └─ AGENT_REVIEW_CMD  = ${AGENT_REVIEW_CMD:-$AGENT_CMD}
```

Then each wrapper sets `AGENT_CMD` to its side's value:

- `autonomous-dev.sh`     → `AGENT_CMD="$AGENT_DEV_CMD"`
- `autonomous-review.sh`  → `AGENT_CMD="$AGENT_REVIEW_CMD"`

After that line, the rest of `lib-agent.sh` (case statements, log
messages, the AGENT_LAUNCHER guard) keeps reading `$AGENT_CMD` —
no signature changes, no caller changes, no per-CLI branch changes.

`:-` (not `:=`) means an explicit empty string in the conf falls
back to `AGENT_CMD`. That matches the existing semantics of
`AGENT_DEV_MODEL` / `AGENT_REVIEW_MODEL`.

## Backwards compatibility

Existing deployments do not set `AGENT_DEV_CMD` or `AGENT_REVIEW_CMD`.
The defaults make both equal to whatever `AGENT_CMD` was, so behavior
is byte-for-byte identical to pre-change. No conf migration is
required for any operator who does not want the per-side split.

## `AGENT_LAUNCHER` interaction

`AGENT_LAUNCHER` is currently rejected unless `AGENT_CMD == claude`
(lib-agent.sh:106-108). The launcher is a `cc` shell function that
ends in `$CLAUDE_CMD "$@"` — pointing it at codex / kiro / opencode
would silently produce `claude codex …` and fail.

The new check generalizes that gate to both sides:

```bash
if [[ ${#AGENT_LAUNCHER_ARGV[@]} -gt 0 ]]; then
  if [[ "$AGENT_DEV_CMD" != "claude" || "$AGENT_REVIEW_CMD" != "claude" ]]; then
    echo "[lib-agent] ERROR: AGENT_LAUNCHER is only supported when both AGENT_DEV_CMD and AGENT_REVIEW_CMD are claude (got AGENT_DEV_CMD=${AGENT_DEV_CMD}, AGENT_REVIEW_CMD=${AGENT_REVIEW_CMD}). Either unset AGENT_LAUNCHER or write a launcher tailored to your CLI." >&2
    return 1 2>/dev/null || exit 1
  fi
fi
```

The error message names both vars so an operator who sets
`AGENT_REVIEW_CMD=agy` while leaving an inherited claude launcher in
place sees exactly which side broke the contract.

This is **strictly more permissive** than the old check: it still
allows the launcher under the "single AGENT_CMD=claude" pattern (both
sides resolve to claude), and it correctly rejects every previously-
rejected combination. No existing operator config goes from passing
to failing.

## What is NOT covered

- **`AGENT_PERMISSION_MODE`** (claude-only flag) stays shared. If an
  operator runs review on a non-claude CLI they likely don't need
  per-side `AGENT_PERMISSION_MODE` — every other CLI ignores it.
- **`KIRO_AGENT_NAME`** stays shared. Splitting it would only help an
  operator running both wrappers under kiro with different agent
  configs — vanishingly rare; out of scope.
- **`AGENT_TIMEOUT`** stays shared. Wall-clock cap is per-process
  policy, not per-CLI behavior.
- **`AGENT_DEV_EXTRA_ARGS` / `AGENT_REVIEW_EXTRA_ARGS`** already
  split. Operator can already override per-side flags via these.

## Operator-facing config

`autonomous.conf.example` gets a new comment block above the per-CLI
blocks (after the `AGENT_PERMISSION_MODE` line, before the per-CLI
blocks):

```bash
# AGENT_DEV_CMD / AGENT_REVIEW_CMD: per-side override of AGENT_CMD.
# Default to AGENT_CMD when unset/empty, so existing single-CLI
# deployments are unaffected. Set them when you want dev and review
# to run on different CLIs — for example, claude for the heavy dev
# work and agy for the cheaper review pass:
#
#   AGENT_CMD="claude"           # also used by anything not split
#   AGENT_REVIEW_CMD="agy"       # only review goes to agy
#   AGENT_DEV_MODEL="opus[1m]"
#   AGENT_REVIEW_MODEL=""        # ignored by agy (warns), see agy block
#
# AGENT_LAUNCHER (claude-only) is rejected when either side resolves
# to a non-claude CLI. Either unset the launcher or keep both sides
# on claude.
# AGENT_DEV_CMD=""
# AGENT_REVIEW_CMD=""
```

## Failure modes

| Failure | Behavior |
|---|---|
| Neither override set | Both wrappers use `$AGENT_CMD`. Pre-change behavior. |
| Only `AGENT_REVIEW_CMD=agy` set | Dev uses `$AGENT_CMD` (unchanged), review uses `agy`. The podcast-curation use case. |
| Only `AGENT_DEV_CMD=codex` set | Dev uses `codex`, review uses `$AGENT_CMD`. Symmetric. |
| Both set, both non-empty | Each side runs its declared CLI. `$AGENT_CMD` is effectively unused (the dispatcher script's `AGENT_CMD=…` line still resolves it for log breadcrumbs). |
| `AGENT_DEV_CMD=""` (explicit empty) | Falls back to `$AGENT_CMD` via `:-`. Same as unset. |
| `AGENT_LAUNCHER` non-empty + either side ≠ claude | `lib-agent.sh` fails loud at source time, naming both `AGENT_DEV_CMD` and `AGENT_REVIEW_CMD` so the operator can tell which side tripped it. |

## Cross-references

- [INV-31](invariants.md#inv-31-operator-tunable-per-cli-flags-live-in-conf-not-in-lib-agentsh) — operator-tunable flags live in conf. The new vars follow that rule.
- [INV-37](invariants.md#inv-37-per-side-agent_cmd-precedence) — the precedence rule formalized.
- [`agy-cli-support.md`](agy-cli-support.md) — the most likely review-side CLI today and the motivating example.
- `dev-agent-flow.md` and `review-agent-flow.md` — both consumers; neither needs a code change because the `run_agent` / `resume_agent` interface is unchanged.

## Test coverage

New file `tests/unit/test-lib-agent-per-side-cmd.sh` covers ten cases:

| Test | Asserts |
|---|---|
| PSC-S1 | Default — neither override set → both resolve to `${AGENT_CMD:-claude}` |
| PSC-S2 | Only `AGENT_REVIEW_CMD=agy` → dev=claude, review=agy |
| PSC-S3 | Only `AGENT_DEV_CMD=codex` → dev=codex, review=claude |
| PSC-S4 | Both set (`dev=codex`, `review=agy`, `AGENT_CMD=claude`) → each side runs its declared CLI |
| PSC-S5 | `AGENT_DEV_CMD=""` (explicit empty) falls back to `$AGENT_CMD` |
| PSC-S6 | `AGENT_LAUNCHER` non-empty + both sides claude → source succeeds |
| PSC-S7 | `AGENT_LAUNCHER` + dev=claude review=agy → source fails with error naming `AGENT_REVIEW_CMD=agy` |
| PSC-S8 | `AGENT_LAUNCHER` + dev=codex review=claude → source fails naming `AGENT_DEV_CMD=codex` |
| PSC-S9 | Structural — `autonomous-dev.sh` contains the line `AGENT_CMD="$AGENT_DEV_CMD"` immediately after `source ${SCRIPT_DIR}/lib-agent.sh` (with at most one blank line of separation) |
| PSC-S10 | Structural — `autonomous-review.sh` contains the line `AGENT_CMD="$AGENT_REVIEW_CMD"` immediately after the lib-agent.sh source line |

PSC-S1..S8 are behavioral tests that source `lib-agent.sh` directly in
a sandbox and assert the resulting variable values. PSC-S9 and PSC-S10
are structural greps because the wrappers are heavy scripts (GitHub
auth, PID guard, state IO) that can't be sourced cleanly in unit-test
isolation; the structural check is sufficient to catch a regression
where someone accidentally drops or moves the override line.

## Implementation order

1. Lib-agent.sh: add `AGENT_DEV_CMD` / `AGENT_REVIEW_CMD` after the
   existing `AGENT_CMD="${AGENT_CMD:-claude}"` line; rewrite the
   AGENT_LAUNCHER guard to check both sides.
2. autonomous-dev.sh: one-line `AGENT_CMD="$AGENT_DEV_CMD"` after
   `source lib-agent.sh`.
3. autonomous-review.sh: one-line `AGENT_CMD="$AGENT_REVIEW_CMD"` after
   `source lib-agent.sh`.
4. autonomous.conf.example: add the operator-facing comment block.
5. tests/unit/test-lib-agent-per-side-cmd.sh: ten test cases.
6. invariants.md: INV-37 entry.
7. agy-cli-support.md: small note in §Operator-facing config that
   the agy block can be combined with `AGENT_DEV_CMD=claude` for the
   "claude-dev / agy-review" deployment pattern.
