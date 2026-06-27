# Test Cases — Entangled-orchestrator golden-trace gate (#285)

Two new golden-trace suites that stub the **verb layer** (not the `gh` binary)
and assert byte-identical verb argv on every documented path.

- `tests/unit/test-mark-stalled-golden-trace.sh`
- `tests/unit/test-handle-completed-routing-golden-trace.sh`

The verb recorder captures each verb call as `VERB␟arg1␟arg2␟…` (`␟` = a NUL-safe
unit separator) so an assertion can compare the EXACT argv vector, not a fuzzy
substring.

## A. `mark_stalled` golden trace (`test-mark-stalled-golden-trace.sh`)

| TC | Path | Asserted verb argv (byte-identical) |
|----|------|-------------------------------------|
| TC-MSGT-001 | liveness-defer: `pid_alive` ALIVE, no prior deferral marker | `itp_list_comments <issue>` (dedup read) **then** `itp_post_comment <issue> "Stall decision deferred: … (\`INV-26-stall-deferral:pid=<pid>\`)"`; NO `itp_transition_state`, NO stalled-summary post |
| TC-MSGT-002 | liveness-defer idempotent: ALIVE, deferral marker already present | `itp_list_comments <issue>` only; NO `itp_post_comment`, NO transition |
| TC-MSGT-003 | empty-PID local fall-through (DEAD): terminal stall write | `itp_transition_state <issue> pending-dev stalled` **then** `itp_post_comment <issue> "Issue has exceeded the maximum retry limit …"`; NO deferral comment, NO `itp_list_comments` |
| TC-MSGT-004 | dead-wrapper terminal stall (PID file present, process dead) | same verb sequence as TC-MSGT-003 — `itp_transition_state <issue> pending-dev stalled` first, then stalled-summary `itp_post_comment` |
| TC-MSGT-005 | label order pin | `itp_transition_state` is called with REMOVE=`pending-dev` ADD=`stalled` in that exact positional order |
| TC-MSGT-006 | zero raw `gh` in body (source grep) | `grep -nE '\bgh '` over the `mark_stalled()` body (def → next top-level `}`) returns no executable `gh ` (comment line allowed) |
| TC-MSGT-007 | caller-side ops NOT verb-wrapped (source grep) | `pid_alive`, `get_pid`, `count_agent_failures`, `count_dispatcher_crashes`, `count_dispatcher_false_positives` appear as literal calls in the body |

## B. `handle_completed_session_routing` golden trace (`test-handle-completed-routing-golden-trace.sh`)

| TC | Path (`_verdict`) | Asserted verb argv (byte-identical) |
|----|-------------------|-------------------------------------|
| TC-HCGT-001 | `none` (operator handoff) | `itp_list_comments <issue>` (dedup) then `itp_post_comment <issue> "Session \`<sid>\` already ended … (\`INV-12-completed:<sid>\`)"` |
| TC-HCGT-002 | `none`, notice already present | `itp_list_comments <issue>` only; NO post |
| TC-HCGT-003 | `passed` (race no-op) | ZERO verb calls |
| TC-HCGT-004 | `failed-non-substantive`, flip < limit | `itp_post_comment <issue> "<!-- review-aware-flip:non-substantive … -->\nRe-routing to review …"` then `itp_transition_state <issue> pending-dev pending-review` |
| TC-HCGT-005 | `failed-non-substantive`, flip ≥ limit (retry-cap stall) | `itp_post_comment <issue> "Persistent review-failure-non-substantive …"`; then `mark_stalled` (mocked) — NO `itp_transition_state pending-review` |
| TC-HCGT-006 | `failed-substantive` Branch A (bot-unfixable, head==last) | `fetch_pr_for_issue <issue> number,headRefOid,body` → `itp_list_comments` (dedup) → `itp_post_comment <issue> "Substantive review failure … not resolvable … (\`no-progress-substantive:<head>\`)"`; then `mark_stalled` (mocked) |
| TC-HCGT-007 | `failed-substantive` Branch B (no-progress, attempt marker present) | `fetch_pr_for_issue <issue> number,headRefOid,body` → `itp_list_comments` (attempt-marker presence) → `itp_list_comments` (notice dedup) → `itp_post_comment "Substantive review failure … unchanged since the last review …"`; then `mark_stalled` (mocked) |
| TC-HCGT-008 | `failed-substantive` Branch C (fresh dev-new + attempt marker) | `fetch_pr_for_issue <issue> number,headRefOid,body` → `itp_list_comments` (fresh-marker dedup) → `itp_post_comment "Review failed substantively … (\`INV-35-fresh-dev:<sid>\`)"` → `itp_transition_state <issue> pending-dev in-progress` → (mocked `post_dispatch_token` + `dispatch dev-new`) → `itp_post_comment "<!-- no-progress-substantive-attempt:<head> session=<sid> -->"` |
| TC-HCGT-009 | default arm (unknown verdict) | `itp_list_comments` (dedup) → `itp_post_comment "Session \`<sid>\` completed; verdict classifier returned unexpected value … (\`INV-12-completed:<sid>\`)"` |
| TC-HCGT-010a | #274 source-pin — orchestrator's DIRECT call | the recorded `fetch_pr_for_issue` argv FIELDS is byte-identical `number,headRefOid,body` (the literal the orchestrator emits) |
| TC-HCGT-010b | #148 anchor at the REAL verb boundary | the test runs the LIVE chain `fetch_pr_for_issue → resolve_pr_for_issue → chp_find_pr_for_issue` (only `fetch`/`chp` are recorded; `resolve` is real); the recorded `chp_find_pr_for_issue` FIELDS arg is `resolve_pr_for_issue`'s genuine union `number,headRefOid,body,closingIssuesReferences,headRefName` (caller fields + the [INV-86] resolution fields) — which MUST still contain `body` (#148) — plus the `-q` projection. A regression dropping `body` from resolve's union is caught HERE, not hidden behind a hand-rolled mock forward (#285 review m3) |
| TC-HCGT-011 | #274 / INV-85 anchor — attempt-marker token | Branch C's last `itp_post_comment` body contains the EXACT token `no-progress-substantive-attempt:<head>` |
| TC-HCGT-012 | label order pin (Branch A/B/C all reroute via `itp_transition_state`/`label_swap`) | non-substantive flip → REMOVE=`pending-dev` ADD=`pending-review`; Branch C → REMOVE=`pending-dev` ADD=`in-progress` |
| TC-HCGT-013 | zero raw `gh` in body (source grep) | `grep -nE '\bgh '` over the `handle_completed_session_routing()` body returns no executable `gh ` |

## C. Capability-branch negative (§7.4) — in both suites

| TC | Assertion |
|----|-----------|
| TC-MSGT-008 / TC-HCGT-014 | NO `itp_caps`/`chp_caps` call appears in either function body (source grep) — the orchestrators take the GitHub-today path unconditionally; the marker_channel/edit_comment fallbacks live in the verb IMPLs, not these orchestrators |
| TC-HCGT-015 | degraded fake-provider selection (`ISSUE_PROVIDER=degraded` + `AUTONOMOUS_PROVIDERS_DIR` override, verbs still recorded) emits the IDENTICAL verb SEQUENCE for Branch C — proving the orchestrator's verb glue does not branch on caps |

## D. Function-mock shim audit (recorded in PR, asserted in suite)

| TC | Assertion |
|----|-----------|
| TC-HCGT-016 | `fetch_pr_for_issue` is a defined caller-side function delegating to `chp_find_pr_for_issue` (the §7.2 m3 shim), so `fetch_pr_for_issue() { … }` test mocks still intercept |
| TC-MSGT-009 | `label_swap` is a defined caller-side function delegating to `itp_transition_state`, so `label_swap() { … }` test mocks still intercept |

## Regression gate (§7.3.1)

The existing 134-test suite + conformance suite MUST pass unchanged.
Specifically green after this PR (these stub the gh binary / mock the bash
functions, validating the glue logic survived):

- `test-mark-stalled-liveness.sh`
- `test-handle-completed-session-routing.sh`
- `test-inv35-regression-2026-05-21.sh`
- `test-lib-dispatch.sh`
- `test-count-agent-failures-sigterm.sh`
