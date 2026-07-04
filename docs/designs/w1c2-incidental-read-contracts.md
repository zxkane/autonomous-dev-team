# W1c2: CHP incidental-read normalized-shape contracts

Fourth W1 slice of #347 (second W1c half; sibling of W1c1 / #397).
Implementation issue: #398. Full spec cells: `provider-spec.md` §3.2 / Mapping
appendix rows :993-994.

## Scope

Two CHP read verbs move from gh-argv passthrough to abstract contracts with
NORMALIZED output; callers pass positionals; leaves own gh argv +
normalization; caller-side jq runs AFTER the seam over the normalized shape.

- `chp_pr_view <PR> <FIELDS_CSV>` — single normalized JSON object, EXACTLY the
  requested vocabulary fields (per W1c1's vocabulary block). rc≠0 fail-closed
  on not-found / gh failure.
- `chp_list_inline_comments <PR>` — ONE merged normalized flat array
  `[{id,path,line,author,body,createdAt}]` ascending. `line` = leaf-side
  `line // original_line // null` fold. COMPLETE via page walk. Fail-CLOSED
  on any page fetch failure.

Both shims keep their pre-#398 self-guarding posture (leaf-absent → WARN +
`return 1`).

## The 9 caller sites

The 8 `chp_pr_view` sites carry small jq projections:

| Site | Purpose | Vocabulary field | Caller expression |
|---|---|---|---|
| `autonomous-dev.sh:604`     | approved-timestamp | `reviews`     | `[.reviews[]? \| select(.state=="APPROVED") \| .submittedAt] \| sort \| last // empty` |
| `autonomous-review.sh:918`  | preview-URL scrape | `comments`    | `[.comments[].body \| select(contains("Preview"))] \| last`, then `grep -oP … \| head -1` |
| `autonomous-review.sh:948`  | `headRefName`      | `headRefName` | `.headRefName` |
| `autonomous-review.sh:949`  | `headRefOid`       | `headRefOid`  | `.headRefOid` |
| `autonomous-review.sh:1591` | state (E2E gate)   | `state`       | `.state` → `_pr_open_gate` |
| `autonomous-review.sh:3312` | state (PASS chain) | `state`       | `.state` → `_pr_open_gate` |
| `autonomous-review.sh:3357` | bot-review-wait count | `comments` | `[.comments[] \| select(.body \| contains("bot-review-wait sha=\"…\""))] \| length` |
| `lib-review-e2e.sh:262`     | SHA-evidence body  | `comments`    | `[.comments[] \| select(.body \| contains("e2e-evidence: complete sha=\"…\"")) \| .body] \| last // empty` |

The 1 `chp_list_inline_comments` site:

| Site | Purpose | Caller expression |
|---|---|---|
| `autonomous-dev.sh:1091` | dev-resume `PR_REVIEW_COMMENTS` | `[.[] \| "- **\(.path):\(.line // "N/A")** — \(.body)"] \| join("\n")` |

## Normalization jq (leaf-owned)

The GitHub leaf runs one `gh` invocation per verb call. jq runs INSIDE the
leaf on the captured raw JSON, NOT via gh's inline `--jq` — the load-bearing
distinction that makes fail-CLOSED-on-empty-stdout reachable (see below).

- `chp_github_pr_view` maps each vocabulary field to its raw gh counterpart
  (mostly 1:1; `closingIssueNumbers` ↔ `closingIssuesReferences`) then emits
  a single JSON object carrying EXACTLY the requested fields. `comments` and
  `reviews` are normalized to `[{id,author,body,createdAt}]` /
  `[{author,state,submittedAt}]` ascending; `body: null` → `""`;
  `closingIssueNumbers` accepts BOTH the flat `[{number}]` shape real `gh pr
  view --json closingIssuesReferences` returns (the pre-existing repo-wide
  idiom, `lib-pr-linkage.sh:85` anchor) AND the GraphQL cursor `{nodes:[…]}`
  form via `((.closingIssuesReferences // []) | (if type == "object" then
  (.nodes // []) else . end))` — **P1-1 codex pre-review fix**. `author`
  handles both object (`.author.login`) and scalar (already-a-string author)
  inputs via `if type == "object" then .login else . end`.

  **Fail-CLOSED (P1-2 codex pre-review)**: the leaf uses CAPTURE-THEN-CHECK,
  NOT gh's inline `--jq`. `raw=$(gh pr view $PR --repo $REPO --json …) ||
  return 1` propagates gh rc; `[[ -n "$raw" ]] || return 1` rejects a
  silent rc-0 empty-stdout failure; `jq -e 'type == "object"' … || return 1`
  rejects malformed JSON. Only then does the normalization jq run
  (`jq -c "$norm_program" <<<"$raw"`). This is a hard requirement — with
  gh's own `--jq` the empty-stdout case was silently swallowed and callers'
  `|| true` framing turned it into a real-looking "no answer" (reproduced
  on-box: `gh(){ return 0; }` → rc=0 empty out, which callers took as
  "state=UNKNOWN"). Now the same case yields rc≠0 empty out, and the
  caller's `|| echo UNKNOWN` degrades correctly.

- `chp_github_list_inline_comments` uses `gh api --paginate` which emits one
  ARRAY PER PAGE (the trap the issue body flags). The leaf captures the raw
  concatenated stream then runs `jq -c --slurp '(add // []) | […] |
  sort_by(.createdAt // "", .id // 0)'` in a single pass — one normalization,
  one merged array. Fail-CLOSED on ANY page fetch failure (rc propagation)
  AND on rc-0 empty stdout (**P2-3 codex pre-review fix** — a real
  zero-comment PR emits the literal `[]` from `gh api`, so empty stdout can
  only mean a silent gh failure that must degrade to WARN + rc 1 via the
  shim, not smuggle a `[]` back to the dev-resume prompt).

## Deliberate SHAPE change per W1

Byte-identical passthrough was the pre-#398 contract; #398 is a deliberate
W1 shape change. Decision-level parity (not byte-level) is proven by
`tests/unit/test-w1c2-incidental-read-parity.sh` (the frozen-golden anchor
captured on the FIRST TDD commit, before any leaf/shim/caller rewrite
landed).

## Behavior improvement (inline-comments completeness)

The pre-#398 `chp_list_inline_comments` leaf issued ONE REST page (gh's
default 30), so PRs with >30 inline comments silently lost every comment
past page 1 from the dev-resume prompt (the retired `chp-github.sh:323`
"No `--paginate` today" caveat named this). The new leaf page-walks to
exhaustion, so the dev agent sees every inline comment. This is a
DELIBERATE behavior improvement (more prompt content); flagged in the PR
body as such, acceptable per #347 AC4's documented-shape-rewrite clause.

## Conflict cluster (operator rebase)

Shared-file edits with W1c1 (#397) and other in-flight W1 slices:

- `docs/pipeline/provider-spec.md` — §3.2 cells + Mapping appendix rows + §10
  matrix + CONTRACT-PENDING count references.
- `skills/autonomous-dispatcher/scripts/providers/chp-github.sh` — the two
  leaves.
- `skills/autonomous-dispatcher/scripts/lib-code-host.sh` — shim posture
  unchanged; comment amendments only.
- `tests/provider-conformance/coverage.conf` — two `pending`→`asserted` flips.
- `tests/provider-conformance/cap-map.conf` — two new `=-` rows.
- `tests/provider-conformance/run-provider-conformance.sh` — two new
  assertions (`_run_pr_view_assert` / `_run_list_inline_comments_assert`) +
  case-statement wiring.
- `tests/provider-conformance/README.md` — asserted-count narrative + summary
  pin.
- `tests/provider-conformance/fixtures/payloads/` — two new payloads.
- `tests/provider-conformance/fixtures/provider-broken/chp-broken.sh` — two
  correct W1c2 leaves added (broken fixture only violates the DECLARED
  chp_broken_review_threads / chp_broken_resolve_thread cases).
- `tests/unit/fixtures/provider-degraded/chp-degraded.sh` — two correct W1c2
  leaves added (so the runner's degraded run PASSes them, not SKIPs).
- `tests/unit/test-provider-conformance-runner.sh` — pin counts (17→19 PASS,
  10→8 pending, 12→14 non-targeted-still-PASS on broken, 14→16 PASS on
  degraded) + the AC4/AC5 sanity check scoped to "every chp_github_* leaf
  OTHER than the two W1c2-scoped verbs is byte-diff-free vs origin/main"
  (mirrors #371 W1a's ITP-side exception).
- `tests/unit/test-chp-pr-lifecycle.sh` — TC-CHP-PRVIEW / -PRVIEW-ROUTE
  re-pinned to positional argv; TC-CHP-PRGUARD re-scoped to CODE_HOST=fakehost.
- `tests/unit/test-chp-list-inline-comments.sh` — AC1 seam-trace re-pinned to
  positional argv + `--paginate`; AC1-cont. proves OLD/NEW formatter
  rendering equivalence.
- `tests/unit/test-issue-308-b3b4-chp-reads.sh` — S3 argv structural
  (no per-arg golden trace; anti-regression on the caller SHA-selector).
- `tests/unit/test-autonomous-review-fail-branch-open-guard.sh` — line-order
  pins retargeted to `"state"`.
- `tests/unit/test-autonomous-review-e2e-gate-open-guard.sh` — line-order
  pins retargeted to `"state"`.
- `tests/unit/test-dev-resume-post-approval-findings.sh` — isolation harness
  sources the REAL leaf.
- `tests/unit/test-autonomous-review-sequential-e2e.sh` — TC-SE2E-FETCH
  fixtures are `{comments:[…]}` objects; gh stub honors `--jq`.
- `docs/pipeline/invariants.md` — INV-87 Migration-log bullet + INV-95
  amendment.

At operator rebase time (after #397 merges) the vocabulary-block reference in
the `chp_pr_view` spec cell will resolve; the W1c2 note flag is left in
place until then per the parallel-development guidance in the task briefing.

## Out of scope

- `chp_find_pr_for_issue` / `chp_pr_list` (W1c1, #397).
- `chp_ci_status` / `chp_mergeable` (W1d).
- CHP writes (W1e).
- `chp_review_threads` pagination (W1f).
- Any non-GitHub CHP leaf (phase-3).
- The agent-prompt heredocs (phase-3).
