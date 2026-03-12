#!/bin/bash
# Pre-commit hook - verifies unit tests were run before committing code changes
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
STATE_MANAGER="$SCRIPT_DIR/state-manager.sh"

input=$(cat)
command=$(parse_command "$input")

# Only check for git commit commands
if ! is_git_command "commit" "$command"; then
  exit 0
fi

# Check if any implementation files are staged
staged_files=$(git diff --cached --name-only 2>/dev/null || echo "")
has_code_changes=false

while IFS= read -r file; do
  # Check for implementation files (adjust pattern as needed)
  if [[ "$file" =~ \.(ts|tsx|js|jsx|py|go|java|rb|rs)$ ]] && [[ ! "$file" =~ (\.test\.|\.spec\.|__tests__|tests/) ]]; then
    has_code_changes=true
    break
  fi
done <<< "$staged_files"

# Skip if no code changes or unit-tests were run recently
if [[ "$has_code_changes" == "false" ]] || "$STATE_MANAGER" check unit-tests 2>/dev/null; then
  exit 0
fi

# Output warning (not blocking)
cat >&2 <<'EOF'
## ⚠️ Reminder: Run Unit Tests

You're committing code changes but unit tests haven't been run recently.

### Recommended Steps:
1. Run unit tests:
   ```bash
   npm test
   # or
   npm run test:unit
   ```

2. Ensure all tests pass before commit

3. Mark tests as run (optional - auto-cleared after commit):
   ```bash
   .claude/hooks/state-manager.sh mark unit-tests
   ```

### Project Requirements (CLAUDE.md Step 4):
- Unit test coverage >80%
- All tests must pass before commit
- Run tests to verify your changes

**This is a warning - commit will proceed.**
EOF

exit 0
