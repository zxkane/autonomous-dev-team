# Design: codex review via `codex review` subcommand (INV-62, #218)

## Problem

The codex review fan-out member runs through `codex exec --json` (the generic
`lib-agent.sh` codex branch). `codex exec` runs exactly ONE agentic turn, so on a
large PR diff codex burns that turn re-gathering context (`git diff`, file reads)
and ends with no verdict. Three pieces of accidental complexity were layered on to
work around this single-turn budget:

1. **`_run_codex_review_with_resume`** (`lib-review-codex.sh`) — a bounded
   `codex exec resume` loop to nudge codex into finishing a turn.
2. **`_codex_log_has_verdict_message`** — a JSONL event-stream parser that mirrors
   the comment poller's verdict classifier (drift-prone).
3. **INV-55 inline-diff** (`autonomous-review.sh` codex branch) — fetching the PR
   diff in shell and embedding it between nonce'd `DIFF_START_<sid>`/`DIFF_END_<sid>`
   markers (600k cap + self-fetch fallback), plus a "do NOT run `git diff`" prompt.

This machinery is the root cause of a recurring bug class: **#198** (resume loop
ineffective), **#209** (`turn.failed` not retried → opaque `unavailable`), **#212**
(resume drops per-agent extra-args). All three exist *only because* codex review is
shoehorned onto single-turn `codex exec`.

## Approach

`codex review` is the purpose-built subcommand for this job: it is natively
multi-step (re-reads the diff and iterates without a one-turn budget), auto-scopes
the diff to the PR's merge target, and never strands mid-review. Moving the codex
**review** path to `codex review "<prompt>"` removes the machinery and the bug
class together — a net deletion of code.

### Verified codex CLI constraints (0.137.0, from the issue — do not rediscover)

- `codex review "<prompt>"` (no `--base`) is accepted and auto-scopes the diff to
  the PR's default base (merge target) — the exact review range. No flag needed.
- `[PROMPT]` is **mutually exclusive with `--base`/`--commit`** — keep the prompt
  (it carries the gate rules), so do NOT pass `--base`.
- `codex review` has **no resume** (no session/thread/`--json` flag). Its output is
  human-readable text, not a JSONL event stream — so the JSONL parser does NOT
  apply, and "resume" is reimplemented as a plain **re-run** of the same command.
- `codex review` **rejects `-m`**; pass the model via `-c 'model="..."'`.

### Components

**1. `_run_codex_review` (new, `lib-review-codex.sh`)** — the review-codex launch
path. Builds `codex review "<prompt>" -c 'model="<model>"' <extra-args>`
(no `-m`, no `--base`, no `--json`; the model is the only `-c` the builder emits —
any extra `-c` knob such as `model_reasoning_effort` is supplied by the operator via
`AGENT_REVIEW_EXTRA_ARGS_CODEX`), runs it under the shared `_run_with_timeout`
(so PGID/timeout/PID-file mechanics match the rest of the fleet), and captures
stdout to a caller-provided file. On a non-zero / stream-error exit it **re-runs**
(bounded by `CODEX_REVIEW_MAX_RERUNS`, default 3, + the `AGENT_REVIEW_TIMEOUT`
wall-clock deadline) — a fresh review each time (no thread state). This subsumes
#209: a transient `turn.failed`/stream blip is a non-zero exit the wrapper re-runs,
not a permanent `unavailable` drop.

**2. `_codex_review_classify_stdout` (new)** — the stdout→verdict classifier:
any `[P1]` (a codex priority-1 / blocking finding marker) → `fail`; otherwise
`pass`. Mirrors the gate logic the manual `/codex review` skill uses.

**3. `_codex_review_compose_body` (new)** — composes the canonical verdict body
from codex's stdout: a one-line `Review PASSED …` summary for pass, or a
`Review findings:` + the captured findings for fail. The wrapper posts this via
`post-verdict.sh` (agent name `codex`) **only when codex did not self-post** a
verdict comment within the poll window — double-insurance.

**4. Prompt (codex branch of `build_review_prompt`)** — keep a custom `[PROMPT]`
carrying the decision-gate BLOCKING rules + `Review PASSED`/`Review findings:`
verdict format + the `post-verdict.sh` instruction. **Delete the INV-55 inline-diff
block** — `codex review` fetches its own diff. The prompt tells codex it is running
inside `codex review` (diff already scoped) and to emit `[P1]` for blocking findings
so the wrapper's stdout fallback can classify.

**5. Wrapper wiring (`autonomous-review.sh`)** — the fan-out codex branch calls
`_run_codex_review` instead of `_run_codex_review_with_resume`. After verdict
resolution, if a codex member produced stdout but **no** self-posted verdict comment
landed (still `unavailable` after the poll), the wrapper composes + posts the
canonical body via `post-verdict.sh` and re-polls so the comment poller (authoritative
gate) classifies it.

### Verdict capture (double-insured)

1. The prompt instructs codex to self-post via `post-verdict.sh` (full contract).
2. The wrapper parses codex review stdout (`[P1]` → FAIL else PASS); if codex did
   NOT self-post within the poll window, the wrapper composes the canonical body and
   posts it via `post-verdict.sh` as agent `codex`.
3. The comment poller (`lib-review-poll.sh::_classify_verdict_body`) stays the
   authoritative gate — unchanged.

This double-insurance is load-bearing: `codex review` has its own review-output
orchestration and may not reliably honor a "call post-verdict.sh" instruction the way
`codex exec` (a pure prompt executor) did. The wrapper fallback guarantees exactly one
verdict comment lands.

### Deletions

- **Delete**: `_run_codex_review_with_resume`, `_codex_log_has_verdict_message`,
  `_codex_resume_prompt`.
- **Keep + reuse**: `_codex_review_deadline_seconds` (the re-run wall-clock bound)
  and `_codex_now_seconds` (the clock seam) — both already unit-tested and clock-stubbable.
- The INV-55 inline-diff prompt construction in the codex branch of
  `build_review_prompt` (the `gh pr diff` fetch, the nonce'd markers, the 600k cap,
  the self-fetch fallback). INV-55 is retired for the codex path (no other agent uses
  it — it was codex-only).
- The stream-error JSONL detector (`_codex_log_has_stream_error`,
  `_classify_codex_drop_reason`, `_codex_drop_reason_phrase`) keys on the `codex exec`
  JSONL event stream, which `codex review` does not emit. Re-target the drop-reason to
  a **stdout** stream-error scan so a sustained `codex review` failure still surfaces a
  distinct `stream-error` reason rather than a bare `unavailable`.

### Scope guards

- The codex **dev** path (`run_agent`/`resume_agent` codex branch in `lib-agent.sh`)
  stays on `codex exec` — **byte-for-byte unchanged**. codex-review knowledge stays
  OUT of the generic primitives (CLI-agnostic layering); it lives in
  `lib-review-codex.sh`.
- Other review agents (claude/kiro/agy/gemini/opencode) keep their `run_agent` path.

## Invariants touched

- **NEW INV-62** — the codex review lane runs `codex review "<prompt>"` (auto-scoped,
  prompt-carried gate), parses stdout for the verdict, and posts via the wrapper as a
  fallback. Replaces the INV-51 resume loop + INV-55 inline-diff for the review path.
- **INV-51** — superseded for the review path (resume loop removed). Marked superseded.
- **INV-55** — superseded for the review path (inline-diff removed). Marked superseded.
- **INV-59** — re-scoped: the JSONL stream-error detector becomes a stdout scan; the
  retry half is subsumed by INV-62's bounded re-run.

## Out of scope

- The codex **dev** path (stays on `codex exec`).
- Switching kiro/agy/claude off their current invocation.
- Upstream Bedrock 5xx (infra, separate from this refactor).
