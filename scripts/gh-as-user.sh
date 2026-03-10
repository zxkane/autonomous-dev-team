#!/bin/bash
# gh-as-user.sh — Run `gh` as a real user (not a GitHub App bot).
#
# Amazon Q Developer ignores `/q review` comments posted by bot accounts.
# This wrapper ensures the `gh` call is authenticated as a real user.
#
# Token resolution (priority order):
#   1. GH_USER_PAT env var — if set, use as GH_TOKEN
#   2. Host `gh auth` session — call real `gh` without any GH_TOKEN override
#   3. If neither available — log warning and exit 0 (non-fatal)
#
# Usage:
#   bash scripts/gh-as-user.sh pr comment 42 --body "/q review"

# Find the real gh binary (skip the gh-with-token-refresh.sh wrapper)
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
CLEAN_PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "^${SELF_DIR}$" | tr '\n' ':' | sed 's/:$//')
REAL_GH=$(PATH="$CLEAN_PATH" command -v gh 2>/dev/null) || {
  echo "WARNING: Cannot find real gh binary — skipping user-auth gh call" >&2
  exit 0
}

# Priority 1: Use explicit user PAT
if [[ -n "${GH_USER_PAT:-}" ]]; then
  exec env GH_TOKEN="$GH_USER_PAT" "$REAL_GH" "$@"
fi

# Priority 2: Use host gh auth session (unset GH_TOKEN so gh uses its own auth store)
if env -u GH_TOKEN -u GITHUB_TOKEN -u GITHUB_PERSONAL_ACCESS_TOKEN \
     "$REAL_GH" auth status >/dev/null 2>&1; then
  exec env -u GH_TOKEN -u GITHUB_TOKEN -u GITHUB_PERSONAL_ACCESS_TOKEN "$REAL_GH" "$@"
fi

# Priority 3: No user auth available — warn and skip
echo "WARNING: No user auth available for gh (GH_USER_PAT not set, no host gh auth session). Skipping." >&2
exit 0
