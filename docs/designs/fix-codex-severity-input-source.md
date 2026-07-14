# Design: codex severity extraction scores the wrong text (issue #481)

## Problem

`autonomous-review.sh`'s pre-aggregation severity ratchet (issue #449 R1,
INV-129) picks the text it scores per agent right before calling
`_review_extract_highest_severity`:

```bash
if [[ "${AGENT_NAMES[$_i]}" == "codex" && -n "${AGENT_CODEX_LOGS[$_i]:-}" && -f "${AGENT_CODEX_LOGS[$_i]}" ]]; then
  _sev_text=$(cat -- "${AGENT_CODEX_LOGS[$_i]}" 2>/dev/null || true)
else
  _sev_text="${AGENT_VERDICT_BODIES[$_i]:-}"
fi
```

For a codex member with a captured stdout file, this ALWAYS scores the raw
`codex review` stdout — even when the agent's verdict was actually resolved
from a validated verdict ARTIFACT (`AGENT_VERDICT_SOURCES[i] == "artifact"`,
`AGENT_VERDICT_BODIES[i]` already holds the clean, artifact-rendered
findings body). The raw stdout capture, per `build_review_prompt`, always
begins with the full rendered prompt echoed back by `codex exec`/`codex
review`'s own turn transcript before any agent output — dozens of numbered
instruction/checklist lines (`1. [ ] Design canvas created...`, `## Review
Checklist`, etc.) with no `[P0]`-`[P3]` tags. `_review_extract_highest_severity`'s
per-finding fail-safe scan (added by issue #449 to stop a correctly-tagged
low-severity finding from masking a genuinely untagged one) sees those
untagged numbered lines and collapses the WHOLE scan to `none` — regardless
of what severity tags the agent's actual findings carried.

`none` always blocks (`shouldBlockFinding`'s fail-safe default), so:
- R1's ratchet never demotes a codex verdict, ever (INV-126/INV-129 inert on
  the codex path).
- `_aggregate_has_p0p1_fail` treats `none` as P0/P1-class (by design — an
  unscoreable finding must never be excluded from the terminal floor), so
  INV-127's round-cap counter advances even on a P2-only round, and
  eventually trips with a false "P0/P1 floor is still failing" report.

## Root cause

The call site picks its input by **agent identity** (`codex` vs not), not by
**how the verdict was actually resolved**. Every other agent scores
`AGENT_VERDICT_BODIES[i]` — the rendered findings text, whichever channel
produced it. Codex is special-cased to score its raw stdout unconditionally,
even on the artifact-resolved path where a clean, already-rendered body is
sitting right there in `AGENT_VERDICT_BODIES[i]`.

## Fix

**R1 — prefer the artifact/verdict body.** Change the call-site selection so
a codex agent scores `AGENT_VERDICT_BODIES[i]` whenever its verdict was
resolved via a channel that already rendered a findings body (artifact,
comment-fallback, or the wrapper's own stdout-derived fallback post — all of
which populate `AGENT_VERDICT_BODIES[i]` before this loop runs). The raw
`AGENT_CODEX_LOGS[i]` stdout is consulted ONLY as a legacy fallback when
`AGENT_VERDICT_BODIES[i]` is empty (the historical shape this code inherited
from before the artifact channel existed, and still exercised by codex
agents whose verdict comes purely from a stdout-derived post).

Concretely: swap the branch condition from "is this agent named codex" to
"is `AGENT_VERDICT_BODIES[i]` non-empty" first, falling back to the codex
stdout only when the body is empty:

```bash
if [[ -n "${AGENT_VERDICT_BODIES[$_i]:-}" ]]; then
  _sev_text="${AGENT_VERDICT_BODIES[$_i]}"
elif [[ "${AGENT_NAMES[$_i]}" == "codex" && -n "${AGENT_CODEX_LOGS[$_i]:-}" && -f "${AGENT_CODEX_LOGS[$_i]}" ]]; then
  _sev_text=$(_codex_review_strip_prompt_echo "${AGENT_CODEX_LOGS[$_i]}")
else
  _sev_text="${AGENT_VERDICT_BODIES[$_i]:-}"
fi
```

This is a pure input-selection change — no change to
`_review_extract_highest_severity`'s scan semantics (R3) and no change to any
non-codex path (both already score `AGENT_VERDICT_BODIES[i]` and this branch
order is a no-op for them: they hit the first `-n` check exactly like today,
or fall through to the same `else` if somehow empty).

**R2 — harden the raw-stdout fallback.** For the residual case where a codex
agent has NO rendered verdict body at all (pure legacy stdout-classify path,
`AGENT_VERDICT_BODIES[i]` empty), strip the echoed prompt before scoring
instead of scanning the whole capture. New helper
`_codex_review_strip_prompt_echo` (`adapters/codex.sh`, sibling to
`_codex_review_stdout_is_malformed`): reuses the SAME `_echo_region`
boundary logic already proven by the malformed-prompt-echo detector (INV-73)
— truncate at the codex CLI's own launch-header + prompt-echo boundary and
return everything AFTER it. Concretely, the boundary is the last line of the
contiguous LEADING region that structurally matches the wrapper's own
`build_review_prompt` scaffolding (the same `## Step 0:` / `## You are
running inside` / `Prefix EACH...`-style markers `_codex_review_stdout_is_malformed`
already recognizes) — everything up to and including that region is the
echoed prompt; everything after is codex's own authored output. If no such
boundary is found (a capture that never echoed the prompt at all — e.g. a
short, well-formed review), the helper returns the ORIGINAL text unchanged
(fail-safe — R2's "no change to current behavior" clause).

**R3 — no scanner change.** `_review_extract_highest_severity` is untouched.
Its per-finding fail-safe (an untagged numbered line collapses the whole
scan to `none`) is exactly what we want it to keep doing — on the RIGHT
input.

**R4 — docs.** Update the INV-127 gate description and the R1
call-site paragraph (`review-agent-flow.md`'s severity-filter section) to
name the corrected source-selection order, and record this bug (issue #481)
as the motivating incident. New invariant `INV-132` (INV-131 is already
claimed by the base-branch work) documents the call-site contract itself:
"the pre-aggregation severity filter always scores a RENDERED verdict body
when one exists; the raw per-CLI stdout capture is a fallback ONLY for a
resolution path that produced no body at all."

## Alternatives considered

- **Widen `_review_extract_highest_severity` to ignore instruction-shaped
  lines.** Rejected — that's a scanner change (explicitly out of scope, and
  risks reintroducing the very untagged-finding-masking bug #449 fixed) when
  the actual defect is at the call site: the wrong text is being handed to a
  scanner that is behaving exactly as designed.
- **Always strip the prompt echo from `AGENT_CODEX_LOGS` regardless of
  `AGENT_VERDICT_BODIES`.** Rejected — the artifact-rendered body is already
  clean findings text with zero echo risk; running echo-stripping heuristics
  over it is unnecessary surface area. Preferring the body when present is
  strictly simpler and matches every other agent's path (R1's own framing:
  "identical to the non-codex path").

## Test plan

See `docs/test-cases/codex-severity-extraction.md` (`TC-SEVEXT-NNN`).
