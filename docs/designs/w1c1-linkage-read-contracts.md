# W1c1 — CHP linkage-read abstract contracts (#397)

## Problem

Two CHP read verbs (`chp_find_pr_for_issue`, `chp_pr_list`) shipped in #282 as
byte-identical gh-argv passthroughs — the caller composed `--json <fields>
-q <expr>` and the leaf forwarded them verbatim. That contract couples the
provider seam to `gh` (jq programs cross the seam; a GitLab leaf would have to
emulate gh's `-q` semantics AND gh's field names) and inherits gh's silent
`--limit 30` default at the linkage read — a >30-open-PR repo can miss its
own close-linked PR, driving the dispatcher to re-dispatch dev-new against
an issue that already has a PR.

The 6 body-mention `chp_pr_list` caller sites additionally split into TWO
guard shapes: `needs_open_pr_only`/`_pr_created_at` guard `.body != null`;
the other four (autonomous-dev.sh:774/:1079, lib-auth.sh:453/:605) don't —
the #148 hazard class, waiting to abort on a null-body sibling.

## Solution

Rewrite both verbs to abstract positional contracts (mirroring W1a=#371's
ITP state-read normalization):

- `chp_find_pr_for_issue ISSUE FIELDS-CSV` → normalized JSON array of open PR
  candidates, projected to `FIELDS-CSV` ∪ the [INV-86] resolution keys
  (`number,closingIssueNumbers,headRefName`). The provider owns the gh argv +
  normalization jq (spec §3.2.1 vocabulary: body → string, state → enum,
  closingIssueNumbers → int-array). The [INV-86] two-tier resolution
  (close-linkage beats branch-name) is pure caller-side jq over the
  normalized array in `lib-pr-linkage.sh`.
- `chp_pr_list STATE FIELDS-CSV` → normalized JSON array (no forced union),
  same normalization vocabulary; six callers keep their #N-boundary regex
  over the normalized `body` string. Empty match set → `[]` (never null;
  the #148-class fix).

Both leaves use a bounded page-walk (`CHP_GITHUB_PR_LIST_PAGE_CAP`, default
20 pages / 2000 open PRs); cap-hit is fail-CLOSED (rc≠0, no partial output).
This closes the silent-truncation hazard.

## Constraints

- **Decision-level parity** with the pre-change code across the recorded
  fixture set. Anchor: `tests/unit/test-w1c1-linkage-read-parity.sh` +
  `tests/unit/fixtures/w1c1-parity/decision-golden.json` (goldens captured
  from the PRE-change guarded selectors — post-normalization, all 6 sites
  converge on those decisions).
- **Zero gh flags cross the seam** (`TC-W1C1-SEAM-TRACE`): grep the caller
  layer for `chp_pr_list -q` / `chp_find_pr_for_issue --json` → nothing.
- **Fail-CLOSED at the linkage read**: `needs_open_pr_only` uses `|| return 1`,
  so a transport error must not classify as pushed-no-PR.
- **Byte-diff pin on chp-github.sh lifted** (same as W1a for itp-github.sh):
  the two rewritten leaves are the deliberate SHAPE change; the byte-diff
  check in `test-provider-conformance-runner.sh` is retired in favor of
  the decision-level parity suite.

## Rejected alternatives

- **Keep `-q` as the caller-side jq at the seam boundary**: rejected because
  it re-couples to gh (a GitLab leaf would have to emulate `-q`).
- **Server-side narrowing by ISSUE**: rejected because GitHub has no such
  filter — the `ISSUE` positional is a documented narrowing HINT the provider
  MAY use only when no true candidate can be excluded; the GitHub leaf
  ignores it today.
- **A fixed `--limit N` bump (say N=200)**: rejected because it just moves
  the silent-truncation threshold; §3.5 mandates COMPLETE-set with
  fail-CLOSED cap-hit.

## Related work

- W1a (#371) — the ITP state-read counterpart (list_by_state/count_by_state/
  list_forbidden_combos) that established the abstract-contract pattern.
- W1c2 (#398, sibling) — the PR-view / inline-comment reads; the normalized
  PR-field vocabulary in §3.2.1 is shared with W1c2 (defined once here).
- INV-86 (#277) — the close-linkage/branch resolution the caller-side jq
  now runs over the normalized array.
- INV-87 (#282) — the provider-dispatch contract; §3.5 the COMPLETE-set
  requirement this issue makes real for the two linkage-read verbs.
