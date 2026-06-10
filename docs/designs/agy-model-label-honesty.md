# Design: agy model-label honesty for the INV-50-drop case (issue #220)

## Problem

The three review model-label producers report the value
`_resolve_review_agent_model "$agent"` returns:

1. `lib-review-resolve.sh::_review_fanout_model_label` — the `Fanning out …` log
   line (INV-58).
2. `autonomous-review.sh::build_review_prompt` → `_agent_model` — the 6th
   `post-verdict.sh` arg folded into the verdict comment's `Review Agent: <name>
   (model: <model>)` line (INV-60).
3. `autonomous-review.sh` `_REVIEW_HEAD_MODEL` — the `Reviewed HEAD: … model …`
   forensic trailer (INV-04, rendered per INV-58).

For an `agy` member with **no** `AGENT_REVIEW_MODEL_AGY` per-agent key, the
resolver falls back to the shared `AGENT_REVIEW_MODEL` (e.g. `claude-sonnet-4.6`,
set so kiro accepts a model). But `claude-sonnet-4.6` is **not an `agy models`
id**, so INV-50 (`lib-agent.sh::_agy_build_model_args` → `_agy_known_model`)
**drops** the `--model` flag and agy silently runs its `settings.json` default
(e.g. a Gemini model). The label then asserts agy reviewed with
`claude-sonnet-4.6` while agy actually ran something else — **the reported model
is a lie for agy in this configuration.**

This is the display-layer gap INV-58/INV-60 left open: those invariants made the
labels show the *resolved* model, but for agy the resolved value can be one
INV-50 then discards, so "resolved" ≠ "what ran".

## Decision (chosen option)

**Option 1 from the issue — mirror INV-50 in the label resolver.** Introduce one
new pure-ish helper in `lib-review-resolve.sh`:

```bash
_resolve_review_agent_model_label <name>   # echoes the HONEST display label
```

Logic:

1. `resolved=$(_resolve_review_agent_model "$name")`, then `resolved=${resolved:-sonnet}`
   (the same `${…:-sonnet}` launch default the three producers already apply).
2. If `name` (lowercased) is `agy` **and** the resolved id is NOT a known
   `agy models` id (i.e. INV-50 would drop `--model` for it) → echo the agy
   default label `agy default (settings.json)` instead of the dropped id.
3. Otherwise echo `resolved` verbatim.

This keeps the label honest for *exactly* the case INV-50 drops, and leaves
claude/kiro/codex (which honor `--model`) untouched.

### Why Option 1 over Option 2

Option 2 (`agy (model: <id> [dropped by agy; ran its default])`) is more verbose
and risks breaking the load-bearing `Review Agent: <name>` discriminator
(INV-40/INV-20) and the single-line trailer if the bracketed text contains a
newline or a `(` that the prompt's single-quoted 6th-arg interpolation can't
absorb. The model arg validation (INV-60) already rejects control chars; a short,
fixed, parens-free label (`agy default (settings.json)` — note: the parens here
are *inside* the model token, which INV-60 accepts as a legitimate model-id shape
like `Gemini 3.5 Flash (High)`) is the minimum-risk honest rendering. Operators
who want the exact runtime id set `AGENT_REVIEW_MODEL_AGY` to a real `agy models`
id (the recommended practice), which makes BOTH the run and the label correct and
bypasses this branch entirely.

## Fail-safe contract (AC #4)

`_resolve_review_agent_model_label` MUST NOT abort the `set -euo pipefail`
wrapper and MUST NEVER assert a wrong id when it cannot prove the resolved id is
unknown to agy. Specifically:

- **agy-model enumeration unavailable** — `_agy_known_model` returns `2` (the
  `agy models` enumeration-failure sentinel). The label degrades to the generic
  `agy default` (NOT the dropped id, NOT a crash). This is the conservative
  honest choice: we can't prove the id is valid, so we don't assert it; but we
  also don't have the enumerated default name, so we render the generic form.
- **`_agy_known_model` not defined** — the label helper lives in
  `lib-review-resolve.sh`, which is unit-tested *in isolation* (sourced without
  `lib-agent.sh`). When `_agy_known_model` is undefined the helper treats agy
  conservatively: it cannot validate, so for an agy agent it renders the generic
  `agy default` (never the possibly-wrong id). In the live wrapper
  `lib-agent.sh` is always sourced first (line 22) before `lib-review-resolve.sh`
  (line 38), so `_agy_known_model` is defined there.
- The function uses `|| true` / explicit-rc capture around the `_agy_known_model`
  call so a non-zero rc under `set -e` never aborts the caller.

### agy-binary resolution caveat

`_agy_known_model` enumerates via `${AGENT_CMD:-agy}`. The three label producers
run in the **main wrapper context**, where `AGENT_CMD` is the shared default
(possibly `kiro`/`codex`), not the per-agent name. To enumerate the *agy* model
list correctly regardless of `AGENT_CMD`, the label helper invokes
`_agy_known_model` with `AGENT_CMD` locally forced to `agy` (a `local AGENT_CMD=…`
shadow inside the function, never leaking). This matches INV-50's intent: the
enumeration is of *agy's* models.

## Label-default constants

- `agy default (settings.json)` — used when we KNOW the resolved id is not an agy
  model (enumeration succeeded, id absent → INV-50 would drop it).
- `agy default` — generic fallback when enumeration is unavailable / the helper
  cannot validate (fail-safe, never a wrong id).

Both are short, single-line, control-char-free → safe for the INV-60 verdict
trailer, the INV-58 fan-out line, and the INV-04 trailer.

## Touch points

| File | Change |
|---|---|
| `lib-review-resolve.sh` | Add `_resolve_review_agent_model_label`. `_review_fanout_model_label` renders each agent through it. |
| `autonomous-review.sh::build_review_prompt` | `_agent_model` for the verdict trailer = `_resolve_review_agent_model_label "$_agent_name"`. |
| `autonomous-review.sh` `_REVIEW_HEAD_MODEL` | = `_resolve_review_agent_model_label "$_REVIEW_HEAD_AGENT"`. |

**No change** to INV-50's drop behavior, the INV-40 vote, the verdict poller, or
the `run_agent` launch arg (the launch arg keeps using `_resolve_review_agent_model`
+ `${…:-sonnet}` — agy's own INV-50 validation drops the unknown id there; the
label helper is display-only).

## Invariant docs (same PR, required)

- `invariants.md` INV-58 / INV-60 entries amended: the per-agent model label/
  trailer renders an agy member's INV-50-dropped resolved id as the agy default,
  not the dropped id. INV-50 cross-reference notes the label honesty consumer.
  No new INV-NN — this is a fix to existing invariants.
- `review-agent-flow.md` "Fan-out model label (INV-58)", "Reviewed HEAD trailer",
  and the INV-60 verdict-line bullet amended with the agy-default rendering.
