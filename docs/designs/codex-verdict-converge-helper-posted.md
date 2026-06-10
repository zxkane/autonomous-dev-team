# Design: codex convergence recognizes a `post-verdict.sh`-posted verdict (INV-53 gap, issue #214)

## Problem

A `codex` review fan-out member double-posts its `Review PASSED` verdict comment
for a single review round (same session id, ~18s apart). The second post carries
a **doubled trailer** (a hand-written `Review Agent:`/`Review Session:` block plus
the helper-appended one).

Root cause, two contributing defects in the codex review lane
(`lib-review-codex.sh`):

1. **Detector blind spot.** The INV-51/INV-53 convergence detector
   `_codex_log_has_verdict_message` only recognizes a verdict that codex emits as
   an `item.completed` `agent_message` carrying a verdict trailer. But since
   INV-56 the verdict is posted by running `bash scripts/post-verdict.sh … pass …`,
   so on the common turn-1 path the verdict signal lands in a
   **`command_execution`** event (the argv / the helper's stdout comment URL), NOT
   in an `agent_message`. The detector returns false → "not converged" → the loop
   fires a resume, and codex posts the verdict a second time.

2. **Stale resume-prompt trailer instruction.** `_codex_resume_prompt` still tells
   codex to hand-write the `Review Agent:` / `Review Session:` lines (a
   pre-INV-56 instruction). Since the verdict now goes through `post-verdict.sh`
   (which writes the trailer itself), the hand-written lines are redundant and
   produce the doubled trailer whenever a resume turn *does* post.

This is benign in outcome (the wrapper's authoritative comment poller still reads
one PASS verdict; the INV-40 vote is not double-counted; `no-auto-close` still
gates merge) but it burns ≥1 extra resume on every helper-posted codex verdict and
the duplicate comment with a malformed double trailer is operator-confusing.

## Approach

Scope is the **codex review lane only** (`lib-review-codex.sh`). No change to
`lib-agent.sh`, the dev side, the comment poller, or INV-40 aggregation. This is
NOT a new invariant — it closes the gap INV-56 opened in the INV-53 detector, so
the INV-51/INV-53 docs are amended.

### Part 1 — Detector recognizes a `post-verdict.sh` invocation

Extend `_codex_log_has_verdict_message` so a turn that posts the verdict via
`post-verdict.sh` is recognized as converged. The verdict-posting signal in the
JSONL stream is a `command_execution` whose **command** invokes `post-verdict.sh`
with a `pass`/`fail` verdict argument.

Add a SECOND per-turn conjunct path to the single-pass awk, mirroring the existing
`agent_message`-trailer path:

- The line is an `item.completed` (`"type":"item.completed"`), AND
- the item is a `command_execution` scoped INSIDE the item object
  (`"item":{…,"type":"command_execution"…}`) — the same item-scoped narrowing the
  `agent_message` path uses, so a tool OUTPUT containing the literal substring
  `post-verdict.sh` (e.g. codex catting `SKILL.md`, which documents the helper)
  is NOT a false positive, AND
- the line contains `post-verdict.sh` followed by a `pass`/`fail` verdict token.

Because codex JSONL escapes newlines as `\n`, the whole `command_execution` item
(including its `command` field) is on one physical line, so the three conjuncts
hold on one line — identical to the `agent_message` path. A `post-verdict.sh`
phrase appearing in a SEPARATE narration `agent_message` (codex saying "I'll run
post-verdict.sh") cannot trip the command path — it fails the
`command_execution` item-scope conjunct.

The existing `agent_message`-trailer path is **kept** (a CLI that posts a verdict
as a plain assistant message still converges — no regression of the INV-53 path).
A turn converges iff EITHER path fires.

The over-claim guard is preserved: progress narration (no `post-verdict.sh`
invocation AND no verdict-trailer `agent_message`) still does NOT converge. Only a
real verdict signal — a `post-verdict.sh pass|fail` invocation OR a verdict-trailer
`agent_message` — counts.

#### Matching the verdict argument robustly

The production argv is
`bash scripts/post-verdict.sh <issue> <pass|fail> /tmp/verdict-<agent>.md <agent> <session> '<model>'`.
Match `post-verdict\.sh` followed (allowing the issue-number positional in
between) by a `pass`/`fail` word — keyed case-insensitively on the lowercased
line, consistent with the `agent_message` path. Use a tolerant pattern that does
not over-anchor on exact whitespace/argument positions (a future helper-arg
reshuffle must not silently break detection): require `post-verdict.sh` and a
`\<pass\>|\<fail\>`-style standalone verdict token on the same line. POSIX awk has
no `\<`/`\>`, so use surrounding-non-word-char guards consistent with the
subsystem's RE2/portability discipline, or match the documented adjacent shape
`post-verdict.sh <digits> pass|fail`. Chosen: match `post-verdict.sh` AND a
standalone `pass`/`fail` token bounded by non-alphanumeric chars on the same line
— tolerant of the issue-number/path arguments, robust to whitespace.

### Part 2 — Resume prompt drops the hand-written trailer instruction

Align `_codex_resume_prompt` with the main review prompt and INV-56: instruct
codex to post the verdict **only** via `bash scripts/post-verdict.sh` and to **NOT**
hand-write the `Review Agent:` / `Review Session:` trailer (the helper writes it).
This removes the doubled trailer even if a resume turn legitimately posts.

The prompt MUST keep the substance the INV-53 sub-rule-5 fix added: prefer
already-loaded context, allow re-reading the minimum on compaction, never refuse a
verdict for missing context. It also keeps the pass/fail body phrasing guidance
(`Review PASSED` / `Review findings:`), but the trailer is now the helper's job —
the session id is still passed so the prompt can interpolate it into the
`post-verdict.sh` invocation arguments codex must run.

## Files changed

| File | Change |
|---|---|
| `skills/autonomous-dispatcher/scripts/lib-review-codex.sh` | `_codex_log_has_verdict_message`: add the `post-verdict.sh pass\|fail` `command_execution` convergence path; `_codex_resume_prompt`: route the verdict through `post-verdict.sh`, drop the hand-written trailer directive |
| `tests/unit/test-lib-review-codex.sh` | new convergence + resume-prompt cases (see test-case doc) |
| `tests/unit/fixtures/codex-post-verdict-turn.jsonl` | committed fixture: a turn-1 helper-posted verdict (command_execution, no verdict-trailer agent_message) |
| `docs/pipeline/invariants.md` | amend INV-51 sub-rule 1 + INV-53 to state the convergence signal includes a `post-verdict.sh`-posted verdict |
| `docs/pipeline/review-agent-flow.md` | amend the Codex auto-resume step-2 paragraph for the helper-posted signal |
| `docs/test-cases/codex-review-resume-loop.md` | extend with the helper-posted convergence + resume-prompt cases |

## Risks & mitigation

| Risk | Mitigation |
|---|---|
| False positive: a tool OUTPUT mentioning `post-verdict.sh pass` mis-detected as a verdict | Item-scope the match (`"item":{…"type":"command_execution"…}`), mirroring the `agent_message` substring guard (TC-CXR-DET-08/14). Add a regression test (narration `agent_message` saying "run post-verdict.sh" must NOT converge). |
| Helper argv reshuffle breaks detection | Tolerant pattern (does not anchor on exact arg positions); fail-safe toward resuming means a missed detection just wastes one bounded resume — never a silent drop. |
| Regression of the INV-53 narration guard | Keep the narration-only-no-signal test green; add an explicit no-over-claim test for a `command_execution` that is NOT post-verdict (e.g. `gh pr view`). |
