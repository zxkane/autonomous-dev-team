#!/bin/bash
# lib-review-verdict.sh — INV-35 verdict-trailer emission for the review wrapper.
#
# Posts a `<!-- review-verdict: ... -->` HTML-comment trailer on the issue so
# the dispatcher's classify_recent_review_verdict (lib-dispatch.sh) can route
# Step 4b.5.1 correctly when a completed dev session is followed by a review
# failure. See docs/designs/inv35-review-aware-resume.md § 4 for the trailer
# schema and acceptable cause tokens.
#
# Why a separate file: the trailer-emission logic is short and shared by
# multiple branches in autonomous-review.sh (PASS, FAIL-substantive,
# FAIL-non-substantive auto-merge-failure). Extracting it keeps the wrapper
# readable and the logic unit-testable in isolation.

# [INV-87]/[INV-89] The verdict trailer is an issue-level MACHINE MARKER, so its
# write routes through itp_post_comment (the marker_channel choke-point), not a
# raw `gh issue comment`. The review wrapper does not source lib-issue-provider.sh,
# and this lib is also sourced standalone in unit tests — so self-source the seam
# from the REAL skill tree via readlink -f of this file's own BASH_SOURCE (the
# same idiom lib-dispatch.sh / lib-review-e2e.sh use). Idempotent + guarded.
if ! declare -F itp_post_comment >/dev/null 2>&1; then
  _lrv_self="${BASH_SOURCE[0]:-$0}"
  _lrv_dir="$(cd "$(dirname "$(readlink -f "$_lrv_self")")" && pwd 2>/dev/null)" || _lrv_dir=""
  if [ -n "$_lrv_dir" ] && [ -r "${_lrv_dir}/lib-issue-provider.sh" ]; then
    # shellcheck source=lib-issue-provider.sh
    source "${_lrv_dir}/lib-issue-provider.sh"
  fi
  unset _lrv_self _lrv_dir
fi

# emit_verdict_trailer <issue_num> <repo> <verdict> <cause>
#
#   verdict ∈ { passed, failed-substantive, failed-non-substantive }
#   cause   — required only for failed-non-substantive (extensible token,
#             e.g. bot-timeout, ci-transport, no-pr-found,
#             merge-conflict-unresolvable, other). Defaults to "other"
#             when verdict is failed-non-substantive and cause is empty,
#             or when cause contains characters outside the whitelist.
#
# Returns 0 on success, 1 on rejection (unknown verdict).
#
# Side effect: posts one comment via `gh issue comment`. The comment's body
# is JUST the trailer line — no human text — so it doesn't render in the
# GitHub issue UI. Posting an additional, separate comment (rather than
# merging into the agent's verdict comment) is intentional: the wrapper
# can guarantee the trailer's content even if the agent's verdict comment
# format drifts; classify_recent_review_verdict picks the newest matching
# bot comment so a later trailer-only comment shadows any earlier one.
emit_verdict_trailer() {
  local issue_num="$1"
  local repo="$2"
  local verdict="$3"
  local cause="${4:-}"

  case "$verdict" in
    passed|failed-substantive|failed-non-substantive)
      ;;
    *)
      return 1
      ;;
  esac

  local body=""
  if [ "$verdict" = "failed-non-substantive" ]; then
    # Whitelist: lowercase letters, digits, dashes only. Anything else
    # (uppercase, shell metachars, HTML) is sanitized to "other" so the
    # trailer cannot be weaponized as an injection vector or break the
    # dispatcher's regex-based parser.
    if [[ -z "$cause" || ! "$cause" =~ ^[a-z0-9-]+$ ]]; then
      cause="other"
    fi
    body="<!-- review-verdict: failed-non-substantive cause=${cause} -->"
  else
    body="<!-- review-verdict: ${verdict} -->"
  fi

  # [INV-89] Route through the marker choke-point. `itp_github_post_comment` posts
  # to the global $REPO; every caller passes $repo == $REPO (the wrapper's repo),
  # so the emitted `gh issue comment … --body "$body"` is byte-identical.
  itp_post_comment "$issue_num" "$body" >/dev/null 2>&1 || true
  return 0
}
