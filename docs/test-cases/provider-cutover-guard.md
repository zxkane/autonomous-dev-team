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
| TC-CUTOVER-009 | Header cites INV-91; `set -uo pipefail`; depends only on jq+coreutils | grep assertions on the script source |
| TC-CUTOVER-010 | `--help` prints usage, `exit 0`; unknown flag → `exit 2` | usage/exit-code contract |

## `tests/unit/test-provider-caps-branches.sh` — caps-branch coverage gate

Spec §4.3: on this GitHub-only HEAD only the 7 caps with a LIVE caller branch can
be exercised; the other 6 have no caller branch yet.

| ID | Scenario | Expected |
|---|---|---|
| TC-CAPS-001..007 | For each LIVE-branch cap (`cross_ref_shorthand`, `edit_comment`, `label_colors`, `native_issue_pr_link`, `rest_request_changes`, `review_bots`, `merge_closes_issue`): the caller layer HAS a branch reading that cap, AND the fake degraded provider reports the cap's degraded value through the public seam (`itp_caps`/`chp_caps`) | branch present + caps=0/text reachable |
| TC-CAPS-010..015 | For each NO-LIVE-BRANCH cap (`server_side_state_and`, `server_side_state_negation`, `distinct_bot_author`, `read_after_write_state`, `body_checkbox`, `marker_channel`): assert NO caller-layer branch keys on it yet (structural "nothing to cover"); the fixture still DECLARES the degraded value (so when a future PR wires the branch, this assertion flips red and forces a coverage test) | no caller branch; documented gap |
| TC-CAPS-020 | All 13 caps accounted for (7 live + 6 deferred = 13 = 9 ITP + 4 CHP) | sum check |
| TC-CAPS-021 | Fake degraded fixture sourced via `ISSUE_PROVIDER=degraded`/`CODE_HOST=degraded` + `AUTONOMOUS_PROVIDERS_DIR` passes `bash -n` and resolves caps | no crash |
