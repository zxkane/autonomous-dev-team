# Design — `chp_commit_file` whole-op verb for `upload-screenshot.sh` (#330)

> #296 second-tier. Mint a new CHP write verb `chp_commit_file` and migrate the 8
> raw `gh api` git-Data-API calls in `upload-screenshot.sh` behind it as ONE
> whole-op verb. Removes 8 occurrences across 7 baseline signatures (the get-ref
> signature appears twice) from `cutover-baseline.json`. INV-95.

## Problem

`upload-screenshot.sh` performs ONE code-host op — commit a single PNG onto an
orphan `screenshots` branch and return a viewable `/blob/` URL — via 8 low-level
GitHub git-Data-API calls (get-ref → create-blob → create-tree → create-commit →
create-ref → re-get-ref verify → get-contents → put-contents). These are pure
GitHub *implementation* of one high-level op; a GitLab backend collapses the whole
thing into a single Files API call (`POST /projects/:id/repository/files/:path`).

So they collapse into **one whole-op verb** (the leaf ≈ the cohesive op; the
surrounding control flow stays caller-side — the `chp_review_threads`-wraps-a-
whole-GraphQL-walk posture), NOT 8 thin per-call shims.

## Architecture decision: whole-op verb (not 8 shims)

```
caller (upload-screenshot.sh, provider-neutral)        leaf (providers/chp-github.sh)
────────────────────────────────────────────────      ───────────────────────────────
 arg validation (PNG path, PR#, TC-ID, GH_TOKEN)
 command -v gh / jq presence guards (residue)
 FILE_PATH = pr-N/TC.png      (caller-rendered)
 CONTENT_BASE64 = base64 -w0  (provider-neutral
                               currency)
 chp_commit_file REPO BRANCH \                  ──────▶ chp_github_commit_file:
   FILE_PATH CONTENT_BASE64 MESSAGE                       get-ref → (absent? blob→tree→
   │                                                       commit→ref→re-get-ref verify)
   │                                                       → get-contents → put-contents
   │                                                       echo committed SHA on success
   ▼                                                       non-zero on commit failure
 [[ -n "$SHA" ]] || fail   →  chp_commit_file … || fail
 echo "https://github.com/REPO/blob/BRANCH/FILE_PATH"
```

### What moves into the leaf (the whole git-Data-API op, lines 76-134 verbatim)
- the get-ref → … → put-contents sequence including the orphan-branch
  create-vs-update branching;
- the `.ref // empty` / `.sha // empty` provider-shape jq extractions
  (leaf-internal, constant jq — NOT a provider-neutral shape);
- the `?ref=${BRANCH}` query;
- the temp-file JSON build for the ARG_MAX limit (base64 can exceed 128 KB);
- the `2>/dev/null || true` best-effort glue.

### What stays caller-side (provider-neutral)
- the local file-read + `base64 -w0` encode (GitLab's Files API also takes
  `encoding=base64` — base64 is the provider-neutral currency);
- the `FILE_PATH` / `BRANCH` / `MESSAGE` rendering (caller params, not hardcoded
  in the leaf);
- the `[[ -n "$SHA" ]] || fail`-on-empty-SHA glue;
- the final `/blob/` URL echo + the `command -v gh`/`jq` presence guards.

## The seam shim (lib-code-host.sh) — self-guarding, like `chp_pr_view`/`chp_pr_list`

`upload-screenshot.sh` is a STANDALONE util: it exits non-zero on failure and does
NOT source the wrapper env. So the shim is **self-guarding** (the
`chp_pr_view`/`chp_pr_list` posture, NOT the lifecycle-verb `chp_has_leaf` posture):
leaf-absent → WARN + `return 1` (a clean non-zero the caller's `|| fail` degrades
on), bare `${CODE_HOST}` dispatch otherwise.

```bash
chp_commit_file() {
  if ! declare -F "chp_${CODE_HOST}_commit_file" >/dev/null 2>&1; then
    echo "WARN: [INV-95] CODE_HOST='${CODE_HOST}' provider defines no chp_${CODE_HOST}_commit_file leaf — file commit unavailable." >&2
    return 1
  fi
  chp_${CODE_HOST}_commit_file "$@"
}
```

## Lib resolution from the standalone util

`upload-screenshot.sh` REALLY lives at `skills/autonomous-review/scripts/`
(symlinked into the dispatcher tree at `skills/autonomous-dispatcher/scripts/` so
it carries `gh` and is scanned by the cutover guard). That dir has NO
`lib-code-host.sh` / `providers/`. So — exactly mirroring `mark-issue-checkbox.sh`'s
[INV-14]/[INV-65] skill-tree idiom — the util resolves the lib via `readlink -f` of
its OWN `BASH_SOURCE` then `../../autonomous-dispatcher/scripts/lib-code-host.sh`
(NOT `$_SCRIPT_DIR`, which is deliberately the project-side symlink dir so the
existing `autonomous.conf` lookup finds the project's conf). Guarded on the verb
being undefined; lib-absent → the verb stays undefined → the self-guarding shim is
also absent → `chp_commit_file` is `command not found` under `set -e` → the script
aborts loud (a raw `gh` fallback would silently run GitHub commands for a non-GitHub
backend — never silently fall through; [INV-91]).

`lib-code-host.sh` sources `providers/chp-github.sh` from its OWN skill-tree
`readlink -f` dir, so the leaf is reachable once the lib is sourced regardless of
the project-side symlink topology — no project-side symlink, no installer re-run
(Step-1 `npx skills update -g` suffices).

## The load-bearing fix — a SELF-DISARMING `trap … RETURN` (P3/AC2, reproduced on-box)

The script's line-116 `trap 'rm -f "$JSON_TMPFILE" "$UPLOAD_RESPONSE_FILE"' EXIT`
MUST NOT move verbatim into the sourced leaf. A sourced function's `trap … EXIT`
**replaces the caller's EXIT trap**, and `$JSON_TMPFILE`/`$UPLOAD_RESPONSE_FILE`
(now leaf-locals) expand empty when the inherited trap fires at *caller* exit
(reproduced on-box: caller trap clobbered + `unbound variable` crash).

Issue #330 AC2 requires a **function-scoped `trap … RETURN`**. A BARE
`trap '…' RETURN` (no self-disarm) was found on-box to crash too: a RETURN trap is
NOT cleared when the leaf returns, so it **persists on the trap table and fires
AGAIN** when the `chp_commit_file` shim itself returns into the caller. By then
the leaf's `local` `$json_tmpfile`/`$upload_response_file` are out of scope, so
the trap body expands them empty → `unbound variable` under the caller's `set -u`
(reproduced on-box via the shim-dispatch path: `leaf(){ local t=$(mktemp); trap
'rm -f "$t"' RETURN; }; shim(){ leaf; }; shim` crashes on the shim's return).

Fix: keep the RETURN trap (satisfying AC2's literal contract) but make it
**self-disarming** — its own last action clears itself:
`trap 'rm -f "$json_tmpfile" "$upload_response_file"; trap - RETURN' RETURN`.
The trap fires exactly once per invocation (cleaning the temps, then
immediately un-installing itself before the RETURN completes), so it never
lingers to fire a second time when the caller/shim frame returns. Verified
on-box across: normal completion, both early `return 1` paths, repeated
shim-mediated calls (two invocations in the same process), and with the
caller's own `trap … EXIT` installed alongside — the caller's EXIT trap fires
normally afterward, untouched.

## REPO threaded explicitly ($1, not a global) — the #324 lesson

`upload-screenshot.sh` resolves its own `$REPO` from `autonomous.conf` and never
sources the wrapper env. The leaf must take REPO as `$1` (not read a global
`$REPO`) so a different ambient `$REPO` can NOT silently win (the #324
dropped-repo-arg lesson). `CONTENT_BASE64` stays caller-encoded.

## No jq injection

The `.sha // empty` / `.ref // empty` are leaf-internal **constant** jq filters.
`$REPO`/`$BRANCH`/`$FILE_PATH`/`$MESSAGE`/`$CONTENT_BASE64` go into REST paths,
`?ref=` query, or the temp-file JSON payload via `printf` — never into a jq pattern.

## Verb signature

```
chp_commit_file REPO BRANCH FILE_PATH CONTENT_BASE64 MESSAGE
chp_github_commit_file REPO BRANCH FILE_PATH CONTENT_BASE64 MESSAGE
```
- echoes the committed blob SHA on success;
- returns non-zero on commit failure (so the caller's empty-SHA `fail` becomes
  `chp_commit_file … || fail`).

## Baseline shrink

Remove the 7 upload-screenshot.sh signatures (8 occurrences: the get-ref signature
has count 2) from `providers/cutover-baseline.json`. The `command -v gh` signature
STAYS (presence guard, not a call site — residue; the leaf is still `gh`-based, but
it lives in providers/ now and is excluded from the scan). Pin mechanically via
`--generate-baseline`.

## Docs (same PR)

- provider-spec.md §3.2 — new `chp_commit_file` row.
- provider-spec.md §7.2 — new migration row.
- invariants.md INV-95 + the `_Triage (issue #236): [machine-checked: …]_` marker
  (heading-adjacent, ≤2 lines) or TC-SPEC-GATE-040/041 go red.

## Out of scope
- chp_pr_comment, chp_list_inline_comments, chp_reply_review_comment,
  itp_transition variadic — separate #296 sub-issues.
- No new E2E (screenshot upload is exercised by the browser-E2E review lane); the
  whole-op golden unit is the behavior-equivalence evidence.
