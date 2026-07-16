#!/bin/bash
# Pre-implementation hook - reminds to create test plan before writing new implementation code
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
STATE_MANAGER="$SCRIPT_DIR/state-manager.sh"

input=$(read_hook_stdin)
if ! edit_operations=$(parse_edit_file_operations "$input"); then
  echo "Warning: could not inspect this edit payload; test-plan reminder skipped because this hook is advisory." >&2
  exit 0
fi

# Skip non-edit tools.
if [[ -z "$edit_operations" ]]; then
  exit 0
fi

# Define patterns for implementation files (customize based on your project)
# Default: TypeScript/JavaScript files in src/ directory
IMPL_PATTERN='src/.*\.(ts|tsx|js|jsx)$'

# Skip every path if the test plan is already marked.
if "$STATE_MANAGER" check test-plan 2>/dev/null; then
  exit 0
fi

# Only creation operations can require a test plan. Updates, deletes, and move
# destinations may name paths that do not exist yet without creating new code.
# Patch paths are normally worktree-relative; Claude may provide an absolute
# path.
worktree_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
needs_test_plan=false
while IFS=$'\t' read -r operation file_path; do
  [[ "$operation" == "add" && -n "$file_path" ]] || continue

  [[ "$file_path" =~ $IMPL_PATTERN ]] || continue
  [[ "$file_path" =~ (__tests__|\.test\.|\.spec\.|tests/) ]] && continue
  [[ "$file_path" =~ (\.config\.|\.d\.ts$) ]] && continue

  if [[ "$file_path" == /* ]]; then
    [[ -f "$file_path" ]] && continue
  elif [[ -f "$worktree_root/$file_path" ]]; then
    continue
  fi

  needs_test_plan=true
  break
done <<< "$edit_operations"

[[ "$needs_test_plan" == "true" ]] || exit 0

cat >&2 <<'EOF'
## Reminder: Test Plan First (TDD Workflow)

You're creating a new implementation file. The project workflow requires:

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
hooks/state-manager.sh mark test-plan
```

### Skip Conditions:
- Bug fix in existing code (no new feature)
- Configuration changes
- Documentation-only changes
- Utility/helper functions

**This is a reminder to follow TDD - proceeding with implementation.**
EOF

exit 0
