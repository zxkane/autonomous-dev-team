# Design — `chp_pr_comment` (issue #329, #296 second-tier)

## Problem

The two HOT review wrapper files still carry **7 raw `gh pr comment`** write
sites — `autonomous-review.sh:3342,3538` (the auto-merge-failure conflict
marker + captured failure marker) and `lib-review-e2e.sh:344,380,387,402,580`
(the E2E-failure reports, the ONE SHA-matching evidence gate, and the
[INV-79] brokered E2E report). The caller layer has already migrated the
lifecycle CHP writes (#282) and the general READ primitives `chp_pr_view` /
`chp_pr_list` (#282 round 8), but the PR-comment WRITE never got its own
primitive — these 7 sites are the last raw-`gh` cluster in the review path
carrying the `[INV-91]` cutover-guard baseline.

## Approach (general write primitive, no leaf-added redirects)

1. **Mint `chp_pr_comment PR [extra gh args…]`** as a general (non-lifecycle)
   CHP verb — the PR-comment WRITE sibling of the shipped read primitives
   `chp_pr_view` / `chp_pr_list`. Shim in `lib-code-host.sh`:
   ```bash
   chp_pr_comment() {
     if ! declare -F "chp_${CODE_HOST}_pr_comment" >/dev/null 2>&1; then
       echo "WARN: CODE_HOST='${CODE_HOST}' provider defines no chp_${CODE_HOST}_pr_comment leaf — PR comment unavailable." >&2
       return 1
     fi
     chp_${CODE_HOST}_pr_comment "$@"
   }
   ```
   **Self-guarding** (the #282 convention, mirroring `chp_pr_view`/`chp_pr_list`):
   unlike the 11 named lifecycle verbs (which callers guard via `chp_has_leaf`),
   this primitive is invoked UNGUARDED at every call site — the shim itself
   checks `declare -F` and degrades to a WARN + `return 1` rather than
   dispatching to an undefined leaf and aborting under `set -e`.

2. **GitHub leaf** `chp_github_pr_comment PR [extra gh args…]` in
   `providers/chp-github.sh` — a pure BYTE-IDENTICAL passthrough:
   ```bash
   chp_github_pr_comment() {
     local pr="$1"; shift
     gh pr comment "$pr" --repo "$REPO" "$@"
   }
   ```
   **The leaf adds NO redirects of its own** — this is the load-bearing
   constraint. The 7 callers use FOUR distinct redirect/capture/gating framings:
   - `… 2>/dev/null || true` (four report posts — fire-and-forget)
   - `if ! _err=$(… 2>&1 >/dev/null)` (the captured auto-merge marker)
   - `… 2>/dev/null || rc=$?` (the ONE gating site — the SHA-marked evidence
     post whose success actually matters to the caller)
   - the broker `… >/dev/null 2>&1` ([INV-79] E2E report)

   Baking any redirect into the leaf would double or clobber whichever framing
   the caller supplies, so every caller's exact framing stays caller-side; the
   leaf only supplies the `gh pr comment $PR --repo $REPO` prefix. Bodies are
   pre-composed positional `--body` strings (no jq pattern) — no injection
   surface.

3. **Migrate** all 7 call sites in `autonomous-review.sh` / `lib-review-e2e.sh`
   to `chp_pr_comment "$PR_NUMBER" ...`, preserving each site's exact trailing
   framing verbatim (only the `gh pr comment "$PR_NUMBER" --repo "$REPO"`
   prefix is replaced).

## Why a NEW verb, not `itp_post_comment`

`itp_post_comment` ([INV-89]) is the ISSUE-level machine-marker choke-point —
it posts on the *issue*. On GitHub a PR *is* an issue, so the REST endpoint
happens to coincide, but the seam ownership differs: this is a **code-host**
concern (PR review-comment surface), not an **issue-tracker** concern. A split
`ISSUE_PROVIDER` ≠ `CODE_HOST` topology (e.g. Asana issue-tracker + GitHub code
host) would route the two operations to different backends entirely. The verbs
must stay distinct.

## Cutover guard impact

`providers/cutover-baseline.json` shrinks by 5 distinct signatures / 7
occurrences (the 7 raw `gh pr comment` call sites collapse to 5 unique
`(file, trimmed-content)` signatures once the `chp_pr_comment` prefix
replaces the varying trailing framing). `check-provider-cutover.sh`
([INV-91]) enforces the shrink (monotonic, may only shrink) — the exact
before/after totals reconcile against whatever `origin/main`'s baseline is at
merge time, since sibling `#296` second-tier migrations land concurrently and
independently shrink the same shared manifest.

## New invariant

Originally claimed **INV-95** at authoring time (INV-93/94 taken/reserved).
By the time this branch actually rebased onto `main`, several more `#296`
second-tier siblings had landed ahead of it and independently claimed
INV-95 through INV-101 — renumbered to the next free slot, **INV-102**, per
the project's documented first-merged-keeps-its-number convention (see the
provenance note under the INV-102 heading in `invariants.md`). The heading
carries a `_Triage (issue #236): [machine-checked: tests/unit/test-chp-pr-comment.sh]_`
marker (the `#236` is a FIXED literal, not this issue's number).

## Rollback

Single-file caller revert (7 sites) + drop leaf/shim + restore the baseline
entries. LOW blast radius — the migrated sites are fire-and-forget report
posts plus one gating evidence check; none of the [INV-52]/[INV-79] approve/
merge/request-changes decision logic moves.
