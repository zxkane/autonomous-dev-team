#!/bin/bash
# Pre-push hook - blocks pushes until PR review is completed
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
STATE_MANAGER="$SCRIPT_DIR/state-manager.sh"

input=$(read_hook_stdin)
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
## BLOCKED - Run PR Review First

Before pushing, you must complete an independent review of the full branch diff.
The mark is bound to the current HEAD commit: any new commit invalidates it,
so you must re-run the review after each commit (issue #48).

### Required Steps:
1. Use the native option for this client:
   - Codex: spawn a reviewer subagent or run `codex review --base <base-branch>`.
   - Claude Code: run `/pr-review-toolkit:review-pr`.
   - Other clients: use an available review agent or review the diff manually.

2. Resolve all Critical/High/Medium severity findings:
   - 🔴 Critical/Severe: MUST fix
   - 🟠 High: MUST fix
   - 🟡 Medium: Should fix
   - 🟢 Low: Optional

3. After review completes and issues resolved, mark it:
   ```bash
   hooks/state-manager.sh mark pr-review
   ```
   The mark stores the current HEAD SHA. If you commit again, re-run
   the review and re-mark before pushing.

4. Retry the push

### What PR Review Checks:
- Code style and patterns adherence
- Silent failure detection
- Type design analysis
- Test coverage gaps
- Security vulnerabilities

### Why This Is Required:
Per development workflow, code review must be completed before pushing.

**To bypass (emergency only):** Use `--no-verify` flag and document the reason
EOF

exit 2
