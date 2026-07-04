#!/bin/bash
# Resolve all unresolved review threads on a GitHub PR
#
# Usage: ./resolve-threads.sh <owner> <repo> <pr_number>
#
# Example:
#   ./resolve-threads.sh zxkane openhands-infra 5
#
# [INV-87] (#282) The reviewThreads list + resolveReviewThread mutation are the
# Code-Host-Provider (CHP) `chp_review_threads` / `chp_resolve_thread` verbs
# (docs/pipeline/provider-spec.md §3.2 [M8]). The `gh api graphql` primitives
# move behind the verbs; the select-unresolved + the resolved/failed tally stay
# here (provider-neutral).

set -e

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <owner> <repo> <pr_number>"
    echo ""
    echo "Arguments:"
    echo "  owner       - Repository owner (e.g., zxkane)"
    echo "  repo        - Repository name (e.g., openhands-infra)"
    echo "  pr_number   - Pull request number (e.g., 5)"
    echo ""
    echo "Example:"
    echo "  $0 zxkane openhands-infra 5"
    exit 1
fi

# Sanitize inputs to prevent command injection
OWNER=$(printf '%s' "$1" | sed 's/[^a-zA-Z0-9._-]//g')
REPO=$(printf '%s' "$2" | sed 's/[^a-zA-Z0-9._-]//g')
PR_NUMBER=$(printf '%d' "$3" 2>/dev/null || echo '0')

# Validate inputs
if [ -z "$OWNER" ] || [ -z "$REPO" ] || [ "$PR_NUMBER" -eq 0 ]; then
    echo "Error: Invalid arguments provided"
    exit 1
fi

# The CHP verbs derive owner/name from $REPO, so this CLI's `owner repo` arg pair
# becomes the provider-neutral `$REPO` namespace.
export REPO="${OWNER}/${REPO}"

# Source lib-code-host.sh (the CHP dispatch shims). It resolves from the REAL
# skill tree via readlink -f. In the INSTALLED skill tree this script and
# lib-code-host.sh are siblings in autonomous-dispatcher/scripts/; in the SOURCE
# repo this file lives in autonomous-common/scripts/ while lib-code-host.sh lives
# in autonomous-dispatcher/scripts/ — so try the own-dir first, then the
# dispatcher-sibling fallback. (The verbs are the contract — fail loudly rather
# than silently re-inlining the gh leaves.)
#
# [#401 / #347 W1f] The chp_review_threads leaf walks BOTH GraphQL pagination
# levels internally and returns rc != 0 with no partial stdout on any mid-walk
# failure. This script's job on this side of the pipe is to (a) capture the
# leaf's stdout INTO a variable — never pipe into jq without pipefail — and
# (b) test the leaf's rc BEFORE selecting unresolved thread ids, so a failed
# multi-page walk aborts the resolve loop LOUD instead of silently reporting
# "0 resolved, 0 failed" success on an empty stream.
_rt_self="${BASH_SOURCE[0]:-$0}"
_rt_dir="$(cd "$(dirname "$(readlink -f "$_rt_self")")" && pwd 2>/dev/null)" || _rt_dir=""
_rt_chp=""
for _c in \
  "${_rt_dir}/lib-code-host.sh" \
  "${_rt_dir}/../../autonomous-dispatcher/scripts/lib-code-host.sh"; do
  if [ -r "$_c" ]; then _rt_chp="$_c"; break; fi
done
if [ -z "$_rt_chp" ]; then
  echo "Error: lib-code-host.sh not found beside resolve-threads.sh — cannot resolve the CHP review-thread verbs." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$_rt_chp"
unset _rt_self _rt_dir _rt_chp _c

echo "Fetching unresolved review threads for PR #$PR_NUMBER..."

# Get unresolved thread IDs via the CHP verb. chp_review_threads returns the M8
# thread shape ([{thread_id, resolved, comments:[…]}]); select the unresolved
# thread_ids — byte-equivalent to the prior inline
# `reviewThreads.nodes[]|select(.isResolved==false).id`.
#
# [#401 R2] Capture-then-test: pipe-into-jq without pipefail turned a mid-walk
# leaf failure (empty stdout, non-zero rc) into an empty THREAD_IDS and a false
# "0 resolved, 0 failed" success. Capture the leaf's stdout and check its exit
# BEFORE selecting.
if ! _threads_json=$(chp_review_threads "$PR_NUMBER"); then
    echo "Error: chp_review_threads failed for PR #$PR_NUMBER (see stderr above)" >&2
    exit 1
fi
THREAD_IDS=$(printf '%s' "$_threads_json" \
  | jq -r '.[] | select(.resolved == false) | .thread_id')
unset _threads_json

if [ -z "$THREAD_IDS" ]; then
    echo "No unresolved threads found!"
    exit 0
fi

# Count threads
THREAD_COUNT=$(echo "$THREAD_IDS" | wc -l | tr -d ' ')
echo "Found $THREAD_COUNT unresolved thread(s)"

# Resolve each thread and track results
RESOLVED=0
FAILED=0

# Use here-string to avoid subshell (pipe creates subshell where variable updates are lost)
while read thread_id; do
    if [ -n "$thread_id" ]; then
        echo -n "Resolving thread $thread_id... "
        # CHP verb resolves the thread and echoes the post-mutation isResolved.
        result=$(chp_resolve_thread "$thread_id" 2>/dev/null)

        if [ "$result" = "true" ]; then
            echo "OK"
            RESOLVED=$((RESOLVED + 1))
        else
            echo "FAILED"
            FAILED=$((FAILED + 1))
        fi
    fi
done <<< "$THREAD_IDS"

echo ""
echo "Summary: $RESOLVED resolved, $FAILED failed"
