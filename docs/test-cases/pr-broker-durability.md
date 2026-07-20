# Test Cases: PR-create broker durability + recovery (issue #519)

Covers the INV-79 brokered PR-create path after the #519 fix: durable request
location (D1), loud scoped-run diagnostics (D2), and the strict single-branch
recovery fallback (D3).

Unit suite: `tests/unit/test-pr-broker-durability.sh`
E2E fixture: `tests/e2e/run-pr-broker-durability-e2e.sh`

## D1 — durable request location

| ID | Scenario | Expected |
|----|----------|----------|
| TC-PRBROKER-001 | Wrapper provisioning with `RUN_DIR` set | `AGENT_PR_CREATE_FILE=${RUN_DIR}/agent-pr-create`, pre-created empty, mode `0600` |
| TC-PRBROKER-002 | Wrapper provisioning without `RUN_DIR` | private `mktemp /tmp/agent-pr-create-<issue>-XXXXXX` fallback, mode `0600` |
| TC-PRBROKER-003 | Regression: `GH_WRAPPER_DIR` deleted after the agent writes the request, before the drain | request survives (it never lived in `GH_WRAPPER_DIR`); drain consumes it and records exactly one PR-create provider call |
| TC-PRBROKER-004 | Drain succeeds | request file is NOT deleted (retained until INV-81 `RUN_RETENTION_DAYS` pruning) |

## D2 — loud diagnostics (scoped runs only)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-PRBROKER-010 | Unscoped run (`AGENT_GH_TOKEN_FILE` empty), any file state | silent `return 0`, no WARN, no create |
| TC-PRBROKER-011 | Scoped + existing PR + missing request | silent `return 0` (existing-PR check runs FIRST; missing request is harmless) |
| TC-PRBROKER-012 | Scoped + zero-match + `AGENT_PR_CREATE_FILE` unset | WARN contains `path=<unset> exists=no size=unknown` |
| TC-PRBROKER-013 | Scoped + zero-match + file absent | WARN contains `path=<path> exists=no size=unknown` |
| TC-PRBROKER-014 | Scoped + zero-match + file present but empty | WARN contains `path=<path> exists=yes size=0` |
| TC-PRBROKER-015 | Any diagnostic | never includes request body content or credential material |

## D3 — single-branch recovery fallback

| ID | Scenario | Expected |
|----|----------|----------|
| TC-PRBROKER-020 | Missing request + exactly one boundary-valid `issue-<N>` branch strictly ahead of `${BASE_BRANCH}` | exactly one `chp_create_pr` with that head; title = 3rd drain argument; body = `Closes #<N>` + fixed recovery note with no other numeric `#` reference |
| TC-PRBROKER-021 | Missing request + two candidate branches | no create; WARN lists candidate count |
| TC-PRBROKER-022 | Issue 12, only branch `feat/issue-123-x` pushed | boundary filter rejects it — zero candidates, no create |
| TC-PRBROKER-023 | Candidate diverged from base (not ancestor) | no create (ancestry REQUIRED; no SHA-inequality fallback) |
| TC-PRBROKER-024 | Candidate equal to base (zero commits ahead) | no create |
| TC-PRBROKER-025 | `chp_pr_list` UNKNOWN (read fails) + missing request + valid candidate | no recovery create; WARN (never-duplicate outranks fail-soft) |
| TC-PRBROKER-026 | `chp_pr_list` UNKNOWN + VALID request file (normal path) | create still fires (pre-existing fail-soft preserved) |
| TC-PRBROKER-027 | Malformed non-empty request (empty title) | WARN, NO recovery create (recovery only for unset/missing/zero-byte) |
| TC-PRBROKER-028 | Normal create fails | no recovery second create |
| TC-PRBROKER-029 | Configured non-`main` `BASE_BRANCH` | recovery validates against that branch |
| TC-PRBROKER-030 | Drain called without 3rd arg (title unavailable) | recovery uses deterministic fallback title, still exactly one create |

## E2E (wrapper fixture)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-PRBROKER-040 | Clean agent exit; auth dir (`GH_WRAPPER_DIR`) deleted mid-cleanup before drain | exactly one PR created; wrapper reaches `pending-review`; no extra dev retry consumed |
