# Test Cases — ITP write-leaf migration (#283)

Suite: `tests/unit/test-itp-write-leaves.sh` (new). All existing unit + conformance
suites MUST also pass UNCHANGED (`env -u PROJECT_DIR` for CI parity).

## 1. Golden-trace — byte-identical `gh` argv per write leaf (spec §7.3)

| ID | Leaf | Assertion |
|---|---|---|
| TC-GT-TRANS-BOTH | `itp_github_transition_state 42 pending-dev pending-review` | argv == `issue edit 42 --repo $REPO --remove-label pending-dev --add-label pending-review` |
| TC-GT-TRANS-EMPTYREMOVE | `itp_github_transition_state 42 "" in-progress` | argv == `issue edit 42 --repo $REPO --add-label in-progress` (no `--remove-label`) |
| TC-GT-TRANS-EMPTYADD | `itp_github_transition_state 42 reviewing ""` | argv == `issue edit 42 --repo $REPO --remove-label reviewing` (no `--add-label`) |
| TC-GT-POST | `itp_github_post_comment 42 "hello"` | argv == `issue comment 42 --repo $REPO --body hello` |
| TC-GT-POST-INV18 | post_dispatch_token body | the `<!-- dispatcher-token: <tok> at <ts> mode=dev-new -->` first-line marker is passed verbatim as `--body` (INV-18) |
| TC-GT-POST-INV39 | _dep_block_comment body | the `<!-- dep-block:<repo>#<num> -->` marker is passed verbatim as `--body` (INV-39) |
| TC-GT-EDIT | `itp_github_edit_comment 42 999 "newbody"` | argv == `api -X PATCH repos/$O/$N/issues/comments/999 -f body=newbody` |
| TC-GT-CHECKBOX | `itp_github_mark_checkbox 42 "B"` | argv == `api repos/$REPO/issues/42 --method PATCH --field body=B --silent` |
| TC-GT-PROVISION-CREATE | `itp_github_provision_states autonomous 0E8A16 "desc"` (not-exists) | create argv == `label create autonomous --repo $REPO --color 0E8A16 --description desc` |
| TC-GT-PROVISION-SKIP | provision when `gh label view` succeeds | NO `gh label create` emitted (idempotent skip) |

## 2. Dispatch routing — `itp_<verb>` → `itp_github_<verb>` (spec §7.4)

| ID | Assertion |
|---|---|
| TC-RT-TRANS | `itp_transition_state` → `itp_github_transition_state` (args forwarded) |
| TC-RT-POST | `itp_post_comment` → `itp_github_post_comment` |
| TC-RT-EDIT | `itp_edit_comment` → `itp_github_edit_comment` |
| TC-RT-CHECKBOX | `itp_mark_checkbox` → `itp_github_mark_checkbox` |
| TC-RT-PROVISION | `itp_provision_states` → `itp_github_provision_states` |

## 3. `.caps` parse — values the write branches consume (spec §7.4 / INV-88)

| ID | Assertion |
|---|---|
| TC-CAPS-EDIT | `itp_caps edit_comment` == 1 (github) |
| TC-CAPS-CHECKBOX | `itp_caps body_checkbox` == 1 (github) |
| TC-CAPS-COLORS | `itp_caps label_colors` == 1 (github) |
| TC-CAPS-CHANNEL | `itp_caps marker_channel` == html (github) |

## 4. Capability-branch via the named degraded fake provider (spec §7.4)

The degraded fixture declares `edit_comment=0`, `body_checkbox=0`, `label_colors=0`,
`marker_channel=text`. Caps read through the PUBLIC seam (`ISSUE_PROVIDER=degraded`
+ `AUTONOMOUS_PROVIDERS_DIR`). Leaf dispatch stubbed inline (fixture endorses this).

| ID | Assertion |
|---|---|
| TC-CAP-EDIT0 | INV-46 caller: `edit_comment=0` → `itp_post_comment` re-posts the FULL report body + SHA marker (never marker-only), no `itp_edit_comment` PATCH — driven through the real `_stamp_browser_evidence_marker` |
| TC-CAP-EDIT1 | `edit_comment=1` (github) → PATCH path taken (`itp_edit_comment` called) |
| TC-CAP-CHECKBOX0 / -BRANCH | `body_checkbox=0` → the documented native-subtask-remap branch: the REAL mark-issue-checkbox.sh (run with `ISSUE_PROVIDER=degraded`) takes the cap-gated fallback (no markdown PATCH), fails LOUD-but-clean, and does NOT crash with `itp_degraded_mark_checkbox: command not found` (the branch keys on `itp_caps body_checkbox`, not `declare -F` of the always-defined shim) |
| TC-CAP-COLORS0 / -BRANCH | `label_colors=0` → the documented color-omitted path: the REAL setup-labels.sh (`ISSUE_PROVIDER=degraded`) takes the cap-gated fallback (no `gh label` call), fails LOUD-but-clean, and does NOT crash with `itp_degraded_provision_states: command not found` |

## 5. `marker_channel` regression (INV-89 / INV-18 / INV-39 survival)

| ID | Assertion |
|---|---|
| TC-MARKER-HTML | `itp_github_post_comment 42 "<!-- dispatcher-token: x -->body"` passes the `<!-- … -->` to `--body` UNMODIFIED (no strip/sanitize) — pins the html channel the dispatcher markers depend on |

## 6. Function-mock shim audit + cutover pin (spec §7.3 m3)

| ID | Assertion |
|---|---|
| TC-AUDIT-NORENAME | `label_swap` / `post_dispatch_token` / `_dep_block_comment` / `mark_checkbox` keep their names after sourcing (existing function-mocks still bind) |
| TC-CUTOVER-COMMENT0 | `grep -c 'gh issue comment' lib-dispatch.sh` == 0 |
| TC-CUTOVER-SWAP | `label_swap()` body contains no raw `gh issue edit` (delegates to `itp_transition_state`) |
| TC-CALLERSIDE-INV25 | the INV-25 terminal-state jq subtraction stays in lib-dispatch.sh caller code (NOT moved into `itp_transition_state`) |

## 7. Regression — existing suites pass unchanged

Run the full `tests/unit/*.sh` suite + the conformance suite. Critical
function-mock consumers that must stay green: `test-handle-completed-session-routing.sh`,
`test-inv35-regression-2026-05-21.sh`, `test-dispatcher-step4-stale-verdict.sh`,
`test-mark-stalled-liveness.sh`, `test-lib-dispatch.sh`, `test-itp-read-leaves.sh`,
`test-provider-dispatch.sh`, `test-spec-drift.sh`.
