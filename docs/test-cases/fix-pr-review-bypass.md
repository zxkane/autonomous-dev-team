# Test Cases: Fix check-pr-review Bypass and is_git_command Substring

**Date:** 2026-04-25
**Issue:** #48
**Feature:** fix-pr-review-bypass

## Test IDs and Scenarios

### TC-PRB-001: `check pr-review` passes when HEAD matches marked SHA

- Mark `pr-review` at HEAD `A`.
- Immediately call `check pr-review`.
- Expect: exit 0 (PASS), no error output.

### TC-PRB-002: `check pr-review` fails when HEAD advances past marked SHA

- Mark `pr-review` at HEAD `A`.
- Create a new commit (HEAD becomes `B`).
- Call `check pr-review`.
- Expect: exit 1 (FAIL). State file deleted so a fresh mark is required.

### TC-PRB-003: `check pr-review` fails when state file older than 30 min

- Mark `pr-review` at HEAD `A` with a manually backdated timestamp (>30m old).
- HEAD still at `A`.
- Call `check pr-review`.
- Expect: exit 1. Timestamp guard still enforced as secondary check.

### TC-PRB-004: Non-pr-review actions remain time-based only

- Mark `code-simplifier`; move HEAD to new commit.
- Call `check code-simplifier`.
- Expect: exit 0 (still valid — SHA binding is pr-review only).

### TC-PRB-005: `check pr-review` when state file missing

- No mark has been set.
- Call `check pr-review`.
- Expect: exit 1.

### TC-PRB-006: `check pr-review` with state file missing `git_head`

- Mark is written without a git repository (git_head == "unknown").
- Call `check pr-review` inside a repo.
- Expect: exit 1 (treat "unknown" as stale).

### TC-IGC-001: `is_git_command push` matches plain `git push`

- Command: `git push`
- Expect: match (exit 0).

### TC-IGC-002: `is_git_command push` matches `git push origin main`

- Command: `git push origin main`
- Expect: match.

### TC-IGC-003: `is_git_command push` matches with global flag

- Command: `git -c user.email=x@y.z push`
- Expect: match.

### TC-IGC-004: `is_git_command push` does NOT match `git log`

- Command: `git log`
- Expect: no match (exit 1).

### TC-IGC-005: `is_git_command push` does NOT match substring inside quotes

- Command: `gh issue create --body "see git push docs"`
- Expect: no match.

### TC-IGC-006: `is_git_command push` does NOT match `echo "git push"`

- Command: `echo "git push"`
- Expect: no match.

### TC-IGC-007: `is_git_command commit` matches after `&&`

- Command: `cd /tmp && git commit -m "x"`
- Expect: match.

### TC-IGC-008: `is_git_command push` does NOT match `git push-subcmd`

- Command: `git push-something`
- Expect: no match (operation must be a complete token).

## Acceptance Criteria

- All 14 test cases pass under `bash tests/unit/test-pr-review-bypass.sh`
  and `bash tests/unit/test-is-git-command.sh`.
- Existing hook tests (cleanup-pr-check, retry-counter-reset, etc.)
  continue to pass.
- `shellcheck` clean on modified scripts.
