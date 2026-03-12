#!/bin/bash
# Pre-implementation hook - reminds to create test plan before writing new implementation code
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
STATE_MANAGER="$SCRIPT_DIR/state-manager.sh"

input=$(cat)
file_path=$(parse_file_path "$input")

# Skip if no file path
if [[ -z "$file_path" ]]; then
  exit 0
fi

# Define patterns for implementation files (customize based on your project)
# Default: TypeScript/JavaScript files in src/ directory
IMPL_PATTERN='src/.*\.(ts|tsx|js|jsx)$'

# Skip if not an implementation file
if [[ ! "$file_path" =~ $IMPL_PATTERN ]]; then
  exit 0
fi

# Skip test files
if [[ "$file_path" =~ (__tests__|\.test\.|\.spec\.|tests/) ]]; then
  exit 0
fi

# Skip config files
if [[ "$file_path" =~ (\.config\.|\.d\.ts$) ]]; then
  exit 0
fi

# Skip if test-plan state exists or file already exists (editing existing code)
if "$STATE_MANAGER" check test-plan 2>/dev/null || [[ -f "$file_path" ]]; then
  exit 0
fi

# Warn about test plan for new file creation
cat >&2 <<'EOF'
## Reminder: Test Plan First (TDD Workflow)

You're creating a new implementation file. Per CLAUDE.md Step 2, the test-driven workflow requires:

### Before Writing Implementation:
1. **Create test case document**: `docs/test-cases/<feature>.md`
   - List all test scenarios (normal flows, edge cases, errors)
   - Assign test IDs (e.g., TC-AUTH-001)
   - Define expected results and acceptance criteria

2. **Create test skeleton files**:
   - Unit tests: `tests/unit/<feature>.test.ts`
   - E2E tests: `tests/e2e/<feature>.spec.ts` (if applicable)

### After Test Plan Created:
Mark as complete:
```bash
.claude/hooks/state-manager.sh mark test-plan
```

### Skip Conditions:
- Bug fix in existing code (no new feature)
- Configuration changes
- Documentation-only changes
- Utility/helper functions

**This is a reminder to follow TDD - proceeding with implementation.**
EOF

exit 0
