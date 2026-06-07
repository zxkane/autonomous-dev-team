# Design: codex review convergence keys on the VERDICT, not any agent_message (INV-53, #198)

## Context

INV-51 (#189, merged in #194) added `lib-review-codex.sh` — a codex-specific
review path that auto-resumes the codex thread until it posts a verdict. Issue
#198 reports that codex review agents still drop to `unavailable` on non-trivial
reviews and proposed two root causes. The issue is scoped **investigation-first**:
the wrapper fix is gated on what the investigation finds.

## Investigation (done first — see PR/issue for the reproducible artifact)

Reproduced on this box: codex-cli **0.137.0**, `~/.codex/config.toml`
`model_provider = "amazon-bedrock"` (`openai.gpt-5.5`, region `us-east-2`).

### Root cause 1 — "resume is a no-op on amazon-bedrock" — **NOT reproducible**

The minimal `remember 42` repro (the exact one in the issue body) shows that
`codex exec resume <tid>` **DOES carry session context** on this provider/CLI:

| Signal | Issue RC1 prediction | Observed (0.137.0) |
|---|---|---|
| `thread.started` id on resume | a NEW id every resume | **SAME** id `019ea217…` across turn-1, resume-1, resume-2 |
| recall of prior turn | does NOT recall 42 | turn-1 "OK 42" → resume "**RECALL 42**" → resume "**AGAIN 42**" |
| input-token shape | re-reads everything from zero | input grows turn-over-turn with `cached_input_tokens` populated (e.g. 53500 in / 46817 cached) — history replayed + Bedrock prompt-cached |

So the resume mechanism is **sound** on the current CLI. The issue's prod-log
evidence (distinct thread ids per dispatch) is most consistent with an OLDER
codex CLI, or with the `_codex_capture_thread` sidecar being clobbered on each
resume — but the underlying `resume` carries context today.

**Decision (issue step 2):** because resume CAN carry session, we **keep the
resume loop** and fix the convergence detector (root cause 2). We do NOT abandon
resume / inline the diff — that rejected alternative is recorded in INV-51 and
remains rejected.

### Root cause 2 — convergence detector false-positives on progress narration — **CONFIRMED**

`_codex_log_has_verdict_message` breaks the loop iff the last completed turn
contains **any** `item.completed` of type `agent_message`. But codex emits
`agent_message` for narration ("Next I'm reading the workflow instructions…"),
not only for final findings. A gather-heavy turn that narrates then dies before
posting the verdict trips the heuristic as "converged" → no resume fires →
poller finds no verdict → `unavailable`.

Confirmed against a real-shaped review-193 log (138668 input / 746 output, three
short narration `agent_message`s, never read the diff, never posted a verdict):
the current detector returns **rc 0 (converged)** — the bug.

## The fix

Re-key `_codex_log_has_verdict_message` so "converged" means **the last completed
turn posted the VERDICT**, not "emitted any assistant message".

Convergence requires an `item.completed` `agent_message` in the last completed
turn whose **text** contains one of the verdict markers the wrapper's poller
itself recognises (`lib-review-poll.sh::_classify_verdict_body`), or the
`Review Agent: codex` discriminator the resume prompt forces codex to emit:

- Pass-side: `Review PASSED`, `Review APPROVED`, `APPROVED FOR MERGE`, `LGTM`,
  `Review PASS`.
- Fail-side: `Review FAILED`, `Review REJECTED`, `Review findings:`,
  `Changes requested`.
- Attribution trailer: `Review Agent: codex` (case-insensitive).

A turn whose `agent_message`s are pure narration (no marker) is treated as
gather-only → the loop resumes (bounded by `CODEX_REVIEW_MAX_RESUMES` + the
wall-clock deadline, unchanged).

### Why this is the right layer / signal

- The detector still reads codex's own JSONL event stream — it never queries
  GitHub (INV-51 sub-rule 2 unchanged). The poller stays the authoritative gate;
  the detector only decides whether to issue ANOTHER turn.
- Keying on the same verdict phrasings the poller matches makes the two agree:
  "the JSONL stream shows a verdict-shaped message" ⇒ "the poller will find the
  comment". The previous any-`agent_message` heuristic broke that alignment.
- It is **fail-safe toward resuming**: an ambiguous turn resumes (bounded), it
  never false-stops. Worst case wastes one bounded resume — never silently drops.

### Invariants preserved (must not regress)

1. **Last-turn-decides + turn-boundary reset** — a verdict marker in an EARLIER
   turn does not count; only the last *completed* turn's `agent_message`s do.
2. **Mid-flight / killed-mid-message** — a marker with no trailing
   `turn.completed` does not count.
3. **Tool-output substring is not a verdict** — the marker must live inside an
   `item.completed` `agent_message` item, not in a `command_execution`
   `aggregated_output` (e.g. codex grepping its own log / reading SKILL.md text
   that contains "Review PASSED").
4. **INV-48 timeout rc-stickiness** (`_run_codex_review_with_resume`) — UNCHANGED.
   A timed-out turn (rc 124/137) still vetoes via the wrapper sweep; the detector
   change is orthogonal to rc handling.
5. **Bounds unchanged** — `CODEX_REVIEW_MAX_RESUMES`, the wall-clock deadline, the
   max=0 disable, the non-numeric-degrade.

## Implementation surface

- `skills/autonomous-dispatcher/scripts/lib-review-codex.sh` —
  `_codex_log_has_verdict_message` awk body: replace the any-`agent_message`
  match with a verdict-marker match against the message text. (The fix is scoped
  to this one function; the controller, deadline parser, resume prompt, and
  rc-stickiness are untouched.)
- `tests/unit/fixtures/codex-gather-only-turn.jsonl`,
  `codex-verdict-turn.jsonl` — sanitized real-shaped fixtures (no private repo
  bodies) for the regression tests.
- `tests/unit/test-lib-review-codex.sh` — new TC-CXR-DET-09..12 cases.
- `docs/test-cases/codex-review-resume-loop.md` — new convergence cases.
- `docs/pipeline/invariants.md` (amend INV-51 + new INV-53),
  `docs/pipeline/review-agent-flow.md` — Pipeline Documentation Authority.

## No new dispatcher script / lib file

This PR edits an EXISTING lib (`lib-review-codex.sh`) and adds only test fixtures
+ docs — it does **not** add a new `scripts/*.sh` or `lib-*.sh`. So the
"Post-install / upgrade re-run `install-project-hooks.sh`" step is NOT required
(only added/removed dispatcher scripts need it).
