# Test Cases: Codex review thread auto-resume (INV-51, #189; INV-53, #198)

All tests live in `tests/unit/test-lib-review-codex.sh` — the pure-function +
controller harness AND the wrapper-wiring source-of-truth assertions
(TC-CXR-ISO-*) — plus backward-compat assertions in the existing multi-agent /
per-agent / cli-exit-grace tests (which must stay green). The committed
real-shaped fixtures live in `tests/unit/fixtures/` (`codex-gather-only-turn.jsonl`,
`codex-verdict-turn.jsonl`, `codex-resume-carry-session-repro.txt`).

## Investigation artifact (#198 — resume carries session, RC1 disproven)

`tests/unit/fixtures/codex-resume-carry-session-repro.txt` records the minimal
`remember 42` repro and its result: on codex-cli 0.137.0 / `amazon-bedrock`,
`codex exec resume <tid>` KEEPS the same `thread.started` id, replays + caches the
prior conversation (growing `input_tokens` with `cached_input_tokens`), and
recalls prior context (`OK 42` → `RECALL 42` → `AGAIN 42`). So the issue's Root
Cause 1 ("resume is a no-op on amazon-bedrock") is NOT reproducible on the current
CLI — the resume loop is kept; the fix is the convergence detector (Root Cause 2).

## Unit — verdict-message detection (`_codex_log_has_verdict_message`, INV-53)

Convergence means **the last completed turn posted the VERDICT TRAILER** (a
pass/fail phrasing the wrapper poller matches, or the `Review Agent: codex`
discriminator) — NOT "the last turn emitted any `agent_message`". `VERDICT_TURN`
in the harness carries `Review PASSED`; `NARRATION_TURN` carries only progress
narration.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXR-DET-01 | Log whose last turn has an `agent_message` carrying a verdict trailer (`Review PASSED`) | rc 0 (verdict posted) |
| TC-CXR-DET-02 | Log whose only turn is gather-only (`tool_call`/`reasoning` only) | rc 1 (no verdict) |
| TC-CXR-DET-03 | Multi-turn log: turn 1 gather-only, turn 2 posts a verdict-trailer `agent_message` | rc 0 (last turn decides) |
| TC-CXR-DET-04 | Multi-turn log: turn 1 had a verdict trailer, turn 2 gather-only | rc 1 (last turn is gather-only) |
| TC-CXR-DET-05 | Empty/missing log file | rc 1 (no verdict) — never crashes |
| TC-CXR-DET-06 | Log with a verdict `agent_message` but NO trailing `turn.completed` (turn still mid-flight / killed) | rc 1 — only a COMPLETED turn counts |
| TC-CXR-DET-07 | Turn killed mid-verdict-`agent_message` (no `turn.completed`), then a later gather-only turn DOES complete | rc 1 — the stale flag must not leak across the `turn.started` boundary; the last COMPLETED turn is gather-only |
| TC-CXR-DET-08 | A `tool_call` turn whose OUTPUT text contains the literal substring `"type":"agent_message"` (e.g. codex grepping its own log) | rc 1 — the narrowed regex requires `agent_message` INSIDE the `item` object, not anywhere on the line (#189 review finding 2) |
| TC-CXR-DET-09 | **#198 RC2**: last completed turn emits `agent_message` items that are PURE PROGRESS NARRATION (no verdict trailer) | rc 1 — NOT converged → the loop RESUMES (the pre-fix any-`agent_message` detector returned rc 0 here and dropped codex `unavailable`) |
| TC-CXR-DET-09b | The same shape from the committed `fixtures/codex-gather-only-turn.jsonl` (sanitized review-193 capture) | rc 1 (resumes) |
| TC-CXR-DET-10 | Last turn `agent_message` text contains the PASS trailer `Review PASSED` | rc 0 (converged) |
| TC-CXR-DET-10b | The committed `fixtures/codex-verdict-turn.jsonl` (`Review PASSED` + `Review Agent: codex`) | rc 0 (converged) |
| TC-CXR-DET-11 | Last turn `agent_message` text contains the FAIL trailer `Review findings:` | rc 0 (converged — a failing verdict is still a verdict; do not resume) |
| TC-CXR-DET-12 | Last turn `agent_message` carries only the `Review Agent: codex` discriminator trailer | rc 0 (converged) |
| TC-CXR-DET-13 | Multi-turn: turn 1 posts a verdict trailer, turn 2 is narration-only | rc 1 — last-turn-decides still applies to the trailer match |
| TC-CXR-DET-14 | A `command_execution` turn whose OUTPUT text contains a verdict PHRASE (e.g. codex catting SKILL.md, whose text literally says "Review PASSED") | rc 1 — the trailer must be inside an `agent_message` item, not a tool output (strengthens DET-08 for the text match) |

## Unit — deadline parsing (`_codex_review_deadline_seconds`)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXR-DL-01 | `AGENT_REVIEW_TIMEOUT=1h` | 3600 |
| TC-CXR-DL-02 | `AGENT_REVIEW_TIMEOUT=90m` | 5400 |
| TC-CXR-DL-03 | `AGENT_REVIEW_TIMEOUT=120s` | 120 |
| TC-CXR-DL-04 | `AGENT_REVIEW_TIMEOUT=1d` | 86400 |
| TC-CXR-DL-05 | `AGENT_REVIEW_TIMEOUT=3600` (bare seconds) | 3600 |
| TC-CXR-DL-06 | `AGENT_REVIEW_TIMEOUT` unset/empty/garbage | 3600 (1h default, never unbounded) |

## Unit — resume-loop controller (`_run_codex_review_with_resume`)

Strategy: stub `run_agent` / `resume_agent` to APPEND scripted JSONL turns to the
per-agent log and record their call count + argv to recorder files. Stub the
clock so wall-clock tests are deterministic.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXR-CTL-01 | turn 1 gather-only, turn 2 (resume) posts `agent_message` | exactly **one** `resume_agent` call; loop stops; final rc 0 |
| TC-CXR-CTL-02 | turn 1 already has `agent_message` (small diff happy path) | **zero** `resume_agent` calls; loop stops immediately |
| TC-CXR-CTL-03 | every turn gather-only, `CODEX_REVIEW_MAX_RESUMES=3` | exactly **3** `resume_agent` calls then stop (no infinite loop); returns last rc |
| TC-CXR-CTL-04 | every turn gather-only, wall-clock deadline already passed before round 1 | **zero** resumes (deadline guard fires before first resume) |
| TC-CXR-CTL-05 | resume prompt content (via controller) | the `resume_agent` prompt tells codex to reuse already-loaded context and to post the verdict |
| TC-CXR-CTL-06 | resume reuses the same dispatcher session_id | `resume_agent` is called with the SAME `session_id` as `run_agent` (so the codex thread_id sidecar is reused) |
| TC-CXR-CTL-07 | `run_agent` rc propagation | the controller returns the rc of the LAST invocation (run_agent if no resume; here run_agent returns 9 on an immediate verdict → controller returns 9) |
| TC-CXR-CTL-08 | `CODEX_REVIEW_MAX_RESUMES=0` | zero resumes even when gather-only (knob can disable the loop) |
| TC-CXR-CTL-09 | non-numeric `CODEX_REVIEW_MAX_RESUMES` (operator typo) under `set -euo pipefail`, gather-only turn so the bound check is reached | degrades to the default, no `unbound variable` crash (regression for the stranded-`reviewing` failure mode) |
| TC-CXR-CTL-10 | turn-1 rc **124** (timeout) + a clean (rc 0) resume + bound-exhaustion | controller returns **124** — a per-turn timeout rc is STICKY across resumes so the INV-48 timeout-veto is not silently reset to a drop (#189 review finding 1) |
| TC-CXR-CTL-11 | turn-1 is a non-timeout launch failure (rc 1) | controller returns **1 immediately**, **zero** resumes — no point resuming a thread that never started (#189 review finding 3) |
| TC-CXR-CTL-12 | turn-1 rc 0, **resume-1 rc 124**, resume-2 rc 0, bound-exhaustion | controller returns **124** — a timeout on a *resume* turn (not just turn 1) is also sticky through a later clean resume (the stronger half of #189 review finding 1) |

## Unit — resume prompt context-compaction safety (`_codex_resume_prompt`, #198 follow-up)

The original resume prompt forbade re-reading the diff/files absolutely. When
codex compacts its OWN context between turns, the diff is gone from its working
context, so the absolute bar left codex unable to substantiate a verdict and it
defensively posted a "[BLOCKING] review context unavailable" FAIL (observed on the
codex lane reviewing PR #199). The prompt now prefers reuse but allows minimal
re-reading when context is lost, and forbids refusing a verdict for missing context.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXR-RP-01 | prompt no longer contains an ABSOLUTE "do NOT re-read" bar | substring absent |
| TC-CXR-RP-02 | prompt allows re-reading when context is unavailable | contains a `re-read … minimum` allowance |
| TC-CXR-RP-03 | prompt still prefers reusing already-loaded context (no gratuitous re-gather on the common path) | contains "ALREADY loaded" |
| TC-CXR-RP-04 | prompt instructs codex to ISSUE a verdict and NEVER refuse one for lack of context | contains "post your verdict" AND "do NOT refuse" |
| TC-CXR-RP-05 | the INV-40/INV-20 attribution trailers survive | contains `Review Agent: codex` and the session uuid |

## Unit / source-of-truth — wrapper isolation

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXR-ISO-01 | `lib-agent.sh` `run_agent`/`resume_agent` are NOT modified for this feature | the generic codex branch still calls `codex exec --json`/`exec resume` exactly as before (existing `test-lib-agent-codex.sh` stays green) |
| TC-CXR-ISO-02 | fan-out dispatch: codex agent routes through `_run_codex_review_with_resume` | source-of-truth grep: the fan-out loop calls `_run_codex_review_with_resume` guarded by `AGENT_CMD == codex` (or `_agent == codex`) |
| TC-CXR-ISO-03 | fan-out dispatch: non-codex agent routes through bare `run_agent` | non-codex branch still calls `run_agent` directly (claude/agy/kiro/gemini unchanged) |
| TC-CXR-ISO-04 | `autonomous-review.sh` sources `lib-review-codex.sh` | source line present, ShellCheck clean |
| TC-CXR-ISO-05 | `bash -n` parse of `lib-review-codex.sh` and `autonomous-review.sh` | both parse cleanly |
| TC-CXR-ISO-06 | new lib registered in CI shellcheck job | `.github/workflows/ci.yml` lists `lib-review-codex.sh` |

## Integration / E2E (documented; exercised via the controller harness)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXR-E2E-01 | Fleet review where codex turn-1 is gather-only then turn-2 posts a verdict → codex contributes a verdict instead of `unavailable` | controller emits a converged stream; the wrapper's poller (unchanged) then finds the verdict (covered structurally by TC-CXR-CTL-01 + the poller's own tests) |
| TC-CXR-E2E-02 | Wall-clock cap governs: a resume loop that would exceed `AGENT_REVIEW_TIMEOUT` is cut off and falls back cleanly | TC-CXR-CTL-04 / TC-CXR-DL-* |

## Backward-compat gate (must stay green)

- `tests/unit/test-lib-agent-codex.sh` — generic codex branch unchanged.
- `tests/unit/test-autonomous-review-multi-agent.sh` — fan-out for non-codex.
- `tests/unit/test-autonomous-review-per-agent-model.sh`,
  `test-autonomous-review-per-agent-launcher.sh` — per-agent resolution unchanged.
- `tests/unit/test-review-cli-exit-grace.sh`, `test-review-e2e-command-poll-budget.sh`
  — verdict-poll behavior (the authoritative gate) unchanged.
