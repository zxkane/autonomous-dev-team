# Test Cases: AGENT_DEV_EXTRA_ARGS / AGENT_REVIEW_EXTRA_ARGS passthrough

**Issue**: #140
**Test file**: `tests/unit/test-lib-agent-extra-args.sh`
**Strategy**: stub each CLI binary, capture argv, assert flag composition. Mirrors
`tests/unit/test-lib-agent-gemini.sh` and `tests/unit/test-lib-agent-kiro-permission.sh`.

## Acceptance: every TC below must pass; full unit suite remains green.

| TC ID | Scenario | Expected |
|---|---|---|
| TC-EXTRA-001 | claude `run_agent` with `AGENT_DEV_EXTRA_ARGS="--debug"` | argv contains both `--permission-mode auto` (existing) AND `--debug` (new) |
| TC-EXTRA-002 | gemini `run_agent` with empty `AGENT_DEV_EXTRA_ARGS` | argv does NOT contain `--approval-mode yolo` or `--output-format stream-json` (regression-pin demotion) |
| TC-EXTRA-003 | gemini `run_agent` with `AGENT_DEV_EXTRA_ARGS="--approval-mode yolo --output-format stream-json"` | both flags present in argv; structural `--session-id <uuid>` retained |
| TC-EXTRA-004 | kiro `run_agent` with empty `AGENT_DEV_EXTRA_ARGS` and `AGENT_PERMISSION_MODE=bypassPermissions` | argv does NOT contain `--trust-all-tools` (regression-pin demotion) |
| TC-EXTRA-005 | kiro `run_agent` with `AGENT_DEV_EXTRA_ARGS="--trust-all-tools"` | argv contains `--trust-all-tools`; `--no-interactive`, `--agent`, `chat` retained |
| TC-EXTRA-006 | gemini `resume_agent` with `AGENT_REVIEW_EXTRA_ARGS="--debug"` and `AGENT_DEV_EXTRA_ARGS="--approval-mode yolo"` | resume argv contains `--debug` (review-side var); does NOT contain `--approval-mode yolo` (dev-side var, must not leak) |
| TC-EXTRA-007 | All five CLIs (claude / codex / gemini / kiro / opencode) | structural flags preserved per CLI (`--session-id`, `exec --json`, `run --format json`, `--agent`, `--no-interactive`) — no regression |
| TC-EXTRA-008 | claude with `AGENT_DEV_EXTRA_ARGS='--policy "/path with spaces/policy.json"'` | argv parses to 2 tokens: `--policy` and `/path with spaces/policy.json` |
| TC-EXTRA-009 | All CLIs with empty/unset `AGENT_DEV_EXTRA_ARGS` | argv contains no leftover empty-string elements (clean subprocess invocation) |
| TC-EXTRA-010 | Backward compat: gemini/kiro conf without EXTRA_ARGS | wrapper invocations omit demoted flags entirely (operator MUST migrate per conf.example callout) |

## Static assertions (also part of the test file)

- `lib-agent.sh` no longer contains `--approval-mode yolo` as a hardcoded literal in the gemini case branches (it remains in comments / docstring as historical reference).
- `lib-agent.sh` no longer contains the conditional `if [[ "$AGENT_PERMISSION_MODE" == "bypassPermissions" ]]; then ... --trust-all-tools` block in kiro case branches.
- `lib-agent.sh` references `AGENT_DEV_EXTRA_ARGS` and `AGENT_REVIEW_EXTRA_ARGS` symbols (presence check).

## Smoke tests (post-merge, manual)

These validate the end-to-end migration story for each CLI:

- gemini: `AGENT_CMD=gemini` + `AGENT_DEV_EXTRA_ARGS="--approval-mode yolo --output-format stream-json"` → produces real PR (validates R2'' migration)
- kiro: `AGENT_CMD=kiro` + `AGENT_DEV_EXTRA_ARGS="--trust-all-tools"` → produces real PR (validates R5' migration)
- opencode: `AGENT_CMD=opencode` with empty EXTRA_ARGS → still works (validates R4 backwards compat)
- claude: existing baseline conf works unchanged

## Notes

- `read -ra` handles space-separated tokens but does NOT honor shell quoting around paths
  with spaces. For TC-EXTRA-008 we use the same `eval` tokenization pattern as
  `AGENT_LAUNCHER_ARGV` (lib-agent.sh lines ~75-89). Trust level matches AGENT_LAUNCHER:
  values come from operator-controlled `autonomous.conf`.

- The file's existing `test-lib-agent-gemini.sh` and `test-lib-agent-kiro-permission.sh` are
  updated where they asserted hardcoded `--approval-mode yolo` / `--trust-all-tools`. After
  this PR, those tests assert the demoted shape (no hardcoded flags). The new
  `test-lib-agent-extra-args.sh` covers the conf-driven shape.
