#!/bin/bash
# Pre-command hook - warns when using --no-verify to skip verification hooks
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

input=$(cat)
command=$(parse_command "$input")

# Check if command contains --no-verify with git push or commit
if [[ ! "$command" =~ git[[:space:]]+(push|commit).*--no-verify ]] && \
   [[ ! "$command" =~ git[[:space:]]+(push|commit).* -n([[:space:]]|$) ]]; then
  exit 0
fi

# Output warning (non-blocking)
cat >&2 <<'EOF'
## Warning: Skipping Verification Detected

You're using `--no-verify` which skips pre-commit/pre-push hooks.

**This project requires (per CLAUDE.md):**
- All commits pass code-simplifier review
- All pushes pass pr-review review
- CI must pass before declaring task complete
- E2E tests must be run on preview environment

**Acceptable use cases:**
- Fixing a CI issue that the hook itself is causing
- Emergency hotfix (must still verify manually afterward)
- Documentation-only changes

**If skipping intentionally:**
1. Document why in the commit message
2. Ensure manual verification is done
3. Consider re-running the skipped checks after

**Proceeding with command...**
EOF

exit 0
