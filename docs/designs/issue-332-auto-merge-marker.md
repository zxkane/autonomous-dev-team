# Design — migrate the auto-merge-marker read behind `itp_list_comments` (#332)

> #296 second-tier batch. Migrates `autonomous-dev.sh`'s `AUTO_MERGE_FAILURE_MARKER`
> read from a raw `gh api "repos/${REPO}/issues/${PR_NUM}/comments"` call to the
> **SHIPPED** `itp_list_comments` verb — NO new verb (shape-equivalent, the #315
> precedent). Shrinks `scripts/providers/cutover-baseline.json` by exactly 1.

## Problem

`autonomous-dev.sh`'s `Mode = resume` branch reads the PR's issue-level comments to
detect the review wrapper's auto-merge-failure marker (the comment whose body starts
with `Auto-merge failed:` that the review wrapper posts when `gh pr merge` fails,
#145 / [INV-33]). When present, the resume prompt prepends a `## Pre-implementation:
rebase onto main — MANDATORY FIRST STEP` block so the dev agent rebases before
re-attempting work.

Today that read is a raw `gh api` call sitting in the provider-neutral caller layer
— a survivor in `autonomous-dev.sh`'s [INV-91] cutover baseline:

```bash
# autonomous-dev.sh today (the survivor):
AUTO_MERGE_FAILURE_MARKER=$(gh api "repos/${REPO}/issues/${PR_NUM}/comments" \
  --jq '[.[] | select(.body | startswith("Auto-merge failed:"))] | last // empty | .body' 2>/dev/null || true)
```

`#296` routes raw-`gh` caller sites behind provider verbs. This is an **issue-level
comment read** — exactly what the SHIPPED `itp_list_comments ISSUE` covers (spec
§3.1: "every issue-level `gh issue view --json comments` site"). It needs **no new
verb**. (#319 deferred it as "different shape, issue-only verb does not forward
`-q`"; this issue resolves it by moving the `select` to a separate caller-side `jq`
over the normalized array — the canonical #281 / #319 form.)

## Solution

Route the read through the shipped `itp_list_comments` verb and keep the `select`
caller-side over the verb's normalized array:

```bash
AUTO_MERGE_FAILURE_MARKER=$(itp_list_comments "$PR_NUM" 2>/dev/null \
  | jq -r '[.[] | select(.body | startswith("Auto-merge failed:"))] | last // empty | .body' 2>/dev/null || true)
```

- A PR **is** an issue on GitHub, so PR issue-level comments resolve via
  `itp_list_comments "$PR_NUM"` (which runs `gh issue view "$PR_NUM" --repo "$REPO"
  --json comments`).
- The `select` moves to a SEPARATE system-`jq` over the verb's normalized
  `[{id, author, authorKind, body, createdAt}]` array (spec §3.3 / [INV-90]):
  the raw-`gh` `.[]` iterates the REST array; the verb's array is already flat, so
  `.[]` iterates it identically. `.body` is **verbatim** (the verb copies it
  byte-for-byte). `id`/`author`/`authorKind`/`createdAt` are unused here.
- `last // empty` newest-wins is **preserved** by the verb's normative ascending
  `sort_by(.createdAt)` ([INV-90] MUST): `last` over an ascending array picks the
  newest matching comment, exactly as the raw `gh api` array (REST returns
  ascending-by-creation) gave.

### Shape-equivalent, not byte-identical (#315 precedent)

`gh api .../issues/N/comments` and `itp_list_comments` (→ `gh issue view --json
comments`) use a **different transport** but read the **same logical issue
comments**. This is the same shape-equivalence the #315 `gh api` → `gh issue view`
migration relied on for `mark-issue-checkbox.sh`'s body read. The `.body` field is
preserved verbatim across both; the unused metadata fields differ in encoding but
are never read by this selector.

### No engine divergence (the #319 / #321 lesson)

The selector uses `startswith()` (literal prefix) + `last` + `.body` — **NO**
`test()` / regex, **NO** `\b` / `\s` / `(?i)`. The only RE2 → Oniguruma divergence
class is regex case-fold / boundary behavior, which is **absent here**. `startswith`
is engine-agnostic: it is a literal prefix test in both gh's Go-RE2 jq and the
system jq's Oniguruma. So moving the selector from gh's jq to the system jq is a
behavior-preserving transport swap with no fixture-class to guard beyond
"the selector is `startswith`, not `test`."

The startswith anchor is also the false-positive guard the original comment cites:
a dev status comment that *quotes* the marker as history (e.g. `> Auto-merge
failed: …`) does **not** start with `Auto-merge failed:`, so it is correctly NOT
matched.

## Scope

- **In scope**: the single `:1093` `AUTO_MERGE_FAILURE_MARKER` read; the matching
  `cutover-baseline.json` entry (baseline −1); the `dev-agent-flow.md` step-3
  migration-log update.
- **Out of scope**:
  - `autonomous-dev.sh`'s `:1086` PR inline `/pulls/N/comments` read →
    `chp_list_inline_comments` (a separate CHP shape, separate issue #328).
  - The `lib-review-e2e.sh` [INV-46] GET-comment-id / GET-body reads stay
    caller-side (documented residue per provider-spec.md:821 + invariants.md
    [INV-46] / [INV-89]).

## No new verb, no new INV

This reuses the shipped `itp_list_comments` and extends the #281 issue-level
comment-scanner pattern. No `lib-*.sh` change, no provider impl change, no new
`INV-NN`. The migration log lives in `docs/pipeline/dev-agent-flow.md` step 3
(`Mode = resume`).

## Risk / rollback

Tiny / low-risk: a single observe-only read feeding a resume-prompt block. Revert =
one-line caller revert + restore the one `cutover-baseline.json` entry +
revert the `dev-agent-flow.md` step-3 wording.

`autonomous-dev.sh` is a HOT live-wrapper file — developed in a worktree only; the
dispatcher serializes same-file batches. NO new entry-point script → no
`install-project-hooks.sh` re-run; Step-1 `npx skills update -g autonomous-dispatcher`
suffices on the dev box.
