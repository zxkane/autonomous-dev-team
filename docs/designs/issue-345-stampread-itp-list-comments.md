# Design — migrate the INV-46 stamp-path comment reads behind `itp_list_comments` (#345)

> #296 deferred batch. Migrates `lib-review-e2e.sh::_stamp_browser_evidence_marker`'s
> two raw `gh api` reads — the paginated find-report-comment-id read (`:492`) and the
> single-comment body fetch (`:504`) — behind the **SHIPPED** `itp_list_comments` verb,
> shape-equivalently. **No new verb minted.** Retires the INV-46 carve-out that had kept
> these two reads raw (the earlier framing in #296's Deferred section — "not
> byte-identical" — was corrected by design review: the normalized §3.3 shape already
> carries everything this caller needs). Shrinks `scripts/providers/cutover-baseline.json`
> by exactly 2 signatures.

## Problem

`_stamp_browser_evidence_marker` (lib-review-e2e.sh) finds the browser lane's posted
`## E2E Verification Report` PR comment and edits it in place to append the SHA
evidence marker. Today that lookup is TWO raw `gh api` reads:

```bash
# lib-review-e2e.sh today (the survivors, ~:492 / ~:504):
_comment_id=$(gh api "repos/${REPO_OWNER}/${REPO_NAME}/issues/${PR_NUMBER}/comments" --paginate \
  --jq "[.[] | select(${_author_jq}(.created_at >= \"${WRAPPER_START_TS}\") and (.body | contains(\"## E2E Verification Report\")))] | last | .id" \
  2>/dev/null | tail -n1 || true)
...
_body=$(gh api "repos/${REPO_OWNER}/${REPO_NAME}/issues/comments/${_comment_id}" \
  --jq '.body' 2>/dev/null || true)
```

Both are frozen in the [INV-91] cutover baseline as documented "stay caller-side"
survivors (`provider-spec.md:884`, `invariants.md` INV-46 entry). #296's Deferred
section listed these sites as needing a new verb (`itp_read_comment`) because
`itp_list_comments` "normalizes shape → not byte-identical." Byte-identical they are
indeed not — but the **shape-equivalent** migration path (precedent: #332 auto-merge
marker, #315 body-read, #333 broker-dedup read in this SAME file) is available.

## Solution

Route BOTH reads through ONE `itp_list_comments` call, selecting the newest matching
report from the normalized array and reading `.body` from the SAME selected element:

```bash
_select_jq="[.[] | select(${_author_jq}(.createdAt >= \"${WRAPPER_START_TS}\") and (.body | contains(\"## E2E Verification Report\")))] | sort_by(.createdAt // \"\", .id // 0) | last"
_selected=$(itp_list_comments "$PR_NUMBER" 2>/dev/null | jq -c "$_select_jq" 2>/dev/null || true)
_comment_id=$(printf '%s' "$_selected" | jq -r '.id // empty' 2>/dev/null || true)
...
_body=$(printf '%s' "$_selected" | jq -r '.body // empty' 2>/dev/null || true)
```

- `id` is the REST **numeric** comment id (spec §3.3): "consumed by the same
  provider's `itp_edit_comment`" — provider-spec.md names the INV-46 PATCH path as the
  load-bearing consumer. The normalized element carries exactly this id.
- `body` is verbatim (spec §3.3). Once the report comment is selected from the list,
  the body IS already in hand — the separate `gh api …/issues/comments/{id} --jq
  .body` GET is redundant. **One verb call now serves both reads** (R2).
- `createdAt` ascending sort + `| last` matches the "newest report comment" selection
  the raw call performed.

### Author predicate re-expression

The raw call's `_author_jq` binds `.user.login == "${BOT_LOGIN}"` (dropped entirely
when `BOT_LOGIN` is unset — the INV-20 fallback). The normalized array exposes
`.author` directly (no `.user.` wrapper), so the re-expression is:

```
(.user.login == "${BOT_LOGIN}") and    →    (.author == "${BOT_LOGIN}") and
```

Exact-equality, engine-irrelevant (no regex on either side) — the #321 verdict
migration's Fix 1 is the precedent for this exact `.user.login`→`.author` rename.

### Same-second tie-break (R3)

The raw call selected `last` over gh's own (undocumented) comment ordering. The
migrated select adds `sort_by(.createdAt // "", .id // 0) | last` — re-sorting the
already-ascending [INV-90] array is idempotent, and the added `.id` secondary key
makes a same-second tie deterministic (the higher/later-inserted REST id wins). This
is the exact tie-break `_fetch_agent_verdict_body` (`lib-review-poll.sh`, #321) uses
for the sibling verdict-comment selection.

### `// empty` on both id and body reads (fail-closed parity)

A no-match selection over `.[] | select(...)` yields jq `null` for the array-empty
case; `.id`/`.body` accessed on `null` also yield `null`. `jq -r` prints a bare `null`
as the literal string `"null"`, which would NOT satisfy `[[ "$_comment_id" =~
^[0-9]+$ ]]` (good — that's the fail-closed branch) but WOULD satisfy `[[ -n
"$_body" ]]` for the body (bad — a literal "null" string is non-empty). `// empty`
after each accessor restores the raw-gh empty-on-no-match contract both guards
depend on.

### `.created_at` → `.createdAt`

Same lexical-format equivalence #332/#333/#321 established: both are ISO-8601 UTC
`YYYY-MM-DDTHH:MM:SSZ`, so the `>=` string-compare boundary semantics carry over
unchanged (R3's boundary test pins this).

### REPO_OWNER / REPO_NAME no longer read here

`itp_list_comments` (→ `gh issue view --repo "$REPO"`) owns the host-side repo scope
internally — the function no longer needs the split `REPO_OWNER`/`REPO_NAME` vars for
this read (mirrors `_fetch_sha_evidence`'s existing `chp_pr_view` call in the same
file). `itp_edit_comment`'s GitHub leaf still needs `REPO_OWNER`/`REPO_NAME` for its
own REST PATCH path — those are unrelated and unchanged.

## Shape-equivalent, not byte-identical (#332/#315/#333 precedent)

`gh api .../issues/{N}/comments --paginate` + a second `gh api
.../issues/comments/{id}` and `itp_list_comments` (→ `gh issue view --json
comments`) use a different transport but read the same logical issue comments. This
is the same class of equivalence #332/#315/#333 ratified in this repo, and the #321
verdict-choke-point migration is the worked example for the exact select rewrite
(author/time/marker predicates over normalized fields + the `sort_by(...) | last`
tie-break).

## Behavior preservation

The three outcomes `_stamp_browser_evidence_marker` produces are unchanged:

| Scenario | Before | After |
|---|---|---|
| A matching report comment exists, not yet stamped | PATCH (or re-post on `edit_comment=0`) | same |
| A matching report comment exists, already stamped | idempotent no-op, return 0 | same |
| No matching report comment | return 1 (gate fails closed) | same |

A wrong selection at worst fails the gate closed (never fabricates a marker) — the
downstream `_fetch_sha_evidence` dual-signal gate remains the authoritative evidence
check. Revert is a function-body swap.

## Risk

Minimal. Two-read → one-call transport swap inside a single function, in a
HOT-adjacent lib (sourced by the live review wrapper) — dev in a worktree only, no
new entry-point script. Covered by golden-equivalent unit tests (tie-break, boundary,
author-predicate parity, fail-closed, idempotent-skip) + source-shape + cutover-guard
+ full-suite tests.

## Pipeline docs (same PR — Pipeline Documentation Authority)

- `docs/pipeline/invariants.md` — INV-46 entry updated to describe the `itp_list_comments`
  routing (retiring the "GET-comment-id / GET-body reads stay caller-side" carve-out
  text) plus an [INV-90] cross-reference for the normalized-shape reuse.
- `docs/pipeline/provider-spec.md` — the `itp_edit_comment` mapping row's caller-side
  note updated, and a new mapping row added naming `lib-review-e2e.sh:492`/`:504` as
  **migrated #345** behind `itp_list_comments`.
- `docs/pipeline/review-agent-flow.md` — the browser-mode E2E lane bullet's stamp
  paragraph updated to describe the `itp_list_comments` routing instead of "STAY raw."
- `tests/unit/test-broker-dedup-read-migration.sh` (#333) — its TC-333-SRC-04/05b
  negative-scope assertions ("the :486/:498 INV-46 reads STILL present + raw") are
  inverted to assert they are now GONE (the #345 migration this file previously
  excluded is now the expected state).

## Out of scope

- `itp_read_comment` (the new-verb fallback the issue's Design Considerations
  section named) — not needed; the shipped `itp_list_comments` shape suffices.
- The remaining deferred reads elsewhere (lib-review-poll single-comment read,
  dispatcher-tick timeline read) — unrelated call sites.
- Any GitLab/Asana leaf implementation.
- Changing INV-46 semantics or the stamp format.
