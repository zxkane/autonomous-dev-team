# Test cases — #328 `chp_list_inline_comments` (the dev-resume PR-inline-comment read)

Test file: `tests/unit/test-chp-list-inline-comments.sh` (TC-CLIC-NNN).
Run under `env -u PROJECT_DIR` for CI parity.

## TC-CLIC-001 — Golden-trace: leaf emits byte-identical `gh api` argv

Source the REAL `lib-code-host.sh` (live `chp_list_inline_comments` shim +
`chp_github_list_inline_comments` leaf) with a recording `gh` stub that captures
argv NUL-delimited (boundaries preserved). Drive `chp_list_inline_comments "$PR" --jq
'<formatter>'`. **Expected**: the stub OBSERVES exactly
`gh api repos/$REPO/pulls/$PR/comments --jq <formatter>` — argc + each exact arg incl.
the verbatim `--jq` formatter as a SINGLE argv element (it carries spaces, a `|` pipe,
`**`, and `\(…)` interpolations).

## TC-CLIC-002 — Caller-formatter rendering is unchanged

Feed the leaf's stub a sample `pulls/N/comments` JSON payload through the **system jq**
with the caller's verbatim formatter; assert the rendering is the byte-identical
`- **path:line** — body` lines (and `.line // .original_line // "N/A"` fallback)
the pre-migration site produced.

## TC-CLIC-010 — Self-guarding shim: leaf-absent → WARN + return 1 (no abort)

Source `lib-code-host.sh` with `CODE_HOST` pointing at a backend whose provider file
omits the leaf (or unset the leaf), under `set -e`. Call `chp_list_inline_comments 5`.
**Expected**: prints a `WARN: [INV-95] …` line to stderr, returns 1, and does NOT abort
the surrounding `set -e` shell. The `$(… 2>/dev/null || true)` site degrades to an empty
`PR_REVIEW_COMMENTS`.

## TC-CLIC-011 — Non-github backend whose leaf is absent bare-guards (no abort)

With `CODE_HOST=fakehost` (a non-default backend selected through the public seam — no
`providers/chp-fakehost.sh` is sourced, so `chp_fakehost_list_inline_comments` is
absent), `chp_list_inline_comments 5` degrades via the bare `declare -F
chp_fakehost_list_inline_comments` miss (WARN naming that leaf + return 1), never a
`chp_fakehost_…` command-not-found abort under `set -e`. This proves the bare
`${CODE_HOST}` guard is IDENTICAL to the leaf dispatch (#323/#324 bare-guard lesson).

> NOTE: an EMPTY `CODE_HOST` is NOT a valid leaf-absent probe — `lib-code-host.sh`
> defaults `CODE_HOST="${CODE_HOST:-github}"` at source time, so `""` resolves to the
> `github` leaf (which exists) and dispatches normally. The leaf-absent probe must use
> a real non-default backend name (`fakehost`).

## TC-CLIC-020 — Source-shape: zero raw `gh api …pulls/…/comments` at `:1086`

`autonomous-dev.sh` has ZERO executable (non-comment) raw `gh api
"repos/${REPO}/pulls/${PR_NUM}/comments"` lines; the `chp_list_inline_comments
"$PR_NUM"` call is present at the migrated position. The DISTINCT `:1093`
`repos/$REPO/issues/$PR_NUM/comments` AUTO_MERGE-marker read this issue had scoped OUT
was migrated independently behind `itp_list_comments` by #334 (merged onto main before
this branch's rebase), so it too is now ABSENT as a raw-`gh` site — asserted absent +
its `AUTO_MERGE_FAILURE_MARKER=$(itp_list_comments "$PR_NUM"` replacement asserted
present, so this PR neither resurrects it nor over-reaches.

## TC-CLIC-021 — Verb defined in the seam

`lib-code-host.sh` defines the `chp_list_inline_comments` shim; `providers/chp-github.sh`
defines the `chp_github_list_inline_comments` leaf.

## TC-CLIC-030 — Baseline shrank by exactly 1, mechanically

`providers/cutover-baseline.json` no longer carries the
`PR_REVIEW_COMMENTS=$(gh api "repos/${REPO}/pulls/${PR_NUM}/comments" \` survivor. (The
distinct `issues/${PR_NUM}/comments` AUTO_MERGE survivor was independently dropped by
#334, so it too is now absent.) The baseline matches
`check-provider-cutover.sh --generate-baseline` output (the guard's Check 1 reconciles).

## TC-CLIC-040 — INV-91 Migration-log bullet present

`docs/pipeline/invariants.md` carries the exact `#296 second-tier (#328): …` bullet
in the INV-91 Migration-log (also pinned in test-spec-drift.sh as TC-SPEC-GATE-328).

## Gates exercised by existing suites

- `tests/unit/test-provider-cutover.sh` (drives `check-provider-cutover.sh`) — the
  shrunk baseline reconciles tree-wide; monotonicity (Check 4) allows the shrink.
- `tests/unit/test-spec-drift.sh` TC-SPEC-GATE-040/041 — the INV-95 heading carries a
  valid heading-adjacent triage tag.
