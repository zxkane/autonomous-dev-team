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

  gh issue comment "$issue_num" --repo "$repo" --body "$body" >/dev/null 2>&1 || true
  return 0
}
