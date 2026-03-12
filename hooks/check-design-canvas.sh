#!/bin/bash
# Pre-implementation hook - reminds to create design canvas before starting new feature
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
STATE_MANAGER="$SCRIPT_DIR/state-manager.sh"

input=$(cat)
command=$(parse_command "$input")

# Only check for git commit commands on feature branches
if ! is_git_command "commit" "$command"; then
  exit 0
fi

# Get current branch
current_branch=$(git branch --show-current 2>/dev/null || echo "")

# Exit early if not in a branch (e.g., detached HEAD)
if [[ -z "$current_branch" ]]; then
  exit 0
fi

# Skip for main/master branches and fix/hotfix branches
if [[ "$current_branch" =~ ^(main|master|fix/|hotfix/) ]]; then
  exit 0
fi

# Skip amend commits
if [[ "$command" =~ --amend ]]; then
  exit 0
fi

# Check if design-canvas state exists
if "$STATE_MANAGER" check design-canvas 2>/dev/null; then
  exit 0
fi

# Check if any design document exists for this feature
# Extract feature name from branch (e.g., feature/user-auth -> user-auth)
feature_name="${current_branch##*/}"
feature_name="${feature_name##feature/}"

project_root=$(get_project_root)
design_dir="$project_root/docs/designs"

# If design document exists, auto-mark as complete
if [[ -d "$design_dir" ]]; then
  shopt -s nullglob
  for design_file in "$design_dir"/*.md; do
    [[ -f "$design_file" ]] || continue
    base_name=$(basename "$design_file" .md)
    if [[ "$base_name" == *"$feature_name"* ]] || [[ "$feature_name" == *"$base_name"* ]]; then
      "$STATE_MANAGER" mark design-canvas "$design_file" 2>/dev/null || true
      exit 0
    fi
  done
fi

# Warn about missing design canvas
cat >&2 <<EOF
## Reminder: Design Canvas (Step 1)

You're committing on feature branch '$current_branch' but no design canvas was found.

### Per CLAUDE.md Step 1, before implementation:
1. **Create design canvas**: \`docs/designs/<feature>.md\`
   - Document the feature architecture
   - Define data flows and API design
   - Include UI mockups if applicable

2. **After creating design**:
   Mark as complete:
   \`\`\`bash
   .claude/hooks/state-manager.sh mark design-canvas
   \`\`\`

### Skip Conditions:
- Bug fix (use fix/ or hotfix/ branch prefix)
- Minor refactoring
- Documentation-only changes

**This is a reminder - commit will proceed.**
EOF

exit 0
