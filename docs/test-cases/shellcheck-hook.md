# Test Cases: ShellCheck Pre-Commit Hook

**Feature:** check-shellcheck.sh
**Issue:** #35

## Test Scenarios

### TC-SC-001: Non-commit command passes through
- **Input:** `git push origin main`
- **Expected:** Exit 0 (pass through, no check)

### TC-SC-002: Amend commit is skipped
- **Input:** `git commit --amend`
- **Expected:** Exit 0 (skip, code already checked)

### TC-SC-003: No staged .sh files
- **Input:** `git commit -m "update readme"` with only `.md` files staged
- **Expected:** Exit 0 (nothing to check)

### TC-SC-004: Staged .sh file with shellcheck errors
- **Input:** `git commit -m "add script"` with a staged `.sh` file containing SC2086 (unquoted variable)
- **Expected:** Exit 2 (block commit), stderr shows findings

### TC-SC-005: Staged .sh file with no errors
- **Input:** `git commit -m "add script"` with a clean `.sh` file staged
- **Expected:** Exit 0 (pass)

### TC-SC-006: shellcheck not installed
- **Input:** `git commit -m "add script"` with `.sh` files staged, but `shellcheck` binary not on PATH
- **Expected:** Exit 0 (warn on stderr, allow commit)

### TC-SC-007: Mixed staged files (some .sh, some not)
- **Input:** `git commit -m "update"` with `.md` and `.sh` files staged; `.sh` file is clean
- **Expected:** Exit 0 (only checks .sh files, passes)

### TC-SC-008: Multiple .sh files, one has errors
- **Input:** `git commit -m "update"` with two `.sh` files staged; one clean, one with errors
- **Expected:** Exit 2 (block), stderr shows findings for the bad file

### TC-SC-009: Hook passes shellcheck itself
- **Input:** Run `shellcheck --severity=error check-shellcheck.sh`
- **Expected:** Exit 0 (no findings)

### TC-SC-010: Deleted .sh files are not checked
- **Input:** `git commit -m "remove script"` with a `.sh` file deleted (git status shows D)
- **Expected:** Exit 0 (deleted files skipped via --diff-filter=ACM)
