# Design: Codex review thread auto-resume until verdict (INV-51, #189)

## Problem

The codex member of a multi-agent review fleet (`AGENT_REVIEW_AGENTS`) is
frequently dropped as `unavailable` on large diffs. `codex exec` runs **one**
agentic turn. On a large diff (4,300-line example) codex non-deterministically
spends that whole turn reading the diff (`git diff`, file reads, ~55k–120k input
tokens) and then emits `turn.completed` with no findings and **no verdict
comment**. The wrapper's comment poller sees no verdict, marks codex
`unavailable` ([INV-40](../pipeline/invariants.md#inv-40)), and decides on the
remaining agent(s) alone — losing the independent second opinion exactly when the
diff is large enough to need it.

Waiting longer does not help: codex's turn already **ENDED**
(`turn.completed`). The fix must issue **another turn**, not poll longer.

## Constraints (from the engineering review on the issue)

1. **Layer**: the loop must NOT live in the generic `run_agent` — that would leak
   verdict/GitHub semantics into the CLI-agnostic `lib-agent.sh`. It lives in a
   **codex-specific review path** that watches codex's own JSONL event stream.
2. **The wrapper's existing issue-comment verdict poller stays the authoritative
   verdict gate** after the loop ends. The JSONL loop only gets codex to FINISH
   its turn; it does NOT poll the GitHub comments API mid-loop (wrong layer +
   per-turn latency).
3. **No native step-budget flag** (`codex exec --help` has no `--max-turns`).
   `codex exec resume <thread_id> [PROMPT]` is the confirmed resume primitive —
   the same one the existing `resume_agent` codex branch uses.

## Real codex `--json` event shapes (captured live)

```
{"type":"thread.started","thread_id":"<uuid>"}
{"type":"turn.started"}
{"type":"item.completed","item":{"type":"agent_message"|"tool_call"|"reasoning", ...}}
{"type":"turn.completed","usage":{"input_tokens":N,"output_tokens":M,...}}
```

A **gather-only turn** = a `turn.completed` whose preceding `item.completed`
events (since the previous `turn.completed`/`turn.started`) are all
`tool_call` / `reasoning`, with **no** `agent_message`. That is the resume
trigger — detectable from the stream, no GitHub query needed.

## Architecture

A new review-side library `lib-review-codex.sh` provides
`_run_codex_review_with_resume`. The fan-out subshell in `autonomous-review.sh`,
when the per-agent `AGENT_CMD == codex`, calls this function **instead of** the
bare `run_agent`. All other CLIs keep the bare `run_agent` invocation — byte-for-byte
unchanged.

```
fan-out subshell (AGENT_CMD=$_agent)
  └─ if $_agent == codex:  _run_codex_review_with_resume <sid> <prompt> <model> <name>
     else:                 run_agent <sid> <prompt> <model> <name>     # unchanged
```

### `_run_codex_review_with_resume <session_id> <prompt> <model> <session_name>`

```
1. compute deadline = now + _codex_review_deadline_seconds()   # from AGENT_REVIEW_TIMEOUT
2. run_agent <sid> <prompt> <model> <name>   # turn 1; codex branch captures thread_id
   rc = $?
3. resumes = 0
4. while true:
     a. if _codex_log_has_verdict_message <log>:  break          # codex finished — poller decides
     b. if resumes >= CODEX_REVIEW_MAX_RESUMES:    break          # bound hit → fall back to unavailable
     c. if now >= deadline:                        break          # wall-clock bound → fall back
     d. resumes++
     e. resume_agent <sid> "<continue-and-emit-verdict prompt>" <model> <name>
        rc = $?
5. return rc      # the wrapper's comment poller is the authoritative verdict gate
```

The per-agent log is the JSONL stream codex already writes (the fan-out redirects
`run_agent ... >>"$_agent_log" 2>&1`). The function appends each turn to that
same log, so `_codex_log_has_verdict_message` inspects the cumulative stream.

### Verdict-message detection — `_codex_log_has_verdict_message <log_file>`

The trigger is "did codex's **last** turn contain a verdict-posting
`agent_message`?" We approximate this robustly and cheaply in awk:

- Scan the JSONL for the **last** `turn.completed`.
- Within the window from the previous turn boundary to that last
  `turn.completed`, return true iff there is an `item.completed` whose
  `item.type == "agent_message"`.

This is intentionally a "did codex emit a final assistant message" signal, not a
GitHub-comment check (that is the poller's job, [Constraint 2]). An
`agent_message` is codex's way of saying "I have something to say to the user"
— the verdict comment-post happens via a `tool_call` (shell) *and* codex narrates
it in an `agent_message`. If codex emitted an `agent_message`, it has converged on
output and further resumes are wasteful; the poller then confirms whether the
verdict comment actually landed.

### Bounds

| Bound | Knob | Default | Behavior on hit |
|---|---|---|---|
| Max resumes | `CODEX_REVIEW_MAX_RESUMES` | `3` | stop looping, return last rc |
| Wall-clock | `AGENT_REVIEW_TIMEOUT` (existing) | `1h` | stop looping, return last rc |

Each individual turn is already wall-clock-capped by `_run_with_timeout`
(`AGENT_TIMEOUT`, rebound to the review cap). The loop's own deadline is a
**second** guard so `N` turns × per-turn cap cannot blow far past the review
window. `_codex_review_deadline_seconds` parses the `AGENT_REVIEW_TIMEOUT`
coreutils duration (`s/m/h/d`) to seconds; an unparseable value degrades to the
1h default (3600s) — never unbounded.

On either bound: the function returns; codex still posted no verdict; the
wrapper's post-window sweep resolves it `unavailable` ([INV-40]) — **exactly
today's fallback, no regression**.

### Resume prompt

Explicit, per the issue requirement:

> "Continue the review of the diff you already loaded. Do NOT re-run `git diff`
> or re-read files you already read. Produce your findings now and post the
> verdict comment (`Review PASSED` / `Review findings:`) on the issue, including
> the `Review Agent: codex` and `Review Session: <uuid>` lines."

## Why not the rejected alternatives

- **Pre-stuff the full diff into the prompt** so codex never spends a turn on
  `git diff`: bloats the prompt unboundedly on large diffs, loses codex's own
  file navigation, and diverges the codex prompt shape from the other CLIs.
- **A longer verdict-poll window only**: codex's turn already ENDED; polling
  longer waits for a verdict that will never come without another turn.
- **Raise codex's step budget**: no native flag exists.

## Scope / isolation

Strictly `AGENT_CMD == codex`. The claude / agy / kiro / gemini / opencode paths
take the single-invocation `run_agent` path unchanged (pinned by test). The
generic `run_agent` / `resume_agent` in `lib-agent.sh` are **not** modified.

## New-file footgun (operator step)

`lib-review-codex.sh` is a **new** dispatcher lib. After merge +
`npx skills update -g`, `install-project-hooks.sh` must be re-run on every
onboarded project (CLAUDE.local.md Post-merge Step 2) or wrappers crash on the
missing `source`. The PR body carries a `## Post-install / upgrade` note. The
file is added to the CI shellcheck job.
