# Design — `chp_reply_review_comment` (issue #327, #296 second-tier)

## Problem

`reply-to-comments.sh:41` (an autonomous-common util) is the **last** raw
`gh api … pulls/<n>/comments -X POST … in_reply_to=…` site in the dispatcher
scripts tree — a CHP review-thread reply leaf the provider-spec already
pre-classifies as "owned by chp-pr-lifecycle, NOT migrated in #283"
(`provider-spec.md` §3.2 deferred-sites table, the `reply-to-comments.sh:44-45`
row). This issue is that follow-up: mint the CHP verb and migrate the site so the
caller layer carries zero executable raw `gh` for the review-reply POST.

## Approach (byte-identical leaf, self-source the seam)

1. **Shim** `chp_reply_review_comment() { chp_${CODE_HOST}_reply_review_comment "$@"; }`
   in `lib-code-host.sh`, placed with the lifecycle shims (after
   `chp_close_keyword`). Mirrors the existing 11 named verb shims byte-for-byte —
   the `lib-agent.sh:597 adapter_invoke_"$AGENT_CMD" … "$@"` shape.

2. **GitHub leaf** `chp_github_reply_review_comment PR COMMENT_ID BODY` in
   `providers/chp-github.sh`, emitting the **byte-identical** argv:
   ```bash
   gh api "repos/${REPO}/pulls/${pr}/comments" \
     -X POST -f body="$body" -F in_reply_to="$comment_id" \
     --jq '{id: .id, url: .html_url}'
   ```
   The leaf uses the global `$REPO` (the `owner/repo` slug) like every CHP leaf.

3. **Migrate** `reply-to-comments.sh:41` to call the verb. The util is invoked
   **standalone** (`bash scripts/reply-to-comments.sh <owner> <repo> <pr>
   <comment_id> "<msg>"`) and sources NO lib today, so it **self-sources the seam**
   via `readlink -f` of its own `BASH_SOURCE` — the exact precedent of the sibling
   cross-skill util `mark-issue-checkbox.sh` (#315), which self-sources
   `lib-issue-provider.sh`. Guard on the verb being undefined; if the lib is absent
   the verb stays undefined and the POST **FAILs LOUD** ([INV-91]: a raw-`gh`
   fallback would silently execute GitHub).

4. **Repo threading** (#324 lesson): the leaf's endpoint path is
   `repos/$REPO/pulls/$PR/comments`. The caller composes `REPO="$OWNER/$REPO"` for
   the leaf's scope so the path is byte-identical to today's
   `repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments`. The owner/repo arg split + the
   `COMMENT_ID` `sed 's/[^0-9]//g'` sanitization stay **caller-side**.

## Why no caps key, no injection pre-encode

- **No `.caps` key**: the reply POST is a core code-host write (every code host
  with PR review comments has a reply endpoint); NOT capability-gated like
  `rest_request_changes` / `review_bots`. Adding a cap would be untested under the
  #286 caps tripwire and imply an undefined degraded path.
- **No injection surface**: `body` is a REST `-f` field (form-encoded, not a jq
  pattern); `in_reply_to` is a REST `-F` field (caller-sanitized numeric); the
  `--jq '{id,url}'` is a fixed literal with zero `${var}` interpolation. No
  `jq -rn … @json` pre-encode needed (contrast the injection-prone sibling verbs
  `chp_count_reviews_by_login` / `itp_label_event_ts`).

## Cross-skill note

The verb seam lives in **autonomous-dispatcher**; the util in
**autonomous-common**. The `readlink -f` self-source is the [INV-14]/[INV-65]
skill-tree idiom (NOT `dirname "$0"`, which is the project-side symlink dir — the
conf-lookup deliberately uses `$0`/SCRIPT_DIR so it finds the project's
autonomous.conf, while `readlink -f "$BASH_SOURCE"` resolves the real skill tree).

## Cutover guard impact

`providers/cutover-baseline.json` shrinks by exactly the one migrated
`reply-to-comments.sh` entry (signatures 66 → 65, occurrences 72 → 71).
`check-provider-cutover.sh` ([INV-91]) enforces the shrink (monotonic, may only
shrink). The new leaf in `providers/chp-github.sh` is excluded from the scan
(under `providers/`), so it adds no baseline entry.

## New invariant

**INV-96.** Next-free survey at authoring: INV-93=#323 (on main), INV-94=#324
(reserved by open PR #326), **INV-95=#330** (reserved by open PR #335, also a
`#296` second-tier verb mint). To avoid a rebase collision with #335's INV-95,
this PR claims **INV-96** (the next free above both in-flight reservations) — per
the project INV-collision protocol (first-merged keeps its number; the other
renumbers in one commit on rebase). Re-check actual next-free on rebase. The
heading carries a `_Triage (issue #236): [machine-checked: <test>]_` marker (the
`#236` is a FIXED literal, not this issue's number — else TC-SPEC-GATE-040/041 go
CI-red).

## Rollback

Single-file caller revert + drop leaf/shim + restore the baseline entry. LOW
blast radius (agent-invoked reply util, not a gate).
