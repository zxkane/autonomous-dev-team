# Test Cases: codex review via `codex review` subcommand (INV-62, #218)

All tests live in `tests/unit/test-lib-review-codex.sh` (the pure-function +
launch-builder + classifier harness, the wrapper-wiring source-of-truth
assertions, AND the dev-path byte-for-byte guard `TC-CXRS-DEV-01/02`) plus
backward-compat assertions in the existing multi-agent / per-agent /
cli-exit-grace tests (which must stay green). The pre-existing
`tests/unit/test-lib-agent-codex.sh` (`TC-LA-CODEX-*`) independently pins the
`codex exec` dev branch shape and is the canonical dev-path guard — this PR
leaves it untouched and green.

This refactor moves the codex **review** path from `codex exec --json` + a resume
loop to the purpose-built `codex review "<prompt>"` subcommand. The codex **dev**
path stays on `codex exec`.

## Unit — stdout→verdict classifier (`_codex_review_classify_stdout`)

`codex review` emits human-readable findings. The gate logic the manual
`/codex review` skill uses: any `[P1]` (priority-1 / blocking) marker → FAIL,
otherwise PASS.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-CLS-01 | stdout containing a `[P1]` finding | `fail` |
| TC-CXRS-CLS-02 | stdout with only `[P2]`/`[P3]` findings | `pass` |
| TC-CXRS-CLS-03 | stdout with no priority markers at all (clean review) | `pass` |
| TC-CXRS-CLS-04 | empty stdout | `pass` (no `[P1]` → pass; the wrapper still posts a verdict) |
| TC-CXRS-CLS-05 | `[P1]` appearing mid-line / multiple `[P1]` | `fail` (any occurrence) |
| TC-CXRS-CLS-06 | a `[P1]` only inside a fenced code block quoting the diff is still counted | `fail` (conservative — a blocking finding wins) |
| TC-CXRS-CLS-07 | runs under `set -euo pipefail` without aborting | rc 0, classified token printed |

## Unit — canonical body composition (`_codex_review_compose_body`)

Composes the body the wrapper hands to `post-verdict.sh` when codex did not
self-post. The helper does NOT prepend the `Review PASSED` / `Review findings:`
prefix (post-verdict.sh does that from its `pass`/`fail` arg) — it supplies the
human summary/findings text.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-BODY-01 | pass verdict, non-empty stdout | body summarizes a passing review; mentions codex review |
| TC-CXRS-BODY-02 | fail verdict, stdout with `[P1]` findings | body carries the captured findings text |
| TC-CXRS-BODY-03 | empty stdout, pass | a non-empty default pass summary (post-verdict.sh won't choke) |
| TC-CXRS-BODY-04 | very large stdout | body is truncated under post-verdict.sh's body cap (no `body too long` rejection) |

## Unit — launch builder (`_run_codex_review` argv)

Drives `_run_codex_review` with a stubbed `codex` on PATH that records argv +
prints scripted stdout, and a stubbed `_run_with_timeout` seam.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-LAUNCH-01 | basic launch | argv is `review "<prompt>"` (the prompt is the positional) |
| TC-CXRS-LAUNCH-02 | model supplied | argv carries `-c model="<model>"` |
| TC-CXRS-LAUNCH-03 | model supplied | argv does NOT carry `-m` |
| TC-CXRS-LAUNCH-04 | any launch | argv does NOT carry `--base` |
| TC-CXRS-LAUNCH-05 | any launch | argv does NOT carry `--json` |
| TC-CXRS-LAUNCH-06 | extra-args supplied | the per-agent extra-args are appended to argv as DISTINCT elements |
| TC-CXRS-LAUNCH-07 | launch writes the clean review stdout to the caller's stdout-capture file | the capture file holds codex review's stdout |
| TC-CXRS-LAUNCH-08 | **#218 finding 1**: a MULTI-LINE prompt (the real `build_review_prompt` heredoc) | stays a SINGLE argv element; element count is unaffected by prompt newlines (NOT split into positionals) |
| TC-CXRS-MLP-01 | end-to-end: `_run_codex_review` with a multi-line prompt + a recording stub | the stubbed binary receives the prompt as ONE arg (4 elements total, `argv[0]==review`) |

## Unit — PR-branch worktree for codex review (#218 finding 3)

`codex review` auto-scopes its diff against the CURRENT checkout, so the wrapper
must run it from a worktree checked out to the PR branch — NOT `PROJECT_DIR`
(which the dispatcher keeps on `main`, where the PR diff would be empty). Tested
against a throwaway git repo with a diverging `pr-branch`.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-WT-01 | `_codex_review_prepare_worktree pr-branch <dest>` then cleanup | rc 0; `<dest>` HEAD is the PR-branch tip (the PR change is present); cleanup removes it |
| TC-CXRS-WT-02 | prepare with empty branch / empty dest / non-git-repo cwd | rc 1 (cannot scope → caller degrades) |
| TC-CXRS-WT-03 | prepare for a non-existent branch (no ref resolves) | rc 1 |
| TC-CXRS-WT-03b | **#218 stale-ref**: a clone whose `origin/<branch>` is STALE (no fetch refspec) while the remote advanced | prepare checks out the FRESH tip via `FETCH_HEAD`, NOT the stale `origin/<branch>` (proven to fail against the pre-fix `origin/<branch>`-first resolver) |
| TC-CXRS-WT-03c | **#218 stale-ref**: `origin` present but the `git fetch` FAILS | HARD prepare failure (rc 1) — no fall-through to a stale local/`FETCH_HEAD` ref → caller fails closed |
| TC-CXRS-WT-04 | cleanup on a missing / empty dest | rc 0 always (no `set -e` abort) |
| TC-CXRS-WT-05 | `_run_codex_review` with a prepared worktree | runs `codex review` FROM the worktree; the wrapper's own cwd is unchanged (subshell `cd`) |
| TC-CXRS-WT-06 | `_run_codex_review` with an EMPTY workdir | runs from cwd + logs a loud warning (degraded, never crashes) |
| TC-CXRS-WT-SRC-01..03 | wrapper source-of-truth | the codex branch prepares the PR-branch worktree, passes it to `_run_codex_review` (4th arg), and tears it down |
| TC-CXRS-WT-SRC-04..07 | **#218 finding 1 fail-closed** | the wrapper gates `_run_codex_review` behind a `_cx_wt_ready` flag, sets the `CODEX_REVIEW_NO_WORKTREE_RC` (70) sentinel → `unavailable` on prepare failure, and the stale fail-open "running from PROJECT_DIR" path is removed |

## Unit — bounded re-run (`_run_codex_review`, subsumes #209)

`codex review` has no resume; "resume" is a fresh re-run. A non-zero / stream
exit is re-run, bounded by `CODEX_REVIEW_MAX_RERUNS` (default 3) + the
`AGENT_REVIEW_TIMEOUT` wall-clock deadline. Stub the clock for determinism.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-RUN-01 | run 1 exits 0 (clean) | 1 run, 0 re-runs, rc 0 |
| TC-CXRS-RUN-02 | run 1 exits non-zero, run 2 (re-run) exits 0 | 1 run + 1 re-run, rc 0 (transient ridden out — closes #209) |
| TC-CXRS-RUN-03 | every run exits non-zero, max=3 | 1 run + 3 re-runs then stop, returns last rc (sustained → graceful degrade) |
| TC-CXRS-RUN-04 | `CODEX_REVIEW_MAX_RERUNS=0` | 1 run, 0 re-runs |
| TC-CXRS-RUN-05 | non-numeric `CODEX_REVIEW_MAX_RERUNS` under `set -euo pipefail` | degrades to default, no `unbound variable` crash |
| TC-CXRS-RUN-06 | wall-clock deadline already passed before a re-run | no further re-run (deadline guard) |
| TC-CXRS-RUN-07 | **#218 finding 4**: turn-1 timeout (124) | STOPS the loop immediately — 1 run, 0 re-runs, returns 124 (INV-48 veto) |
| TC-CXRS-RUN-07b | turn-1 timeout then a would-be-clean re-run | NO extra re-run issued (1 run, rc 124) — no duplicate-verdict path |
| TC-CXRS-RUN-07c | turn-1 timeout 137 (`--kill-after` SIGKILL) | breaks immediately — 1 run, returns 137 |
| TC-CXRS-RUN-07d | stream-error then a re-run that ITSELF times out | stops at the timeout — 2 runs, rc 124 (mid-loop timeout veto) |

## Unit — dev-path byte-for-byte guard (`test-lib-review-codex.sh`)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-DEV-01 | the codex dev `run_agent` branch | still emits `codex exec --json … -` (NOT `codex review`) |
| TC-CXRS-DEV-02 | `lib-agent.sh` contains no `codex review` token | the dev primitives are CLI-agnostic (no review knowledge leak) |

> The pre-existing `tests/unit/test-lib-agent-codex.sh` (`TC-LA-CODEX-01`)
> separately pins the `codex exec --json` / `codex exec resume` dev-branch shape;
> this PR keeps it green without modification.

## Unit — wrapper wiring (source-of-truth)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-WIRE-01 | the fan-out codex branch calls `_run_codex_review` | grep hit in `autonomous-review.sh` |
| TC-CXRS-WIRE-02 | `_run_codex_review_with_resume` is GONE from both lib + wrapper | no grep hit |
| TC-CXRS-WIRE-03 | `_codex_log_has_verdict_message` is GONE | no grep hit |
| TC-CXRS-WIRE-04 | the INV-55 `DIFF_START_`/`DIFF_END_` inline-diff block is GONE from the codex branch | no grep hit in `autonomous-review.sh` |
| TC-CXRS-WIRE-05 | non-codex agents still route through bare `run_agent` | grep hit |
| TC-CXRS-WIRE-06 | the wrapper posts the codex stdout fallback verdict via `post-verdict.sh` when codex did not self-post | grep hit (`_codex_review_compose_body` / fallback-post call site) |
| TC-CXRS-WIRE-07 | `bash -n` parses lib-review-codex.sh + autonomous-review.sh | both parse |
| TC-CXRS-WIRE-08 | CI shellcheck still lists lib-review-codex.sh | grep hit in ci.yml |

## Integration / behavioral

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-INT-01 | stubbed codex review prints `[P1]` to stdout, does NOT self-post | wrapper classifies FAIL, composes a `Review findings:` body, posts via post-verdict (one verdict, classifiable by the poller) |
| TC-CXRS-INT-02 | stubbed codex review prints a clean review, does NOT self-post | wrapper classifies PASS, posts a `Review PASSED` body (one verdict) |
| TC-CXRS-INT-03 | codex self-posted a verdict comment | wrapper does NOT double-post (always exactly one verdict) |
| TC-CXRS-INT-04 | stubbed transient-then-recovering codex review (non-zero then clean) | bounded re-run yields a verdict (closes #209 for the review path) |
| TC-CXRS-INT-05 | wrapper posted the PASS fallback, but the immediate re-fetch LAGS (comments API hasn't surfaced it) | resolves `pass` from the wrapper's composed body — NOT left unresolved → dropped `unavailable` (re-fetch-lag guard) |
| TC-CXRS-INT-06 | wrapper posted the FAIL fallback, re-fetch LAGS | resolves `fail` from the wrapper's composed body (a merge veto survives the lag) |
| TC-CXRS-INT-07 | **#218 finding 2**: `_run_codex_review` exited non-zero (CLI usage/auth error stdout, no `[P1]`) | NOT posted as a false PASS; left unresolved for the sweep → `unavailable` (rc-0 gate) |
| TC-CXRS-INT-08 | non-zero exit even with `[P1]` in the partial stdout | still left unresolved (a non-completed review is not a verdict source) |
| TC-CXRS-INT-09 | rc-0 clean review | still posts PASS (the gate admits a completed review) |
| TC-CXRS-INT-10 | **#218 finding 2 (2nd part)**: rc-0 review, EMPTY capture, no self-post | still posts the default PASS — NOT dropped `unavailable` (clean review with no blocking findings; upholds "exactly one verdict") |
| TC-CXRS-INT-04b | **#218 finding 5**: an rc-0 review whose capture MENTIONS the stream-error phrase (e.g. reviewing this PR's stream-error fixtures/detector) but has no `[P1]` | still posts the default PASS — NOT dropped by a broad-substring stream-error skip (the rc-0 gate is the sole gate; the skip is removed) |
| TC-CXRS-WT-SRC-09 | **#218 finding 5** source-of-truth | the wrapper no longer CALLS `_codex_review_has_stream_error` to gate the rc-0 fallback (the helper survives only for `_classify_codex_drop_reason`) |

## Regression / superseded

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-REG-01 | a large-diff codex review no longer needs the inline-diff prompt | the codex prompt contains no `DIFF_START_` marker |
| TC-CXRS-REG-02 | #198 / #209 / #212 machinery for the review path is removed | the resume controller + JSONL verdict parser are deleted |
