# Test cases — verdict + launcher + prompt_too_long fallback

Three groups: TC-VRD (Fix 1, verdict detector), TC-LCH (Fix 2, launcher), TC-PTL (Fix 3, prompt_too_long fallback). Each maps to a unit test in `tests/unit/`.

## Setup

All cases run as bash unit tests with no real `claude` / `gh` invocations. We:
- Stub `gh` via a `PATH`-shadowed script that reads canned JSON from `$TMPDIR/gh-fixture-*`.
- Source the wrapper or library under test in a subshell with mocked deps so we exercise the actual code path.
- For verdict cases, drive synthetic `comments` JSON through the wrapper's live regex (extracted from source) so test failures pinpoint regex drift.

## TC-VRD — verdict detection (Fix 1)

Replaces `tests/unit/test-autonomous-review-verdict-regex.sh` cases TC-RVR-009 and TC-RVR-010 (which assert "no/wrong session-id → no-match"). Under the new actor+time-window model those comments DO match if the author and timestamp are right, so we re-test those scenarios for the new model and add new anti-spoof cases.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-VRD-001 | Comment by `BOT_LOGIN`, createdAt=now, body="Review PASSED ..." | `pass` |
| TC-VRD-002 | Comment by `BOT_LOGIN`, createdAt=now, body="APPROVED FOR MERGE ..." | `pass` |
| TC-VRD-003 | Comment by `BOT_LOGIN`, createdAt=now, body="Review findings: ..." | `fail` |
| TC-VRD-004 | Comment by `BOT_LOGIN`, createdAt=now, body has `Review Session: <random-uuid>` (NOT the wrapper's) | `pass` if body keyword passes (anti-regression: agent-minted UUID no longer breaks detection) |
| TC-VRD-005 | Comment by **different** login, createdAt=now, body="Review PASSED" | `no-match` (anti-spoof: foreign actor) |
| TC-VRD-006 | Comment by `BOT_LOGIN`, createdAt=**before** wrapper start, body="Review PASSED" | `no-match` (anti-spoof: stale comment from prior tick) |
| TC-VRD-007 | Both pass + fail keywords in body, BOT_LOGIN actor, in window | `fail` (conservative tie-break unchanged) |
| TC-VRD-008 | `BOT_LOGIN` resolution failed (empty), comment matches by old session-id binding | `pass` (degraded fallback to legacy regex) |
| TC-VRD-009 | `BOT_LOGIN` resolution failed AND comment lacks session-id | `no-match` (legacy fallback engaged, original anti-spoof preserved) |

## TC-LCH — AGENT_LAUNCHER (Fix 2)

Tested by inspecting the actual command lib-agent.sh would invoke (without running it). We capture argv via a `claude` shim that writes its argv to a file and exits 0.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LCH-001 | `AGENT_LAUNCHER` unset; `run_agent` claude branch | argv[0]=`claude`, no launcher prefix |
| TC-LCH-002 | `AGENT_LAUNCHER="env FOO=bar"`; run_agent claude | argv begins with `env FOO=bar claude`; FOO=bar reaches claude's env |
| TC-LCH-003 | `AGENT_LAUNCHER` set; `resume_agent` claude branch | launcher applied to resume too (symmetry) |
| TC-LCH-004 | `AGENT_LAUNCHER` set; `AGENT_CMD=codex` | launcher applied to codex's `exec --json` invocation; `_codex_capture_thread` pipe still receives valid JSONL |
| TC-LCH-005 | `AGENT_LAUNCHER` set; `AGENT_CMD=opencode` | launcher applied; `_opencode_capture_session` pipe still works |
| TC-LCH-006 | `AGENT_LAUNCHER` set; `AGENT_CMD=kiro` | launcher applied to `kiro-cli chat` invocation |
| TC-LCH-007 | autonomous-dev.sh exports `CC_USER=autonomous-dev-bot` and `CC_ROLE_KIND=dev` before run_agent | both env vars visible in claude's env |
| TC-LCH-008 | autonomous-review.sh exports `CC_USER=autonomous-review-bot` and `CC_ROLE_KIND=review` | both env vars visible in claude's env |
| TC-LCH-009 | `AGENT_LAUNCHER` containing single quotes (the canonical `bash -c '...' --` form) parses correctly via eval-once | argv reflects the intended launcher tokens |

## TC-PTL — prompt_too_long fresh fallback (Fix 3)

Tested by feeding synthetic JSONL log files into `is_session_completed` and exercising autonomous-dev.sh's resume→fallback path with a stub claude that exits non-zero on resume.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-PTL-001 | Log ends with `stop_reason=end_turn,terminal_reason=completed` | `is_session_completed` → 0 (existing behavior unchanged) |
| TC-PTL-002 | Log ends with `stop_reason=stop_sequence,terminal_reason=prompt_too_long` | `is_session_completed` → 0 (NEW: treat as terminal) |
| TC-PTL-003 | Log ends with `terminal_reason=api_error` | `is_session_completed` → 1 (api_error is transient — keep retrying) |
| TC-PTL-004 | Log file missing | `is_session_completed` → 1 (unchanged, conservative) |
| TC-PTL-005 | autonomous-dev.sh MODE=resume, stub claude exits non-zero | fallback path mints NEW_SESSION_ID, posts standalone `Dev Session ID: \`${NEW_SESSION_ID}\`` comment to issue, then runs new session |
| TC-PTL-006 | dispatcher-tick.sh detects prompt_too_long via is_session_completed | Posts handoff comment with marker `INV-12-prompt-too-long:<sid>`, sets label → `pending-dev` (so next tick runs a fresh session, not stuck waiting for human) |
| TC-PTL-007 | Same issue, second tick after PTL handoff | fresh session minted, new `Dev Session ID:` posted (extracted by `extract_dev_session_id`'s `last`); old PTL session not resumed |

## Negative cases (cross-cutting)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-NEG-001 | `AGENT_LAUNCHER` set to a nonexistent command | wrapper fails fast at run_agent invocation; existing trap-on-exit posts startup-failure report |
| TC-NEG-002 | `gh api user` rate-limited at wrapper start | `BOT_LOGIN` empty; verdict detector falls back to legacy session-id binding (TC-VRD-008/009 path) |
| TC-NEG-003 | Concurrent dev and review wrappers on same issue (existing concurrency model) | each wrapper's verdict detector uses its own `WRAPPER_START_TS`, so reads only its own bot's recent comments |

## Manual smoke (post-merge, on consumer machine)

Not part of CI — to be run by the user on their `podcast-curation` host once the dispatcher picks up the merged change:

1. Confirm `AGENT_LAUNCHER` set in their `autonomous.conf` causes `cc` env (`CLAUDE_CODE_USE_BEDROCK=1`, etc.) to flow into the wrapper. Verify by checking the next dispatch's `/tmp/agent-*-issue-N.log` JSONL `modelUsage` field — should now show `global.anthropic.claude-opus-4-7` instead of `anthropic.claude-haiku-4-5`.
2. Confirm `CC_USER=autonomous-dev-bot` / `autonomous-review-bot` shows up in their telemetry attribution.
3. Confirm a stuck issue with the dev↔review loop converges to `approved` after one full cycle (review's verdict detector now matches by actor+time, agent's self-minted session UUID no longer breaks detection).
