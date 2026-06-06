# Test Cases: Codex review thread auto-resume (INV-51, #189)

All tests live in `tests/unit/test-lib-review-codex.sh` — the pure-function +
controller harness AND the wrapper-wiring source-of-truth assertions
(TC-CXR-ISO-*) — plus backward-compat assertions in the existing multi-agent /
per-agent / cli-exit-grace tests (which must stay green).

## Unit — verdict-message detection (`_codex_log_has_verdict_message`)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXR-DET-01 | Log whose last turn has an `agent_message` item | rc 0 (verdict-message present) |
| TC-CXR-DET-02 | Log whose only turn is gather-only (`tool_call`/`reasoning` only) | rc 1 (no verdict message) |
| TC-CXR-DET-03 | Multi-turn log: turn 1 gather-only, turn 2 has `agent_message` | rc 0 (last turn decides) |
| TC-CXR-DET-04 | Multi-turn log: turn 1 had `agent_message`, turn 2 gather-only | rc 1 (last turn is gather-only) |
| TC-CXR-DET-05 | Empty/missing log file | rc 1 (no verdict) — never crashes |
| TC-CXR-DET-06 | Log with `agent_message` but NO trailing `turn.completed` (turn still mid-flight / killed) | rc 1 — only a COMPLETED turn with a message counts |
| TC-CXR-DET-07 | Turn killed mid-`agent_message` (no `turn.completed`), then a later gather-only turn DOES complete | rc 1 — the stale message flag must not leak across the `turn.started` boundary; the last COMPLETED turn is gather-only |
| TC-CXR-DET-08 | A `tool_call` turn whose OUTPUT text contains the literal substring `"type":"agent_message"` (e.g. codex grepping its own log) | rc 1 — the narrowed regex requires `agent_message` INSIDE the `item` object, not anywhere on the line (#189 review finding 2) |

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
| TC-CXR-CTL-05 | resume prompt content | the `resume_agent` prompt contains "do NOT re-run git diff" and "post the verdict" instructions |
| TC-CXR-CTL-06 | resume reuses the same dispatcher session_id | `resume_agent` is called with the SAME `session_id` as `run_agent` (so the codex thread_id sidecar is reused) |
| TC-CXR-CTL-07 | `run_agent` rc propagation | the controller returns the rc of the LAST invocation (run_agent if no resume; here run_agent returns 9 on an immediate verdict → controller returns 9) |
| TC-CXR-CTL-08 | `CODEX_REVIEW_MAX_RESUMES=0` | zero resumes even when gather-only (knob can disable the loop) |
| TC-CXR-CTL-09 | non-numeric `CODEX_REVIEW_MAX_RESUMES` (operator typo) under `set -euo pipefail`, gather-only turn so the bound check is reached | degrades to the default, no `unbound variable` crash (regression for the stranded-`reviewing` failure mode) |
| TC-CXR-CTL-10 | turn-1 rc **124** (timeout) + a clean (rc 0) resume + bound-exhaustion | controller returns **124** — a per-turn timeout rc is STICKY across resumes so the INV-48 timeout-veto is not silently reset to a drop (#189 review finding 1) |
| TC-CXR-CTL-11 | turn-1 is a non-timeout launch failure (rc 1) | controller returns **1 immediately**, **zero** resumes — no point resuming a thread that never started (#189 review finding 3) |
| TC-CXR-CTL-12 | turn-1 rc 0, **resume-1 rc 124**, resume-2 rc 0, bound-exhaustion | controller returns **124** — a timeout on a *resume* turn (not just turn 1) is also sticky through a later clean resume (the stronger half of #189 review finding 1) |

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
