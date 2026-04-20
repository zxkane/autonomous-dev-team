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

# Find the real gh binary — skip ALL wrapper scripts (gh-with-token-refresh.sh
# and its symlinked `gh` alias). lib-auth.sh prepends the dispatcher's scripts/
# dir to PATH, which is different from SELF_DIR, so stripping only our own dir
# leaves the wrapper reachable. Strip every dir that contains the wrapper.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
CLEAN_PATH=$(echo "$PATH" | tr ':' '\n' \
  | while IFS= read -r dir; do
      [[ -e "${dir}/gh-with-token-refresh.sh" ]] && continue
      [[ "$dir" == "$SELF_DIR" ]] && continue
      printf '%s:' "$dir"
    done | sed 's/:$//')
REAL_GH=$(PATH="$CLEAN_PATH" command -v gh 2>/dev/null) || {
  echo "WARNING: Cannot find real gh binary — skipping user-auth gh call" >&2
  exit 0
}

# Priority 1: Use explicit user PAT
if [[ -n "${GH_USER_PAT:-}" ]]; then
  exec env -u GH_TOKEN_FILE GH_TOKEN="$GH_USER_PAT" "$REAL_GH" "$@"
fi

# Priority 2: Use host gh auth session.
# Unset ALL token env vars AND GH_TOKEN_FILE — the wrapper reads the bot token
# from GH_TOKEN_FILE even when GH_TOKEN is unset.
if env -u GH_TOKEN -u GITHUB_TOKEN -u GITHUB_PERSONAL_ACCESS_TOKEN -u GH_TOKEN_FILE \
     "$REAL_GH" auth status >/dev/null 2>&1; then
  exec env -u GH_TOKEN -u GITHUB_TOKEN -u GITHUB_PERSONAL_ACCESS_TOKEN -u GH_TOKEN_FILE "$REAL_GH" "$@"
fi

# Priority 3: No user auth available — exit with distinct code
echo "WARNING: No user auth available for gh (GH_USER_PAT not set, no host gh auth session). Skipping." >&2
exit 2
