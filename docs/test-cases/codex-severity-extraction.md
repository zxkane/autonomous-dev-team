# Test cases: codex severity-extraction input-source fix (issue #481, INV-132)

Extends `tests/unit/test-review-convergence-rules.sh` (issue #449/#475's own
suite) with a new section pinning the call-site input-selection fix, plus a
new helper `_codex_review_strip_prompt_echo` in `adapters/codex.sh` covered
by `tests/unit/test-lib-review-codex.sh`.

## TC-SEVEXT: severity call-site input selection

| ID | Scenario | Expected |
|----|----------|----------|
| TC-SEVEXT-001 | Codex agent, `AGENT_VERDICT_SOURCES[i]=artifact`, `AGENT_VERDICT_BODIES[i]` holds an artifact-rendered `[P2]`-only body, `AGENT_CODEX_LOGS[i]` holds a real-shaped stdout capture (CLI header + echoed prompt with ≥3 untagged numbered instruction lines + `[P2]`-tagged findings) | severity extraction on the SELECTED text → `P2` (scores the body, not the raw stdout) |
| TC-SEVEXT-002 | Same fixture as TC-SEVEXT-001, but pinning the OLD behavior is gone | whole-stdout scan of the fixture alone (bypassing the fix) would yield `none` — asserted as a regression pin so a revert is caught |
| TC-SEVEXT-003 | Codex agent, NO verdict body at all (`AGENT_VERDICT_BODIES[i]` empty — legacy stdout-only resolution), `AGENT_CODEX_LOGS[i]` holds the same real-shaped capture | fallback path strips the prompt echo via `_codex_review_strip_prompt_echo`, then scores → `P2` |
| TC-SEVEXT-004 | Codex agent, empty verdict body, `AGENT_CODEX_LOGS[i]` holds a capture with NO recognizable echo boundary (e.g. a short, well-formed review with no prompt scaffolding at all) | `_codex_review_strip_prompt_echo` returns the text UNCHANGED (fail-safe); severity extraction proceeds on the whole text |
| TC-SEVEXT-005 | Any agent (codex or non-codex), `AGENT_VERDICT_BODIES[i]` non-empty and genuinely carries an untagged numbered finding (R3 pin) | severity extraction still → `none` (the fail-safe scan is unmodified — this is an input-selection fix, not a scanner relaxation) |
| TC-SEVEXT-006 | `_aggregate_has_p0p1_fail` fed `(fail, P2)` pairs only | → `false` (INV-127's counter does not advance on a P2-only round once extraction is fixed) |
| TC-SEVEXT-007 | Non-codex agent, `AGENT_VERDICT_BODIES[i]` non-empty | unchanged — still scores the body (regression pin: the fix must not alter any non-codex path) |

## TC-CXSTRIP: `_codex_review_strip_prompt_echo` (adapters/codex.sh)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXSTRIP-001 | Real-shaped capture: CLI header (`OpenAI Codex v…`, `workdir:`/`model:`/`provider:`) + echoed prompt (`## Step 0:` / `## Review Checklist` / numbered checklist lines) + genuine `[P2]` findings after | returns only the text AFTER the echo boundary — the `[P2]` findings, none of the numbered checklist lines |
| TC-CXSTRIP-002 | Capture with no CLI header and no recognizable prompt-scaffolding markers (a short clean review) | returns the input UNCHANGED |
| TC-CXSTRIP-003 | Empty / missing / unreadable file | returns empty, rc 0 (fail-safe, no crash under `set -euo pipefail`) |
| TC-CXSTRIP-004 | A genuine review with leading prose before its first tagged finding (no prompt scaffolding at all) | the finding + its tag survive stripping; severity extraction on the result is unaffected (the boundary is "first genuine finding line", so harmless leading prose before it is dropped without changing the scoring outcome) |

## TC-CXRS-BODY: `_codex_review_compose_body` end-to-end echo stripping (PR review round-1 [P1])

The severity call site's `elif` branch (TC-SEVEXT-003/004) only strips the
echo when `AGENT_VERDICT_BODIES[i]` is empty — but on the live wrapper path,
the stdout-derived fallback post ([INV-62]) populates that body via
`_codex_review_compose_body` BEFORE the severity loop ever runs. Pre-fix,
that composer embedded the raw un-stripped stdout as the FAIL body, so the
severity loop's PRIMARY (body-preferred) branch re-poisoned the scan anyway.
These tests pin the fix at its actual point of effect: composition time.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-BODY-05a | `_codex_review_compose_body fail <echo+P2 fixture>` | composed body contains no numbered checklist line (`1. [ ] Design canvas created` absent) |
| TC-CXRS-BODY-05b | Same call | composed body still carries the real `[P2] src/handler.ts:88` finding |
| TC-CXRS-BODY-05c | `_review_extract_highest_severity` on that composed body | → `P2` (not `none`) — the end-to-end proof the gap is closed, not just that the echo text is visually gone |
| TC-CXRS-BODY-06 | `_codex_review_compose_body pass <capture with a CLI header>` | composed body is UNCHANGED by the strip fix — stripping is gated on `verdict == "fail"` only |

## Acceptance-criteria fixtures

- **Reproduction fixture** (issue body): a real-shaped codex stdout capture
  with the CLI header, an echoed prompt containing ≥3 untagged numbered
  instruction lines, and agent output with only `[P2]`-tagged findings.
  Both the artifact-resolved path (TC-SEVEXT-001) and the stripped-stdout
  fallback (TC-SEVEXT-003) must yield `P2`.
- **5-round P2-only loop**: simulated via the existing `_review_round_next_count`
  progression (mirrors TC-INV129-032/033 in `test-review-convergence-rules.sh`)
  combined with `_aggregate_has_p0p1_fail fail P2` at every round → `false`
  throughout, confirming INV-127's counter never advances and the ratchet
  demotes at round 5 exactly as INV-129 specifies.
