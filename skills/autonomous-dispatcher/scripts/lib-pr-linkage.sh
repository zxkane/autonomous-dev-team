#!/bin/bash
# lib-pr-linkage.sh — INV-86 (#277). Authoritative PR↔issue resolution.
#
# Binds an issue to the open PR that *closes* it (GitHub's parsed
# `closingIssuesReferences`), NOT to any open PR whose body merely mentions
# `#N`. The pre-#277 body-mention match (`select(.body | test("#N"))] | .[0]`)
# bound an issue to a cross-referencing sibling PR: when two issues were in
# flight concurrently and one PR's body carried a good-practice
# `- related to #A` line, the review wrapper for issue A reviewed and *mutated*
# the WRONG PR (submitted `REQUEST_CHANGES` against a foreign PR and posted a
# dev-actionable FAILED verdict to issue A — a non-terminating dev↔review loop
# driver). `closingIssuesReferences` is GitHub's parsed close-linkage and is
# immune to body cross-references.
#
# Lives in its own lib (mirrors lib-review-request-changes.sh layering) so BOTH
# the dispatcher (`lib-dispatch.sh`, via the `fetch_pr_for_issue` delegate) AND
# the review wrapper (`autonomous-review.sh`, which does NOT source the heavy
# lib-dispatch.sh) can resolve PRs identically — the issue's "fix both sites"
# requirement. No `set -e`, no required-env enforcement on source (matches the
# other lib-review-*.sh): the only dependency is `gh` on PATH and `$REPO`.
#
# All regexes are RE2-safe (`(^|[^0-9])` / `([^0-9]|$)` — plain alternation, no
# look-behind/ahead) so a `gh --jq` run can never abort a caller under `set -e`
# (see the repo's "gh --jq is RE2" note). `.body`/`.headRefName`/
# `.closingIssuesReferences` are guarded with `// ""` / `[]?` so a null field
# can't abort the jq filter and silently hide a match (parity with the #148
# null-body guard).
#
# [INV-87] (#282, W1c1 #397) The CHP `chp_find_pr_for_issue` verb is an
# ABSTRACT contract (spec §3.2 [M1]): positional args `<issue> <fields-csv>`,
# returning a NORMALIZED JSON array of candidate PRs with `closingIssueNumbers`
# as ints and `body` pinned to a string (null → "") — no gh flags and no jq
# programs cross the seam. The [INV-86] two-tier resolution + projection stays
# HERE as pure jq over the normalized array (caller-side, provider-neutral;
# mirrors INV-44 classifiers-stay-caller-side). The complete-set walk
# ([`provider-spec.md`](provider-spec.md) §3.5) is the leaf's responsibility.
# Sourced from the REAL skill tree via readlink -f (the lib-dispatch.sh idiom)
# so a standalone unit test that sources only this lib still gets the verb.
# Idempotent (the shims + .caps reader guard their own redefinition).
if ! declare -F chp_find_pr_for_issue >/dev/null 2>&1; then
  _lpl_self="${BASH_SOURCE[0]:-$0}"
  _lpl_dir="$(cd "$(dirname "$(readlink -f "$_lpl_self")")" && pwd 2>/dev/null)" || _lpl_dir=""
  if [ -n "$_lpl_dir" ] && [ -r "${_lpl_dir}/lib-code-host.sh" ]; then
    # shellcheck source=lib-code-host.sh
    source "${_lpl_dir}/lib-code-host.sh"
  fi
  unset _lpl_self _lpl_dir
fi

# resolve_pr_for_issue <issue_num> [fields]
#
# Echoes the single-line JSON object of the open PR bound to <issue_num>, with
# the caller's requested `fields` (comma-separated `--json` list, default
# "number"), or empty when no PR is bound.
#
# Precedence (first non-empty wins):
#   1. Close linkage (authoritative): the open PR whose
#      `closingIssuesReferences[].number` equals this issue. Lowest PR number on
#      ties (GitHub binds one closing PR per issue, so ties shouldn't occur — the
#      sort makes selection deterministic regardless).
#   2. Branch-name fallback (close-keyword-less partial-fix PRs deliberately omit
#      `Closes #N` so GitHub doesn't auto-close — see the repo's close-keyword
#      guidance): the open PR whose `headRefName` matches the boundary-anchored
#      `issue-<N>` marker. Lowest PR number on ties. NEVER a bare `.[0]` body
#      mention.
#
# One `gh pr list` call fetches the union of the caller's fields and the
# resolution fields; the `-q` does resolution AND projection in jq.
resolve_pr_for_issue() {
  local issue_num="$1" fields="${2:-number}"
  # W1c1 (#397): fetch the normalized candidate array, then run the resolution
  # jq over it caller-side. The leaf owns the union with `number,
  # closingIssueNumbers, headRefName` (the resolution keys) — so we pass the
  # caller's fields verbatim and trust the leaf's field-union. Fail-closed on
  # a transport error (`|| return 1`) — the pushed-no-PR classification MUST
  # NOT proceed under a failed read.
  local candidates
  candidates=$(chp_find_pr_for_issue "$issue_num" "$fields") || return 1
  [ -n "$candidates" ] || return 0
  # Both `$closes` and `$branch` bind from the SAME normalized candidate array
  # — close linkage first, branch-name fallback second. Boundary-anchored
  # branch match: `issue-273` must not match `issue-2730`.
  #
  # The branch tier ALSO requires the candidate to carry NO close linkage at
  # all (`closingIssueNumbers` empty) — this keeps it SYMMETRIC with
  # verify_pr_closes_issue's branch clause (#277 review [P1] finding 1): a PR
  # on an `issue-N` branch that actually `Closes #OTHER` would otherwise be
  # sorted into the branch candidates and could shadow the real close-keyword-
  # less partial-fix PR for this issue, only to be REJECTED by the guard → a
  # spurious abort even though a valid PR exists. (A PR that closes THIS issue
  # is already handled by the authoritative `$closes` tier, so excluding all
  # close-linked PRs from the branch tier never drops a real match.)
  #
  # `closingIssueNumbers` is normalized as an array of INTS by the leaf
  # (W1c1 #397), so `contains([<issue>])` is the correct membership test —
  # simpler than the pre-#397 `any(.closingIssuesReferences[]?; .number == N)`.
  local q
  q="$(cat <<JQ
. as \$prs
| ([\$prs[] | select((.closingIssueNumbers // []) | contains([${issue_num}]))] | sort_by(.number)) as \$closes
| ([\$prs[] | select(((.closingIssueNumbers // []) | length) == 0 and ((.headRefName // "") | test("(^|[^0-9])issue-${issue_num}([^0-9]|\$)")))] | sort_by(.number)) as \$branch
| (if (\$closes | length) > 0 then \$closes[0] elif (\$branch | length) > 0 then \$branch[0] else empty end)
JQ
)"
  jq -c "$q" <<<"$candidates"
}

# verify_pr_closes_issue <pr_num> <issue_num>
#
# Hard linkage guard. Returns 0 iff PR <pr_num> closes issue <issue_num> by
# GitHub's parsed close linkage, OR (when that PR carries NO close linkage at
# all) its branch name matches the boundary-anchored `issue-<N>` marker. The
# review wrapper asserts this before ANY PR mutation (submit_request_changes /
# approve / merge / label flip) so it can NEVER review or mutate a foreign PR
# (the second, independent bug in #277: `submit_request_changes` was unguarded
# once `PR_NUMBER` was set).
#
# Fail-closed: a `gh` transport error / empty result returns 1 (refuse), never a
# false accept.
verify_pr_closes_issue() {
  local pr_num="$1" issue_num="$2"
  [ -n "$pr_num" ] && [ -n "$issue_num" ] || return 1
  # W1c1 (#397): fetch the normalized candidate array once, then run the guard
  # jq caller-side. The leaf's field-union already includes number,
  # closingIssueNumbers, headRefName, so we pass an empty field list (only the
  # resolution keys are needed — but the leaf normalizes the full vocabulary
  # regardless, so requesting `number` is enough).
  local candidates hit
  candidates=$(chp_find_pr_for_issue "$issue_num" "number" 2>/dev/null) || return 1
  [ -n "$candidates" ] || return 1
  local q
  q="$(cat <<JQ
[.[] | select(.number == ${pr_num})
  | select(((.closingIssueNumbers // []) | contains([${issue_num}]))
           or (((.headRefName // "") | test("(^|[^0-9])issue-${issue_num}([^0-9]|\$)"))
               and ((.closingIssueNumbers // []) | length) == 0))] | length
JQ
)"
  hit=$(jq -r "$q" <<<"$candidates" 2>/dev/null) || return 1
  [ -n "$hit" ] && [ "$hit" != "0" ]
}

# _pr_field_union is retired in W1c1 (#397): the leaf owns the union with the
# resolution keys (number, closingIssueNumbers, headRefName) so callers pass
# their bare requested fields directly to `chp_find_pr_for_issue`. If a
# consumer test still references it, they should switch to the abstract
# contract.
