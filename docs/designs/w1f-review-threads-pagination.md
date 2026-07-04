# W1f — `chp_review_threads` pagination completeness

Design brief for issue #401 (#347 W1f): close the last GraphQL completeness
gap in the CHP seam so a PR with >100 review threads (or one thread with
>100 comments) is fully covered and the sole caller
(`resolve-threads.sh`) fails LOUD on mid-walk failure instead of silently
reporting "0 resolved, 0 failed".

## Motivation

`chp_github_review_threads` (`providers/chp-github.sh:156-197`) issues one
GraphQL query with `reviewThreads(first: 100)` and, per-thread,
`comments(first: 100)` — no cursor walk on either level. `gh api graphql`
is NOT auto-paginated, so §3.5's normative "COMPLETE set" MUST is under-served
by exactly this leaf. `resolve-threads.sh:74-75` pipes the verb output
straight into jq without `set -o pipefail`, so a failed page fetch with empty
stdout produces empty `THREAD_IDS` → "0 resolved, 0 failed" false success.

## Design

### Leaf — two-level cursor walk

`chp_github_review_threads PR` becomes:

1. **Thread-level walk** — starting with an unset `threadCursor`, issue
   `reviewThreads(first: 100, after: $threadCursor)`; on the response, extract
   `data.repository.pullRequest.reviewThreads.pageInfo.{hasNextPage,endCursor}`
   and `data.repository.pullRequest.reviewThreads.nodes[]`. Append `nodes` to
   an accumulator in arrival order; loop while `hasNextPage`, passing
   `endCursor` as the next `$threadCursor`. Bounded at 50 pages; on cap-hit,
   return rc != 0 with a diagnostic (`page cap exceeded (thread level)`).
2. **Comment-level walk** — after the thread-level walk terminates, for each
   accumulated thread whose `.comments.pageInfo.hasNextPage` is true, issue a
   follow-up `node(id: $threadId) { ... on PullRequestReviewThread { comments(first: 100, after: $commentCursor) { pageInfo{…} nodes{…} } } }`
   query walking `commentCursor` the same way. Append additional comment
   nodes into that thread's `comments.nodes` in arrival order. 50-page cap
   with the same loud rc != 0 (`page cap exceeded (comment level, thread <id>)`).
3. **Normalize** the assembled complete tree once at the end into the M8
   shape `[{thread_id, resolved, comments:[{id, path, line, author, body, createdAt}]}]`
   — byte-compatible with today when the response fits in one page.

**Fail-closed**: every `gh api graphql` invocation is captured
(`out=$(gh api graphql … 2>err_capture) || return $?`) BEFORE the payload is
merged; on any non-zero rc, the accumulator is discarded and the verb
returns non-zero with no stdout output. This mirrors
`chp_github_count_reviews_by_login`'s capture-check-sum pattern ([INV-94]).

### Caller — capture-then-test rewrite

`skills/autonomous-common/scripts/resolve-threads.sh:74-75`:

```bash
# Before (pipes into jq; empty leaf → empty THREAD_IDS → false 0/0 success)
THREAD_IDS=$(chp_review_threads "$PR_NUMBER" \
  | jq -r '.[] | select(.resolved == false) | .thread_id')

# After (capture-then-test; leaf failure aborts loud)
if ! _threads_json=$(chp_review_threads "$PR_NUMBER"); then
  echo "Error: chp_review_threads failed for PR #$PR_NUMBER (see logs)" >&2
  exit 1
fi
THREAD_IDS=$(printf '%s' "$_threads_json" | jq -r '.[] | select(.resolved == false) | .thread_id')
unset _threads_json
```

Single-page success is byte-identical to today. Mid-walk failure now surfaces
as a script-level non-zero exit, not silent zero.

### Bounded walk

50 pages ≈ 5000 threads (or 5000 comments in one thread). The pinned cap
guards a pathological/hostile backend against unbounded looping in the
wrapper lane. The pipeline's chunked-sleep/watchdog lessons apply
(`docs/pipeline/invariants.md::INV-*` fixture-watchdog family). Cap-hit is
loud rc != 0 — never silent truncation.

### Degraded fixture posture

`chp_degraded_review_threads` (`tests/unit/fixtures/provider-degraded/chp-degraded.sh`)
keeps its single-page shape. **The spec explicitly documents that completeness
is asserted per-provider** — the degraded fixture asserts M8 SHAPE only, not
pagination completeness. This preserves the fixture's role (leaf-body-present
proof for `chp_has_leaf` branching + a shape-conformant response) without
duplicating the GitHub leaf's cursor logic. The runner's `coverage.conf`
stays `asserted`; the multi-page COMPLETENESS check is scoped to
`--chp github`.

### Spec updates (same PR)

- §3.2 cell (:251) — retire "Known cut-line", document nested comment-level
  completeness, flip the `**Asserted (shape only, NOT pagination completeness)**`
  wording to shape + multi-page completeness. Fix the caller mis-attribution
  (`lib-review-resolve.sh` is INV-41 model-resolution, NOT a thread consumer;
  sole caller is `resolve-threads.sh`).
- §3.5 blockquote — amend to state the GraphQL leaf now walks cursors
  internally. `gh --json` auto-pagination is still the transport for the ITP
  `--json` reads; `gh api graphql` (this leaf's transport) is NOT
  auto-paginated, so this leaf implements the walk itself.
- §4.4 (:552) — flip `chp_review_threads` disposition wording
  (`always asserted (shape only)` → `always asserted (shape + completeness)`).
- §10 checklist (:944) — flip `TC-PCONF-009` label
  (`§3.2 [M8] thread shape (shape only)` →
  `§3.2 [M8] thread shape + multi-page completeness`).
- Mapping appendix row (:991) — annotate the migrated leaf now walks BOTH
  pagination levels.
- `chp-github.sh:150-155` — rewrite the overclaiming leaf header (drop the
  stale `resolve-threads.sh:46` line ref; describe the two-level walk +
  fail-closed contract).

### Runner + tests

- `run-provider-conformance.sh` — add a payload-sequence stub-gh mode. The
  `_PCF_GH_PAYLOAD` env var stays a single file path for existing verbs; when
  a new `_PCF_GH_PAYLOAD_SEQ` is set (`:`-separated list of files), the stub
  serves them in invocation order, cycling back to the last on exhaustion.
  Assertion for `chp_review_threads`: 2-page thread fixture +
  nested-comment-page fixture → full merged array; mid-walk-failure fixture
  → rc != 0, empty stdout. Drop the shape-only carve-outs in `README.md:80-82`,
  `:126-131` + `docs/designs/provider-conformance-runner.md:230-232`.
- `test-chp-pr-lifecycle.sh` — re-pin TC-CHP-THREADS to the cursor-walk
  query (assert `pageInfo`/`after:` presence, drop the `reviewThreads(first: 100)`
  literal). TC-CHP-THREAD-SHAPE stays green unchanged.
- Add TC-W1F unit tests (see `docs/test-cases/w1f-review-threads-pagination.md`):
  multi-page merge, nested comment completeness, mid-walk fail-closed,
  caller-side capture-then-test parity, bounded walk cap.

### Invariant — INV-87 Migration-log amendment

INV-87's Status paragraph gets a `#401 (#347 W1f)` sentence recording that
`chp_review_threads` now walks both GraphQL pagination levels internally,
retiring the §3.2 "Known cut-line". No new INV mint — §3.5 stays the
normative home for list-completeness.

### AC6 follow-up

`skills/autonomous-common/hooks/verify-completion.sh:71` and `:100` still
carry a raw `reviewThreads(first: 100)` GraphQL query used by the local
completion gate. Same false-unblock hazard class, but OUTSIDE the CHP seam
(hook layer, not provider layer) and not autonomous-managed. The operator
files a non-`autonomous` follow-up issue and this PR's body links to it
before merge — see `## Conflict notes` in the PR draft.

## Out of scope

- Shape changes to `chp_review_threads` or `chp_resolve_thread` (already M8).
- The three same-class gaps: `chp_list_inline_comments` single-REST-page
  (W1c2 owns), `itp_label_event_ts` timeline page-1 (documented best-effort),
  the hook-side raw GraphQL in `verify-completion.sh` (AC6 follow-up).
- Non-GitHub CHP leaves (phase-3).
