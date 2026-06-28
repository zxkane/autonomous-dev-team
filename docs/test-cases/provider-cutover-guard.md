# Test cases — providers cutover guard (#286, INV-91)

Two suites, both credential-free (jq + coreutils), auto-discovered by the
`tests/unit/test-*.sh` CI glob.

## `tests/unit/test-provider-cutover.sh` — the lint

Drives `check-provider-cutover.sh` against scratch copies via the
`--scripts-dir` / `--baseline` path-override flags (mirroring `test-spec-drift.sh`).

| ID | Scenario | Expected |
|---|---|---|
| TC-CUTOVER-001 | Clean real repo (baseline matches HEAD survivors) | `exit 0`, prints PASS |
| TC-CUTOVER-002 | Inject a NEW `gh pr view …` (content NOT in baseline) into a scratch `lib-dispatch.sh` | `exit 1`, `::error::` names `lib-dispatch.sh` + the offending line content |
| TC-CUTOVER-003 | Allowlisted file (`gh-with-token-refresh.sh` / `gh-app-token.sh`) holds raw gh | does NOT trip the lint (allowlisted file) |
| TC-CUTOVER-004 | Consuming-boundary catch — a `gh ` token a naive `\bgh`/look-behind would miss is still caught by `(^|[^A-Za-z_-])gh ` | the injected new site is caught (`exit 1`) |
| TC-CUTOVER-005 | DUPLICATE bump — append a 2nd identical copy of an already-baselined line | `exit 1` (discovered count > baseline count) |
| TC-CUTOVER-006 | Stale baseline entry — baseline names a file that no longer exists | `exit 1`, names the stale file |
| TC-CUTOVER-007 | `providers/itp-github.sh` or `chp-github.sh` missing | `exit 1`, names the missing provider file |
| TC-CUTOVER-008 | REMOVED site — delete a baselined gh line from a scratch wrapper (simulates a migration landing) | `exit 1` (baseline count > discovered → forces baseline shrink) |
| TC-CUTOVER-009 | Header cites INV-91; `set -uo pipefail`; RE2-safe boundary present, no look-behind/ahead | grep assertions on the script source |
| TC-CUTOVER-010 | `--help` prints usage, `exit 0`; unknown flag → `exit 2` | usage/exit-code contract |
| TC-CUTOVER-011 | `--generate-baseline` emits valid JSON the checker then accepts (generator ⇄ checker consistent by construction) | round-trip PASS |
| TC-CUTOVER-012 | **(F2/AC #41)** Inject a NEW `gh` into a NON-caller dispatcher script (`setup-labels.sh`) | `exit 1`, caught tree-wide, names `setup-labels.sh:LINE` |
| TC-CUTOVER-013 | A NEW `gh` UNDER `providers/` (the migration target) | does NOT trip (`exit 0`) |
| TC-CUTOVER-014 | **(R2-F2)** The guard is NOT wholesale-allowlisted — a NEW `gh api user` in the checker itself | `exit 1`, names `check-provider-cutover.sh:LINE` (clean tree still PASSES — its legit gh lines are baselined) |
| TC-CUTOVER-015 | **(R2-F1)** Inject a NEW `gh` into a NESTED `adapters/codex.sh` | `exit 1`, caught by the recursive scan, names `adapters/codex.sh:LINE` |
| TC-CUTOVER-016 | **(R2-F1)** Inject a NEW `gh` into a tracked-but-symlinked script (`mark-issue-checkbox.sh`) | `exit 1` (`find -L` keeps symlinked scripts in scope) |
| TC-CUTOVER-017 | **(Check 4)** In a real git repo: commit the clean tree as `trusted-main`, then inject a `gh` + `--generate-baseline` (the same-PR self-ratification bypass), run with `--trusted-ref trusted-main` | `exit 1`, `baseline GREW vs trusted-main` names the grown `dispatcher-tick.sh` site (bypass closed) |
| TC-CUTOVER-018 | **(Check 4)** Unchanged baseline vs `trusted-main`; and an unresolvable `--trusted-ref` | unchanged → `exit 0` (`baseline did not grow`); missing ref → `exit 0` (graceful skip, `not resolvable`) |

> Note (F1/AC #2): TC-CUTOVER-002 asserts the `::error::` names the exact
> `file:line` (`lib-dispatch.sh:NNNN`), not just the file.
> Note (Check 4): the monotonicity guard reads the trusted baseline at
> `--trusted-ref` (default `origin/main`) via `git show`; a PR may only SHRINK the
> baseline, never grow it — closing the same-PR self-ratification bypass.

## `tests/unit/test-provider-caps-branches.sh` — caps-branch coverage gate

Spec §4.3: on this GitHub-only HEAD only the 8 caps with a LIVE caller branch can
be EXERCISED; the other 5 have no caller branch yet and are WAIVED behind a
fail-on-wiring tripwire (NOT a free pass). Fabricating a test-only consumer to
"exercise" a nonexistent branch would violate §4.3 (no behavior change), so the
waiver+tripwire is the honest maximum.

| ID | Scenario | Expected |
|---|---|---|
| TC-CAPS-000 | Tripwire self-test: `caller_branch_for` returns a hit for a known-present cap and empty for a known-absent token | detector is not a no-op grep |
| TC-CAPS-001..008 | For each LIVE-branch cap: caller layer HAS a branch reading it AND the degraded fixture reports the degraded value through the public seam | reachable + driveable |
| TC-CAPS-008 | END-TO-END execution of ≥4 caps=0 branches against the degraded fixture: `label_colors=0` (real `setup-labels.sh` subprocess → exit 1 + documented error), `merge_closes_issue=0`+`native_issue_pr_link=0/1` (real `_render_close_keyword` → `Related to #N` / empty), default `merge_closes_issue=1` → `Closes #N`, `body_checkbox=0` (real `mark-issue-checkbox.sh` subprocess → exit 1 + documented native-subtask-remap error, no PATCH) | branches RUN, degraded observable asserted |
| TC-CAPS-010..015 | For each WAIVED cap (`server_side_state_and`, `server_side_state_negation`, `distinct_bot_author`, `read_after_write_state`, `marker_channel`): assert NO caller branch keys on it yet (tripwire) AND the fixture still declares the degraded value. If a branch EVER appears → FAIL (wiring landed → must exercise) | waived + tripwire armed |
| TC-CAPS-020 | Accounting: `exercised=8 waived=5 total=13` (9 ITP + 4 CHP); ≥4 executed end-to-end; no cap unaccounted | sum + split checks |
| TC-CAPS-021 | Fake degraded fixture passes `bash -n` and all 13 caps resolve through the seam | no crash |
