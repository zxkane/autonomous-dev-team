# Test Cases: codex review prompt-echo / startup-trace stdout guard (INV-73, #252)

Covers the malformed-stdout detection, the bounded re-run, and the `unavailable`
drop with a specific `malformed-output` reason for `codex review` output that is
prompt-echo / startup-trace rather than a real review.

Implementation: `skills/autonomous-dispatcher/scripts/lib-review-codex.sh`,
`skills/autonomous-dispatcher/scripts/autonomous-review.sh`.
Unit tests: `tests/unit/test-lib-review-codex.sh` (TC-CXRS-MAL-* block).
Fixture: `tests/unit/fixtures/codex-review-stdout-prompt-echo.txt`.

## Background

`codex review` (INV-62 / #218) sometimes exits **rc 0** but writes its own prompt +
CLI startup trace to stdout instead of a review. The prompt text contains the
literal `[P1]` (the "Prefix EACH blocking finding with `[P1]`" instruction + quoted
prior-round findings), so the pre-fix `_codex_review_classify_stdout` `grep -qF '[P1]'`
matched and posted a phantom blocking FAIL — vetoing a clean, twice-PASSED,
CI-green, mergeable PR on every round. Distinct from #209 (non-zero/stream),
#246 (timeout 124/137), #247 (post-failed): this is **clean exit, bogus stdout**.

## Detector — `_codex_review_stdout_is_malformed`

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-MAL-DET-01 | Capture begins with the codex startup banner (`OpenAI Codex v…`) | malformed (rc 0) |
| TC-CXRS-MAL-DET-02 | Capture has a `workdir:`+`model:`+`provider:` header block near the top | malformed (rc 0) |
| TC-CXRS-MAL-DET-03 | Capture reproduces **≥2 distinct** prompt-scaffolding markers (a: instruction + Step-0 heading; b: Step-0 + Step-0.5; c: codex-review header + Review Process) | malformed (rc 0) |
| TC-CXRS-MAL-DET-10 | A genuine `[P1]` review that QUOTES a single prompt marker (`Prefix EACH blocking finding`) — reviewing THIS PR | NOT malformed (rc 1) — PR #253 [P1] regression |
| TC-CXRS-MAL-DET-11 | A real review quoting ONE `## Step 0:` heading inline | NOT malformed (rc 1) |
| TC-CXRS-MAL-DET-12 | ≥2 distinct co-occurring prompt markers | malformed (rc 0) |
| TC-CXRS-MAL-CLS-02b | A genuine `[P1]` review quoting one prompt marker | `fail` (NOT `malformed`) — PR #253 [P1] regression |
| TC-CXRS-MAL-DET-04 | Capture is at/near the char cap with no verdict/`Summary`/`Findings` structure (truncated dump) | malformed (rc 0) |
| TC-CXRS-MAL-DET-05 | Genuine review with a real `[P1]` finding | NOT malformed (rc 1) |
| TC-CXRS-MAL-DET-06 | Genuine review with only `[P2]`/`[P3]` / no markers | NOT malformed (rc 1) |
| TC-CXRS-MAL-DET-07 | Empty / missing / unreadable / short capture | NOT malformed (rc 1), no abort under `set -euo pipefail` |
| TC-CXRS-MAL-DET-08 | A real review that merely MENTIONS a banner word or quotes a short instruction snippet (no structural echo) | NOT malformed (rc 1) — no false positive |
| TC-CXRS-MAL-DET-09 | Fixture-backed prompt-echo capture | malformed (rc 0) |
| TC-CXRS-MAL-DET-13 | A genuine `[P1]` review that QUOTES the banner/header fixture in a code block (after review prose, not the top header) | NOT malformed (rc 1) — PR #253 2nd-round [P1] regression |
| TC-CXRS-MAL-DET-14 | Review prose first, the `workdir:/model:/provider:` triple quoted later in a code block | NOT malformed (rc 1) |
| TC-CXRS-MAL-DET-15 | A real startup trace (banner is the first non-empty line, after leading blanks) | malformed (rc 0) — regression guard |
| TC-CXRS-MAL-DET-16 | The contiguous launch header at the very top (no banner, just the workdir/model/provider block) | malformed (rc 0) — regression guard |
| TC-CXRS-MAL-DET-17 | A genuine `[P1]` review QUOTING two prompt headings (`## Step 0:` + `## Step 0.5:`) in a FENCED code block | NOT malformed (rc 1) — #252 3rd-round [P1] regression |
| TC-CXRS-MAL-DET-18 | A genuine `[P1]` review with two markers quoted UNFENCED but AFTER the finding | NOT malformed (rc 1) |
| TC-CXRS-MAL-DET-19 | An unfenced echo (≥2 leading markers, no preceding finding) | malformed (rc 0) — regression guard |
| TC-CXRS-MAL-DET-20 | Fixture (banner + unfenced `## Step` headings in the leading region) | malformed (rc 0) — regression guard |
| TC-CXRS-MAL-DET-21 | A genuine `[P1]` review in the wrapper's NUMBERED+BOLD format (`1. **[P1] …`) then quoting two column-0 markers | NOT malformed (rc 1) — #252 4th-round [P1] regression |
| TC-CXRS-MAL-DET-22 | A markdown-bullet `[P1]` finding (`- **[P1]** …`) then quoting markers | NOT malformed (rc 1) |
| TC-CXRS-MAL-DET-23 | A JSON `[P1]` finding (`"severity": "P1"`) then quoting markers | NOT malformed (rc 1) |
| TC-CXRS-MAL-DET-24 | The prompt's `[P1]` INSTRUCTION line (`Prefix EACH blocking finding with [P1]`) followed by markers | malformed (rc 0) — guard: instruction is NOT a finding boundary |
| TC-CXRS-MAL-DET-25 | A direct `[P1]` finding line then quoting markers | NOT malformed (rc 1) — guard: direct finding still bounds |
| TC-CXRS-MAL-DET-26 | A LONG (≥45000) genuine review with a numbered `[P1]` finding, no verdict heading | NOT malformed (rc 1) — #252 5th-round finding-2 [P1] regression |
| TC-CXRS-MAL-DET-27 | A LONG review with a bare `[P1]` finding, no heading | NOT malformed (rc 1) |
| TC-CXRS-MAL-DET-28 | A LONG truncated dump with NO finding structure + no heading | malformed (rc 0) — signal-3 guard |

## Classifier — `_codex_review_classify_stdout` (malformed checked FIRST)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-MAL-CLS-01 | Prompt-echo capture (banner + prompt, `[P1]` present ONLY as quoted instruction text) | `malformed` (NOT `fail`) |
| TC-CXRS-MAL-CLS-02 | Genuine review with a real `[P1]` | `fail` (no over-suppression) |
| TC-CXRS-MAL-CLS-03 | Genuine review with no `[P1]` | `pass` |
| TC-CXRS-MAL-CLS-04 | Empty capture | `pass` (unchanged — empty is a valid clean review) |
| TC-CXRS-MAL-CLS-05 | Fixture-backed prompt-echo | `malformed` (the #252 regression — was `fail`) |
| TC-CXRS-MAL-CLS-02b | A genuine `[P1]` review quoting one prompt marker | `fail` (NOT `malformed`) — PR #253 1st-round [P1] |
| TC-CXRS-MAL-CLS-02c | A genuine `[P1]` review quoting the banner/header fixture in a code block | `fail` (NOT `malformed`) — PR #253 2nd-round [P1] |
| TC-CXRS-MAL-CLS-02d | A genuine `[P1]` review quoting two prompt headings in a fenced code block | `fail` (NOT `malformed`) — #252 3rd-round [P1] |
| TC-CXRS-MAL-CLS-02e | A genuine `[P1]` review in numbered+bold format then quoting two column-0 markers | `fail` (NOT `malformed`) — #252 4th-round [P1] |
| TC-CXRS-MAL-CLS-02f | A LONG (≥45000) genuine `[P1]` review with no verdict heading | `fail` (NOT `malformed`) — #252 5th-round finding-2 [P1] |
| TC-CXRS-MAL-CLS-06 | Bare call under `set -euo pipefail` on a malformed capture | rc 0, `malformed`, no abort |

## Terminal routing — all-unavailable path (`test-autonomous-review-multi-agent.sh`)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-MAR-MALEXIT-01 | A single-agent codex fleet, malformed-output (rc 0, unavailable), all-unavailable | `AGENT_EXIT=1` → `failed-non-substantive` (NOT `failed-substantive`) — #252 5th-round finding-1 [P1] |
| TC-MAR-MALEXIT-02 | Source-of-truth: the wrapper flags `_any_nonsubstantive_drop` on `malformed-output` and raises `AGENT_EXIT` on it | grep pins both wiring points |

## Re-run state machine — `_run_codex_review` (malformed rc-0 retry)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-MAL-RUN-01 | run 1 rc 0 but malformed, re-run rc 0 clean review → final clean | 2 runs, rc 0 (malformed ridden out) |
| TC-CXRS-MAL-RUN-02 | malformed rc-0 on every run, max=3 → 1 + 3 = 4 runs, rc 0 (still malformed; the rc-0 fallback + `malformed` token drop it) | 4 runs, rc 0 |
| TC-CXRS-MAL-RUN-03 | `CODEX_REVIEW_MAX_RERUNS=0` → 1 run only, no malformed re-run | 1 run, rc 0 |
| TC-CXRS-MAL-RUN-04 | malformed then a genuine `[P1]` review → final is the genuine review (no over-retry) | 2 runs, rc 0; capture holds the genuine review |
| TC-CXRS-MAL-RUN-05 | A clean (non-malformed) rc-0 run on turn 1 → NO malformed re-run (happy path unaffected) | 1 run, rc 0 |

## Drop reason — `_classify_codex_drop_reason` / `_codex_drop_reason_phrase`

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-MAL-DROP-01 | Prompt-echo rc-0 capture, no clap, no stream error | `malformed-output` |
| TC-CXRS-MAL-DROP-02 | A clap config-error capture (rc 2) — config-error still wins | `config-error:-s` (malformed bucket does not shadow it) |
| TC-CXRS-MAL-DROP-03 | A stream-error capture — stream-error still wins | `stream-error:5/5` (malformed bucket does not shadow it) |
| TC-CXRS-MAL-DROP-04 | A clean / `[P1]` review | empty (no over-claim) |
| TC-CXRS-MAL-DROP-05 | Phrase renders `malformed-output` | clause names "malformed-output" + "prompt" |
| TC-CXRS-MAL-DROP-06 | Fail-safe bare call under `set -euo pipefail` on a malformed capture | rc 0, no abort |

## Wrapper fallback (behavioral) — `autonomous-review.sh` INV-62 fallback

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-MAL-INT-01 | rc-0 prompt-echo capture, codex did NOT self-post → wrapper does NOT post a `Review findings:` FAIL; agent left unresolved | NOPOST, resolves empty (→ `unavailable` via sweep) |
| TC-CXRS-MAL-INT-02 | rc-0 genuine `[P1]` review → wrapper still posts FAIL | POST fail, resolves fail (regression guard) |
| TC-CXRS-MAL-INT-03 | rc-0 clean review → wrapper still posts PASS | POST pass, resolves pass (regression guard) |

## Wrapper wiring (source-of-truth)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-MAL-WIRE-01 | The wrapper fallback handles the `malformed` token (does not compose/post a body from it) | grep pins the `malformed` branch in `autonomous-review.sh` |

## E2E (stub fleet)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-MAL-E2E-01 | Drive `autonomous-review.sh` with a stubbed codex emitting the prompt-echo shape (rc 0) alongside a surviving agent | no phantom FAIL vote; the drop reason names `malformed-output`; the aggregate is decided by the surviving agent |
