# Dispatcher SKILL.md slimming refactor

PR-3 of the pipeline-docs plan. Extracts the 224 lines of bash currently embedded in `skills/autonomous-dispatcher/SKILL.md` into a single-entry-point script (`dispatcher-tick.sh`) backed by a helper library (`lib-dispatch.sh`). **Pure refactor — zero behavior change.**

## Why

Current `SKILL.md`: 438 lines, of which 224 (51%) are bash code blocks the dispatcher agent reads and re-types verbatim each tick. This has three problems:

1. **Bug surface**: every change to the dispatcher logic is a SKILL.md edit, which is reviewed as prose, not as code (no shellcheck, no unit tests, no diff against a working baseline). Recent bugs #41, #50, #53, #54, #56, #57 all touched these bash blocks.
2. **Re-typing risk**: the agent occasionally "improves" or paraphrases the bash on its way through the prompt → subtle drifts (e.g. dropping a stderr capture, changing a regex anchor).
3. **Maintenance overhead**: 224 lines of bash + 214 lines of prose all in one file makes targeted reading hard.

After PR-2, `docs/pipeline/dispatcher-flow.md` is the spec. SKILL.md should be the agent invocation contract, not the spec.

## Scope: what changes

### New files

- `skills/autonomous-dispatcher/scripts/lib-dispatch.sh` — ~13 small composable functions (helpers).
- `skills/autonomous-dispatcher/scripts/dispatcher-tick.sh` — single entry-point script. Sources `lib-dispatch.sh`, runs Steps 1–5 in order in one process, with `JUST_DISPATCHED` as a normal in-process bash array.
- `tests/unit/test-lib-dispatch.sh` — unit tests for the helpers.

I considered splitting Steps 2/3/4/5 into separate sub-scripts but rejected that — `JUST_DISPATCHED` is tick-local state that has to flow from Steps 2/3/4 into Step 5, and the simplest way to share it is to keep all five steps in one process. The lib-dispatch.sh helpers are still testable in isolation; the tick script is just orchestration glue.

### Modified files

- `skills/autonomous-dispatcher/SKILL.md` — slim from 438 → ~80 lines. Body becomes prose explaining what the dispatcher does, plus a single delegation: `bash "$PROJECT_DIR/scripts/dispatcher-tick.sh"`. Cross-links `docs/pipeline/` for the full state-machine spec.
- `docs/pipeline/dispatcher-flow.md` — update prose to reference the new scripts (instead of "in SKILL.md").
- `.github/workflows/ci.yml` — extend ShellCheck job to cover the new scripts.

### Out of scope (deferred to later PRs)

- **#58** readlink-vendor in lib-agent.sh — not touched here. Lives in lib-agent.sh, which this PR doesn't modify.
- **#59** resume-on-completed-session — needs a new gate in scan-pending-dev.sh (INV-12), but adding it would mix refactor with behavior change. Defer to PR-5.
- **#60** wall-clock timeout — lives in `lib-agent.sh::run_agent`. Defer to PR-5.
- **#61** MERGED dependency check — tempting (the dependency-check helper is being created here), but folding in a one-line behavior change muddies bisect. Defer to PR-4.
- **#62** multi-repo dispatch — major architectural change, separate PR.
- **#67** INV-15 SIGTERM race — wrapper-side fix, doesn't touch dispatcher tick logic. Defer to its own PR.
- **#70** Dev Session ID regex broken on jq 1.6+ — surfaced by PR-3's unit tests. The original SKILL.md uses `(?P<id>...)` which jq Oniguruma rejects. PR-3 preserves the bug byte-for-byte; the test for `extract_dev_session_id` asserts the BROKEN behavior (returns empty) so the refactor stays pure. Fix bundled into PR-4.

The refactor is the contract; bug fixes layer onto it cleanly because each helper has a single, documented responsibility.

## Mapping: current SKILL.md → new structure

| SKILL.md section | Going to | Helper / script |
|---|---|---|
| Step 1 concurrency count | `lib-dispatch.sh` | `count_active()` |
| Step 2 scan-new query | `lib-dispatch.sh` | `list_new_issues()` |
| Step 2 dependency check | `lib-dispatch.sh` | `check_deps_resolved()` (preserves current `state != "CLOSED"` bug — #61 fixed in PR-4) |
| Step 2 dispatch loop | `scan-new.sh` | entry point |
| Step 3 scan-pending-review query | `lib-dispatch.sh` | `list_pending_review()` |
| Step 3 dispatch loop | `scan-pending-review.sh` | entry point |
| Step 4 scan-pending-dev query | `lib-dispatch.sh` | `list_pending_dev()` |
| Step 4 retry counter | `lib-dispatch.sh` | `count_retries()`, `mark_stalled()` |
| Step 4 session-id extract | `lib-dispatch.sh` | `extract_dev_session_id()` |
| Step 4 dispatch loop | `scan-pending-dev.sh` | entry point |
| Step 5 PID liveness | `lib-dispatch.sh` | `pid_alive()` |
| Step 5a PR-info / CI / idle | `lib-dispatch.sh` | `fetch_pr_for_issue()`, `ci_is_green()`, `pr_idle_seconds()` |
| Step 5b reviewed-HEAD trailer | `lib-dispatch.sh` | `last_reviewed_head()` |
| Step 5 orchestration (5a + 5b branches) | `detect-stale.sh` | entry point |
| `JUST_DISPATCHED` array | `dispatcher-tick.sh` | tick-local var, passed to `detect-stale.sh` via env |

## Behavior preservation

The refactor MUST NOT change any observable behavior. Specifically:

- **Same labels** are written at the same transition points.
- **Same comments** are posted with the same exact phrasing (the [INV-06] keyword contract depends on this).
- **Same exit codes** from each script. (`dispatcher-tick.sh` exits 0 on success, 1 on tick-level failure.)
- **Same retry-counter semantics** ([INV-05] cutoff rule).
- **Same `JUST_DISPATCHED` skip rule** ([INV-09]).
- **Same `> 300` strict idle gate** ([INV-10]).
- **Same fail-closed semantics** on malformed jq output / token expiry.
- **Same `mktemp` for CI-error capture** (CWE-377 mitigation).

To verify: every comment string, every label name, and every regex pattern in the new scripts must be byte-for-byte identical to what appears in `main` SKILL.md today.

## Test plan

Unit tests in `tests/unit/test-lib-dispatch.sh`, mocking `gh` via stub functions:

1. `check_deps_resolved`: 0 deps → resolved; one CLOSED → resolved; one OPEN → blocked; one MERGED → blocked (preserves the #61 bug, which PR-4 will then fix and re-run this test).
2. `count_retries` with stalled-cutoff: comment timeline with 2 failures before stall + 1 after → counter returns 1; comment timeline with 0 stall comments → counter returns total failure count.
3. `extract_dev_session_id`: comment with `Dev Session ID: \`abc-123\`` → returns `abc-123`; comment with `Review Session ID:` only → returns empty (the regex must NOT confuse them).
4. `pr_idle_seconds`: PR.updatedAt = now-301s → returns 301 (caller's `> 300` gate fires); PR.updatedAt = now-300s → returns 300 (gate does NOT fire); malformed timestamp → returns empty (caller leaves alone).
5. `last_reviewed_head`: trailer with valid SHA → returns SHA; no trailer → returns empty; multiple trailers → returns the last.
6. `pid_alive`: live PID → returns 0; dead PID → returns 1; missing PID file → returns 1.

E2E verification (manual): run `bash dispatcher-tick.sh` once locally against a test repo with one autonomous issue, confirm the same labels and comments appear as before the refactor. Compare against an old SKILL.md run via git stash.

## Per CONTRIBUTING.md Rule 1

This PR touches `skills/autonomous-dispatcher/scripts/*.sh` and `skills/autonomous-dispatcher/SKILL.md` (both watched paths). It also touches `docs/pipeline/dispatcher-flow.md`. The CI gate passes via the docs-touched path.

## Risk

Medium. Largest refactor of the dispatcher to date. Mitigations:

- **Behavior preservation by construction**: every helper is a 1-1 port of an existing bash block. Comment phrasings copied verbatim. Regex patterns copied verbatim.
- **Unit tests** for each helper (6 tests, see test plan).
- **Manual E2E** against a test repo before merging.
- **No new gates, no new comments, no removed retries** — anything that smells like "while I'm here..." gets deferred.
- **Fast rollback**: if the refactor introduces a regression, revert the merge commit. The old SKILL.md returns intact, the new scripts get deleted but were not yet referenced by anything else.

If the refactor surfaces a real bug in current behavior (e.g. via testing), I will document it as a new issue and fix it in PR-4 — not in this PR.
