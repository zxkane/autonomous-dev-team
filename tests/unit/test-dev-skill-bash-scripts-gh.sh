#!/bin/bash
# test-dev-skill-bash-scripts-gh.sh — Regression guard for issue #142.
#
# Asserts that agent-facing docs in the autonomous-dev skill never tell the
# agent to call bare `gh issue comment` for status/summary/progress posts.
#
# Why: in GH_AUTH_MODE=app, the wrapper PATH-prepends a gh-with-token-refresh
# symlink so all gh calls route through the App-installed bot identity. The
# agent's embedded Bash tool, however, doesn't reliably honor that injected
# PATH for `gh` resolution — bare `gh issue comment` resolves to /usr/bin/gh
# and posts under the host operator's `gh auth login` user instead of the
# bot. The fix is to instruct the agent to call the project-vendored wrapper
# explicitly: `bash scripts/gh issue comment …`. This test ensures future
# edits don't regress to bare `gh issue comment` in the agent-facing docs.
#
# Scope: skills/autonomous-dev/SKILL.md plus skills/autonomous-dev/references/*.md.
# Other doc trees (docs/pipeline/, design docs, dispatcher SKILL) are NOT
# agent-facing instructions and are out of scope.
#
# Run: bash tests/unit/test-dev-skill-bash-scripts-gh.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# scoped_files: every agent-facing markdown file in the autonomous-dev skill.
mapfile -t scoped_files < <(
  find "$PROJECT_ROOT/skills/autonomous-dev" -type f -name '*.md' | sort
)

if [[ ${#scoped_files[@]} -eq 0 ]]; then
  echo -e "${RED}FAIL${NC}: no agent-facing markdown files found under skills/autonomous-dev"
  exit 1
fi

echo "=== TC-COMMENT-004: no bare 'gh issue comment' in agent-facing docs ==="
echo "  scoped files:"
for f in "${scoped_files[@]}"; do
  echo "    ${f#$PROJECT_ROOT/}"
done
echo ""

# A "bare" hit is `gh issue comment` used as an actual command — i.e.,
# followed by an argument (a number, a placeholder like {pr}/<id>/$VAR, or a
# quoted string). Inline-code anti-pattern callouts like
#   "Never use bare `gh issue comment` …"
# are documentation OF the rule and don't represent commands the agent would
# copy, so they are excluded.
#
# Allowed forms:
#   bash scripts/gh issue comment …   (preceded by `/`)
#   `gh issue comment` (inline-code, no argument — prose)
#   "bare `gh issue comment`" (inline-code, anti-pattern callout — prose)
#
# Disallowed forms (regression):
#   gh issue comment 142 --body …
#   gh issue comment "$ISSUE" …
#   gh issue comment {pr} …
violations=()
for f in "${scoped_files[@]}"; do
  while IFS= read -r line; do
    [[ -n "$line" ]] && violations+=("${f#$PROJECT_ROOT/}:$line")
  done < <(grep -nE "(^|[^/])gh issue comment[[:space:]]+([0-9\"'<{$]|--)" "$f" 2>/dev/null || true)
done

if [[ ${#violations[@]} -eq 0 ]]; then
  echo -e "  ${GREEN}PASS${NC}: zero bare 'gh issue comment' in agent-facing docs"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: bare 'gh issue comment' found — must be 'bash scripts/gh issue comment' instead"
  for v in "${violations[@]}"; do
    echo "      $v"
  done
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-COMMENT-004b: autonomous-mode.md documents the dual-wrapper rule ==="
# ---------------------------------------------------------------------------
# Sanity check that the docs explain WHY there are two wrappers, so future
# editors understand the intent and don't collapse both into one path.

AUTO_MODE_MD="$PROJECT_ROOT/skills/autonomous-dev/references/autonomous-mode.md"
if [[ ! -f "$AUTO_MODE_MD" ]]; then
  echo -e "  ${RED}FAIL${NC}: $AUTO_MODE_MD missing"
  FAIL=$((FAIL + 1))
else
  if grep -q 'bash scripts/gh issue comment' "$AUTO_MODE_MD" \
     && grep -q 'gh-as-user.sh' "$AUTO_MODE_MD"; then
    echo -e "  ${GREEN}PASS${NC}: autonomous-mode.md mentions both bash scripts/gh and gh-as-user.sh"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: autonomous-mode.md does not mention both wrappers (bash scripts/gh and gh-as-user.sh)"
    FAIL=$((FAIL + 1))
  fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
