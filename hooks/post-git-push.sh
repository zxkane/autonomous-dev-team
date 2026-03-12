#!/bin/bash
# Post git push hook - reminds Claude to wait for CI and run E2E tests
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

input=$(cat)
command=$(parse_command "$input")
exit_code=$(parse_exit_code "$input")

# Only process successful git push commands
if ! is_git_command "push" "$command" || [[ "$exit_code" != "0" ]]; then
  exit 0
fi

# Get current branch for context
current_branch=$(git branch --show-current 2>/dev/null || echo "unknown")

# Output verification reminder as JSON
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "## 📤 Post-Push Verification Required\\n\\nGit push completed to branch '$current_branch'. Complete these steps before declaring the task done:\\n\\n### Step 7: Wait for GitHub Actions CI\\n\`\`\`bash\\ngh run list --limit 1 --json status,conclusion,name,headBranch\\ngh run watch\\n\`\`\`\\n\\n### If CI Fails:\\n- Analyze failure logs: \`gh run view --log-failed\`\\n- Fix issues and push again\\n- Run \`/pr-review-toolkit:review-pr\` before next push\\n- Return to Step 7\\n\\n### Step 8: If CI Passes - Run E2E Tests\\nUse Chrome DevTools MCP to test the PR preview environment:\\n1. Get preview URL: \`gh pr view --json url\`\\n2. Navigate to the preview URL\\n3. Execute E2E tests (authentication, core functionality)\\n4. Verify no console errors\\n5. Capture screenshots if needed\\n\\n### After E2E Verification:\\n\`\`\`bash\\n.claude/hooks/state-manager.sh mark e2e-tests\\n\`\`\`\\n\\n**⚠️ DO NOT skip these steps or declare completion prematurely.**"
  }
}
EOF

exit 0
