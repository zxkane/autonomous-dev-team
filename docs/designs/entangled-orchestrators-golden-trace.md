# Design — Entangled-orchestrator golden-trace gate (#285)

## Context

Per `provider-spec.md` §7.1(b)/§7.3, `mark_stalled()` and
`handle_completed_session_routing()` (both in `lib-dispatch.sh`) are the two
named **class-(b) entangled multi-op orchestrators**: after the leaf-migration
PRs (#281 itp-reads, #283 itp-writes, #282 chp-pr-lifecycle, #284
itp-deps-begin-tick) moved their inner `gh` primitives behind ITP/CHP verbs,
these functions are now provider-neutral **glue** that interleaves 5+ verb
calls with NON-host ops that MUST stay caller-side.

### What is already done (merged via #283, #282, #284)

The body rewrite is **already complete on `main`**. Both functions hold ZERO
raw `gh ` invocations today:

- `mark_stalled()` — deferral-marker dedup read → `itp_list_comments`; deferral
  comment + stalled-summary comment → `itp_post_comment`; the
  `pending-dev → stalled` edit → `label_swap` (→ `itp_transition_state`).
- `handle_completed_session_routing()` — every comment-dedup read →
  `itp_list_comments`; every comment post (incl. the failed-substantive
  Branch C no-progress attempt HTML marker) → `itp_post_comment`; the
  failed-non-substantive label move → `label_swap` (→ `itp_transition_state`);
  the PR lookup → `fetch_pr_for_issue` (the kept same-named delegate shim →
  `chp_find_pr_for_issue`).

The non-host ops stay caller-side per §7.1(b): `pid_alive`, `get_pid`, the
`EXECUTION_BACKEND` resolve (TC-RPA-010 separate-line invariant),
`count_agent_failures` / `count_dispatcher_crashes` /
`count_dispatcher_false_positives`, `classify_recent_review_verdict`,
`last_reviewed_head`, `dev_report_bot_unfixable`, `count_review_aware_flips`,
the `: > "$_log_file"` truncate, `post_dispatch_token`, and `dispatch dev-new`.

### What THIS issue (#285) delivers

#283 explicitly **deferred the golden-trace gate** to this issue (see
`provider-spec.md` §7.2 "These are the code-bearing siblings' tests — NOT this
PR" and the INV-87 Status line naming `entangled-orchestrators-golden-trace`).
So #285 is the **gate**, not the rewrite:

1. **Golden-trace tests** — stub the **verb layer** (not the `gh` binary) to
   record argv, drive each documented path, assert byte-identical verb argv vs
   a captured baseline. Stubbing the verb layer is what makes this gate
   *sufficient* (the existing gh-stub tests pass by construction even if a
   verb's GitHub impl stops calling `gh` — §7.2.1).
2. **Function-mock shim audit** — recorded in the PR; confirm each moved leaf
   the orchestrators call retains a same-named caller-side shim so the existing
   function-level mocks still intercept.
3. **Docs** — provider-spec appendix per-arm cut-line detail; dispatcher-flow
   Step-3/Step-4 narrative note; INV-87/INV-89 code-site / status updates
   (reference, not author — the provider INVs are owned by #279).

## Approach

### Golden-trace test mechanism

Each test:

1. Sources `lib-dispatch.sh`.
2. **Overrides the ITP/CHP verbs** (`itp_list_comments`, `itp_post_comment`,
   `itp_transition_state`, `fetch_pr_for_issue` / `chp_find_pr_for_issue`) with
   recorders that append their full argv (`$*`, NUL-safe per-arg) to a trace
   array and return canned output. The verbs are the seam boundary; recording
   THERE proves the orchestrator emits the exact verb argv regardless of which
   provider is wired.
3. **Mocks the NON-host caller-side ops** (`pid_alive`, `get_pid`,
   `count_*`, `classify_recent_review_verdict`, `last_reviewed_head`,
   `dev_report_bot_unfixable`, `count_review_aware_flips`, `post_dispatch_token`,
   `dispatch`) so each documented path is reachable deterministically.
4. Drives the path, then asserts the recorded verb argv equals the locked
   baseline — including label order (`pending-dev`/`stalled`,
   `pending-dev`/`pending-review`) and the `chp_find_pr_for_issue` FIELDS
   literal `number,headRefOid,body`.

### Anchors (regression pins)

- **#148** — the PR-lookup FIELDS string MUST include `body` (omitting it
  silently hid the PR). This is asserted at **two** boundaries: (a) the
  orchestrator's direct call `fetch_pr_for_issue "$issue_num"
  "number,headRefOid,body"` (the literal #274 source-pin), and (b) the **real**
  `chp_find_pr_for_issue` verb boundary — see the caveat below.
- **#274 / INV-85** — the no-progress attempt marker carries the EXACT token
  `no-progress-substantive-attempt:<head>` via `itp_post_comment`.

### Caveat — the PR-lookup delegation chain is run LIVE, not mock-forwarded

`handle_completed_session_routing` calls `fetch_pr_for_issue "$issue_num"
"number,headRefOid,body"`, but the real chain is `fetch_pr_for_issue →
resolve_pr_for_issue → chp_find_pr_for_issue`, and `resolve_pr_for_issue`
(`lib-pr-linkage.sh`) does NOT forward FIELDS byte-identically — it computes a
field **union** (`_pr_field_union "$fields"
"number,closingIssuesReferences,headRefName"`) and calls
`chp_find_pr_for_issue "$issue_num"
"number,headRefOid,body,closingIssuesReferences,headRefName" -q "$q"`. So the
test records the orchestrator's *direct* `fetch_pr_for_issue` call but then
invokes the **real** `resolve_pr_for_issue` (sourced into scope via
`lib-dispatch.sh`) so `chp_find_pr_for_issue` receives its genuine runtime
union argv — NOT a hand-rolled forward of the orchestrator's `$@`. TC-HCGT-010b
asserts that real union, so a regression in resolve's union (e.g. dropping
`body`) is caught at the verb boundary. (`#285` review finding m3.)

This is also why these tests stub the **verb layer** rather than the `gh`
binary that §7.2.1 item 2 literally names: for a class-(b) orchestrator the
verb argv IS the observable output, and the literal `gh … --json` argv at the
`gh` boundary is already golden-traced by the #281/#282/#283 leaf suites. The
gate is *sufficient* (a verb bypassed by a raw `gh` is caught by the
source-level zero-`gh` assertion TC-MSGT-006 / TC-HCGT-013) without
re-asserting the leaf's `gh` argv here.

### Capability-branch coverage (§7.4 — negative requirement)

Neither function contains a `caps=0` branch — GitHub takes the identical path
today. So the requirement is the NEGATIVE: a test asserting both functions emit
the GitHub-today verb argv **unconditionally** (no caps gate inside the
orchestrators), and that a degraded fake-provider selection does NOT change the
verb *sequence* these two functions emit (the `marker_channel`/`edit_comment`
fallbacks live in the verb impls, not the orchestrators).

## Out of scope

- Migrating the leaf verbs themselves (done in #281–#284).
- The dispatch skeleton / `.caps` reader (#280).
- Authoring `provider-spec.md` or minting provider INVs (#279).
- The cutover-guard CI lint (separate issue).
- Any GitLab/Asana provider or `caps=0` branch logic inside these functions.
- State-machine / retry-count semantics changes (INV-26/30/35/85) or the
  TC-RPA-010 backend-resolve line layout.
