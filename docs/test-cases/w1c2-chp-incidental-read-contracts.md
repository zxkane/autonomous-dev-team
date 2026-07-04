# W1c2: CHP incidental-read contracts test cases (`chp_pr_view` / `chp_list_inline_comments`)

Test-case IDs: `TC-W1C2-NNN`. Fourth W1 slice of #347, second W1c half — see
issue #398 for the requirements. Every case listed here is hermetic (stub `gh`,
no network) and runs under `env -u PROJECT_DIR bash …`.

## Fixture provenance (R4)

The parity goldens under `tests/unit/fixtures/w1c2-parity/` were captured on
the FIRST TDD commit of the #398 branch, BEFORE any leaf / shim / caller
rewrite landed, per R4. `decision-golden.json.meta` records the exact regen
procedure. The parity test `tests/unit/test-w1c2-incidental-read-parity.sh`
runs 12 assertions against the frozen goldens (repeated on every subsequent
commit — decision-level parity, not byte-level).

## Assertions

### TC-W1C2-001 — site1 approved-timestamp (`autonomous-dev.sh:604`)
The rewritten caller `chp_pr_view "$pr_num" "reviews" | jq -r '[.reviews[]? |
select(.state == "APPROVED") | .submittedAt] | sort | last // empty'` produces
the SAME approved-timestamp string the OLD `--json reviews -q '<sel>'` form
produced against the mixed-reviews fixture (latest APPROVED submittedAt wins).
Fail-CLOSED on gh failure: `if !` catches a pipefail-propagated non-zero. No
approval → empty (`// empty`), rc 0 (a legitimate "no approval" case).

### TC-W1C2-002 — site2 preview-URL (`autonomous-review.sh:918`)
The rewritten caller `chp_pr_view "$PR_NUMBER" "comments" 2>/dev/null | jq -r
'[.comments[].body | select(contains("Preview"))] | last' | grep -oP
'https://[^\s"]+' | head -1` produces the SAME URL string. The URL scrape
(`grep -oP …`) stays caller-side.

### TC-W1C2-003 — site3 `headRefName` (`autonomous-review.sh:948`)
`chp_pr_view "$PR_NUMBER" "headRefName" | jq -r '.headRefName'` — the
vocabulary field is 1:1 mapped from gh; the caller reads it plainly.

### TC-W1C2-004 — site4 `headRefOid` (`autonomous-review.sh:949`)
Sibling of TC-W1C2-003; the leaf projects `.headRefOid` directly.

### TC-W1C2-005 — site5 state (E2E-lane, `autonomous-review.sh:1591`)
`chp_pr_view "$PR_NUMBER" "state"` returns `{state:"OPEN"|"CLOSED"|"MERGED"}`;
`_pr_open_gate` consumes the raw OPEN token unchanged (vocabulary state
values match gh's).

### TC-W1C2-006 — site6 state (PASS-chain, `autonomous-review.sh:3312`)
Sibling of TC-W1C2-005. The two-sites-in-file-order property is preserved (the
two open-guard tests' TC-OG-SRC-03 / TC-EOG-SRC-05 pins re-target the
positional `"state"` form).

### TC-W1C2-007 — site7 bot-review-wait count (`autonomous-review.sh:3357`)
`chp_pr_view "$PR_NUMBER" "comments" | jq -r '[.comments[] | select(.body |
contains("bot-review-wait sha=\"…\""))] | length'` — the extraction produces
the SAME integer count over the SAME comments array.

### TC-W1C2-008 — site8 SHA-evidence body (`lib-review-e2e.sh:262`)
`chp_pr_view "$PR_NUMBER" "comments" | jq -r '[.comments[] |
select(.body|contains("e2e-evidence: complete sha=\"…\"")) | .body] | last //
empty'` — the multi-line evidence body survives intact (the load-bearing
property; `head -1` was rejected in the original site).

### TC-W1C2-009 — site9 inline-comment formatter (`autonomous-dev.sh:1091`)
`chp_list_inline_comments "$PR_NUM" | jq -r '[.[] | "- **\(.path):\(.line //
"N/A")** — \(.body)"] | join("\n")'` — the caller renders `.line // "N/A"`
over the normalized `line` field (which is the leaf's `line // original_line
// null` fold). Byte-identical to the OLD `.line // .original_line // "N/A"`
rendering on a mixed line-populated / originalLine-only fixture.

### TC-W1C2-010 — inline completeness (>1 REST page reaches the block)
The NEW leaf page-walks (`gh api --paginate`) and slurps into ONE array;
site9's `- **path:line** — body` rendering contains lines from BOTH pages.
The pre-#398 leaf silently truncated at gh's REST-default first page (30
comments); this is the deliberate behavior improvement the issue body flags
(more prompt content — acceptable per #347 AC4's documented-shape-rewrite
clause).

### TC-W1C2-011 — `chp_pr_view` fail-CLOSED
Missing FIELDS_CSV (2nd arg) → rc 2 (fail-CLOSED per R2; mirrors
`chp_github_find_pr_for_issue`'s [M1]).

### TC-W1C2-012 — `chp_pr_view` fail-CLOSED on gh failure
Stub `gh` returning non-zero → verb rc≠0, no partial stdout. The caller's
`|| true` / `|| echo UNKNOWN` framing degrades unchanged.

### TC-W1C2-013 — `chp_list_inline_comments` fail-CLOSED on any page fail
Stub `gh api --paginate` returning non-zero → verb rc≠0, no partial output
(no smuggled page-1 array).

### TC-W1C2-014 — self-guarding shim (unchanged)
`CODE_HOST=fakehost` (no `providers/chp-fakehost.sh` exists) → both shims
emit `WARN: [INV-87]` / `WARN: [INV-95]` and `return 1`. The 9 caller sites'
`|| true` / `|| echo UNKNOWN` framings degrade to empty / "UNKNOWN"; no
`set -e` abort.

### TC-W1C2-015 — leaf-side line fold
Inline-comments fixture with `{line: null, original_line: N}` → the leaf
emits `{line: N}` after the fold; `original_line` is ABSENT from the
normalized element shape (the caller's `.line // "N/A"` renders `N`, matching
the OLD renderer).

### TC-W1C2-016 — leaf-side ascending sort
`chp_list_inline_comments` returns a `[…]` array sorted ascending by
`createdAt` (id tie-break). The runner asserts this via
`pcf_is_ascending_by_created_at`.

### TC-W1C2-017 — normalized subset projection (`chp_pr_view`)
Requesting `FIELDS_CSV="state,comments,reviews,closingIssueNumbers,body"`
returns an object with EXACTLY those keys (no extras) and each value in the
normalized shape per R1. Enforced by the runner's `_run_pr_view_assert`
(exact-keys diff + element-shape assertions).

### TC-W1C2-018 — CONTRACT-PENDING tripwire
Coverage-runner `CONFORMANCE-COVERAGE PASS (spec CONTRACT-PENDING set ==
coverage.conf pending set, 8 verbs)` — both W1c2 verbs flipped
pending→asserted with the two spec `CONTRACT-PENDING` tokens removed in the
same PR. Enforced by `test-provider-conformance-runner.sh::TC-PCONF-040`.

## Regression anchors touched (R6)

- `test-chp-pr-lifecycle.sh` TC-CHP-PRVIEW / TC-CHP-PRVIEW-ROUTE / TC-CHP-PRVIEW-FAILCLOSED / TC-CHP-PRGUARD (fakehost variant).
- `test-chp-list-inline-comments.sh` AC1 (positional argv, page-walk owned by leaf) + AC1-cont. (OLD/NEW formatter rendering equivalence).
- `test-issue-308-b3b4-chp-reads.sh` S3 (structural argv assertions; caller SHA-selector no longer crosses the seam).
- `test-autonomous-review-fail-branch-open-guard.sh` TC-OG-SRC-02/-03/-03b/-04 (re-pinned to positional `"state"`; line-ORDER kept).
- `test-autonomous-review-e2e-gate-open-guard.sh` TC-EOG-SRC-01/-04/-05 (re-pinned to positional `"state"`; line-ORDER kept).
- `test-dev-resume-post-approval-findings.sh` — the isolation harness sources
  the REAL `chp_github_pr_view` leaf (not a re-implemented shim), so the W1c2
  normalization program is exercised end-to-end.
- `test-autonomous-review-sequential-e2e.sh` TC-SE2E-FETCH-01/-02/-03/-04 —
  fixtures are now `{comments:[…]}` JSON objects (not raw evidence strings);
  the stub `gh` honors the leaf-supplied `--jq` so the real normalization
  runs against the fixtures.
