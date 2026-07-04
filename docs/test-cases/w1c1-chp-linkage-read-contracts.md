# Test cases — W1c1 CHP linkage-read contracts (#397)

## Scope

The W1c1 slice converts two CHP read verbs from gh-argv passthrough to
abstract normalized-shape contracts:

- `chp_find_pr_for_issue ISSUE FIELDS-CSV` → normalized JSON candidate array
  (spec §3.2 [M1], §3.2.1 vocabulary).
- `chp_pr_list STATE FIELDS-CSV` → normalized JSON array projected to the
  caller's field set.

The [INV-86] two-tier close-linkage resolution stays caller-side in
`lib-pr-linkage.sh` (pure jq over the normalized array). The 6 body-mention
`chp_pr_list` caller sites keep their own `#N`-boundary regex over the
normalized `body` string (the `.body != null` guard becomes redundant — the
#148-class fix).

## Test cases

### Linkage decision parity

Anchor: `tests/unit/test-w1c1-linkage-read-parity.sh` +
`tests/unit/fixtures/w1c1-parity/decision-golden.json`. Fixtures mirror the
#277 canonical set + #148 null-body + a #397-headline >30-candidate set.

- **TC-W1C1-001** `linkage.resolve.close-linkage-wins` — sibling PR body-mentions
  #A, real PR closes #A → real PR wins.
- **TC-W1C1-002** `linkage.resolve.close-linkage-274` — symmetric case for the
  cross-referenced sibling.
- **TC-W1C1-003** `linkage.resolve.branch-fallback` — no close linkage; branch
  matches `issue-<A>` → branch-tier PR wins.
- **TC-W1C1-004/005** `linkage.resolve.cross-wired-*` — the #277 driver: two
  PRs, each closing its own issue and body-mentioning the sibling. Each issue
  resolves to its own close-linked PR, not the mentioning sibling.
- **TC-W1C1-006** `linkage.resolve.null-body` — a `body:null` sibling
  alongside a close-linked PR. Under the new normalization the null body
  is pinned to `""` by the leaf, so the caller's jq never aborts. Decision
  unchanged from #148/#277.
- **TC-W1C1-007** `linkage.resolve.no-pr` — no candidate → empty.
- **TC-W1C1-008** `linkage.resolve.boundary` — issue 27 must not match a PR
  closing #270 (substring safety).
- **TC-W1C1-009** `linkage.resolve.overlimit-500` — **W1c1 headline
  regression**: 35 candidates, one close-linked (`>gh --limit 30 default`);
  the new leaf's bounded page-walk (default 20 pages / 2000 PRs) surfaces
  the close-linked PR. Pre-W1c1 code would silently truncate at 30.

### Verify guard

- **TC-W1C1-020..023** `linkage.verify.*` — verify_pr_closes_issue accepts
  the close-linked PR (its own issue), the branch-fallback PR, and rejects
  the foreign-issue PR.

### Per-site chp_pr_list decision parity (6 sites)

Golden values are the "guarded" outputs (per-site body-mention selector with
the `.body != null` guard applied). Under the new normalized shape all 6
sites converge on the guarded decision — the four ex-unguarded sites (the
#148 hazard class) now behave the same as the two ex-guarded sites.

- **TC-W1C1-030..033** `needs_open_pr_only` (autonomous-dev.sh:438):
  length across rich / empty / boundary / nullbody fixtures.
- **TC-W1C1-040..043** `pr_exists` (autonomous-dev.sh:844): same shape;
  #148 fix case explicitly.
- **TC-W1C1-050..052** `_pr_created_at` (autonomous-dev.sh:943): earliest
  matching PR's `createdAt`.
- **TC-W1C1-060..063** `pr_num` (autonomous-dev.sh:1174): first matching
  PR's `number`; #148 fix case explicitly.
- **TC-W1C1-070..072** `lib_auth_existing` (lib-auth.sh:454): length; #148
  fix case explicitly.
- **TC-W1C1-080..082** `lib_auth_pr_number` (lib-auth.sh:610): first PR
  number; #148 fix case explicitly.

### Normalization contract

Anchor: `tests/provider-conformance/run-provider-conformance.sh` +
`fixtures/payloads/pr-list-valid.json`.

- **TC-W1C1-100** (via runner) — `chp_find_pr_for_issue`: every returned
  element has `body` as a string (never null), `closingIssueNumbers` as an
  int-array; caller-requested fields present in the projection.
- **TC-W1C1-101** (via runner) — `chp_pr_list`: same, plus `[]`-not-null
  on empty match set, plus rc != 0 when STATE / FIELDS-CSV positional args
  are missing.
- **TC-W1C1-102** (via runner) — both verbs are **fail-CLOSED** when the
  stub `gh` errors: rc != 0, no partial output.

### Seam-trace: positional argv only (no gh flags cross)

- **TC-W1C1-SEAM-TRACE** (parity suite) — grep the 5 caller-layer files
  (`autonomous-dev.sh`, `autonomous-review.sh`, `lib-auth.sh`,
  `lib-pr-linkage.sh`, `lib-dispatch.sh`) for `chp_pr_list --`/`chp_pr_list -q`
  or `chp_find_pr_for_issue --`/`-q` — no non-comment hits are permitted.

### Golden-trace of the leaf's gh argv

Anchor: `tests/unit/test-chp-pr-lifecycle.sh` (TC-CHP-FINDPR, TC-CHP-PRLIST).

- Both leaves emit `gh api graphql -F owner=<owner> -F repo=<repo> -f query=…`
  and cursor-page-walk `pullRequests(first:100, after:$cursor)` until
  `pageInfo.hasNextPage == false`. R1 prohibits a fixed `--limit N` (it
  just moves the silent-truncation threshold); `--json`/`-q` never cross
  the gh boundary.
- `chp_find_pr_for_issue` hardcodes `states:[OPEN]` (open-PR resolver only)
  and unions the caller's FIELDS-CSV with the [INV-86] resolver keys
  (`number`, `closingIssueNumbers`, `headRefName`).
- `chp_pr_list` maps STATE ∈ `open|closed|merged|all` to the corresponding
  GraphQL `PullRequestState` filter (`[OPEN]`, `[CLOSED]`, `[MERGED]`,
  `[OPEN,CLOSED,MERGED]`); `closed` and `merged` are DISJOINT (diverges
  from `gh pr list --state closed` which INCLUDES merged — deliberate,
  see spec §3.2).
- Both bounded by `CHP_GITHUB_PR_LIST_PAGE_CAP` (default 20 pages = 2000
  PRs). Cap-hit before exhaustion is fail-CLOSED (rc≠0, no partial output);
  every page fetch is capture-then-check gated (empty stdout / non-JSON /
  non-array → rc≠0). Empty match set → `[]` (never null; the #148 fix).
- Projection-only (P1-1): each output element carries EXACTLY the caller-
  requested vocabulary keys (plus, for find_pr_for_issue, the three forced
  resolver keys). No fabrication of unrequested §3.2.1 members.
- Both verbs error (rc != 0) when the FIELDS-CSV positional is missing;
  `chp_pr_list` additionally errors on missing STATE. `comments` in
  FIELDS-CSV → rc 2 loud (issue-level, owned by `itp_list_comments`).

### Regression suites that must stay green

- `tests/unit/test-pr-issue-linkage-277.sh` (INV-86 wire) — 36 assertions,
  decisions unchanged.
- `tests/unit/test-fetch-pr-for-issue-null-body.sh` (#148) — 6 assertions,
  decisions unchanged.
- `tests/unit/test-handle-completed-routing-golden-trace.sh` — Branch A/B/C
  routing traces reconciled to the new FIELDS positional shape; the #148
  body-inclusion anchor at the verb boundary holds.
- `tests/unit/test-token-split-234.sh` — six sub-cases whose gh stubs return
  raw text (e.g. `echo 4242`) updated to emit valid JSON arrays so the
  leaf's normalization jq resolves the caller-side selector correctly.
- `tests/unit/test-autonomous-dev-pushed-no-pr-resume.sh` — the harness's
  local `chp_pr_list` shim rewritten to positional-args + normalization jq.

## Verification

```bash
env -u PROJECT_DIR bash tests/unit/test-w1c1-linkage-read-parity.sh
env -u PROJECT_DIR bash tests/unit/test-chp-pr-lifecycle.sh
env -u PROJECT_DIR bash tests/unit/test-pr-issue-linkage-277.sh
env -u PROJECT_DIR bash tests/unit/test-fetch-pr-for-issue-null-body.sh
env -u PROJECT_DIR bash tests/unit/test-handle-completed-routing-golden-trace.sh
env -u PROJECT_DIR bash tests/unit/test-token-split-234.sh
env -u PROJECT_DIR bash tests/unit/test-autonomous-dev-pushed-no-pr-resume.sh
env -u PROJECT_DIR bash tests/unit/test-provider-conformance-runner.sh
env -u PROJECT_DIR bash tests/provider-conformance/run-provider-conformance.sh
```

All green pre-merge.
