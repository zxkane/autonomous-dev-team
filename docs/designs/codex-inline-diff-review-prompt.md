# Design: codex review prompt feeds the diff INLINE so turn-1 is self-sufficient (INV-55)

## Problem

INV-53 (#199) fixed the convergence DETECTOR (it no longer false-converges on
progress narration). But re-reviewing #193 with the fixed code exposed the
remaining half of the original problem: codex still drops `unavailable`.

Evidence — #193 review at 2026-06-07 16:23 UTC, run with the INV-53 code
(controller markers present, resume loop fired 5 turns):

```
{"type":"command_execution","command":"... git diff --no-ext-diff --unified=80 origin/main...origin/fix/... "}
{"type":"command_execution","command":"... git diff --no-ext-diff --unified=60 ... "}
{"type":"command_execution","command":"... git diff --no-ext-diff --unified=35 ... "}
{"type":"turn.completed","usage":{"input_tokens":320972,"output_tokens":1945,...}}
[lib-review-codex] codex review hit CODEX_REVIEW_MAX_RESUMES=3 with no verdict turn; falling back to the wrapper poller (likely unavailable).
```

codex re-runs `git diff` at multiple `--unified` context sizes EVERY turn,
burning the turn (320k input tokens) on context-gathering before it can produce
findings + post the verdict. The INV-53 resume loop correctly fired, but each
resumed turn ALSO re-gathered → all 3 resumes exhausted → `unavailable`.

`agy` (Bedrock-backed, same single-agentic-turn shape) was dropped the same run
for the same reason: its log is wall-to-wall "I will check… I will view…" gather
narration that cuts off mid-exploration with no verdict.

Root cause: `build_review_prompt` is CLI-agnostic and instructs the agent to fetch
the diff itself ("Read the PR diff to verify implementation"). For a multi-turn
agent (claude) that's fine. For a single-agentic-turn agent on a large PR, the
gather phase consumes the whole turn before the verdict.

## Fix — inline the diff for the codex lane (and keep it opt-in for other single-turn lanes)

When `build_review_prompt` renders for the **codex** agent, fetch the PR diff ONCE
in the wrapper (shell, cheap, deterministic) and embed it in the prompt between
`DIFF_START`/`DIFF_END` markers, with an explicit instruction: do NOT run
`git diff`, the diff is below, produce findings + post the verdict in THIS turn.

This is the pattern already verified working in two places:
- the manual `/codex review` path (gstack codex skill) — 4318-line diff → 7
  findings incl. 2 P1 in ONE `codex exec` turn;
- the gstack `codex-large-diff-feed-inline` operational learning (confidence 9).

```
                build_review_prompt(agent, sid)
                          │
          ┌───────────────┴────────────────┐
          │ agent == codex ?                │
          └───────┬─────────────────┬───────┘
                  │ yes             │ no (claude/agy/kiro/gemini/…)
                  ▼                 ▼
   inline diff between        unchanged: prompt tells the
   DIFF_START/DIFF_END +      agent to read the PR diff
   "do NOT run git diff,      itself (multi-turn agents
   produce findings NOW"      complete in one invocation)
                  │
                  ▼
   diff size guard: if the diff exceeds CODEX_REVIEW_INLINE_DIFF_MAX_BYTES
   (default 600k), DON'T inline — fall back to the self-fetch prompt + a
   note that the diff is large (never blow the prompt the other way).
```

### Scope & blast radius

- **codex lane only.** `build_review_prompt` takes `_agent_name`; the inline block
  is gated on `[[ "$_agent_name" == "codex" ]]`. The other four CLIs keep the
  byte-for-byte current prompt — they complete multi-step in one invocation and
  inlining a huge diff into their prompt would only bloat context.
- Step 0 (mergeability) and Step 0.5 (requirement-drift: read issue comments) are
  KEPT for codex — they are cheap and load-bearing. Only the **diff** fetch is
  replaced by the inline block; codex still reads issue comments once.
- The diff is computed with `git diff origin/<base>...<pr_branch>` (three-dot =
  changes on the PR branch since it diverged), matching what a reviewer wants.
- Defense: the diff is data, not instructions. The delimiters are NONCE'd —
  `DIFF_START_<sid>` / `DIFF_END_<sid>`, suffixed with the per-render session UUID —
  so a PR diff that contains a literal `DIFF_END` line can't forge the boundary and
  push attacker text into instruction position (a static sentinel would). The prompt
  also tells codex to disregard any directive-shaped text inside the fence, and the
  lane refuses to inline (falls back to self-fetch) if the diff somehow contains the
  exact nonce'd end marker. (Hardening added in PR review.)

### Why not also fix agy here

agy shows the same gather-burn, but the robust agy fix is a separate question
(agy's CLI may support a different diff-injection or multi-turn flag). This PR is
codex-scoped to keep the diff small and the blast radius contained; an agy follow-up
is captured as a TODO, not bundled.

## Invariant

New **INV-55**: the codex review lane receives the PR diff INLINE in its prompt
(between `DIFF_START`/`DIFF_END`) and is instructed not to fetch it, so its single
agentic turn reaches a verdict instead of exhausting the turn on `git diff`
re-gathering. Bounded by `CODEX_REVIEW_INLINE_DIFF_MAX_BYTES` (fall back to
self-fetch above the cap). Complements INV-53 (convergence detection) — INV-53
stops false-converging; INV-55 removes the reason the real turn can't converge.
