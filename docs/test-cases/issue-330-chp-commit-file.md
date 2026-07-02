# Test Cases — `chp_commit_file` for `upload-screenshot.sh` (#330)

Test file: `tests/unit/test-chp-commit-file.sh` (`TC-CCF-NNN`).
Run under `env -u PROJECT_DIR bash tests/unit/test-chp-commit-file.sh`.

> Mandatory TDD. The golden whole-op needs a **stateful `gh` stub** that emits
> realistic per-endpoint JSON — the leaf PIPES `gh api | jq -r '.ref // empty'`
> at the get-ref steps and `.sha` at the create/put steps, so a pure
> argv-recorder stub (writes nothing to stdout) would break the multi-call
> orchestration ([P3 F2 fix]).

## 1. Golden whole-op (AC1)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CCF-001 | Orphan branch ABSENT (get-ref → empty) | leaf runs create-blob → tree → commit → ref → re-get-ref verify → get-contents → put-contents; echoes the put-contents `.content.sha`; rc 0 |
| TC-CCF-002 | Branch PRESENT (get-ref → ref) | leaf SKIPS branch-create; runs get-contents (existing → sha for update) → put-contents (with `sha`); echoes committed SHA; rc 0 |
| TC-CCF-003 | put-contents step fails (empty `.content.sha`) | leaf returns NON-zero (so the caller's `chp_commit_file … || fail` triggers) |
| TC-CCF-004 | Branch-create fails (re-get-ref still empty) | leaf returns NON-zero |
| TC-CCF-005 | New-file (branch present, file ABSENT → get-contents empty) | put-contents WITHOUT `sha` (create, not update); echoes SHA; rc 0 |

## 2. Trap-hazard regression (AC2 — the load-bearing fix)

> The leaf uses a **function-scoped, SELF-DISARMING `trap '…; trap - RETURN' RETURN`**
> (AC2's literal contract). `trap … EXIT` would replace the standalone caller's EXIT
> trap. A BARE `trap … RETURN` (no self-disarm) is no safer — it is NOT cleared at
> leaf return, so it persists and re-fires when the `chp_commit_file` shim returns
> into the caller, by then the leaf's `local` temps are out of scope → `unbound
> variable` under `set -u` (both crash modes reproduced on-box). The self-disarm
> — the trap body's own last action is `trap - RETURN` — keeps the RETURN-trap
> contract while firing exactly once per invocation, sidestepping the persistence
> hazard.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CCF-010 | Source-shape: leaf installs a function-scoped `trap … RETURN`, never `trap … EXIT` | `grep` of the `chp_github_commit_file` body (comments stripped) finds a `trap '…' RETURN` (TC-CCF-010) and no `trap … EXIT` (TC-CCF-010a) |
| TC-CCF-010b/c | The RETURN trap SELF-DISARMS (`trap - RETURN` is its own last action) and its body cleans `$json_tmpfile`/`$upload_response_file` | both assertions green |
| TC-CCF-011 | Behavioral (the production crash path): a caller under `set -euo pipefail` with its OWN `trap … EXIT` sources the FULL `lib-code-host.sh` and calls the verb TWICE THROUGH the `chp_commit_file` shim; the caller reaches `PRE_EXIT_OK`, both shim calls return their SHA, the caller's EXIT trap STILL fires and its temp is cleaned, with NO `unbound variable` on either call | TC-CCF-011/011b/011b2/011c/011d/011e all green (no crash, both SHAs returned, no `unbound variable`, caller EXIT trap fires, caller temp cleaned) |

## 3. REPO threaded from arg (AC3)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CCF-020 | A DIFFERENT global `$REPO` is exported; leaf called with `$1=owner/correct` | every recorded `gh api` path uses `repos/owner/correct/…`, never the global |

## 4. Source-shape (AC4)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CCF-030 | Zero raw `gh api …git/…` / `…contents/…` in `upload-screenshot.sh` | grep count == 0 |
| TC-CCF-031 | `command -v gh` presence guard STAYS | grep finds the guard line |
| TC-CCF-032 | New leaf `chp_github_commit_file` present in `providers/chp-github.sh` | `declare -F` / source-grep present |
| TC-CCF-033 | New shim `chp_commit_file` present + self-guarding in `lib-code-host.sh` | shim defined; absent-leaf → WARN + `return 1` |
| TC-CCF-034 | Baseline shrank by exactly 8 occurrences / 7 signatures; the `command -v gh` sig stays; `check-provider-cutover.sh` PASSES | no upload-screenshot.sh git/contents sigs in baseline; `command -v gh` sig present; checker exit 0 |
| TC-CCF-035 | `upload-screenshot.sh` routes through `chp_commit_file` (verb call present) | source-grep finds `chp_commit_file` invocation |

## 5. Lib resolution / standalone util

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CCF-040 | `upload-screenshot.sh` resolves `lib-code-host.sh` via `readlink -f` skill-tree idiom (not `$_SCRIPT_DIR`) | source-grep finds the `readlink -f` + `../../autonomous-dispatcher/scripts/lib-code-host.sh` resolution |
| TC-CCF-041 | Self-guarding shim: leaf-absent (degraded fixture) → `chp_commit_file` returns non-zero + WARN | rc != 0; stderr WARN |

## 6. Conformance fixture rule (INV-75) — already satisfied

The fake-skill-tree E2E fixture's `cp -r .../providers` already carries the whole
`providers/` dir (the new leaf is just a new function in the existing
`chp-github.sh`, NOT a new provider file) — covered by the existing
TC-CHP-FIXTURE-CPR pin. No fixture change needed.

## E2E
No new E2E (AC: screenshot upload is exercised by the browser-E2E review lane).
The whole-op golden unit is the behavior-equivalence evidence.
