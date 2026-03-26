#!/bin/bash
# PreToolUse hook - runs shellcheck on staged .sh files before commit
# Blocks commit if error-level findings exist; warns if shellcheck not installed
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

input=$(cat)
command=$(parse_command "$input")

# Only check git commit commands
if ! is_git_command "commit" "$command"; then
  exit 0
fi

# Skip amends (code was already checked)
if [[ "$command" =~ --amend ]]; then
  exit 0
fi

# Find staged .sh files (Added, Copied, Modified only — skip Deleted)
staged_sh_files=$(git diff --cached --name-only --diff-filter=ACM -- '*.sh' 2>/dev/null || true)

# No staged shell scripts — nothing to check
if [[ -z "$staged_sh_files" ]]; then
  exit 0
fi

# Graceful degradation: warn if shellcheck is not installed
if ! command -v shellcheck &>/dev/null; then
  cat >&2 <<'EOF'
## Warning: shellcheck not installed

Staged `.sh` files were not checked for shell scripting errors.
Install shellcheck for automatic linting: https://github.com/koalaman/shellcheck#installing

**Proceeding with commit...**
EOF
  exit 0
fi

# Run shellcheck on each staged file, collect failures
has_errors=false
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  [[ ! -f "$file" ]] && continue
  if ! shellcheck --severity=error "$file" >&2; then
    has_errors=true
  fi
done <<< "$staged_sh_files"

if [[ "$has_errors" == "true" ]]; then
  cat >&2 <<'EOF'

## BLOCKED - ShellCheck errors found

Fix the error-level findings above before committing. Common fixes:

| Code | Fix |
|------|-----|
| SC2086 | Quote variables: `"$var"` instead of `$var` |
| SC2046 | Quote command substitution: `"$(cmd)"` instead of `$(cmd)` |
| SC2155 | Declare and assign separately: `local var; var=$(cmd)` |

Run `shellcheck --severity=error <file>` to re-check after fixing.
EOF
  exit 2
fi

exit 0
