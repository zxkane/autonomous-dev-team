# Test cases: post-failed verdict drop reason (INV-69, issue #247)

Unit tests in `tests/unit/test-lib-review-postfail.sh` (the new CLI-agnostic
detector) and `tests/unit/test-post-verdict.sh` (extended: breadcrumb on a failed
post), plus source-of-truth assertions against `autonomous-review.sh`.

The breadcrumb path is `pid_dir_for_project()/verdict-postfail-<session_id>`. Tests
pin `AUTONOMOUS_PID_DIR` (and `PROJECT_ID`) to a temp dir so the path is hermetic.

## TC-PF-BC: `post-verdict.sh` writes the breadcrumb on a failed post

| ID | Scenario | Expected |
|----|----------|----------|
| TC-PF-BC-01 | stubbed `scripts/gh issue comment` exits non-zero | `post-verdict.sh` exits 1 AND a breadcrumb file exists at `verdict-postfail-<sid>` |
| TC-PF-BC-02 | (same) | breadcrumb records `issue=<n>`, `agent=<name>`, `session=<sid>`, `gh_rc=<rc>` |
| TC-PF-BC-03 | (same) | breadcrumb file mode is 0600 |
| TC-PF-BC-04 | stubbed `gh` exits 0 (success) | NO breadcrumb file is written; helper exits 0 + echoes the URL |
| TC-PF-BC-05 | `pid_dir_for_project` cannot resolve (PROJECT_ID unset / unwritable) on a failed post | helper STILL exits 1 (breadcrumb skipped silently, no abort) |
| TC-PF-BC-06 | breadcrumb directory write fails on a failed post | helper exit code is still 1 (breadcrumb best-effort, never load-bearing) |
| TC-PF-BC-07 | `post-verdict.sh` parses under `bash -n` and runs under `set -euo pipefail` | rc as above, no unbound-variable abort |

## TC-PF-DET: `_classify_postfail_drop_reason <session_id>`

| ID | Input (breadcrumb state for the session) | Expected stdout |
|----|------------------------------------------|-----------------|
| TC-PF-DET-01 | breadcrumb present with `gh_rc=1` | `post-failed:gh-rc 1` |
| TC-PF-DET-02 | breadcrumb present, no parseable rc | `post-failed` |
| TC-PF-DET-03 | no breadcrumb for the session | `` (empty) |
| TC-PF-DET-04 | breadcrumb path is a dir / unreadable | `` (empty, no crash) |
| TC-PF-DET-05 | empty session id arg | `` (empty, no crash) |
| TC-PF-DET-06 | runs under `set -euo pipefail` (absent breadcrumb) | rc 0 (always) |
| TC-PF-DET-07 | existing breadcrumb with **no** `gh_rc`, under `set -euo pipefail` + `inherit_errexit` (#247 finding) | rc 0 (no abort) AND `post-failed` — the `gh_rc` grep exits 1, so without `\|\| true` inside the `$(…)` the failed assignment aborts the wrapper once errexit propagates into the substitution |

## TC-PF-PHR: `_postfail_drop_reason_phrase <reason-token>`

| ID | Input token | Expected (substring) |
|----|-------------|----------------------|
| TC-PF-PHR-01 | `post-failed:gh-rc 1` | contains `post-failed` AND `gh rc 1` |
| TC-PF-PHR-02 | `post-failed` (no rc) | contains `post-failed`, no `gh rc` |
| TC-PF-PHR-03 | `` (empty) | empty |
| TC-PF-PHR-04 | unknown token | empty (no over-claim) |

## TC-PF-SRC: source-of-truth wiring (`autonomous-review.sh`)

| ID | Assertion |
|----|-----------|
| TC-PF-SRC-01 | wrapper sources `lib-review-postfail.sh` |
| TC-PF-SRC-02 | wrapper calls `_classify_postfail_drop_reason "${AGENT_SESSION_IDS[$_i]}"` for an `unavailable` agent |
| TC-PF-SRC-03 | the post-failed check runs BEFORE the per-CLI agy/codex/kiro branches (precedence) |
| TC-PF-SRC-04 | the dropped-agent comment body interpolates the post-failed reason when a breadcrumb exists |
| TC-PF-SRC-05 | CI shellcheck job lists `lib-review-postfail.sh` |
| TC-PF-SRC-06 | `bash -n` parses `lib-review-postfail.sh` AND `post-verdict.sh` AND `autonomous-review.sh` |

## TC-PF-REG: regression

| ID | Assertion |
|----|-----------|
| TC-PF-REG-01 | an `unavailable` agent with NO breadcrumb keeps the bare `unavailable` wording (no over-claim) and falls through to the per-CLI scrapers unchanged |
| TC-PF-REG-02 | a post-failed agent is STILL dropped `unavailable` from the vote — INV-40 aggregation truth table unchanged (`test-autonomous-review-multi-agent` / `test-review-agent-timeout` stay green) |
| TC-PF-REG-03 | an agy agent dropped for quota (breadcrumb absent, agy log present) still reports the INV-58 quota reason — the post-failed precedence does not mask a genuine CLI-specific drop when no breadcrumb exists |
| TC-PF-REG-04 | existing `test-post-verdict.sh` cases (trailer composition, first-line phrasing, exit codes, model arg) stay green — the breadcrumb addition does not regress them |
