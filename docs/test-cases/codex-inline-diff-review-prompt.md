# Test cases — codex review prompt inlines the PR diff (INV-55)

Covers `autonomous-review.sh::build_review_prompt` codex-lane inline-diff behavior.
Test file: `tests/unit/test-codex-inline-diff-prompt.sh`.

## Source-of-truth (function-body greps)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXIN-SRC-01 | `build_review_prompt` has a codex-gated branch | matches `_agent_name == "codex"` |
| TC-CXIN-SRC-02 | codex lane fetches the diff via `gh pr diff "${PR_NUMBER}"` | present |
| TC-CXIN-SRC-03 | emits `DIFF_START` marker | present |
| TC-CXIN-SRC-04 | emits `DIFF_END` marker | present |
| TC-CXIN-SRC-05 | instructs codex NOT to run `git diff` | "NOT run … git diff" present |
| TC-CXIN-SRC-06 | size guard keyed on `CODEX_REVIEW_INLINE_DIFF_MAX_BYTES` | present |
| TC-CXIN-SRC-07 | markers are nonce'd with the agent session id | `DIFF_(START\|END)_${_cx_nonce}` / `_cx_nonce=…_agent_session_id` present |

## Behavioral (rendered prompt, stubbed `gh pr diff`)

The function is extracted to a tempfile and **sourced** (one heredoc-processing
level, exactly as the real wrapper does — `eval` of the text would double-process
the escaping and misrender). `gh pr diff` is stubbed to emit a sentinel diff body.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXIN-BEHAVE-01 | render for `codex` | the stub diff body (`SENTINEL_NEW_DIFF_BODY`) appears INLINE between the markers |
| TC-CXIN-BEHAVE-02 | render for `claude` (non-codex) | the stub diff body does NOT appear (claude self-fetches) |
| TC-CXIN-BEHAVE-03 | render for `codex` | the "do NOT run git diff" instruction is present |
| TC-CXIN-BEHAVE-04 | render for `codex` | the rendered `DIFF_END` marker is nonce'd (`DIFF_END_<sid>`) |
| TC-CXIN-BEHAVE-05 | diff body contains a literal `DIFF_END` + injected directive | the injected text stays BEFORE the real `DIFF_END_<sid>` marker (data position) — boundary not forged |

## Not unit-tested (verified manually / by re-review)

- The size-guard fall-back branch (diff > `CODEX_REVIEW_INLINE_DIFF_MAX_BYTES`)
  renders the "read it with a SINGLE `gh pr diff`" note instead of inlining — the
  byte-count guard (`wc -c | tr -dc 0-9`, default 0) is exercised implicitly by the
  behavioral render (a small sentinel diff stays under the default 600k cap).
- End-to-end confirmation that a real codex review reaches a verdict and is no
  longer dropped `unavailable` is validated by re-reviewing a live PR (#193) with
  the merged code — see the INV-55 entry's Why field for the pre-fix evidence
  (320k input tokens, no verdict, `CODEX_REVIEW_MAX_RESUMES=3` exhausted).
