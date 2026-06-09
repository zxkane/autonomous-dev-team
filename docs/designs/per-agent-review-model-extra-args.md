# Design: per-agent model + extra-args for the multi-agent review fan-out (#168)

## Problem

The INV-40 multi-agent review fan-out (`AGENT_REVIEW_AGENTS`, #166/#167) runs N
verdict-reaching agents in parallel, but passes **the same** model and the same
extra-args to every one:

- model: `autonomous-review.sh` calls `run_agent "$_agent_session_id" "$_agent_prompt" "${AGENT_REVIEW_MODEL:-sonnet}" ...` inside the per-agent subshell — every agent gets `${AGENT_REVIEW_MODEL:-sonnet}`.
- extra-args: `run_agent` (lib-agent.sh) tokenizes a single shared variable.

This breaks the moment two listed CLIs expect **different model namespaces**.
Concrete live case: a `"kiro <claude-fam>"` fan-out wants kiro on
`claude-sonnet-4.6` (kiro-cli's id) and the claude-family agent on `sonnet[1m]`
(the claude/agy id). The two ids are mutually incompatible — kiro rejects
`sonnet[1m]`, claude rejects `claude-sonnet-4.6`. With one shared model the
operator must pick one and accept the other agent fails to launch (→ dropped as
unavailable) or silently ignores it. Per-agent extra-args has the same shape
(one agent wants `--trust-all-tools`, another `--approval-mode yolo`).

This is the follow-up explicitly deferred in #166
(`autonomous.conf.example`: "All listed agents currently share
`AGENT_REVIEW_MODEL` (per-agent model/extra-args is a documented follow-up).").

## Locked design decisions (from the issue)

1. **Naming** — per-agent override keys extend the flat `AGENT_REVIEW_*`
   convention with an uppercased agent-name suffix (non-alphanumeric → `_`):
   - `AGENT_REVIEW_MODEL_<AGENT>` (e.g. `AGENT_REVIEW_MODEL_KIRO="claude-sonnet-4.6"`)
   - `AGENT_REVIEW_EXTRA_ARGS_<AGENT>` (e.g. `AGENT_REVIEW_EXTRA_ARGS_KIRO="--trust-all-tools"`)
2. **Fallback** — when a per-agent key is unset/empty, the agent falls back to
   the shared `AGENT_REVIEW_MODEL` / `AGENT_REVIEW_EXTRA_ARGS`, which itself
   falls back to the lib default (`sonnet` for model, empty for extra-args). An
   all-unset config is byte-for-byte today's behavior.
3. **Scope** — per-subshell only. Inside the existing fan-out subshell (which
   already overrides `AGENT_CMD="$_agent"` and neutralizes the launcher for
   non-claude members, INV-38), resolve the effective model + extra-args for
   that agent and pass/export them so `run_agent` → `lib-agent.sh` picks them
   up. No change to the dev side, dispatcher, `reviewing` label, or
   `review-<N>.pid`.
4. **agy still warns** — passing a resolved model to agy keeps the existing
   "agy ignores `--model` (warns once)" behavior. Per-agent model simply makes
   the resolved value correct for the CLIs that DO consume it.

   > **Superseded by [INV-50] (#190):** agy now honors `--model`, validated
   > against `agy models`. `AGENT_REVIEW_MODEL_AGY` is the per-agent key that
   > gives agy a valid *agy-namespace* model; an unknown id is omitted with a
   > WARN (agy would otherwise silently run its default). See
   > [`docs/pipeline/invariants.md` INV-50](../pipeline/invariants.md#inv-50-agy---model-is-validated-against-agy-models-before-forwarding).

## The extra-args plumbing reality (key implementation note)

The review fan-out calls **`run_agent`** (a fresh session), and `run_agent`
tokenizes **`AGENT_DEV_EXTRA_ARGS`** — NOT `AGENT_REVIEW_EXTRA_ARGS`. Only
`resume_agent` reads `AGENT_REVIEW_EXTRA_ARGS`, and the review wrapper never
calls `resume_agent`. (`autonomous.conf.example`, kiro block: "kiro's
resume_agent falls through to run_agent ... and reads `AGENT_DEV_EXTRA_ARGS`,
so setting `AGENT_REVIEW_EXTRA_ARGS` is generally unnecessary for kiro.")

So for the per-agent extra-args to actually take effect on the review side, the
resolved value must end up in the variable `run_agent` reads. The resolver
reads the operator-facing **review** knobs (`AGENT_REVIEW_EXTRA_ARGS_<AGENT>` →
`AGENT_REVIEW_EXTRA_ARGS`) — that's the documented, intuitive operator surface
— and the wrapper subshell assigns the resolved string to `AGENT_DEV_EXTRA_ARGS`
(the var `run_agent` consumes) before calling `run_agent`. The assignment is
**inside the subshell**, so it cannot leak to the dev side or to other agents'
subshells.

## Architecture

A new pure-helper lib `lib-review-resolve.sh` (mirrors `lib-review-aggregate.sh`
/ `lib-review-verdict.sh`): sourced by `autonomous-review.sh`, unit-tested in
isolation. Three pure functions:

```
_review_agent_key_suffix <name>              # agy → AGY, kiro → KIRO, claude-code → CLAUDE_CODE
_resolve_review_agent_model <name>           # AGENT_REVIEW_MODEL_<SUF> → AGENT_REVIEW_MODEL → (caller defaults to sonnet)
_resolve_review_agent_extra_args <name>      # AGENT_REVIEW_EXTRA_ARGS_<SUF> → AGENT_REVIEW_EXTRA_ARGS
```

- `_review_agent_key_suffix`: uppercase, then map every char outside `[A-Z0-9]`
  to `_`. Pure string transform, no env reads. This is the unit-of-test the
  issue calls out (`agy`→`AGY`, `kiro`→`KIRO`, `claude-code`→`CLAUDE_CODE`).
- `_resolve_review_agent_model`: looks up `AGENT_REVIEW_MODEL_<SUF>` (the
  per-agent key) via indirect expansion; if unset/empty, falls back to
  `AGENT_REVIEW_MODEL`. Echoes the resolved value (may be empty if the shared
  value is also empty; the caller applies the `:-sonnet` lib default exactly as
  the legacy `run_agent` arg did, so the resolver itself stays a pure
  precedence function).
- `_resolve_review_agent_extra_args`: same precedence over the extra-args keys.
  May echo empty (the common default).

### Wiring into the fan-out subshell

Inside the existing `for _agent in "${REVIEW_AGENTS_LIST[@]}"; do ( ... ) &`
subshell, after the `AGENT_CMD="$_agent"` / launcher-neutralization lines and
before the `run_agent` call:

```bash
# Per-agent model + extra-args resolution (INV-41, #168). Resolves the
# per-agent override key, else the shared review value. Scope is this
# subshell only.
_agent_model=$(_resolve_review_agent_model "$_agent")
AGENT_DEV_EXTRA_ARGS=$(_resolve_review_agent_extra_args "$_agent")   # run_agent reads AGENT_DEV_EXTRA_ARGS
run_agent "$_agent_session_id" "$_agent_prompt" "${_agent_model:-sonnet}" "$_agent_session_name" \
  >>"$_agent_log" 2>&1 || _rc=$?
```

The model arg changes from the literal `${AGENT_REVIEW_MODEL:-sonnet}` to
`${_agent_model:-sonnet}` — `_agent_model` is the per-agent resolution that
falls back to `AGENT_REVIEW_MODEL`, so when no per-agent key is set the value is
identical to today's `${AGENT_REVIEW_MODEL:-sonnet}`.

## Backward compatibility (the carve-out)

- All per-agent keys unset → `_resolve_review_agent_model` returns
  `$AGENT_REVIEW_MODEL` (default `sonnet` via lib-agent.sh), so the
  `run_agent` model arg equals today's `${AGENT_REVIEW_MODEL:-sonnet}`.
- `_resolve_review_agent_extra_args` returns `$AGENT_REVIEW_EXTRA_ARGS`
  (default empty). Today the fan-out never set `AGENT_DEV_EXTRA_ARGS` away from
  the operator's value inside the subshell; assigning it the *resolved review*
  value is the intentional new behavior, but with all keys unset and
  `AGENT_REVIEW_EXTRA_ARGS=""` the assigned value is `""`. Note: this changes
  the review subshell so that the **operator-facing review** knob
  (`AGENT_REVIEW_EXTRA_ARGS`) finally takes effect on the review side (it was
  silently ignored before — see the plumbing note). For an all-default config
  both are empty so argv is byte-for-byte unchanged.
- N=1 (`AGENT_REVIEW_AGENTS` unset) → `REVIEW_AGENTS_LIST=("$AGENT_CMD")`, the
  single subshell resolves the same shared values, identical to legacy.

## Invariant

New **INV-41** (per-agent review model / extra-args resolution), cross-referenced
from INV-40. Distinct concern from INV-40 (attribution + aggregation): INV-41 is
the per-agent *resolution precedence* contract. Documents the key-suffix
normalization, the two-level fallback, the `AGENT_DEV_EXTRA_ARGS` plumbing on the
review side, and the all-unset / N=1 byte-for-byte carve-out.

## Out of scope (confirmed no change)

- `handoffs.md` — fan-out stays internal to the wrapper; no handoff contract
  changes. (Note "no change".)
- `state-machine.md` — no label transition changes. (Note "no change".)
- Dev side, dispatcher, `review-<N>.pid`, `reviewing` label.

---

## #212 addendum: the resolved extra-args must reach `resume_agent` too

**Bug found after #168 shipped.** `run_agent` (turn 1) tokenizes
`AGENT_DEV_EXTRA_ARGS`; `resume_agent` (subsequent turns) tokenizes
`AGENT_REVIEW_EXTRA_ARGS` — two different vars for the same concept. The #168
wiring aliased the resolved per-agent value onto **only** `AGENT_DEV_EXTRA_ARGS`,
justified by "the review wrapper never resumes". That justification is **false
for codex**: the codex lane's gather-only turns route through
`lib-review-codex.sh::_run_codex_review_with_resume`, which calls `resume_agent`
(INV-51). On resume, `resume_agent` read the **shared** `AGENT_REVIEW_EXTRA_ARGS`,
dropping the per-agent `AGENT_REVIEW_EXTRA_ARGS_CODEX` override. A "dev=kiro,
review fleet includes codex" project sets a shared
`AGENT_REVIEW_EXTRA_ARGS="--trust-all-tools"` (kiro's flag); `codex exec resume`
rejects it with exit 2, every resume fails, and codex is dropped `unavailable` on
every review. A claude-dev project sets no shared review var, so its codex resume
read an empty shared value and ran clean — hence "flaky on host X, fine on host Y".

**Fix (Option 1, wrapper layer).** Resolve the per-agent review extra-args ONCE
(`_resolved_review_extra_args`) inside the per-agent subshell and assign it to
**both** `AGENT_DEV_EXTRA_ARGS` and `AGENT_REVIEW_EXTRA_ARGS`. Wrapper-local,
zero dev-side blast radius, keeps per-agent resolution where the model/launcher
overrides already live.

**Subshell scoping (the one real correctness risk).** The fix writes
`AGENT_REVIEW_EXTRA_ARGS`, a var the parent fan-out loop also reads. The
assignment happens inside the per-agent `( … )` subshell, so it cannot mutate the
parent or a sibling. TC-CXR-XA-ISO-01 pins this.

**Out of scope (deferred follow-up).** The deeper smell — `run_agent` and
`resume_agent` reading two different vars — should be unified in `lib-agent.sh`,
but that lib change has a second caller (`autonomous-dev.sh` dev-resume) and
carries dev-side blast radius this fix deliberately avoids. Captured as a separate
issue.

**Invariant.** This is a fix to the existing **INV-41** (no new INV-NN); the
INV-41 plumbing note + `review-agent-flow.md` per-agent paragraph are updated to
state the dual-var alias.
