# Test cases — launcher claude-only contract + example fix

Companion to `docs/designs/launcher-claude-only-contract.md`. All cases live in `tests/unit/test-autonomous-launcher-verdict-fresh.sh`.

## TC-LCH (verdict + launcher) — updated for new contract

| ID | Scenario | Expected | Status |
|----|----------|----------|--------|
| TC-LCH-001 | launcher unset → claude shim invoked with `--session-id`; `LAUNCHER_FOO` env unset | argv contains `--session-id`; env shows `LAUNCHER_FOO=<unset>` | unchanged |
| TC-LCH-002 | launcher `bash -c 'LAUNCHER_FOO=bar exec claude "$@"' --` → claude env contains `LAUNCHER_FOO=bar` and argv contains `--session-id` | both present | rewritten — replaces old `env LAUNCHER_FOO=bar` form |
| TC-LCH-002 anti-regression | argv must NOT contain `-u` or the literal `claude` token under launcher mode | no leak | NEW — guards against the `env -u CLAUDECODE claude` regression this PR fixes |
| TC-LCH-003 | quoted launcher form `bash -c '...' --` → env propagates through bash -c | env shows propagated value | rewritten — uses canonical "exec claude" launcher shape |
| TC-LCH-007 | autonomous-dev.sh exports CC_USER=autonomous-dev-bot | grep finds it | unchanged |
| TC-LCH-008 | autonomous-review.sh exports CC_USER=autonomous-review-bot | grep finds it | unchanged |

## Negative path coverage (already in lib-agent.sh, not separately unit-tested)

| Scenario | Behavior |
|----------|----------|
| `AGENT_LAUNCHER` malformed (parse error) | hard-fail at config load, error message includes original value (TC-PTL-005-style snapshot) |
| `AGENT_LAUNCHER` non-empty, tokenizes to zero argv | WARN, treat as unset |
| `AGENT_LAUNCHER` set + `AGENT_CMD!=claude` | hard-fail at config load with actionable message |

## Manual smoke (post-merge, on consumer machine)

After merging this PR and re-running `npx skills update autonomous-dispatcher` in each downstream project:

1. Confirm next dispatch on a project with `AGENT_LAUNCHER='bash -c '\''source ~/.bash_aliases && cc "$@"'\'' --'` produces a successful claude run. The agent log should show JSONL output, not `error: unknown option '-u'`.
2. Confirm the JSONL `modelUsage` field shows the configured Bedrock model id (e.g. `global.anthropic.claude-opus-4-7`), not `anthropic.claude-haiku-4-5` (the silent-fallback fingerprint).
3. Confirm CloudTrail `AssumeRole` events tagged via cc-creds carry `User=autonomous-dev-bot` / `autonomous-review-bot` and `Project=<project-name>` for autonomous traffic, separable from `User=ubuntu` interactive traffic.

## Why no "test the example value parses" case

The example file is doc, not code. Adding a CI test that grep-extracts AGENT_LAUNCHER from `autonomous.conf.example` and runs it through the lib-agent.sh tokenizer would couple the doc to a specific shape that we may want to evolve. The pitfall comments in the example are the contract; if a future operator copies the canonical form, the lib-agent.sh load-time validators (parse error, claude-only check) will catch their mistakes at runtime.
