# Test Cases — provider-spec doc validation (issue #279)

This is primarily a **docs-consistency** deliverable. The shipped test is
`tests/unit/test-provider-spec.sh`, modeled on
`tests/unit/test-adapter-spec-schemas.sh` (#229 / INV-66 precedent). It runs
credential-free on bare `ubuntu-latest` and exercises NO wrapper/lib *behavior*.

Still NO golden-trace, capability-branch (fake-provider), or `.caps`-parse
runtime tests — those gate the code-bearing sibling issues (already landed:
dispatch-skeleton-caps-reader #280, the itp/chp leaf migrations #281–#330).
**#367 (this revision) adds one narrow exception**: TC-016/017/018 read the
REAL `lib-issue-provider.sh` / `lib-code-host.sh` shim function names (via
`grep`, not by sourcing/executing them) to reconcile them against the
spec-derived verb sets — a docs-vs-tree consistency check, not a
dispatch-routing runtime test.

## Scenarios (mirrors the test's `TC-PROVIDER-SPEC-NNN` blocks)

| ID | Scenario | Expected |
|---|---|---|
| TC-PROVIDER-SPEC-001 | `docs/pipeline/provider-spec.md` exists | file present |
| TC-PROVIDER-SPEC-002 | NORMATIVE banner + RFC-2119 keyword paragraph + "MUST NOT redefine" clause | greps found |
| TC-PROVIDER-SPEC-003 | Both config keys with defaults | `ISSUE_PROVIDER` (default github; ∈ {github,gitlab,asana}) and `CODE_HOST` (default github; ∈ {github,gitlab}) |
| TC-PROVIDER-SPEC-004 | All 14 ITP verbs verbatim | `itp_list_by_state`, `itp_count_by_state`, `itp_list_forbidden_combos`, `itp_transition_state`, `itp_read_task`, `itp_post_comment`, `itp_edit_comment`, `itp_list_comments`, `itp_resolve_dep`, `itp_mark_checkbox`, `itp_provision_states`, `itp_caps`, `itp_begin_tick`, `itp_label_event_ts` (#323) |
| TC-PROVIDER-SPEC-005 | All 19 CHP verbs verbatim (18 §3.2 table rows) | `chp_find_pr_for_issue`, `chp_ci_status`, `chp_mergeable`, `chp_create_pr`, `chp_approve`, `chp_request_changes`, `chp_merge`, `chp_review_threads`, `chp_resolve_thread`, `chp_list_inline_comments`, `chp_pr_view`, `chp_pr_list`, `chp_pr_comment`, `chp_trigger_bot`, `chp_close_keyword`, `chp_reply_review_comment`, `chp_count_reviews_by_login`, `chp_commit_file`, `chp_caps` |
| TC-PROVIDER-SPEC-006 | All 14 capability keys (10 ITP + 4 CHP) | `server_side_state_and`, `server_side_state_negation`, `distinct_bot_author`, `read_after_write_state`, `cross_ref_shorthand`, `body_checkbox`, `edit_comment`, `label_colors`, `marker_channel`, `assignees` (#435); `native_issue_pr_link`, `rest_request_changes`, `review_bots`, `merge_closes_issue` |
| TC-PROVIDER-SPEC-007 | Normalized comment-shape literal | `[{id, author, body, createdAt}]` present |
| TC-PROVIDER-SPEC-008 | GitHub caps pin today's behavior | `server_side_state_negation=0`, `native_issue_pr_link=0`, `marker_channel=html` |
| TC-PROVIDER-SPEC-009 | verb↔function mapping appendix cites real names | `count_active`, `list_new_issues`, `label_swap`, `mark_stalled`, `fetch_pr_for_issue`, etc. + (a)/(b) taxonomy |
| TC-PROVIDER-SPEC-010 | verdict-channel reconciliation section | the typed-artifact channel (INV-78 / design-spec "INV-77") + `lib-review-artifact.sh` + INV-20/40/53 pin |
| TC-PROVIDER-SPEC-011 | §auth per-seam ownership boundary | INV-83 ITP-side dep token + INV-79 CHP-side approve/merge token + same-token for github/github |
| TC-PROVIDER-SPEC-012 | invariants.md provider INV headings | `^## INV-87:`..`^## INV-90:` present |
| TC-PROVIDER-SPEC-013 | each new INV carries an adjacent machine-checked triage tag | `_Triage (issue #236): [machine-checked: tests/unit/test-provider-spec.sh]_` within 2 lines of each INV-87..90 heading |
| TC-PROVIDER-SPEC-014 | state-machine.md abstract-state-per-backend note | the note present (mermaid + transition table unchanged) |
| TC-PROVIDER-SPEC-016 | Spec-derived ITP verb set (§3.1, TC-004's array) == the shipped `lib-issue-provider.sh` shim set (`grep`-derived, not sourced) | equal, same count — a shim added without a spec row, or a spec row added without a shim, fails here |
| TC-PROVIDER-SPEC-017 | Spec-derived CHP verb set (§3.2, TC-005's array) == the shipped `lib-code-host.sh` shim set (`chp_has_leaf` excluded — a guard helper, not a verb) | equal, same count |
| TC-PROVIDER-SPEC-018 | **Automated negative proof (AC1):** append a fake shim (`chp_frobnicate_unlisted`) to a SCRATCH COPY of `lib-code-host.sh` (never the committed tree); re-run the TC-017 reconciliation against the scratch copy | reconciliation turns RED naming the unlisted shim — demonstrates the derive-from-spec assertion actually catches an unlisted shim (not a passing tautology) |

## INV-numbering note (why INV-87..90, not INV-86..89)

The issue text asks for "the next free numbers above INV-85" and — written when
INV-85 was the max — names them `INV-86..INV-89`. Between issue authoring and this
PR, **PR #278 (issue #277) merged its own `INV-86`** ("PR↔issue binding via
`closingIssuesReferences`") onto `main`. So:

- "the next free numbers above INV-85" is now objectively **INV-87..INV-90**;
- renumbering back to INV-86 would either duplicate #278's INV-86 (breaking
  `test-spec-drift.sh`'s heading-count == tag-count assertion) or renumber an
  existing INV (which AC-11 explicitly forbids).

The test therefore asserts `^## INV-87:`..`^## INV-90:`. This is the standard
INV-collision-via-rebase resolution: the first-merged PR keeps the number, the
later PR shifts to the next free band. The issue ACs are updated to the post-#278
reality.

## Regression gates (existing suite must stay green)

- `tests/unit/test-spec-drift.sh` TC-SPEC-GATE-040/041 — heading-count == tag-count,
  each tag within 2 lines of its `## INV-NN:` heading. The four new INV-87..90
  headings each carry the machine-checked triage tag, keeping the assertion balanced.
- The full existing unit suite must pass unchanged — this PR touches no code, so any
  failure indicates a doc-side regression.
