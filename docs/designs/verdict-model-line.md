# Design: show the review model on every verdict comment (INV-60)

Issue: #208 — `feat(autonomous-review): show the review model on every verdict comment (INV-60)`

## Problem

Today the AGENT verdict trailer that `scripts/post-verdict.sh` appends to a
review agent's verdict comment has exactly two lines:

```
Review Session: `<id>`
Review Agent: <name>
```

The **model** the agent reviewed with is not on the verdict comment — it only
appears on the separate `Reviewed HEAD: … model \`<model>\`` forensic trailer
([INV-04], posted by the wrapper). For a mixed fleet (`AGENT_REVIEW_AGENTS`
lists ≥2 CLIs) each agent may resolve a different model via [INV-41]'s per-agent
override keys, so an operator reading a single verdict comment cannot attribute
a pass/fail to the model that produced it.

## Decision (from the issue, not re-litigated)

Fold the resolved model into the existing `Review Agent:` line, **inline**, as a
parenthetical — NOT a new third trailer line:

```
Review Agent: kiro (model: claude-sonnet-4.6)
```

The trailer stays two lines. The `Review Agent: <name>` substring at the START
of the line stays byte-for-byte intact so the [INV-40] discriminator
(`lib-review-poll.sh::_agent_predicate` → `test("Review Agent: <name>")`, a
substring test) and the [INV-20] trailer-presence binding keep matching.

## Model resolution + fallback

Resolve EXACTLY as the `Reviewed HEAD:` trailer (`autonomous-review.sh` ~L1613)
and the `run_agent` launch arg (~L1294) do:

1. `AGENT_REVIEW_MODEL_<AGENT>` (per-agent override, if set & non-empty) — via
   `lib-review-resolve.sh::_resolve_review_agent_model`
2. else shared `AGENT_REVIEW_MODEL`
3. else the effective launch default **`sonnet`** (i.e. `${resolved:-sonnet}`)

The displayed string is the **launch default `sonnet`** when neither key is
configured — the same value `run_agent` is launched with and the same value the
`Reviewed HEAD:` trailer prints. This keeps the verdict comment consistent with
the `Reviewed HEAD:` line. (Note: `agy` ignores an unknown `--model` per
[INV-50]; `sonnet` is the *launch arg*, not necessarily agy's runtime model —
but matching `Reviewed HEAD:` is the chosen, consistent behavior; no agy
special-case.)

## Implementation shape

The model value comes from the **wrapper's deterministic resolution**, never
from the agent CLI (the CLI doesn't reliably know its resolved model id; the
whole point of [INV-56] is the wrapper supplies trailer facts).

### `scripts/post-verdict.sh` — optional 6th positional arg `<model>`

- New signature:
  `post-verdict.sh <issue> <pass|fail> <body-file|-> <agent-name> <session-id> [<model>]`
- When the 6th arg is present and non-empty → render
  `Review Agent: <name> (model: <model>)`.
- When omitted/empty → render exactly today's `Review Agent: <name>`
  (backward compatible — a caller that doesn't pass it is unchanged).
- **Validation** of the model arg is intentionally LOOSE: the name/session args
  use the strict `^[A-Za-z0-9._-]{1,64}$` regex, but model ids legitimately
  contain spaces, parens and dots (e.g. `Gemini 3.5 Flash (High)`,
  `claude-sonnet-4.6`). So for the model arg we only:
  - reject any **control character** — a newline OR a carriage return (either
    would split the single-line trailer / forge a second `Review Agent:` line)
    → exit 2 (`[[ "$MODEL" =~ [[:cntrl:]] ]]`);
  - cap the length (a sane upper bound, 128 chars).
  Everything else is accepted verbatim.
- Update the usage string, the header comment, and the exit-code docs.

### `autonomous-review.sh::build_review_prompt` — interpolate the 6th arg

`build_review_prompt <agent_name> <agent_session_id>` already interpolates
`${_agent_name}` and `${_agent_session_id}` into the verdict-post examples.
It now ALSO resolves the per-agent model **itself** (lowest-risk option — no
call-site signature churn; the resolver is a pure env lookup):

```bash
local _agent_model
_agent_model=$(_resolve_review_agent_model "${_agent_name}")
_agent_model="${_agent_model:-sonnet}"
```

and interpolates `'${_agent_model}'` (**single-quoted**) as the 6th arg in
**all three** concrete `bash scripts/post-verdict.sh …` invocations in the
prompt:
1. the generic Helper-usage example,
2. the Decision PASS branch concrete example,
3. the Decision FAIL branch concrete example.

> **Single-quoting is load-bearing** (PR review finding): the agent is told to
> copy the example "exactly". A multi-word model id like `Gemini 3.5 Flash
> (High)` rendered UNquoted would (a) split into args 6/7/8 — `post-verdict.sh`
> reads only `$6`, truncating to `(model: Gemini)` — or (b) hit a bash syntax
> error on the literal `(`, so the agent posts no verdict and the poller drops
> it `unavailable`. Single quotes make the agent copy one shell-safe token.
> Safe because the model is wrapper-resolved from operator config and the
> control-char validation already rejects newlines/CR; a literal `'` in a model
> id is not a realistic value.

The prompt's existing mandate ("pass the agent name and session id exactly") is
extended to the model arg.

> The [INV-55] codex-inline-diff block (lines ~662-692) only references
> `post-verdict.sh` by NAME in prose — it carries no positional invocation — so
> there is nothing to thread there. codex still routes its verdict through the
> three positional examples above ([INV-56]), so codex gets the model line for
> free. No `lib-review-codex.sh` change (its resume-prompt fallback is a
> fallback instruction, not the authoritative path — out of scope per #208).

## Out of scope

- The `Reviewed HEAD:` forensic trailer — unchanged (already shows the model).
- The machine-readable `<!-- review-verdict: … -->` marker — unchanged.
- The codex resume-prompt fallback trailer in `lib-review-codex.sh` — unchanged.
- E2E — none (pure wrapper/helper/prompt + doc change; no deployed-resource
  behavior).

## Files touched

| File | Change |
|---|---|
| `skills/autonomous-dispatcher/scripts/post-verdict.sh` | optional 6th `<model>` arg + loose validation + docs |
| `skills/autonomous-dispatcher/scripts/autonomous-review.sh` | `build_review_prompt` resolves model + passes 6th arg in all 3 examples |
| `docs/pipeline/invariants.md` | new INV-60 entry |
| `docs/pipeline/review-agent-flow.md` | verdict-posting section describes the model on the agent line |
| `skills/autonomous-review/SKILL.md` | usage example shows 6th arg |
| `skills/autonomous-review/references/decision-gate.md` | usage example shows 6th arg |
| `tests/unit/test-post-verdict.sh` | TC-PV-17.. (6th arg, newline reject, spaces/parens, discriminator) |
| `tests/unit/test-autonomous-review-verdict-via-helper.sh` | TC-PVP-07.. (model 6th arg in all spots, equals resolved model, codex+non-codex) |
| `docs/test-cases/verdict-model-line.md` | test-case doc |

## Post-install / upgrade

Edits **existing** files only — no new dispatcher script / `lib-*.sh` is added.
The existing `scripts/post-verdict.sh` symlink already resolves to the updated
content after `npx skills update -g`. The "re-run `install-project-hooks.sh`"
Step 2 is **not** required.
