# Test cases: agy quota/auth drop-reason detector (INV-58, issue #205)

Unit tests in `tests/unit/test-lib-review-agy.sh` plus model-label assertions
against `autonomous-review.sh` as the source of truth.

## TC-AGYQ-DET: `_classify_agy_drop_reason`

| ID | Input (agy `--log-file` content) | Expected stdout |
|----|----------------------------------|-----------------|
| TC-AGYQ-DET-01 | `RESOURCE_EXHAUSTED (code 429): Individual quota reached … Resets in 33h48m45s.` | `quota-exhausted:Resets in 33h48m45s` |
| TC-AGYQ-DET-02 | `RESOURCE_EXHAUSTED (code 429): Individual quota reached.` (no Resets line) | `quota-exhausted` |
| TC-AGYQ-DET-03 | only `Individual quota reached` (no `RESOURCE_EXHAUSTED`) | `quota-exhausted` |
| TC-AGYQ-DET-04 | `You are not logged into Antigravity.` (no quota signal) | `auth-failed` |
| TC-AGYQ-DET-05 | `Failed to get OAuth token` (no quota signal) | `auth-failed` |
| TC-AGYQ-DET-06 | BOTH quota AND auth lines (the live repro shape) | `quota-exhausted:…` (quota precedence) |
| TC-AGYQ-DET-07 | a normal log with neither signal | `` (empty) |
| TC-AGYQ-DET-08 | empty file | `` (empty, no crash) |
| TC-AGYQ-DET-09 | missing/nonexistent path | `` (empty, no crash) |
| TC-AGYQ-DET-10 | `Resets in 45m10s` shape | `quota-exhausted:Resets in 45m10s` |
| TC-AGYQ-DET-11 | committed fixture (sanitized real agy quota log) | `quota-exhausted:Resets in …` |
| TC-AGYQ-DET-12 | runs cleanly under `set -euo pipefail` (no unbound/abort) | rc 0 |

## TC-AGYQ-PHR: `_agy_drop_reason_phrase`

| ID | Input token | Expected (substring) |
|----|-------------|----------------------|
| TC-AGYQ-PHR-01 | `quota-exhausted:Resets in 33h48m45s` | contains `quota` AND `resets in 33h48m45s` |
| TC-AGYQ-PHR-02 | `quota-exhausted` (no window) | contains `quota`, no `resets in` |
| TC-AGYQ-PHR-03 | `auth-failed` | contains `auth` / `not logged in` |
| TC-AGYQ-PHR-04 | `` (empty) | empty |

## TC-AGYQ-SRC: source-of-truth wiring (`autonomous-review.sh`)

| ID | Assertion |
|----|-----------|
| TC-AGYQ-SRC-01 | wrapper sources `lib-review-agy.sh` |
| TC-AGYQ-SRC-02 | wrapper captures the per-agent agy log path (`_agy_log_file`) for agy members |
| TC-AGYQ-SRC-03 | wrapper calls `_classify_agy_drop_reason` when an `unavailable` agent is `agy` |
| TC-AGYQ-SRC-04 | the dropped-agent comment body interpolates the agy reason (not a bare `unavailable`) |
| TC-AGYQ-SRC-05 | CI shellcheck job lists `lib-review-agy.sh` |
| TC-AGYQ-SRC-06 | `bash -n` parses `lib-review-agy.sh` AND `autonomous-review.sh` |

## TC-AGYQ-MODEL: per-agent model label (source-of-truth)

| ID | Assertion |
|----|-----------|
| TC-AGYQ-MODEL-01 | the `Fanning out …` log line no longer hard-prints `(shared model: …${AGENT_REVIEW_MODEL}…)` as the ONLY model info — it lists per-agent resolved models via `_resolve_review_agent_model` |
| TC-AGYQ-MODEL-02 | a `_review_fanout_model_label` (or inline equivalent) renders each agent's resolved model; for `AGENT_REVIEW_MODEL_AGY="Gemini 3.5 Flash (High)"` the label contains that string, not `sonnet` |
| TC-AGYQ-MODEL-03 | the Reviewed-HEAD trailer renders the representative agent's RESOLVED model, not the bare shared `${AGENT_REVIEW_MODEL}` |

## TC-AGYQ-REG: regression

| ID | Assertion |
|----|-----------|
| TC-AGYQ-REG-01 | a quota-exhausted agy drop is NOT reported with the identical opaque `unavailable` string a CLI launch failure produces (the comment/log carries the distinct reason) |
| TC-AGYQ-REG-02 | a NON-agy unavailable agent (e.g. codex) is unaffected — bare `unavailable`, no agy reason lookup |
| TC-AGYQ-REG-03 | INV-40 aggregation truth table unchanged (quota agy still dropped, not a deciding FAIL) — existing `test-autonomous-review-multi-agent` / `test-review-agent-timeout` stay green |
