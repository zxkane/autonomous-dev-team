# Design — `mark-issue-checkbox.sh` body-read behind `itp_read_task` (#315, part of #296)

## Goal

Migrate the single issue-body READ in `mark-issue-checkbox.sh:78` behind the
already-shipped `itp_read_task` provider verb (#281). This is the lowest-risk
first-tier remaining batch of #296 (the pluggable-providers raw-`gh` migration):
an agent-callable utility, not a live dispatcher/wrapper hot path.

## The single change

```sh
# BEFORE (mark-issue-checkbox.sh:78)
body=$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}" --jq '.body') || {
  echo "Error: Failed to fetch issue #${ISSUE_NUMBER}" >&2
  return 1
}

# AFTER
body=$(itp_read_task "$ISSUE_NUMBER" body -q '.body') || {
  echo "Error: Failed to fetch issue #${ISSUE_NUMBER}" >&2
  return 1
}
```

The `|| { … }` handler is preserved verbatim. The verb is already reachable: the
script sources `lib-issue-provider.sh` at the top (the source guard at `:42`), so
no new `source` line is needed. The shim → `itp_github_read_task` →
`gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json body -q '.body'`.

## Shape-equivalent, not byte-identical

`gh api … --jq` (raw REST) → `gh issue view … --json body -q` (different
subcommand + endpoint). The returned **issue-body string is identical**, so the
verification is behavior-equivalence (same body, same error handling), mirroring
B2 (#306) and the #281 read leaves. NOT a byte-identical golden-trace.

## Source-guard widening (intentional behavior change — option b)

Today the source guard at `:42` keys on `declare -F itp_mark_checkbox` only. After
migration the body READ also routes through `itp_read_task`. Widen the guard to
source the seam when `itp_read_task` OR `itp_mark_checkbox` is undefined, so the
genuinely-absent-lib case still attempts the source.

If the seam is truly absent, `itp_read_task` is undefined and the body fetch fails
**earlier** (in the fetch handler) than the pre-migration PATCH-cap branch. This is
the **correct, intentional** outcome: re-adding a raw-`gh` fallback would
re-introduce the exact survivor this migration removes (defeats baseline −1,
violates INV-91). The script must fail LOUD with a verb-not-available message
(naming `itp_read_task`), NOT a raw `command not found` and NEVER a silent
raw-`gh` read.

## Out of scope

- Any other #296 survivor (repo-clone-url, dev-resume reads, final marker scanners).
- Minting any new verb; the #286 amendment; GitLab/Asana backends.

## Test surface (all pre-merge via CI `unit` + `Spec Drift`)

- Behavior-equivalence test (real subprocess + binary `gh` stub): same body,
  identical `|| { … }` error handling, REPO-fallback exit-1.
- AC2a: fix the 3 broken `gh` stubs in `test-itp-write-leaves.sh` to the new
  `gh issue view --json body` read shape.
- AC2b: add `itp_degraded_read_task` to the degraded fixture so the
  `body_checkbox=0` cap-branch is reachable.
- AC2c: re-baseline the provider-absent test to the earlier verb-not-available
  fail-loud.
- AC3: `cutover-baseline.json` shrinks by exactly 1.
- AC4: INV-91 Migration-log update (retract stale B1 clause + add new bullet).
