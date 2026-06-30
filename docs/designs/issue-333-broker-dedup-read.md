# Design — migrate the INV-79 E2E-broker dedup read behind `itp_list_comments` (#333)

> #296 second-tier batch. Migrates `lib-review-e2e.sh`'s `_post_brokered_e2e_report`
> dedup **window-count read** from a raw `gh api "repos/${REPO_OWNER}/${REPO_NAME}/issues/${PR_NUMBER}/comments"`
> call to the **SHIPPED** `itp_list_comments` verb — NO new verb, NO new INV
> (shape-equivalent, the same class as #332 / #315). Shrinks
> `scripts/providers/cutover-baseline.json` by exactly 1 (64 → 63 at time of writing;
> the absolute count drifts as sibling #296 PRs land — the load-bearing claim is the
> exactly-one shrink, mechanically pinned by the cutover guard).

## Problem

`_post_brokered_e2e_report` (lib-review-e2e.sh, the [INV-79] report broker) posts the
browser-E2E `## E2E Verification Report` comment on the PR on behalf of the agent (the
agent writes it to `E2E_REPORT_FILE`; the wrapper's full-write token posts it). Before
posting it **dedups**: it counts the `## E2E Verification Report` comments already in
the review window (bounded by `WRAPPER_START_TS`) so it does not double-post when the
agent's direct-write fallback already landed one.

Today that count read is a raw `gh api` call sitting in the provider-neutral caller
layer — a survivor in `lib-review-e2e.sh`'s [INV-91] cutover baseline:

```bash
# lib-review-e2e.sh today (the survivor, ~:571):
_existing=$(gh api "repos/${REPO_OWNER}/${REPO_NAME}/issues/${PR_NUMBER}/comments" --paginate \
  --jq "[.[] | select((.created_at >= \"${WRAPPER_START_TS}\") and (.body | contains(\"## E2E Verification Report\")))] | length" \
  2>/dev/null | tail -n1 || true)
```

`#296` routes raw-`gh` caller sites behind provider verbs. This is an **issue-level
comment LIST read** — exactly what the SHIPPED `itp_list_comments ISSUE` covers (spec
§3.1: "every issue-level comments site"; the 28-scanner #281 cutover + the #332
auto-merge read are the same pattern). It needs **no new verb**.

### Why this was initially missed (and why it IS migratable)

An earlier completeness pass wrongly bundled `:571` with the INV-46 GET-comment-id
(`:486`) / GET-body (`:498`) reads as "documented stay-caller-side." The INV-46
carve-out (`provider-spec.md:821` + `invariants.md:1575`, "GET-comment-id / GET-body
reads stay caller-side") is scoped ONLY to those two reads, which live in a **different
function** — `_stamp_browser_evidence_marker` (`:468-539`). `:571` is in
`_post_brokered_e2e_report` (`:556+`), is a *count* read (not a GET-id/GET-body), and
is **named nowhere** in the pipeline docs as stay-caller-side. Being frozen in the
cutover baseline is migration backlog, not a stay-caller decision. (Verified on-box:
function boundaries + `grep` of provider-spec.md / invariants.md for the broker read
returns nothing.)

## Solution

Route the read through the shipped `itp_list_comments` verb and keep the `select`
caller-side over the verb's normalized array:

```bash
_existing=$(itp_list_comments "$PR_NUMBER" 2>/dev/null \
  | jq -r "[.[] | select((.createdAt >= \"${WRAPPER_START_TS}\") and (.body | contains(\"## E2E Verification Report\")))] | length" \
  2>/dev/null | tail -n1 || true)
```

- A PR **is** an issue on GitHub, so PR issue-level comments resolve via
  `itp_list_comments "$PR_NUMBER"` (which runs `gh issue view "$PR_NUMBER" --repo
  "$REPO" --json comments`). The same `$REPO` the function already uses at its
  `gh pr comment … --repo "$REPO"` post site is in scope; the raw read's
  `REPO_OWNER`/`REPO_NAME` REST-path vars are no longer needed here.
- The `select` moves to a SEPARATE system-`jq` over the verb's normalized
  `[{id, author, authorKind, body, createdAt}]` array (spec §3.3 / [INV-90]): the
  raw-`gh` `.[]` iterates the REST array; the verb's array is already flat, so `.[]`
  iterates it identically. `.body` is **verbatim** (the verb copies it byte-for-byte).
  `id`/`author`/`authorKind` are unused here.

### Two intentional shape rewrites

1. **`.created_at` → `.createdAt`** — the normalized field name. The verb copies gh's
   ISO-8601 UTC `createdAt` string verbatim into a field literally named `createdAt`
   (the REST endpoint named the same value `created_at`). The window filter is a
   *string* `>=` compare, so it is correct **only** if the normalized `.createdAt`
   shares the IDENTICAL lexical format as `WRAPPER_START_TS`. It does:
   `WRAPPER_START_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")` (autonomous-review.sh:958) and
   gh's `createdAt` are both `YYYY-MM-DDTHH:MM:SSZ` (Z suffix, second precision, `T`
   separator). A dedicated golden (TC-BRK-TS-001) pins this lexical-format equivalence
   using the **real `gh issue view` createdAt format** so an in-window vs out-of-window
   boundary comment classifies identically under `.createdAt` as under the raw
   `.created_at`.

2. **`--jq` → system `jq -r`** — the raw call applied the select inside `gh`'s
   embedded Go RE2 `jq`; the migration runs the verb (one `gh issue view --json
   comments`, gh applies only the verb's *normalization* `-q`) and pipes its array to a
   separate **system** `jq -r`. Because the broker select uses only `contains()`
   (literal substring) and `>=` (string compare) — **NO `test()`, no `\b`/`\s`/`(?i)`
   regex** — there is **NO RE2 ↔ Oniguruma divergence** (the #319/#321 engine-boundary
   lesson). The count is byte-identical across engines.

### KEEP `| tail -n1` (do NOT drop it) — folded P2 review finding

The issue's original body proposed dropping `| tail -n1` "for clarity" (a no-op under
the single-array `itp_list_comments`). The folded panel + EM review **reversed** that:
**keep it.** It is a zero-cost safety net — if the verb seam ever re-paginates a
>100-comment connection into multi-line output (a future ITP provider, or a `gh issue
view` that concatenates per-page JSON), a bare `jq … | length` with no `tail -n1` would
feed a multi-line value into the `[[ … =~ ^[0-9]+$ ]]` numeric guard → fail-closed →
silently defeat dedup → double-post. Today the verb runs ONE `gh issue view` and the
system-`jq | length` produces a SINGLE line, so `tail -n1` is a harmless no-op;
tomorrow it is defensive. Net behavior today: unchanged.

### Shape-equivalent, not byte-identical (#332 / #315 precedent)

`gh api .../issues/N/comments --paginate` and `itp_list_comments` (→ `gh issue view
--json comments`) use a **different transport** but read the **same logical issue
comments**. This is the same shape-equivalence #332 (auto-merge marker) and #315
(`gh api` → `gh issue view`) ratified. The normalized `id`/`author`/`authorKind` are
unused here.

## NOT covered by the INV-46 carve-out (out of scope)

`:486` (GET-comment-id) and `:498` (GET-body-by-id) — the INV-46 reads documented to
STAY caller-side (`provider-spec.md:821` + `invariants.md:1575`) — live in the
**separate** `_stamp_browser_evidence_marker` function and STAY raw. `:498` is
additionally id-keyed (`issues/comments/<id>`) with no issue-keyed `itp_list_comments`
equivalent. The source-shape test asserts they remain present and raw (TC-BRK-SRC-004).

## Behavior preservation (INV-79 broker dedup)

The migration is a **transport swap on a best-effort dedup count**. The three broker
outcomes are unchanged:

| Window state | count | broker action |
|---|---|---|
| an in-window `## E2E Verification Report` comment exists | ≥ 1 | **SKIP** the brokered post (dedup) |
| only a before-window report, OR none | 0 | proceed to post |
| in-window comment NOT containing the marker | 0 | proceed to post |
| `itp_list_comments` empty/error (non-zero exit, empty stdout) | non-numeric / empty | numeric guard fails → proceed (best-effort) |

A wrong count at worst double-posts or skips one broker report; the agent's direct-write
fallback + the SHA-marker gate ([INV-46]) remain the authoritative evidence check.
Revert is one line.

## Risk

Minimal. Single-line transport swap on a non-gate, best-effort dedup count, in a
HOT-adjacent lib (sourced by the live review wrapper) — dev in a worktree only, NO new
entry-point script. Engine-agnostic (literal `contains`/`>=`). Covered by golden +
parity + source-shape + broker-behavior + full-suite tests.
