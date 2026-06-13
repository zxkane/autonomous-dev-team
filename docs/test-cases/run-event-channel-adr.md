# Test Cases — run-event channel ADR (issue #237)

> **ADR-shape PR.** This is a research-and-decide artifact with **no code
> behavior change**. The "tests" are therefore (a) the **measurements** that
> ground the ADR's rate-limit math in observation, and (b) the **doc-quality
> gates** that the acceptance criteria enumerate. Code-test coverage is N/A
> except for the optional measurement script, which carries a ShellCheck gate
> and a `--dry-run` control-flow test.

## A. Measurement gates (the empirical "tests")

| ID | Gate | Method | Expected | Result |
|----|------|--------|----------|--------|
| TC-EVCH-001 | comment-creation → list-propagation lag is **measured, not estimated** | `measure-event-channels.sh --comment-only` against this repo, 5 samples | a real ms distribution (min/median/max) appears verbatim in the ADR | **PASS** — median 3986 ms, max 4965 ms, n=5 (see ADR §6.2) |
| TC-EVCH-002 | check-run creation latency is **measured** | `measure-event-channels.sh --check-only` against a real HEAD SHA | a real ms latency for a single check-run POST | **PASS** — 1564 ms single POST (ADR §6.3) |
| TC-EVCH-003 | the PAT-vs-App check-run permission split is **empirically probed**, not just asserted | the same probe reports whether the active token may create check-runs | the probe classifies the token (App-with-`checks:write` → permitted; PAT → 403/422) | **PASS** — App installation token here IS permitted (ADR §4, §6.3) |

## B. Doc-quality gates (acceptance-criteria mapping)

| ID | Acceptance criterion | Where satisfied | Result |
|----|----------------------|-----------------|--------|
| TC-EVCH-010 | parameter table: lease-renewal cadence vs dead-detection latency | ADR §5.3 (named-parameter table) | **PASS** |
| TC-EVCH-011 | rate-limit arithmetic shown **step-by-step** | ADR §6.4–§6.5 (worked, per-candidate, per-mode) | **PASS** |
| TC-EVCH-012 | answers "at 25 concurrent runs + 60 s heartbeat, which channels stay inside rate limits in App mode? in PAT mode?" with numbers | ADR §6.6 (the headline answer table) | **PASS** |
| TC-EVCH-013 | candidate analysis vs each topology cell (PAT / App / local / remote-SSM; 5×5 worst-case) | ADR §3 (topology matrix) + §4 (auth matrix) | **PASS** |
| TC-EVCH-014 | failure-mode comparison: outage, eventual-consistency lag, idempotency key scheme, ordering (seq vs ts) | ADR §7 | **PASS** |
| TC-EVCH-015 | run-ledger question (review T1): canonical ledger vs label-canonical + additive events, honest pros/cons + verdict | ADR §8 | **PASS** |
| TC-EVCH-016 | verdict: recommended channel + second choice + flip conditions; explicit GATED / stop-rule statement | ADR §9 | **PASS** |
| TC-EVCH-017 | `docs/pipeline/invariants.md` gains a pointer entry (decision recorded; implementation gated) | invariants.md INV-71 | **PASS** |
| TC-EVCH-018 | no code behavior change anywhere | `git diff --stat` touches only `docs/**` + the throwaway script | **PASS** |

## C. Measurement-script unit gates

| ID | Gate | Method | Result |
|----|------|--------|--------|
| TC-EVCH-020 | `measure-event-channels.sh` is ShellCheck-green | `shellcheck docs/designs/measure-event-channels.sh` | **PASS** |
| TC-EVCH-021 | `--dry-run` makes **zero network calls** and exits 0 | run with `--dry-run`, confirm only `[dry-run]` lines, no `gh api` invocation | **PASS** |
| TC-EVCH-022 | input validation rejects a malformed `--repo` / non-positive `--samples` | run with `--repo bad` and `--samples 0` | **PASS** (exits 1 with a clear error) |

## Notes

- The metrics baseline (#228, this PR's stated dependency) is the source of the
  **events-per-run** decomposition used in the rate-limit math: the documented
  per-run event set (`wrapper_start`, `wrapper_end`, `token_usage`, `pr_opened`
  / `verdict`, `review_agent_run`×N, `agent_drop`?, `merge`) is taken from
  `docs/pipeline/metrics.md`. On this dev box the live `metrics.jsonl` was not
  yet populated with a multi-run history at measurement time, so the ADR uses
  the documented event model (a conservative upper bound) rather than a
  back-derived historical rate, and says so explicitly (ADR §6.1).
- Probe comments created by TC-EVCH-001 were deleted after measurement; the
  TC-EVCH-002/003 check-run (neutral conclusion, old SHA) is inert and cannot
  be deleted via API — it is harmless.
