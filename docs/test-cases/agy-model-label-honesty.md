# Test cases: agy model-label honesty for the INV-50-drop case (issue #220)

Covers `lib-review-resolve.sh::_resolve_review_agent_model_label` and the three
label producers that route through it (INV-58 fan-out line, INV-60 verdict
trailer, INV-04 Reviewed-HEAD trailer). Regression tests FAIL before the fix and
PASS after.

`_agy_known_model` / the agy model enumeration is **stubbed** in every test so the
suite is deterministic (no shelling out to `agy models`).

## Unit: `_resolve_review_agent_model_label`

Test file: `tests/unit/test-autonomous-review-per-agent-model.sh`
(extends the existing INV-41 suite — new `TC-PAML-*` block).

| ID | Setup | Expected |
|---|---|---|
| TC-PAML-01 | agy, resolved = shared `claude-sonnet-4.6` (non-agy id), `_agy_known_model` stub → rc 1 (enumerated, unknown) | label is an honest agy-default rendering, NOT `claude-sonnet-4.6` (contains `agy default`, does NOT contain `claude-sonnet-4.6`) |
| TC-PAML-02 | agy, `AGENT_REVIEW_MODEL_AGY="Gemini 3.5 Flash (High)"`, stub → rc 0 (known agy id) | label is `Gemini 3.5 Flash (High)` verbatim |
| TC-PAML-03 | kiro, resolved = `claude-sonnet-4.6` | label is `claude-sonnet-4.6` verbatim (claude/kiro/codex honor `--model` → no agy branch) |
| TC-PAML-04 | codex, resolved = `sonnet` | label is `sonnet` verbatim |
| TC-PAML-05 | claude, resolved = `sonnet[1m]` | label is `sonnet[1m]` verbatim |
| TC-PAML-06 | agy, resolved id non-agy, stub → rc 2 (enumeration UNAVAILABLE) | label degrades to a generic `agy default` (fail-safe), NEVER the wrong id; no crash |
| TC-PAML-07 | agy, `_agy_known_model` UNDEFINED (isolation: lib-agent.sh not sourced) | label is the generic `agy default` for agy (conservative — never the possibly-wrong id) |
| TC-PAML-08 | agy, no shared model, no per-agent key (resolved empty → `sonnet` default), stub → rc 1 (sonnet not an agy id) | label is `agy default` (the dropped `sonnet` default is not asserted) |
| TC-PAML-09 | agy uppercase `AGY` / mixed case `Agy` | agy branch still triggers (case-insensitive name match) |
| TC-PAML-10 | runs under `set -euo pipefail` via command-substitution AND a bare call with a rc-1 stub | reaches the echo + `return 0` without an errexit abort |

## Unit: `_review_fanout_model_label` honesty (INV-58 producer)

Same test file, `TC-PAML-FAN-*` block.

| ID | Setup | Expected |
|---|---|---|
| TC-PAML-FAN-01 | fleet `agy codex`, shared `claude-sonnet-4.6`, no `_AGY` key, stub rc 1 | label diverges → `models: agy=agy default…, codex=claude-sonnet-4.6` — the agy member shows the honest default, NOT `claude-sonnet-4.6` |
| TC-PAML-FAN-02 | fleet `agy codex`, `AGENT_REVIEW_MODEL_AGY="Gemini 3.5 Flash (High)"`, codex shared `sonnet`, stub rc 0 for the Gemini id | `models: agy=Gemini 3.5 Flash (High), codex=sonnet` (no regression for a valid agy id) |
| TC-PAML-FAN-03 | fleet `kiro codex`, both shared `claude-sonnet-4.6` (uniform, no agy) | `model: claude-sonnet-4.6` (uniform, unchanged — no agy member) |

## Source-of-truth: wrapper wiring

Same test file, extends `TC-PAM-SRC-*`.

| ID | Assertion |
|---|---|
| TC-PAML-SRC-01 | `build_review_prompt`'s `_agent_model` is assigned from `_resolve_review_agent_model_label` (the verdict-trailer path is honesty-aware) |
| TC-PAML-SRC-02 | `_REVIEW_HEAD_MODEL` is assigned from `_resolve_review_agent_model_label` (the Reviewed-HEAD trailer is honesty-aware) |
| TC-PAML-SRC-03 | `_review_fanout_model_label` renders each agent through `_resolve_review_agent_model_label` |
| TC-PAML-SRC-04 | `autonomous-review.sh` passes `bash -n` |

## Backward-compat (must stay green)

- `tests/unit/test-autonomous-review-per-agent-model.sh` — all existing INV-41
  `TC-PAM-*` cases.
- `tests/unit/test-lib-review-agy.sh` — INV-58 `TC-AGYQ-MODEL-02` still surfaces
  `Gemini 3.5 Flash (High)` for a valid per-agent agy override (a known id is
  rendered verbatim by the new helper too).
- `tests/unit/test-post-verdict.sh`, `test-autonomous-review-verdict-via-helper.sh`
  — INV-60 model-line + verdict-via-helper tests.
- `tests/unit/test-autonomous-review-multi-agent.sh`.
