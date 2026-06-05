# Design: Run E2E once before the review fan-out (sequential E2E lane)

**Issue**: #182
**Invariant**: INV-46 (new)

## Problem

Today `autonomous-review.sh` embeds the E2E execution block **inside each review
agent's prompt** (`build_review_prompt` injects the command-mode or browser-mode
E2E block). The fan-out (`AGENT_REVIEW_AGENTS` with N CLIs) spawns N independent
review agents, so each of the N agents runs the full E2E itself:

- N× `E2E_COMMAND_PRE_HOOKS` (e.g. a container image build dispatched N times),
- N× `E2E_COMMAND` (the real verify: deploy/submit/poll, real LLM/API calls),
- N× evidence generation.

The pre-#182 mitigation (INV-43 sub-rule, the "duplicated pre-hook shrink") was
explicitly best-effort — a sibling-evidence re-check in the prompt that all N
agents could race past in the same sub-second window. The honest limitation was
documented in `e2e-command-mode.md` §3: "A wrapper-level 'run pre-hook once
before fan-out' would be the strong guarantee; it changes the command-mode
contract and is deferred." **This design lands that strong guarantee.**

## Goal

Run E2E **once** in a dedicated lane, decoupled from the N review agents. The
pre-hook and the verify command run a single time per review round regardless of
`AGENT_REVIEW_AGENTS` count. A gate fail short-circuits to FAIL **without**
spawning the review agents at all.

## Architecture — sequential E2E, then review fan-out

```
                       autonomous-review.sh
                              │
                  ┌───────────▼────────────┐
                  │  PHASE A: E2E lane (×1) │   runs to completion FIRST
                  │  command: SHELL subshell│   (fan-out has NOT started → the
                  │    setsid + timeout     │    pre-hook structurally cannot
                  │    pre-hooks→verify→     │    run N times)
                  │    parser→post evidence │
                  │  browser: ONE LLM lane  │   wrapper STAMPS the SHA marker
                  └───────────┬────────────┘
                              │ write .rc sidecar (read before fan-out)
                              ▼
                  ┌────────────────────────┐
                  │  E2E HARD GATE (mech.)  │  dual-signal:
                  │  (a) .rc == 0  AND      │   rc==0 ≡ prehooks=0 ∧ verify∈{0,124-rec}
                  │  (b) re-fetch SHA-marked│             ∧ parser=0 ∧ comment-post ok
                  │      evidence comment   │   (b) bounded-retry; rc0+empty →
                  │      vs CAPTURED SHA    │       re-queue non-substantive
                  └───────────┬────────────┘
        gate=fail │ (or E2E_ACTIVE=false → skip) │ gate=pass / not active
        ──────────┼──────────────────────────────┼────────────────────────
   FAIL fast:     │                                ▼
   E2E gate fail  │              ┌─────────────────────────────────────┐
   forces FAIL,   │              │ PHASE B: fan out N review agents     │ (existing
   NO fan-out     │              │ PURE code reviewers — read the       │  INV-40
                  │              │ already-posted evidence comment;     │  fan-out)
                  │              │ judge code quality + AC; post verdict│
                  │              └──────────────────┬───────────────────┘
                  │                                 ▼
                  │              review unanimity (lib-review-aggregate — UNCHANGED)
                  └─────────────────────────────────┤
                                                    ▼
   final PASS ≡  (E2E_ACTIVE == false  OR  e2e_gate == pass)
            AND  review-unanimity-pass (≥1 deciding agent AND all deciding pass)
   final FAIL ≡  e2e_gate == fail
              ∥  any deciding review verdict is blocking
              ∥  ALL review agents unavailable
```

### Why sequential, not parallel (rejected first draft)

The first draft ran E2E as a parallel (N+1)th lane overlapping the review
agents, with two-phase review agents polling for the E2E evidence mid-review.
That shape stacks two INV-43-scaled poll windows serially (agent-side evidence
wait + the wrapper's post-exit verdict poll), pushing worst-case wall-clock to
`~2 × E2E_COMMAND_TIMEOUT_SECONDS` — past the `REVIEW_NEAR_SUCCESS_WINDOW_SECONDS`
operators set per INV-43 sub-rule 2, so the dispatcher would SIGTERM the
still-working wrapper and reproduce the very #172 failure this work fixes. It
also created a `.rc`-sidecar-lifetime race against `_FANOUT_DIR` cleanup. The
sequential design dissolves both structurally. Review-to-E2E wall-clock overlap
is given up on purpose: a heavy E2E (tens of minutes) dwarfs code review
(~1–2 min), so the overlap saved little while costing the hardest concurrency
bugs.

## Components

### 1. E2E runs ONCE, sequentially, before the review fan-out

A Phase-A E2E lane (an inline `if [[ E2E_ACTIVE ]]` block dispatching to
`_run_command_e2e_lane` for command mode / a single `run_agent` for browser mode)
runs to completion first; the wrapper then computes the E2E hard gate; only on a
pass (or `E2E_ACTIVE=false`) does it fan out the N review agents. A gate fail short-circuits to FAIL **without** spawning the
review agents (saves N review runs on a known-bad PR).

### 2. command-mode E2E runs in the wrapper as a pure shell lane (non-LLM, token-free, once)

For `E2E_MODE=command`, the E2E lane is a shell subshell, NOT an LLM agent
(`_run_command_e2e_lane` in a new `lib-review-e2e.sh`):

- runs under `setsid` + `timeout --kill-after=… --signal=TERM …` so the verify
  command's child subtree is contained and reapable on wrapper SIGTERM;
- runs `E2E_COMMAND_PRE_HOOKS_RENDERED` (if set) — failure → E2E fail;
- runs `E2E_COMMAND_RENDERED` under the timeout; interprets the exit code
  (`0` → run parser; `124` → timeout, run parser on partial, fail-unless-recovered;
  other → fail, skip parser) — exactly the existing `e2e-command-mode.md` semantics;
- runs `E2E_COMMAND_EVIDENCE_PARSER_RENDERED`, posts the evidence block as a PR
  comment (SHA-bound marker, unchanged contract);
- each fallible step is guarded `|| rc=$?` so `set -e` cannot abort the subshell
  before the `.rc` sidecar is written;
- writes a `.rc` sidecar capturing the composite result.

**Idempotency / skip-on-fresh-evidence**: before running anything, the lane
re-fetches the PR for a SHA-matching `<!-- e2e-evidence: complete sha="${PR_HEAD_SHA}" -->`
comment. If present (a prior tick already validated this exact HEAD), the lane
reuses it — `rc=0`, no pre-hook, no verify — preserving the existing skip
contract but now wrapper-side.

### 3. browser-mode E2E stays an LLM lane, but only ONE

`E2E_MODE=browser` needs an LLM to drive Chrome DevTools MCP, so it remains a
single LLM-driven lane — not replicated across the N review agents. The browser
lane reuses `run_agent` with a dedicated browser-only prompt
(`build_browser_e2e_prompt`). The LLM judges and posts a `## E2E Verification
Report` PR comment (tables, screenshots, AC results); the **wrapper** (not the
LLM) then mechanically stamps the `<!-- e2e-evidence: complete sha="${PR_HEAD_SHA}" -->`
marker **onto that report comment** via `_stamp_browser_evidence_marker` (REST
`PATCH issues/comments/<id>`, idempotent) once the lane exits clean, so the gate
anchor is deterministic in both modes (the LLM never has to transcribe the SHA).

**Stamp the report, not a separate comment (codex review fix).** The marker MUST
land on the report comment, never as a standalone marker-only comment:
`_fetch_sha_evidence` selects the latest comment containing the marker, so a
marker-only comment would let the gate pass with no real evidence AND hand the
review agents an empty comment. If the lane exits clean but no `## E2E
Verification Report` comment exists to stamp, `_stamp_browser_evidence_marker`
returns non-zero and the wrapper forces the lane rc non-zero → the gate **fails
closed**. The report comment is matched by the INV-20 binding (latest by
`BOT_LOGIN`, `created_at >= WRAPPER_START_TS`, body contains `## E2E Verification
Report`; actor predicate dropped on the `BOT_LOGIN`-empty fallback).

### 4. Review-agent prompts drop the E2E execution block

`build_review_prompt` no longer injects any E2E execution block. Review agents
judge **code quality + acceptance criteria**, and **read the already-posted E2E
evidence comment as input** for an N-way double-check of the evidence against the
issue's acceptance criteria. They do not run, and are not told to run, E2E.
Because the evidence is already posted before fan-out, there is no in-subshell
wait and no timing edge.

### 5. E2E hard gate = mechanical dual-signal, composed with review unanimity

A new pure `_classify_e2e_gate <rc> <evidence_present>` (in `lib-review-e2e.sh`)
decides pass/fail from two independent signals:

- (a) the lane's `.rc` == 0, AND
- (b) a re-fetch of the PR finds a SHA-matching evidence comment for the
  **captured** `PR_HEAD_SHA`.

A crash between "parser ok" and "comment posted" therefore fails **closed**. The
re-fetch (`_fetch_sha_evidence`) gets a bounded retry; if `.rc`==0 but the
re-fetch is still empty after retries (transient GitHub), the gate routes
`failed-non-substantive` (re-queue for re-review), not a substantive dev bounce.

`_classify_e2e_gate` truth table:

| `.rc` | evidence present | gate |
|---|---|---|
| 0 | yes | `pass` |
| 0 | no | `block-nonsubstantive` (crash-after-parser fail-closed / transient re-fetch) |
| ≠0 | yes | `fail` (verify/pre-hook failed; stale-but-present evidence does not rescue) |
| ≠0 | no | `fail` |

`lib-review-aggregate.sh`'s unanimous-PASS over review agents is **unchanged**.
The wrapper AND-s the two:
`final = (E2E_ACTIVE==false OR e2e_gate==pass) AND review_unanimity==pass`.

The E2E gate is a **mandatory** gate (NOT a voter subject to unavailable
tolerance) and is placed before the fan-out (fail → no fan-out) and before the
INV-44 mergeable block (so a CONFLICTING/E2E-fail PR cannot reach the PASS branch).

## Data flow

1. `validate_e2e_config()` + `${PR_NUMBER}` rendering — unchanged.
2. **Phase A**: run the single E2E lane (command: shell; browser: one LLM) to
   completion; post evidence; write the `.rc` sidecar.
3. Compute the E2E hard gate (dual-signal: `.rc` + SHA-matching evidence re-fetch
   vs the captured `PR_HEAD_SHA`, bounded retry). `E2E_ACTIVE=false` → skip the
   gate entirely.
4. Gate fail → emit the aggregated FAIL trailer and route to `pending-dev`
   **without** fan-out. Gate pass (or inactive) → **Phase B**.
5. **Phase B**: fan out the N review agents (existing INV-40 machinery,
   unchanged), each reading the posted evidence as input; bounded
   `wait "${_fanout_pids[@]}"`; poll per-agent verdicts (INV-40/INV-43).
6. Aggregate: `_aggregate_review_verdicts` over review agents AND the E2E gate.
   Emit ONE aggregated INV-35 verdict trailer + ONE INV-04 Reviewed-HEAD trailer.

## Error handling

- E2E lane pre-hook fails → `.rc` ≠ 0 → gate fail → aggregate FAIL (no fan-out).
- E2E lane exit 124 (timeout) → run parser on partial; pass only on the existing
  artifact-recovery exception, else fail.
- E2E lane crashes before posting evidence → `.rc` ≠ 0 and/or no SHA-matching
  comment → gate fails closed.
- E2E lane subtree on wrapper SIGTERM → contained by `setsid` + the trap kill-set
  + the lane's PGID captured alongside the review agents' (reaped by
  `_reap_fanout_processes`).
- Transient GitHub on the gate re-fetch while `.rc`==0 → bounded retry; still
  empty → `failed-non-substantive` re-queue (not a dev bounce).
- A review agent crashes / never posts → unavailable (dropped), per INV-40 —
  UNCHANGED. The E2E gate is orthogonal and already passed before fan-out.
- `E2E_MODE=none` → no E2E lane, no gate; pure review unanimity (pre-#182
  behavior byte-preserved for non-E2E projects).

## Backward compatibility

- **`E2E_MODE=none` projects**: no E2E lane added; review fan-out + aggregation
  identical to today. No behavior change.
- **N=1 single review agent**: E2E runs once, then the single review agent runs
  — the single-agent project also stops paying the agent-runs-E2E cost.
- **browser-mode**: still LLM-driven, but consolidated to one lane, with a
  wrapper-stamped SHA marker.
- INV-40 (unanimous + bounded wait), INV-43 (poll-window scaling / non-zero-exit),
  INV-44 (mergeable hard gate) all preserved. The E2E gate is a NEW layer
  composed with them, not a replacement.

## Out of scope

- Parallel E2E↔review wall-clock overlap (rejected — see Why sequential).
- Background / async E2E that exceeds `E2E_COMMAND_TIMEOUT_SECONDS`.
- Changing the browser-mode E2E procedure beyond de-duplicating it to one lane
  and the wrapper-stamped SHA marker.
- Feeding the evidence to review prompts as a structured machine artifact beyond
  the posted comment text.
