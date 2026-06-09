# Test Cases: codex resume honors the per-agent review extra-args override

**Issue**: #212
**Invariant**: [INV-41](../pipeline/invariants.md#inv-41-per-agent-review-model--extra-args-resolution) (fix in place — no new INV number)
**Test files**:
- `tests/unit/test-lib-review-codex.sh` — codex `exec resume` argv + sibling isolation
- `tests/unit/test-autonomous-review-per-agent-model.sh` — source-of-truth grep (dual-var alias)

## Background

`run_agent` (turn 1, a fresh session) tokenizes **`AGENT_DEV_EXTRA_ARGS`**
(`lib-agent.sh:726`); `resume_agent` (subsequent turns) tokenizes
**`AGENT_REVIEW_EXTRA_ARGS`** (`lib-agent.sh:942`) — two *different* variables for
the same concept. The review fan-out resolves the per-agent value
(`_resolve_review_agent_extra_args`) and, before the fix, aliased it onto **only**
`AGENT_DEV_EXTRA_ARGS`.

The codex review lane is the one CLI that **resumes**: on a non-trivial diff its
first `codex exec` turn is spent gathering (reading the skill, the inlined diff),
so `lib-review-codex.sh::_run_codex_review_with_resume` calls `resume_agent`
(`lib-review-codex.sh:322`) to drive codex to a verdict. On resume,
`resume_agent` read the **shared** `AGENT_REVIEW_EXTRA_ARGS` — the per-agent
`_CODEX` override was lost. A project whose dev side is kiro sets a shared
`AGENT_REVIEW_EXTRA_ARGS="--trust-all-tools"` (kiro denies tools without it);
codex's `exec resume` rejects `--trust-all-tools` with exit 2, every resume turn
fails, and codex is dropped as `unavailable` on every review.

**Fix (Option 1, wrapper layer)**: assign the resolved per-agent review extra-args
to **both** `AGENT_DEV_EXTRA_ARGS` (turn 1) and `AGENT_REVIEW_EXTRA_ARGS` (resume),
inside the per-agent subshell, so the per-agent override survives every turn.

## Acceptance: every TC below must pass; full unit suite remains green.

| TC ID | Scenario | Expected |
|---|---|---|
| TC-CXR-XA-01 | codex `resume_agent` with `AGENT_REVIEW_EXTRA_ARGS_CODEX="-s danger-full-access"` resolved by the per-agent subshell (both vars assigned) and a *different* shared `AGENT_REVIEW_EXTRA_ARGS="--trust-all-tools"` | `codex exec resume` argv contains `-s danger-full-access` (per-agent) and does NOT contain `--trust-all-tools` (shared) |
| TC-CXR-XA-02 | "shared only, no per-agent key": `AGENT_REVIEW_EXTRA_ARGS="--shared-flag"`, no `_CODEX` key; subshell resolves + assigns both vars | `codex exec resume` argv contains `--shared-flag` (no regression for kiro/agy which resume via the shared value) |
| TC-CXR-XA-03 | Regression: pre-fix `--trust-all-tools` only on `AGENT_REVIEW_EXTRA_ARGS` (the dev-side alias does NOT reach `resume_agent`) reproduces a codex resume argv carrying `--trust-all-tools` → exit 2; after the fix the per-agent `_CODEX` value reaches resume and `--trust-all-tools` is absent | codex resume argv carries the per-agent value, NOT the rejected shared flag |
| TC-CXR-XA-ISO-01 | Sibling isolation: the per-agent subshell assigns `AGENT_REVIEW_EXTRA_ARGS` (a var the parent also reads). A codex subshell's `_CODEX` value must NOT leak into a sibling kiro/agy subshell nor back into the parent | after a codex subshell exits, the parent's `AGENT_REVIEW_EXTRA_ARGS` is unchanged; a sibling kiro subshell resolves only its own value |
| TC-PAM-SRC-05b | Source-of-truth: the wrapper aliases the resolved review extra-args onto **both** `AGENT_DEV_EXTRA_ARGS` AND `AGENT_REVIEW_EXTRA_ARGS` | grep finds both assignments fed by `_resolve_review_agent_extra_args` |

## Why subshell scoping is the one real correctness risk

The fix writes `AGENT_REVIEW_EXTRA_ARGS` — a variable the **parent** fan-out loop
also reads (e.g. when the resolver `:-`-falls-back to it). Each fan-out member runs
in its own `( … )` subshell, so an assignment inside one subshell cannot mutate the
parent or a sibling. TC-CXR-XA-ISO-01 pins this explicitly: it runs the assignment
in a subshell and asserts neither the parent's value nor a sibling subshell's
resolution is affected.

## Backward compatibility (the carve-out)

- All per-agent keys unset, `AGENT_REVIEW_EXTRA_ARGS=""` → both vars assigned `""`;
  argv byte-for-byte today's. No CLI other than codex resumes, so the new
  `AGENT_REVIEW_EXTRA_ARGS` assignment is inert for kiro/agy/claude/gemini in the
  fan-out (they only ever call `run_agent`, which reads `AGENT_DEV_EXTRA_ARGS`).
- kiro/agy with a shared `AGENT_REVIEW_EXTRA_ARGS` set: their `run_agent` turn-1
  argv is unchanged (still driven by the `AGENT_DEV_EXTRA_ARGS` alias); they never
  resume, so the additional `AGENT_REVIEW_EXTRA_ARGS` assignment changes nothing
  observable for them.

## Out of scope (confirmed no change)

- `lib-agent.sh` — the lib-layer `run_agent`/`resume_agent` var mismatch is the
  deeper smell; unifying it has a second caller (dev-resume,
  `autonomous-dev.sh:734`) and is deferred to a separate follow-up issue.
- The `autonomous-dev.sh` dev-resume path — out of scope; the corrected comment is
  scoped to the review fan-out only.
- `state-machine.md` / `handoffs.md` — no label or handoff changes.
