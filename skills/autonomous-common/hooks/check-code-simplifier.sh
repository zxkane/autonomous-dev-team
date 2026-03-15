#!/bin/bash
# Pre-commit hook - blocks commits until code-simplifier is run
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
STATE_MANAGER="$SCRIPT_DIR/state-manager.sh"

input=$(cat)
command=$(parse_command "$input")

# Only process git commit commands (skip amends)
if ! is_git_command "commit" "$command" || [[ "$command" =~ --amend ]]; then
  exit 0
fi

# Allow if code-simplifier was run
if "$STATE_MANAGER" check code-simplifier 2>/dev/null; then
  exit 0
fi

# Check if any code files are staged
staged_files=$(git diff --cached --name-only 2>/dev/null || echo "")
has_code_changes=false

while IFS= read -r file; do
  # Check for implementation files (adjust pattern as needed)
  if [[ "$file" =~ \.(ts|tsx|js|jsx|py|go|java|rb|rs)$ ]] && [[ ! "$file" =~ (\.test\.|\.spec\.|__tests__|tests/) ]]; then
    has_code_changes=true
    break
  fi
done <<< "$staged_files"

# Skip if no code changes
if [[ "$has_code_changes" == "false" ]]; then
  exit 0
fi

# Block the commit
cat >&2 <<'EOF'
## ⛔ BLOCKED - Run Code Simplifier First

Before committing, you must run the code-simplifier agent to review and clean up your changes.

### Required Steps:
1. Run the code-simplifier agent (try in order):
   a. Use Agent tool with subagent_type: code-simplifier:code-simplifier
   b. If agent not found, fallback to: /simplify skill

2. After code-simplifier/simplify completes, mark it:
   ```bash
   hooks/state-manager.sh mark code-simplifier
   ```

3. Retry the commit

### Why This Is Required (CLAUDE.md Step 5):
- Ensures consistent code style
- Removes redundant code
- Validates changes follow project patterns
- Part of the project's quality workflow

**To bypass (only for minor fixes):** Use `--no-verify` flag (document reason)
EOF

exit 2
