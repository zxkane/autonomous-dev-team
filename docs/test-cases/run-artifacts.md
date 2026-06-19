# Test Cases — Per-run artifact directory + run-id threading + `status.sh` (#235)

ID format: `TC-RUN-ARTIFACTS-NNN`. Invariant under test: **INV-81** (run-id
threading + durable per-run artifact dir + read-only `status.sh` inspector,
observe-only).

Suites:
- Unit: `tests/unit/test-lib-run-artifacts.sh` (001–039)
- Unit: `tests/unit/test-status.sh` (040–069)
- E2E:  `tests/e2e/run-run-artifacts-e2e.sh` (080–089)

---

## lib-run-artifacts.sh — minting & uniqueness

| ID | Scenario | Expected |
|----|----------|----------|
| TC-RUN-ARTIFACTS-001 | `mint_run_id dev 235` with `PROJECT_ID=proj` | echoes `proj-235-dev-<ts>` matching `^proj-235-dev-[0-9]{8}T[0-9]{6}Z$` |
| TC-RUN-ARTIFACTS-002 | `mint_run_id review 235` | side segment is `review` |
| TC-RUN-ARTIFACTS-003 | `RUN_ID=pinned-id mint_run_id dev 235` | honors pre-set `RUN_ID`, echoes `pinned-id` unchanged |
| TC-RUN-ARTIFACTS-004 | minting for two different issues (`235`, `236`) same side/second | run-ids differ (issue segment) |
| TC-RUN-ARTIFACTS-005 | minting dev vs review for same issue same second | run-ids differ (side segment) |
| TC-RUN-ARTIFACTS-006 | `mint_run_id` with `PROJECT_ID` unset | returns non-zero / empty (no crash); caller guards |

## run_dir_for / coordination with #233

| ID | Scenario | Expected |
|----|----------|----------|
| TC-RUN-ARTIFACTS-010 | `run_dir_for <run-id>` under `XDG_STATE_HOME=/x` | echoes `/x/autonomous-proj/runs/<run-id>` |
| TC-RUN-ARTIFACTS-011 | `XDG_STATE_HOME` unset, `HOME=/h` | falls back to `/h/.local/state/autonomous-proj/runs/<run-id>` |
| TC-RUN-ARTIFACTS-012 | parent `runs/` dir equals #233's `_verdict_artifact_dir` parent | same `…/autonomous-proj/runs` prefix (coordination, not duplication) |
| TC-RUN-ARTIFACTS-013 | a #233 bare-UUID sibling dir present under `runs/` | NOT matched by the wrapper-run-id glob `*-235-dev-*` / `*-235-review-*` |

## run_artifacts_init / finalize / meta.json

| ID | Scenario | Expected |
|----|----------|----------|
| TC-RUN-ARTIFACTS-020 | `run_artifacts_init dev 235` | creates run dir mode 0700; exports `RUN_DIR`; `meta.json` is valid JSON with `started_at`, `run_id`, `side=dev`, `issue=235` |
| TC-RUN-ARTIFACTS-021 | meta.json env summary | contains `agent`, `mode`, `gh_auth_mode`; does NOT contain a token/PEM key (redaction) |
| TC-RUN-ARTIFACTS-022 | `run_artifacts_finalize "$RUN_DIR" 0` | meta.json gains `ended_at`, `rc=0`, numeric `duration_s` |
| TC-RUN-ARTIFACTS-023 | finalize with rc=1 | `rc=1` recorded; valid JSON preserved |
| TC-RUN-ARTIFACTS-024 | init when target dir already exists (same minted string) | disambiguates to `<run-id>-2`; `RUN_DIR`/`RUN_ID` updated; both dirs coexist |
| TC-RUN-ARTIFACTS-025 | init under unwritable XDG base (`set -e` active) | returns non-zero internally but is best-effort (caller `|| true`); surrounding rc unchanged; no abort |
| TC-RUN-ARTIFACTS-026 | finalize on a run dir that was never created | no-op, returns 0 (best-effort) |
| TC-RUN-ARTIFACTS-027 | run.log seeded with first-line pointer | `run.log` first line contains `run-dir:` and `tmp-log:` |

## run_footer

| ID | Scenario | Expected |
|----|----------|----------|
| TC-RUN-ARTIFACTS-030 | `run_footer` with `RUN_ID`+`RUN_DIR` set | echoes a block containing `run-id: <id>` and `artifacts: <dir>` |
| TC-RUN-ARTIFACTS-031 | `run_footer` with `RUN_ID` unset | echoes nothing (empty) — a comment is never broken |
| TC-RUN-ARTIFACTS-032 | footer appended to a body | body + `\n---\n` separator + footer line present |
| TC-RUN-ARTIFACTS-033 | footer string is single-trailer (no secrets) | does not contain `GH_TOKEN`, PEM, or app id |

## run_prune

| ID | Scenario | Expected |
|----|----------|----------|
| TC-RUN-ARTIFACTS-034 | dir with `started_at` 31 days old, retention 30 | pruned (removed) |
| TC-RUN-ARTIFACTS-035 | dir with `started_at` 29 days old, retention 30 | retained (age boundary — strictly older than N) |
| TC-RUN-ARTIFACTS-036 | the active run dir is 99 days old (mtime), prune called from init | **never pruned** (active run-id excluded by name) |
| TC-RUN-ARTIFACTS-037 | #233 bare-UUID dir present, old | NOT pruned by run_prune (only wrapper-run-id dirs are candidates) |
| TC-RUN-ARTIFACTS-038 | prune with non-numeric retention | falls back to default 30, no crash |
| TC-RUN-ARTIFACTS-039 | prune on missing `runs/` dir | no-op, returns 0 |
| TC-RUN-ARTIFACTS-090 | `run_artifacts_init` prunes ALL issues, not just the active one (#235 r14) | init for issue 235 reaps a 99-day dir belonging to issue 236; the active 235 run dir is created + retained |
| TC-RUN-ARTIFACTS-091..095 | `run_artifacts_persist_log` (#235 r14) | copies a /tmp per-agent log into `agent-logs/<label>.log` (content preserved); sanitizes a path-traversal label (slashes→`_`, stays inside agent-logs/); missing src → rc-0 no-op; empty dir → rc-0 no-op |
| TC-RUN-ARTIFACTS-096 | `run_artifacts_init` breadcrumbs the legacy /tmp agent log (#235 r15) | `$LOG_FILE` gains a `[run-artifacts] run-dir: … · run-id: …` line (first line on an empty log); one breadcrumb per distinct run dir; the idempotency guard keeps the original dir's breadcrumb at exactly one occurrence |

## status.sh — four canonical states (TC + predicate parity)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-RUN-ARTIFACTS-040 | **idle** issue (pending-dev, no live PID) | output reports labels=pending-dev, lease=none, next action mentions `dev-new` |
| TC-RUN-ARTIFACTS-041 | **in-progress + live lease** (`pid_alive` true via live PID) | reports lease ALIVE; next action = "leave alone / wrapper alive" |
| TC-RUN-ARTIFACTS-042 | **stalled + dead PID** (in-progress, PID dead, no near-success) | reports lease DEAD; next action mentions crash declaration → pending-dev + retry count |
| TC-RUN-ARTIFACTS-043 | **approved-awaiting-merge** (PR approved + no-auto-close) | reports reviewDecision=APPROVED + no-auto-close; next action = operator merges manually |
| TC-RUN-ARTIFACTS-044 | last 3 run-ids + outcomes rendered | shows up to 3 most-recent `*-<issue>-*` run dirs with their meta rc/outcome, newest first |
| TC-RUN-ARTIFACTS-045 | last drop reasons rendered | reads `drops.jsonl` from the latest review run dir; lists agent+reason |
| TC-RUN-ARTIFACTS-046 | retry count surfaced | matches `count_retries <issue>` exactly (same value) |
| TC-RUN-ARTIFACTS-047 | no run dirs yet | "no runs recorded" line; no crash |
| TC-RUN-ARTIFACTS-048 | `--project <id>` override | resolves dirs/predicates for the named project (PROJECT_ID override) |
| TC-RUN-ARTIFACTS-049 | invalid/missing issue arg | usage error, non-zero exit, no gh calls |
| TC-RUN-ARTIFACTS-050 | **read-only contract** | status.sh issues NO `gh issue edit`, `gh pr merge`, or `gh * comment` (grep-assert the source has no mutation calls) |
| TC-RUN-ARTIFACTS-051 | **predicate parity** | status.sh source `source`s `lib-dispatch.sh` AND calls `pid_alive`, `count_retries`, `fetch_pr_for_issue` (grep-assert — no duplicated predicate logic) |

## E2E — stub fleet + reboot simulation

| ID | Scenario | Expected |
|----|----------|----------|
| TC-RUN-ARTIFACTS-080 | stub dev run (init→finalize rc 0) populates run dir | `meta.json` + `run.log` present under XDG state root |
| TC-RUN-ARTIFACTS-081 | stub review run populates run dir + drops.jsonl | drop reason recorded |
| TC-RUN-ARTIFACTS-082 | comment footers carry the run-id | rendered footer contains the exact minted run-id for both sides |
| TC-RUN-ARTIFACTS-083 | `status.sh` output snapshot for the seeded issue | contains labels, lease, last run-ids, next action lines |
| TC-RUN-ARTIFACTS-084 | reboot simulation: clear `/tmp`, keep XDG state | run dirs + meta.json + run.log still present and readable (durability AC) |
| TC-RUN-ARTIFACTS-085 | FAIL-comment footer → dir round trip (AC1) | given a footer string, the referenced artifact dir exists and contains raw evidence (meta.json/run.log) |
| TC-RUN-ARTIFACTS-086 | wrapper-owned verdict comment carries the footer (AC1, #235 review [P1]) | the review wrapper's `_append_run_footer_to_file` appends the run-id/artifacts footer to a verdict body before `post-verdict.sh`; no-op when `RUN_ID` unset; both wrapper-owned post sites (codex stdout-fallback + INV-78 aggregate) call it |
| TC-RUN-ARTIFACTS-087 | EVERY wrapper-owned diagnostic comment is footered (AC1, #235 review [P1] r4) | structural grep-assert over `autonomous-review.sh`: every real `gh issue/pr comment` call (no-PR-found, E2E-gate, smoke, timeout-veto, dropped-agent, bot-review, mergeable, approval, no-auto-close, auto-merge-failure) carries `run_footer`/`_append_run_footer_to_file` within its body window; the `Reviewed HEAD:` machine-channel trailer is the deliberate exception (NOT footered) |
| TC-ERR-ENVELOPE-042 | startup-failure error envelope carries the footer (AC1, #235 review [P1]) | in `tests/e2e/run-error-envelope-e2e.sh`: with `run_artifacts_init` run BEFORE `error_surface` (the wrappers' new early-init ordering), the posted envelope body gains `run-id: …` + `artifacts: <durable run dir>`, and the `<!-- adt-error-envelope: … -->` marker is preserved (footer appended at END) |
