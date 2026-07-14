# Test cases: codex severity-extraction input-source fix (issue #481, INV-132)

> **Spec revision 2** (operator, applied mid-implementation): the mechanism
> below reflects the FINAL requirements — R1 branches on
> `AGENT_VERDICT_SOURCES[$_i]` (a real, branchable per-agent flag), and R2
> locates a structural `user`→echo→trace→`codex` turn-marker boundary in the
> combined `codex review` capture, not a finding-tag boundary.

Extends `tests/unit/test-review-convergence-rules.sh` (issue #449/#475's own
suite) with a new section pinning the call-site input-selection fix, plus a
new helper `_codex_review_strip_prompt_echo` in `adapters/codex.sh` covered
by both suites.

## TC-SEVEXT: severity call-site input selection

| ID | Scenario | Expected |
|----|----------|----------|
| TC-SEVEXT-001 | `AGENT_VERDICT_SOURCES[i]=="artifact"`, `AGENT_VERDICT_BODIES[i]` holds an artifact-rendered `[P2]`-only body | severity extraction on the body → `P2` |
| TC-SEVEXT-002 | Regression pin: a direct whole-capture scan of the turn-marker reproduction fixture (no channel selection applied) | → `none` (proves the bug's premise is real: the raw capture alone always collapses) |
| TC-SEVEXT-003 | `AGENT_VERDICT_SOURCES[i]=="codex-stdout-fallback"`, `AGENT_CODEX_LOGS[i]` holds a real-shaped combined capture (CLI header + `user` marker + echoed prompt with ≥3 untagged numbered instruction lines + reasoning/tool trace + final `codex` response with only `[P2]`-tagged findings) | the stdout-fallback route strips via `_codex_review_strip_prompt_echo`, then scores → `P2` |
| TC-SEVEXT-004 | `AGENT_CODEX_LOGS[i]` holds a capture with NO recognizable header/marker structure at all (e.g. a short, well-formed review with no CLI header) | `_codex_review_strip_prompt_echo` returns the text UNCHANGED (fail-safe); severity extraction proceeds on the whole text |
| TC-SEVEXT-005 | `AGENT_VERDICT_BODIES[i]` non-empty and genuinely carries an untagged numbered finding (R3 pin) | severity extraction still → `none` (the fail-safe scan is unmodified — this is an input-selection fix, not a scanner relaxation) |
| TC-SEVEXT-006 | `_aggregate_has_p0p1_fail` fed `(fail, P2)` pairs only | → `false` (INV-127's counter does not advance on a P2-only round once extraction is fixed) |
| TC-SEVEXT-007 | Non-codex agent, `AGENT_VERDICT_BODIES[i]` non-empty | unchanged — still scores the body (no `AGENT_VERDICT_SOURCES` concept applies) |
| TC-SEVEXT-008 | Over-stripping fixture: reviewed content contains bare `user`/`codex`/`system` words (fenced, mirroring a quoted diff/code snippet) AFTER the real final response marker | the real `[P2]` finding survives stripping intact; severity extraction on the result → `P2` (not falsely collapsed) |
| TC-SEVEXT-009 | Wiring pin | wrapper's severity call site branches on `AGENT_VERDICT_SOURCES[$_i] == "codex-stdout-fallback"`, calls the strip helper only in that branch, and scores `AGENT_VERDICT_BODIES[$_i]` in the else branch |
| TC-SEVEXT-010 | Wiring pin | wrapper assigns `AGENT_VERDICT_SOURCES[$_i]="codex-stdout-fallback"` at the exact call site where `_codex_review_classify_stdout` supplies the verdict |

## TC-CXSTRIP: `_codex_review_strip_prompt_echo` (adapters/codex.sh)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXSTRIP-001 | Real-shaped combined capture: CLI header + `user` marker + echoed prompt (numbered checklist) + reasoning/tool-trace `codex` turns + final `codex` response with genuine `[P2]` findings | returns only the text AFTER the LAST `codex` marker — the final-response findings, none of the checklist or trace text |
| TC-CXSTRIP-002 | Capture with no CLI header at all (a short clean review) | returns the input UNCHANGED |
| TC-CXSTRIP-003 | Empty / missing / unreadable file | returns empty, rc 0 (fail-safe, no crash under `set -euo pipefail`) |
| TC-CXSTRIP-004 | A validated header present, but NO `user` marker anywhere (legacy free-form capture) | returns the input UNCHANGED (fail-safe) |
| TC-CXSTRIP-005 | Header + `user` marker present, but NO `codex` marker after it | returns the input UNCHANGED (fail-safe — never guess a boundary that isn't there) |
| TC-CXSTRIP-006 | Over-stripping fixture: a fenced code block quoting the literal words `user`/`codex`/`system` (reviewed content), positioned AFTER the real final-response `codex` marker | the fenced quote and the real finding both survive — the fenced lines are never mistaken for genuine markers |
| TC-CXSTRIP-007 | Multiple `codex` turns (reasoning → tool call → final response) | earlier reasoning/tool-call turn text is excluded; only the text after the LAST `codex` marker (the final response) is returned |
| TC-CXSTRIP-008 | Indented (`  user`) or trailing-content (`codexreview`) lines that resemble but are not exact column-0 markers | not treated as markers — returns the input UNCHANGED (fail-safe) |
| TC-CXSTRIP-009 | Tilde-fence fixture: reviewed content quotes bare `user`/`codex`/`system` lines inside a `~~~`-fenced block (not a backtick-fenced one) AFTER the real findings | the `~~~` fence toggles the same `infence` exclusion as a backtick fence; the real `[P2]` findings survive and severity extraction on the result → `P2` (review round-1 finding 2, PR #484) |
| TC-CXSTRIP-010 | Capture with a trailing `tokens used: <N>` (or mixed-case `Tokens Used:`) footer line after the final `codex` marker | the footer line is dropped from the returned text; severity extraction on the result is unaffected by the token count (review round-1 finding 3, PR #484) |
| TC-CXSTRIP-011 | Unfenced-inline-marker fixture: an earlier genuine `[P1]` finding, then an UN-FENCED, column-0 `codex` word flowing directly out of the preceding prose line (no blank line before it, e.g. quoted tool output), then a later genuine `[P2]` finding | the inline hazard word is NOT accepted as the last marker (no blank line precedes it); both the `[P1]` and `[P2]` findings survive, and severity extraction on the result → `P1` (review round-3 finding, PR #484) |

## Acceptance-criteria fixtures

- **Reproduction fixture**: `tests/unit/fixtures/codex-review-stdout-turns-p2-only.txt` — a real-shaped combined `codex review` stdout/stderr capture with the CLI header, a `user` turn marker, an echoed prompt containing ≥3 untagged numbered instruction lines, a reasoning/tool-trace `codex` turn, a final `codex` response with only `[P2]`-tagged findings, and a trailing `tokens used: <N>` footer line. Both the artifact-resolved path (TC-SEVEXT-001) and the turn-marker-stripped fallback (TC-SEVEXT-003) must yield `P2`; a direct whole-capture scan (TC-SEVEXT-002) still yields `none`; the footer line is excluded from the stripped result (TC-CXSTRIP-010).
- **Over-stripping fixture**: `tests/unit/fixtures/codex-review-stdout-turns-overstrip.txt` — reviewed-content that legitimately quotes the literal words `user`/`codex`/`system` inside a backtick-fenced code block, positioned after the real response marker. Proves the boundary detector never mistakes reviewed/tool-output content for a genuine turn marker (TC-SEVEXT-008, TC-CXSTRIP-006).
- **Tilde-fence fixture**: `tests/unit/fixtures/codex-review-stdout-turns-tilde-fence.txt` — the same over-stripping hazard as above, but quoted inside a `~~~`-fenced block instead of a backtick-fenced one (TC-CXSTRIP-009).
- **Unfenced-inline-marker fixture**: `tests/unit/fixtures/codex-review-stdout-turns-unfenced-inline-marker.txt` — a genuine earlier `[P1]` finding, then an UN-FENCED, column-0 `codex` word flowing directly out of the preceding prose line (no blank line before it), then a genuine later `[P2]` finding. Proves the boundary detector's blank-line-before requirement rejects an inline hazard word that fencing alone would miss (TC-CXSTRIP-011, review round-3 finding, PR #484).
- **5-round P2-only loop**: driven through the PRODUCTION helper (`_codex_review_strip_prompt_echo` on the reproduction fixture) at each simulated round via `_review_round_next_count`, then `_review_apply_severity_filter` + `_aggregate_has_p0p1_fail` — rounds 1-4 stay `fail`, round 5 demotes to `pass`, and INV-127's simulated count stays `false` throughout.

## TC-CXRS-MAL: review round 2 — the malformed-echo guard made the fallback route unreachable

Round-1's fix (the sections above) was correct but structurally dead code: a
genuine `codex review` TURN-MARKER capture opens with the wrapper's own
prompt echoed verbatim (that IS the `user` turn's content), which trivially
satisfies [INV-73]'s `_codex_review_stdout_is_malformed` signals 1/2 — the
exact structure a pure prompt-echo/startup-trace triggers on. Since
`_codex_review_classify_stdout` runs the malformed check FIRST, EVERY
turn-marker capture — including one whose final `codex` turn carries a
genuine, fully-formed `[P2]` review — classified `malformed` and never
reached the `codex-stdout-fallback` tagging at all. `tests/unit/test-lib-review-codex.sh` covers the fix (a new signal 0 in
`_codex_review_stdout_is_malformed`, `adapters/codex.sh`):

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-MAL-DET-29 | The real-shaped reproduction fixture (`codex-review-stdout-turns-p2-only.txt`) | `_codex_review_stdout_is_malformed` → NOT malformed (rc 1) |
| TC-CXRS-MAL-DET-30 | The tilde-fence over-strip fixture | → NOT malformed (rc 1) |
| TC-CXRS-MAL-DET-31 | The backtick-fence over-strip fixture | → NOT malformed (rc 1) |
| TC-CXRS-MAL-DET-32 | Turn markers present (header + `user` + `codex`) but NO text after the last `codex` marker (trace captured mid-turn) | signal 0 does not fire (strip helper's output equals the original); falls through to signals 1-3 → STILL malformed (rc 0) |
| TC-CXRS-MAL-DET-33 | The unfenced-inline-marker over-strip fixture | → NOT malformed (rc 1) — signal 0 locates the TRUE last marker, not the inline hazard word |
| TC-CXRS-MAL-CLS-07 | Classifier-level pin on the reproduction fixture | `_codex_review_classify_stdout` → `fail` (the `[P2]` tags survive), NOT `malformed` |
| TC-CXRS-INT-11 | End-to-end: drives the ACTUAL wrapper stdout-fallback block (not a reimplementation) against the reproduction fixture | reaches the fallback and posts `fail` (proves the round-2 fix closes the reachability gap at the wrapper-integration level, not just the unit level) |

## TC-CXRS round 3 — an un-fenced inline marker with no blank line before it

Round 1's over-stripping fix rejected a FENCED quote of the literal words
`user`/`codex`/`system`, but a genuine final response can also legitimately
contain an UN-FENCED, column-0 `codex` word inline in quoted tool or
reviewed-file output — e.g. "Tool output from the reviewed app follows:"
immediately followed by a literal `codex` line. That shape satisfies the
pre-round-3 column-0/exact-word/unfenced discipline, so — being the LAST such
candidate — it won the "last marker" search and discarded every real finding
(including a `[P1]`) that preceded it, reducing a blocking review to a
`[P2]`-only tail. Every genuine turn marker in every known capture shape is
preceded by a blank line (the CLI always closes out the prior turn before
opening a new one); the fix requires that immediately before accepting a
candidate as the last marker (TC-CXSTRIP-011, TC-CXRS-MAL-DET-33).
