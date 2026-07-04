# W1f — `chp_review_threads` pagination completeness

Test cases for issue #401 (#347 W1f): `chp_github_review_threads` walks BOTH
GraphQL pagination levels (thread level + per-thread comment level) and
`resolve-threads.sh` fails closed across page failures.

Governing spec: `docs/pipeline/provider-spec.md` §3.2 cell `chp_review_threads`
(retires the "Known cut-line") + §3.5 (list-completeness MUST for every list
verb, blockquote amended: the GraphQL leaf now walks cursors internally).
Invariant: [INV-87] Migration-log — amended in place (no new INV mint).

## TC-W1F-001 — 2-page thread walk merges to one complete M8 array

**Given** a stub `gh api graphql` that serves page 1 with
`{hasNextPage: true, endCursor: "TCUR1"}` and 2 thread nodes, then page 2
(when re-invoked with `-F threadCursor=TCUR1`) with `{hasNextPage: false}`
and 2 more thread nodes,
**When** `chp_review_threads 42` is called,
**Then** stdout is a single JSON array of length 4 in ARRIVAL order
(`page1[0]`, `page1[1]`, `page2[0]`, `page2[1]`) with the exact M8 element
shape `{thread_id, resolved, comments:[{id, path, line, author, body, createdAt}]}`,
byte-compatible with today's single-page normalization. rc == 0.

## TC-W1F-002 — Nested comment-level completeness (>first-page comments in one thread)

**Given** a stub `gh` that returns ONE thread on page 1 whose
`comments.pageInfo.hasNextPage=true`, `endCursor=CCUR1`, and 2 comment nodes;
then a follow-up `node(id: $threadId)` query with `-F commentCursor=CCUR1`
returns 2 more comment nodes with `hasNextPage=false`,
**When** `chp_review_threads 42` is called,
**Then** the thread's `.comments` array has length 4 in arrival order; the
merge happens BEFORE the M8 normalization so downstream field shape is
unchanged. rc == 0.

## TC-W1F-003 — Mid-walk page failure → rc≠0, zero partial output

**Given** a stub `gh` that succeeds on page 1
(`{hasNextPage: true, endCursor: "TCUR1"}` + 2 threads) and FAILS on page 2
(non-zero exit),
**When** `chp_review_threads 42` is called,
**Then** rc != 0 and stdout is empty (no partial 2-thread array). The caller
must not see a truncated array under a different name — the fail-closed
contract mirrors `chp_count_reviews_by_login`'s capture-check-sum pattern
([INV-94]).

## TC-W1F-004 — Single-page byte-compatibility (today's fixture unchanged)

**Given** the single-page `_GRAPHQL_THREADS` fixture from
`tests/unit/test-chp-pr-lifecycle.sh` (TC-CHP-THREAD-SHAPE): 2 threads, no
`hasNextPage`,
**When** `chp_review_threads 42` is called,
**Then** the resulting M8 array is byte-identical to today's output —
`.[0]|keys_unsorted == "thread_id,resolved,comments"`; comment element
`.[0].comments[0]|keys_unsorted == "id,path,line,author,body,createdAt"`;
`.line // .originalLine` fallback preserved. rc == 0.

## TC-W1F-005 — resolve-threads.sh decision parity across the page boundary

**Given** a 2-page fixture (see TC-W1F-001) where one thread on page 2 has
`resolved=false`,
**When** `resolve-threads.sh <owner> <repo> 42` runs with the stub `gh`,
**Then** the script's unresolved-id selection
(`chp_review_threads | jq '.[]|select(.resolved==false)|.thread_id'`)
includes the page-2 thread's id — proving the fix reaches the sole caller,
not just the verb output.

## TC-W1F-006 — resolve-threads.sh fails loud on mid-walk failure (caller-side)

**Given** the mid-walk-failure fixture from TC-W1F-003,
**When** `resolve-threads.sh <owner> <repo> 42` runs,
**Then** the script exits non-zero with a diagnostic on stderr; it does NOT
report `"0 resolved, 0 failed"` success. This regression-pins the
capture-then-test rewrite (`out=$(chp_review_threads "$PR") || { fail; exit 1; }`)
and closes the pre-#401 fail-open where an empty pipe-into-jq stream
silently produced empty `THREAD_IDS`.

## TC-W1F-007 — Bounded walk cap loud on hit

**Given** a stub `gh` that ALWAYS returns `hasNextPage: true` (a pathological
backend that never terminates the thread-level walk),
**When** `chp_review_threads 42` is called,
**Then** the verb halts at the 50-page cap and returns rc != 0 with a loud
`page cap exceeded` diagnostic on stderr — no partial output. This gates the
wrapper-lane hang risk called out in the issue's Design Considerations.

## TC-W1F-008 — Conformance runner asserts multi-page completeness

**Given** the payload-sequence stub-gh mode added to
`tests/provider-conformance/run-provider-conformance.sh` and a 2-page
`review-threads-multipage.json` fixture,
**When** the conformance runner drives `chp_review_threads`,
**Then** it PASSes on a full merged array (both pages present) AND FAILs if
the leaf emits only page-1 nodes. A separate mid-walk-failure fixture
asserts rc != 0 with no partial output. `coverage.conf` stays `asserted`
(no `CONTRACT-PENDING` token exists to remove).

## TC-W1F-009 — Runner self-test covers payload-sequence mode

**Given** `tests/unit/test-provider-conformance-runner.sh` picks up the new
payload-sequence stub mode,
**When** the self-test runs,
**Then** it PASSes on the multi-page fixture and FAILs when the stub is
deliberately configured to serve only page 1 for the completeness assertion
— gating the runner's own regression.

## TC-W1F-VALIDATE-100..120 — Positional-arg validation (W1e convention, #400 / #401 review r2)

**Given** the W1e convention (`chp_create_pr`/`chp_approve`/`chp_merge`
validate positionals with rc 2 + loud stderr + no gh call) applied to the
review-thread verbs,
**When** an operator invokes `chp_review_threads` with an empty, missing,
or non-numeric `PR`; or `chp_resolve_thread` with an empty or missing
`THREAD_ID`,
**Then** the leaf returns rc 2 with a loud `ERROR:` diagnostic on stderr
and MUST NOT invoke `gh`. A valid numeric PR still passes rc 0 (regression
pin against over-tightening). `resolve-threads.sh` (sole caller) sanitizes
`PR_NUMBER` via `printf '%d' "$3"` and gates thread_id with
`[ -n "$thread_id" ]` before dispatch, so reaching the leaf with an invalid
positional is operator misuse and safe to validate (per the #400
caller-legitimacy rule that broke the too-broad body-empty gate). Mirror
validation lands in `tests/unit/fixtures/provider-degraded/chp-degraded.sh`
so the runner's `--chp degraded` pass exercises the same contract.

## Notes

- `env -u PROJECT_DIR bash …` for CI parity (per project convention).
- No network; every stub is invocation-count or `-F <cursor>=…`-argv keyed.
- Single-page success is byte-identical to the pre-#401 behavior; the
  golden-trace argv assertion in `test-chp-pr-lifecycle.sh` TC-CHP-THREADS
  is RE-PINNED to the cursor-walk query (asserts `pageInfo`/`after:`
  presence), not the retired `reviewThreads(first: 100)` literal.
