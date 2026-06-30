# Design — #296 second-tier: mint `chp_list_inline_comments` for the dev-resume PR-inline-comment read

Issue: #328 · Part of #296 (pluggable-providers raw-`gh` migration). Picks up the
site #319 explicitly deferred ("the `gh api` PR-number REST reads are deferred —
different shape, issue-only verb does not forward `-q`").

## Goal

Mint a NEW CHP read verb `chp_list_inline_comments PR [extra gh args…]` and migrate
the single surviving raw PR **inline (file-anchored) review-comment** read at
`autonomous-dev.sh:1086` behind it, shrinking the `[INV-91]` cutover baseline by
exactly **1**. **Zero behavior change** — the verb forwards the exact same `gh api`
argv the site emits today; the `--jq` formatter STAYS caller-side (#281
jq-stays-caller — it is a prompt-rendering decision).

## The one site (verified against merged main `fb01be0`)

`autonomous-dev.sh` dev-resume prompt builder (`do_resume`):

Before:
```bash
PR_REVIEW_COMMENTS=$(gh api "repos/${REPO}/pulls/${PR_NUM}/comments" \
  --jq '[.[] | "- **\(.path):\(.line // .original_line // "N/A")** — \(.body)"] | join("\n")' 2>/dev/null || true)
```

After:
```bash
PR_REVIEW_COMMENTS=$(chp_list_inline_comments "$PR_NUM" \
  --jq '[.[] | "- **\(.path):\(.line // .original_line // "N/A")** — \(.body)"] | join("\n")' 2>/dev/null || true)
```

## Why a NEW verb, not reuse

The flat REST `pulls/N/comments` inline-comment shape (`.path`/`.line`/
`.original_line`) is **distinct** from every existing read verb:

| Existing verb | Shape | Why it does not fit |
|---|---|---|
| `chp_review_threads` | GraphQL thread tree `{thread_id, resolved, comments:[…]}` | richer thread-resolution shape; the caller here wants the flat REST list it formats inline |
| `chp_pr_view` | `gh pr view --json` projection | no `pulls/N/comments` sub-resource exposed |
| `itp_list_comments` | issue-level normalized `[{id,author,body,createdAt}]` | issue-level; the inline `.path`/`.line` fields are CHP-owned, never folded into the ITP shape |

provider-spec.md §3.2 already states the inline fields (`.path`/`.line`/
`.original_line`, `autonomous-dev.sh`) are **CHP-owned, never folded into the ITP
issue-comment shape** — this is exactly that read.

## Byte-identity premise

- Leaf: `chp_github_list_inline_comments() { local pr="$1"; shift; gh api "repos/${REPO}/pulls/${pr}/comments" "$@"; }`
  (mirrors `chp_github_pr_view PR [extra…]`).
- The site already interpolates the GLOBAL `$REPO` into the REST path and passes
  `$PR_NUM` as the PR number; the verb re-supplies `$REPO` from the same global, so
  the emitted `gh api repos/$REPO/pulls/$PR/comments <passthrough --jq>` argv is
  byte-identical. The caller threads its own `--jq` formatter via `"$@"`.

## Self-guarding shim (the #282 convention)

This site is invoked **UNGUARDED** in a `$(… 2>/dev/null || true)` context, so the
shim self-guards exactly like `chp_pr_view` / `chp_pr_list` (#282 review round 9):
leaf-absent → WARN + `return 1` (a clean non-zero the `|| true` site degrades to an
empty `PR_REVIEW_COMMENTS` on), NOT dispatch-to-undefined-leaf-and-abort under
`set -e`.

```bash
chp_list_inline_comments() {
  if ! declare -F "chp_${CODE_HOST}_list_inline_comments" >/dev/null 2>&1; then
    echo "WARN: [INV-95] CODE_HOST='${CODE_HOST}' provider defines no chp_${CODE_HOST}_list_inline_comments leaf — PR inline-comment read unavailable." >&2
    return 1
  fi
  chp_${CODE_HOST}_list_inline_comments "$@"
}
```

The `declare -F` uses the **bare** `${CODE_HOST}` expansion (identical to the leaf
dispatch; safe under `set -u` because `CODE_HOST` is defaulted at source time) — the
#323/#324 bare-guard lesson (a `:-github` guard would diverge from the bare shim when
`CODE_HOST` is empty).

## No injection / no pagination today

- The `--jq` formatter is a **constant literal** supplied by the caller; `$REPO`/`$PR`
  go into the REST **path**, not a jq pattern. No `@json` pre-encode needed.
- No `--paginate` today — kept byte-identical (a page-walk is a separate change).
- **Leaf returns raw** (focused-raw, #281): the caller threads its own `--jq`
  formatter via `"$@"`; the leaf does no formatting.

## INV / spec / baseline

- New `INV-95` (next free; #323/#324 hold 93/94 — #323 merged as INV-93, #324 in
  flight as INV-94, so INV-95 is the safe claim). Heading carries the
  `_Triage (issue #236): [machine-checked: tests/unit/test-chp-list-inline-comments.sh]_`
  marker within 2 lines (TC-SPEC-GATE-040/041).
- provider-spec.md §3.2 gains a `chp_list_inline_comments` row + the §3.2 status note
  / mapping appendix updated; the Migration-log bullet in invariants.md §INV-91 gains
  a `#296 second-tier (#328)` entry.
- `providers/cutover-baseline.json` shrinks by the one migrated entry (mechanically
  regenerated via `--generate-baseline`).

## Out of scope

- `autonomous-dev.sh:1093` (the `repos/$REPO/issues/$PR_NUM/comments` AUTO_MERGE-marker
  read) — a DISTINCT issue-level shape, migratable behind the SHIPPED
  `itp_list_comments`. (This was a separate follow-up at filing time; it landed
  independently as #334, merged onto main before this branch's rebase — so by the time
  this PR merges that read is already migrated, not a survivor.)
- chp_pr_comment, chp_reply_review_comment, chp_commit_file, itp_transition variadic.
