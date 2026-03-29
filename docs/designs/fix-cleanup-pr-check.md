# Fix: Cleanup trap verifies PR exists before setting pending-review

**Date:** 2026-03-29
**Issue:** #40
**Status:** Approved

## Problem

`autonomous-dev.sh` cleanup trap sets `pending-review` whenever exit code is 0,
without checking if a PR was actually created. This wastes a review dispatch cycle
and confuses retry counting.

## Fix

In the cleanup trap's success branch (exit code 0), check for an open PR whose
body references the issue number. If no PR exists, set `pending-dev` instead
and post a distinguishing comment.

```bash
if [[ $exit_code -eq 0 ]]; then
    PR_EXISTS=$(gh pr list --repo "$REPO" --state open --json body \
      -q "[.[] | select(.body | test(\"#${ISSUE_NUMBER}[^0-9]\") or test(\"#${ISSUE_NUMBER}$\"))] | length" 2>/dev/null || echo "0")
    if [[ "$PR_EXISTS" -gt 0 ]]; then
        # PR found → pending-review
    else
        # No PR → pending-dev with warning
    fi
fi
```

## Files changed

- `skills/autonomous-dispatcher/scripts/autonomous-dev.sh` — cleanup function
