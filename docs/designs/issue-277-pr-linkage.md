# Design: authoritative PR↔issue linkage (issue #277, INV-86)

## Problem

PR-to-issue resolution in the dispatcher / review wrapper keys on a **bare `#N`
body mention** instead of GitHub's parsed **close linkage**. When two issues are
in flight concurrently and one PR's body cross-references the other issue (a
deliberate, good-practice "related to #A" line), the review wrapper for issue A
selects the cross-referencing PR-B, reviews the wrong PR, posts a dev-actionable
FAILED verdict to issue A citing files that exist only in PR-B, and submits a
GitHub `REQUEST_CHANGES` against a **foreign** PR — a non-terminating dev↔review
loop driver.

Reproduced in this repo during the #273/#274 dev cycle (both merged): the
issue-273 review wrapper resolved PR #276 (the #274 fix) because #276's body
contained a `- #273 — …` cross-reference. `gh pr view 276 --json
closingIssuesReferences` returns `274` (not 273), proving the parsed close
linkage is authoritative and immune to body cross-references.

Two code sites carry the loose match:

1. `skills/autonomous-dispatcher/scripts/autonomous-review.sh` — "Finding PR for
   issue" block, Method 1: `select(.body | test("#N[^0-9]") or test("#N$"))] |
   .[0]`. No close-keyword, arbitrary `.[0]`, **no `.body != null` guard** (so a
   null-body sibling can also abort the jq filter, unlike `fetch_pr_for_issue`).
   Methods 2 (scan issue comments for `PR #N`) and 3 (`gh search "issue N"`) share
   the same loose-match weakness.
2. `skills/autonomous-dispatcher/scripts/lib-dispatch.sh::fetch_pr_for_issue` —
   same `#N` body match (gained a `.body != null` guard in #148 but kept the
   mention-based match). Used by `review_near_success` and
   `handle_pending_dev_pr_exists`.

A second, independent bug: once `PR_NUMBER` is set, `submit_request_changes` /
approve / merge / label-flip run **unguarded** — there is no assertion that the
resolved PR actually closes the issue under review.

## Fix

### 1. Authoritative shared resolver — `resolve_pr_for_issue` (lib-pr-linkage.sh)

A single shared helper both sites call, in its own lib (`lib-pr-linkage.sh`) so
the review wrapper — which does NOT source the heavy `lib-dispatch.sh` — can
resolve PRs identically. `lib-dispatch.sh` sources it (lazy `LIB_DIR` pattern)
and `fetch_pr_for_issue` delegates to it. Precedence (first non-empty wins):

1. **Close linkage (authoritative).** Among open PRs, select the one whose
   `closingIssuesReferences[].number` contains **exactly** this issue number.
   This is GitHub's parsed semantics and is immune to body cross-references. On
   ties (should not happen — GitHub binds one closing PR per issue) the lowest PR
   number wins (deterministic sort).
2. **Branch-name fallback (close-keyword-less PRs).** Partial-fix PRs
   deliberately omit `Closes #N` so GitHub does not auto-close (see the repo's
   close-keyword guidance). For those, select the open PR whose `headRefName`
   matches the `issue-<N>` boundary (`(^|[^0-9])issue-N([^0-9]|$)`), lowest PR
   number on ties. Never a bare `.[0]` body mention.

The helper echoes the matched PR's JSON object (requested `--json` fields) or
empty. Resolution is **independent of the requested fields** — it always fetches
`number,closingIssuesReferences,headRefName` to decide, then re-emits the caller's
requested field subset for the winning PR. This keeps `fetch_pr_for_issue`'s
existing contract (echo a JSON object with the requested fields) intact, so its
callers (`review_near_success` needs `mergedAt,reviews`;
`handle_pending_dev_pr_exists` needs `headRefOid,body`; INV-85 needs `body`)
keep working unchanged.

`fetch_pr_for_issue` becomes a thin delegate to `resolve_pr_for_issue` — the
guard-map anchor (`pr-exists-for-issue` / `no-pr-for-issue` → `fetch_pr_for_issue`)
is preserved.

### 2. `autonomous-review.sh` Method 1 uses the authoritative resolver

Method 1 is replaced by a call to `resolve_pr_for_issue "$ISSUE_NUMBER" number`
→ `.number`. Methods 2 and 3 (loose comment / search fallbacks) are **removed** —
they shared the same loose-match weakness and the authoritative resolver +
branch-name fallback supersedes them. If no PR resolves, the existing
no-valid-PR branch fires (diagnostic comment + `failed-non-substantive` /
`no-pr-found` + `reviewing → pending-dev`) — unchanged routing.

### 3. Hard linkage guard before ANY PR mutation

After resolution, before the review proceeds, assert the resolved PR closes this
issue (close linkage) **or** matches the issue's branch-name marker. The guard is
asserted **explicitly and independently** at the wrapper level (defense in
depth): a `verify_pr_closes_issue` predicate is re-checked just before the
discovery block hands `PR_NUMBER` downstream. Discovery's branch tier and the
guard's branch clause share the **same** predicate — a branch-name match counts
only when the PR carries **no** close linkage at all — so a PR on an `issue-N`
branch that actually `Closes #OTHER` is in neither, and `resolve_pr_for_issue`
never returns a PR the guard would reject (a PR closing a *different* issue can no
longer shadow the real close-keyword-less partial-fix PR and force a spurious
abort). The guard remains as defense-in-depth against any future discovery drift.
On failure the wrapper refuses to review, emits a diagnostic, and routes through the
existing no-valid-PR branch — it never runs `submit_request_changes`, approve,
merge, or a label flip against the resolved PR.

No new label transition: the foreign-PR / no-linkage case reuses the existing
`reviewing → pending-dev` no-valid-PR transition. `transitions.json` /
state-machine.md are unchanged; only `invariants.md` (new INV-86) +
`review-agent-flow.md` are updated.

## Files

| File | Change |
|---|---|
| `lib-pr-linkage.sh` (new) | New `resolve_pr_for_issue` + `verify_pr_closes_issue` + `_pr_field_union`. |
| `lib-dispatch.sh` | Sources `lib-pr-linkage.sh` (lazy `LIB_DIR`); `fetch_pr_for_issue` delegates to `resolve_pr_for_issue`. |
| `autonomous-review.sh` | Sources `lib-pr-linkage.sh`; Method 1 → resolver; Methods 2/3 removed; `verify_pr_closes_issue` guard before downstream use; both no-valid-PR cases funnel through one `_review_abort_no_valid_pr` (single `reviewing→pending-dev` write site). |
| `docs/pipeline/invariants.md` | New **INV-86** (+ cross-ref note on INV-85). |
| `docs/pipeline/{review-agent-flow,handoffs,dispatcher-flow}.md` | PR-discovery / consumer-side text references INV-86. |
| `docs/test-cases/issue-277-pr-linkage.md` | TC-XWIRE-001..010 + E2E. |
| `tests/unit/test-pr-issue-linkage-277.sh` | Regression suite (29 tests) — auto-discovered by CI's `tests/unit/test-*.sh` loop, no workflow change needed. |
| `tests/e2e/run-pr-linkage-e2e.sh` | Hermetic cross-wiring E2E (13 assertions). |
| `tests/unit/{test-fetch-pr-for-issue-null-body,test-status}.sh` | Updated fixtures to the close-linkage binding signal. |

> **CI wiring follow-up**: a dedicated CI step for `run-pr-linkage-e2e.sh` and a
> `lib-pr-linkage.sh` entry in the hermetic-shellcheck file list belong in
> `.github/workflows/ci.yml`, but the autonomous agent's scoped GitHub-App token
> lacks the `workflows` permission, so that edit is split out for an operator /
> follow-up PR. The unit suite already covers the fix end-to-end on every CI run
> (auto-discovered); the E2E is runnable locally and hermetic.

## Out of scope

Broader audit of every `#N` body-mention match across the dispatcher (dev
cleanup/resume, bot-trigger brokerage). Captured as a follow-up. This issue fixes
the review-discovery + the shared `fetch_pr_for_issue` it depends on.
