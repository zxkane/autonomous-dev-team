#!/bin/bash
# Pre-push hook - blocks pushes until PR review is completed
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
STATE_MANAGER="$SCRIPT_DIR/state-manager.sh"

input=$(cat)
command=$(parse_command "$input")

# Only process git push commands (skip --no-verify)
if ! is_git_command "push" "$command" || [[ "$command" =~ --no-verify ]]; then
  exit 0
fi

# Allow if pr-review was run
if "$STATE_MANAGER" check pr-review 2>/dev/null; then
  exit 0
fi

# Get current branch
current_branch=$(git branch --show-current 2>/dev/null || echo "")

# Skip for main/master branches (usually protected anyway)
if [[ "$current_branch" =~ ^(main|master)$ ]]; then
  exit 0
fi

# Block the push
cat >&2 <<'EOF'
## ⛔ BLOCKED - Run PR Review First

Before pushing, you must complete a code review using the PR review toolkit.

### Required Steps:
1. Run the PR review command:
   ```
   /pr-review-toolkit:review-pr
   ```

2. Resolve all Critical/High/Medium severity findings:
   - 🔴 Critical/Severe: MUST fix
   - 🟠 High: MUST fix
   - 🟡 Medium: Should fix
   - 🟢 Low: Optional

3. After review completes and issues resolved, mark it:
   ```bash
   .claude/hooks/state-manager.sh mark pr-review
   ```

4. Retry the push

### What PR Review Checks:
- Code style and patterns adherence
- Silent failure detection
- Type design analysis
- Test coverage gaps
- Security vulnerabilities

### Why This Is Required (CLAUDE.md Step 6):
Per development workflow, code review must be completed before pushing.

**To bypass (emergency only):** Use `--no-verify` flag and document the reason
EOF

exit 2
