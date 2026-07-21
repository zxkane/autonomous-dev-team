# Test Cases - Claude Review Verdict Path

## Permission Argument Assembly

| ID | Scenario | Expected result |
|---|---|---|
| TC-REVIEW-VERDICT-PATH-001 | Claude review member in `auto` | The production fan-out mutation seam appends the artifact run dir and body lane dir with `--add-dir`, plus the three deterministic verdict helper patterns with `--allowedTools`. |
| TC-REVIEW-VERDICT-PATH-002 | Claude review member in `bypassPermissions` | No review permission arguments are injected. |
| TC-REVIEW-VERDICT-PATH-003 | Claude review member in `plan` | No permission arguments are injected and a loud unsupported review-lane warning is logged. |
| TC-REVIEW-VERDICT-PATH-004 | Non-Claude review member in `auto` | No Claude permission arguments are injected. |
| TC-REVIEW-VERDICT-PATH-005 | Operator supplies `AGENT_REVIEW_EXTRA_ARGS_CLAUDE` | Operator arguments remain first and injected arguments follow them exactly. |
| TC-REVIEW-VERDICT-PATH-006 | Permission-injection knob is false | No permission arguments are injected in `auto`. |
| TC-REVIEW-VERDICT-PATH-007 | Dev-side Claude launch | Dev argv is byte-identical to the pre-feature expected argv. |

## Deterministic Writers

| ID | Scenario | Expected result |
|---|---|---|
| TC-REVIEW-VERDICT-PATH-008 | Artifact helper receives JSON on stdin | It writes only to `VERDICT_ARTIFACT_PATH` by same-directory temp file plus atomic rename. |
| TC-REVIEW-VERDICT-PATH-009 | Artifact helper target is unset or invalid | It exits nonzero and creates no final artifact. |
| TC-REVIEW-VERDICT-PATH-010 | Body helper receives text on stdin | It writes only to `VERDICT_BODY_FILE` and preserves multiline content. |
| TC-REVIEW-VERDICT-PATH-011 | Body helper target is unset or invalid | It exits nonzero and creates no final body. |
| TC-REVIEW-VERDICT-PATH-012 | Rendered member prompt | It instructs the complete helper sequence: body write, atomic artifact write, then `post-verdict.sh`; it contains no direct `cat`/`printf` verdict-file redirection. |

## Final-Text Recognition

| ID | Scenario | Expected result |
|---|---|---|
| TC-REVIEW-VERDICT-PATH-013 | Result first line starts `Review PASSED` | Recognized as `pass`. |
| TC-REVIEW-VERDICT-PATH-014 | Result first line starts `Review findings:` | Recognized as `fail`. |
| TC-REVIEW-VERDICT-PATH-015 | Arbitrary or ambiguous prose | Recognized as `none`. |
| TC-REVIEW-VERDICT-PATH-016 | Verdict phrase is quoted or appears after other text | Recognized as `none`. |
| TC-REVIEW-VERDICT-PATH-017 | Result record has `is_error: true` | Recognized as `none`. |
| TC-REVIEW-VERDICT-PATH-018 | Result field is missing or non-string | Recognized as `none`. |
| TC-REVIEW-VERDICT-PATH-019 | JSONL contains malformed lines | Malformed records are ignored and do not produce a verdict. |
| TC-REVIEW-VERDICT-PATH-020 | Multiple valid result records | The last valid, non-error, string-valued result record wins. |
| TC-REVIEW-VERDICT-PATH-021 | Result starts on a later line with canonical grammar | Recognized as `none`; only the first line is authoritative. |
| TC-REVIEW-VERDICT-PATH-022 | Legacy `_classify_verdict_body` receives arbitrary prose | Existing fail-first behavior remains unchanged. |

## Current-Run Binding And Fallback Gates

| ID | Scenario | Expected result |
|---|---|---|
| TC-REVIEW-VERDICT-PATH-023 | Prior-round PASS exists in the old reusable log | The current session-suffixed capture does not read it and no current vote is produced. |
| TC-REVIEW-VERDICT-PATH-024 | Current session capture has anchored PASS and launch rc 0 | The production per-member fallback seam posts via `post-verdict.sh`, resolves `pass`, and tags source `claude-finaltext-fallback`. |
| TC-REVIEW-VERDICT-PATH-025 | Current session capture has anchored FAIL and launch rc 0 | Wrapper posts via `post-verdict.sh`, resolves `fail`, and tags source `claude-finaltext-fallback`. |
| TC-REVIEW-VERDICT-PATH-026 | Launch rc is 124 with anchored final text | Fallback is refused; terminal state is `timed-out`. |
| TC-REVIEW-VERDICT-PATH-027 | Launch rc is 137 with anchored final text | Fallback is refused; terminal state is `timed-out`. |
| TC-REVIEW-VERDICT-PATH-028 | Launch rc is another nonzero value | Fallback is refused; terminal state is `unavailable`. |
| TC-REVIEW-VERDICT-PATH-029 | Artifact is malformed and final text is anchored | Fallback is refused under INV-78 Clause V1. |
| TC-REVIEW-VERDICT-PATH-030 | Valid artifact and conflicting final text | Artifact wins; final text is not consulted. |
| TC-REVIEW-VERDICT-PATH-031 | Comment verdict and conflicting final text | Comment wins; final text is not consulted. |
| TC-REVIEW-VERDICT-PATH-032 | Final-text fallback knob is false | No final text is consulted and the legacy terminal resolution remains. |
| TC-REVIEW-VERDICT-PATH-033 | Wrapper fallback post fails | The exact production fallback seam leaves the agent unresolved for terminal `unavailable`; no source tag claims success. Unit and fleet E2E fixtures both execute this branch. |
| TC-REVIEW-VERDICT-PATH-034 | Non-Claude member has anchored text | No Claude final-text fallback is attempted. |

## Hermetic End-To-End Fleet

| ID | Scenario | Expected result |
|---|---|---|
| TC-REVIEW-VERDICT-PATH-035 | Stub Claude in `auto` honors injected arguments | It executes body helper, artifact helper, and `post-verdict.sh` unattended; channel 1 resolves the member without fallback. |
| TC-REVIEW-VERDICT-PATH-036 | Same stub in `bypassPermissions` | It receives no injected arguments. |
| TC-REVIEW-VERDICT-PATH-037 | Stub Claude exits 0 with anchored PASS but posts nothing | Session-bound final-text fallback resolves `pass` with source `claude-finaltext-fallback`. |
| TC-REVIEW-VERDICT-PATH-038 | Stub Claude exits 0 with anchored FAIL but posts nothing | Session-bound final-text fallback resolves `fail` with source `claude-finaltext-fallback`. |
| TC-REVIEW-VERDICT-PATH-039 | Stub Claude exits 0 with ambiguous result text | It remains `unavailable`. |
| TC-REVIEW-VERDICT-PATH-040 | Stub Claude exits 124 with anchored verdict text | It remains `timed-out`; INV-48 veto is preserved. |
| TC-REVIEW-VERDICT-PATH-041 | Stub Claude has malformed artifact plus anchored final text | It remains unavailable/timed-out according to rc; fallback never rescues it. |
| TC-REVIEW-VERDICT-PATH-042 | Verdict-body lane allocation fails and returns the `/tmp` sentinel | Permission injection is refused; the temporary root is never granted with `--add-dir`. |
