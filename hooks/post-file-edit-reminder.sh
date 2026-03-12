#!/bin/bash
# Post file edit hook - reminds to run tests after modifying source code
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

input=$(cat)
file_path=$(parse_file_path "$input")

# Skip if no file path
if [[ -z "$file_path" ]]; then
  exit 0
fi

# Check if it's a source code file (adjust patterns as needed)
if [[ ! "$file_path" =~ \.(ts|tsx|js|jsx|py|go|java|rb|rs)$ ]]; then
  exit 0
fi

# Skip test files
if [[ "$file_path" =~ (\.test\.|\.spec\.|__tests__|tests/|_test\.|_spec\.) ]]; then
  exit 0
fi

# Skip config and declaration files
if [[ "$file_path" =~ (\.config\.|\.d\.ts$|\.json$|\.yaml$|\.yml$) ]]; then
  exit 0
fi

# Output reminder as JSON for Claude
cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "## 📝 Code Change Reminder\n\nYou've modified a source file. Remember the project's verification workflow:\n\n1. **Run unit tests** after making changes:\n   ```bash\n   npm test\n   ```\n\n2. **Run type check** to catch type errors:\n   ```bash\n   npm run typecheck\n   ```\n\n3. **Before committing**, ensure:\n   - code-simplifier agent has reviewed the changes\n   - All tests pass\n   - No linting errors\n\n4. **Before pushing**, ensure:\n   - pr-review agent has reviewed the code\n\nThis is a reminder only - continue with your work."
  }
}
EOF

exit 0
