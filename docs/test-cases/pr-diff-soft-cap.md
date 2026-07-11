# PR-diff-size (over-reach) soft-cap signal — test cases

Test-case IDs: `TC-OVERREACH-NNN`. Issue #452 — a cheap, deterministic
pre-review check that flags when a PR's diff is large relative to its issue
scope, and injects an over-reach advisory note into the review prompt. Soft
signal only — never a gate (see `invariants.md` new `INV-124`).

## Scope

- `PR_DIFF_SOFT_CAP_FILES` / `PR_DIFF_SOFT_CAP_LINES` config keys
  (`lib-review-diffcap.sh::_diff_cap_normalize`).
- The provider-seam diff-stat read (`chp_pr_diffstat`, GitHub +
  GitLab leaves).
- The OR-across-dimensions over-reach comparison
  (`lib-review-diffcap.sh::review_diff_over_reach`).
- The prompt-injection helper (`lib-review-diffcap.sh::review_diff_soft_cap_prompt_note`).
- The `pr_diff_soft_cap` metrics event (once per enabled review round).
- Non-interference with verdict aggregation / PASS / auto-merge.

## Unit test cases

### TC-OVERREACH-001 — both caps unset ⇒ feature fully disabled
`_diff_cap_normalize` on an unset/empty `PR_DIFF_SOFT_CAP_FILES` and
`PR_DIFF_SOFT_CAP_LINES` both yield empty. `review_diff_soft_cap_dimensions_needed`
with both empty returns empty (no dimension needed) — so the wrapper never calls
`chp_pr_diffstat` at all. `build_review_prompt()` output is byte-identical to
pre-change for identical inputs. No `pr_diff_soft_cap` metrics event fires.

### TC-OVERREACH-002 — invalid cap values treated as unset
`0`, `-5`, `abc`, ` ` (whitespace) each normalize to empty via
`_diff_cap_normalize`, per-key independently. No crash, no warning printed.

### TC-OVERREACH-003 — FILES cap set and exceeded (GitHub)
`changed_files=45`, `files_cap=40`, `lines_cap` unset ⇒
`review_diff_over_reach` returns `true`. The prompt note names the files stat
(45 > 40) and is explicit that this is advisory, not a verdict.

### TC-OVERREACH-004 — LINES cap set and exceeded (GitHub)
`changed_lines=3500`, `lines_cap=3000`, `files_cap` unset ⇒ over_reach `true`.
Note names the lines stat.

### TC-OVERREACH-005 — boundary: stats exactly at the cap ⇒ NOT triggered
`changed_files=40`, `files_cap=40` (equal, not greater) ⇒ over_reach `false`
(strict `>`, never `>=`). Same check for lines.

### TC-OVERREACH-006 — diff-stat read failure ⇒ over_reach=false, no note, no wrapper error
Missing/empty `changed_files` and `changed_lines` (as if the provider-seam read
failed) ⇒ `review_diff_over_reach` returns `false` for that dimension — never
fabricates `true` from an unreadable stat. `review_diff_soft_cap_prompt_note`
emits empty string when over_reach is false.

### TC-OVERREACH-007 — GitHub `chp_github_pr_diffstat` single-call contract
Stub `gh pr view --json additions,deletions,changedFiles` once; assert the leaf
issues exactly one `gh` call regardless of which dimension(s) are requested
(`files`, `lines`, or `files,lines`), and projects only the requested
dimension(s) into `{changed_files, changed_lines}`.

### TC-OVERREACH-008 — GitLab FILES-only via `changes_count` — no GraphQL call
`chp_gitlab_pr_diffstat <pr> files` reads the base MR view only (`_gl_api`),
parses `.changes_count`. No GraphQL call is issued (asserted via call-count on
the `_gl_graphql` stub). Includes the `"1000+"` capped-string case, parsed down
to the integer `1000`.

### TC-OVERREACH-009 — GitLab LINES via GraphQL `diffStatsSummary` — exactly one GraphQL call
`chp_gitlab_pr_diffstat <pr> lines` issues exactly one `_gl_graphql` call
(asserted via call-count) and sums `additions + deletions` from
`diffStatsSummary` into `changed_lines`. The base MR view is NOT additionally
required to compute this dimension (LINES-only request does not need the
`changes_count` field).

### TC-OVERREACH-010 — GitLab both dimensions ⇒ base MR view + exactly one GraphQL call
`chp_gitlab_pr_diffstat <pr> files,lines` issues the base MR view (for
`changes_count`) AND exactly one GraphQL call (for `diffStatsSummary`) — never
more than one GraphQL call regardless of how many times the caller asks.

### TC-OVERREACH-011 — GitLab LINES cap unset ⇒ no GraphQL call issued at all
The wrapper-level dimension-selection helper
(`review_diff_soft_cap_dimensions_needed`) with only `files_cap` set never
includes `lines` in the requested dimension set, so `chp_pr_diffstat` is never
invoked with `lines` and the GraphQL leaf path is never reached — pay only if
configured.

### TC-OVERREACH-012 — GitLab GraphQL failure ⇒ FILES dimension unaffected
`_gl_graphql` stub forced to fail (auth/network/schema error) while the base MR
view read succeeds: `chp_gitlab_pr_diffstat <pr> files,lines` returns
`{"changed_files": N}` (FILES key present, LINES key omitted) at rc 0 — the
GraphQL failure never suppresses a FILES result already read successfully.
The caller's `review_diff_over_reach` then evaluates LINES as unreadable
(false for that dimension only) while FILES still evaluates normally.

### TC-OVERREACH-013 — threshold-comparison OR logic across both dimensions
Every combination of {files exceeded, lines exceeded, neither, both} against
independent caps confirms `review_diff_over_reach` is a strict OR: either
dimension alone triggers `true`; neither triggers `false`.

### TC-OVERREACH-014 — `pr_diff_soft_cap` metrics event fires exactly once per enabled review round
Sourcing `lib-metrics.sh` + `lib-review-diffcap.sh` against a temp metrics dir,
simulate one review round with N=3 fan-out members: assert exactly one
`pr_diff_soft_cap` event line (not one per fan-out member — distinct from the
per-member `review_agent_run` event). New numeric fields (`changed_files`,
`changed_lines`, `files_cap`, `lines_cap`) serialize as JSON numbers, not
strings (i.e., added to `lib-metrics.sh`'s `num_keys` allow-list).

### TC-OVERREACH-015 — provider-seam compliance: no raw `gh pr view` added to `autonomous-review.sh`
`check-provider-cutover.sh` stays green after this change — the diff-stat read
goes through `chp_pr_diffstat`, never a raw `gh pr view --json
additions,deletions,changedFiles` call in the caller layer.

### TC-OVERREACH-016 — verdict aggregation / PASS path unaffected by `over_reach`
With all review-agent verdicts fixed to PASS, toggling `over_reach` between
`true` and `false` produces byte-identical aggregation/merge-decision output —
asserted by calling the aggregator directly with and without the over-reach
note present, never by a subjective "is this refactor legitimate" judgment.

## E2E test cases

### TC-OVERREACH-E01 — over-cap PR ⇒ note in prompt + `over_reach=true` metrics event
Simulate a PR whose changed-files/lines exceed the configured cap (stub
`chp_pr_diffstat`). Assert the rendered review prompt contains the over-reach
note and `metrics.jsonl` carries a `pr_diff_soft_cap` event with
`over_reach=true` and the measured stats.

### TC-OVERREACH-E02 — under-cap PR ⇒ no note, `over_reach=false` event
Simulate a PR under the configured cap. Assert no over-reach note is injected
into the prompt, and the `pr_diff_soft_cap` event (emitted unconditionally once
per enabled round) carries `over_reach=false`.
