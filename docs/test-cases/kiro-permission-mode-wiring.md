# Test cases — `lib-agent.sh` kiro permission-mode wiring (#136)

Covers `lib-agent.sh::run_agent` and `resume_agent` learning to thread `AGENT_PERMISSION_MODE=bypassPermissions` into `kiro-cli chat --trust-all-tools`. Mirrors the gemini analog (#134, `docs/test-cases/gemini-lib-agent-branch.md`) and locks in the documented "kiro auto-trust ON when bypassPermissions" wiring against future regression that strips the flag.

## Failure mode this prevents

Per the #102 R5 reproducer (`zxkane/llm-wiki#6`, 2026-05-16):

1. Dispatcher invokes the wrapper with `AGENT_CMD=kiro` and `AGENT_PERMISSION_MODE=bypassPermissions`.
2. `lib-agent.sh` ignores `AGENT_PERMISSION_MODE` for the kiro branch and passes only `--agent <name> --no-interactive`.
3. Kiro's headless policy denies every coding tool:

   ```text
   Command execute_bash is rejected because it matches one or more rules on the denied list:
     - non-interactive mode (no user to approve)
   ```

4. Kiro emits a fluent fabricated "completion" message and exits 0.
5. Wrapper trap sees exit 0 + no PR → `pending-dev` retry, repeats indefinitely.

After this PR: `--trust-all-tools` is appended whenever `AGENT_PERMISSION_MODE=bypassPermissions`, restoring tool access on stock kiro installs without forcing operators to hand-author `allowedTools` agent files.

## Located in

`tests/unit/test-lib-agent-kiro-permission.sh`. Run via:

```bash
bash tests/unit/test-lib-agent-kiro-permission.sh
```

## TC-KIR-001 — `run_agent` with `AGENT_PERMISSION_MODE=bypassPermissions` passes `--trust-all-tools`

**Intent**: Pin the conf-to-CLI wiring. This is the load-bearing fix: without it, kiro's headless policy denies every coding tool and the wrapper observes a fabricated success.

**Setup**:
- Stub `kiro-cli` on PATH that records its argv to a recorder file.
- `AGENT_CMD=kiro`, `AGENT_PERMISSION_MODE=bypassPermissions`, no model.
- Call `run_agent <session-id> "<prompt>" "" ""`.

**Expected**:
- Recorded argv contains `--trust-all-tools` (or the `-a` short form, asserted via either-or substring match).

## TC-KIR-002 — `run_agent` with `AGENT_PERMISSION_MODE=auto` does NOT pass `--trust-all-tools`

**Intent**: Preserve the restrictive default. Operators who deliberately ship a tightly-scoped `~/.kiro/agents/<name>.json` should be able to keep that posture by leaving `AGENT_PERMISSION_MODE` at its default (`auto`). Always-on `--trust-all-tools` would silently override their intent.

**Setup**:
- Same harness as TC-KIR-001.
- `AGENT_PERMISSION_MODE=auto` (the lib's default).

**Expected**:
- Recorded argv does NOT contain `--trust-all-tools`.
- Recorded argv does NOT contain the `-a` short flag (defensive — rule out alternative spellings).

## TC-KIR-003 — `resume_agent` mirrors `run_agent`

**Intent**: kiro has no session model — `resume_agent` falls back to a fresh conversation. The trust flag must still ride along, otherwise operators who hit the resume path (review-driven dev re-runs, retry on transient failure) would suddenly lose tool access mid-pipeline.

**Setup**:
- Stub `kiro-cli` recording argv.
- `AGENT_CMD=kiro`, `AGENT_PERMISSION_MODE=bypassPermissions`.
- Call `resume_agent <session-id> "<follow-up prompt>" "" ""`.

**Expected**:
- Recorded argv contains `--trust-all-tools` (or `-a`).
- Recorded argv contains the follow-up prompt verbatim (sanity check that the resume path actually invoked the stub).

## TC-KIR-004 — model flag still threads correctly when both knobs are set

**Intent**: Regression-pin against an over-eager refactor that swaps the argv-construction order and accidentally drops `--model` when `--trust-all-tools` is appended. Mirrors TC-GEM-004 in spirit.

**Setup**:
- `AGENT_CMD=kiro`, `AGENT_PERMISSION_MODE=bypassPermissions`.
- Call `run_agent <session-id> "<prompt>" "claude-sonnet-4-6" ""`.

**Expected**:
- Recorded argv contains `--model claude-sonnet-4-6`.
- Recorded argv contains `--trust-all-tools`.
- Recorded argv contains `--agent <KIRO_AGENT_NAME>` and `--no-interactive` (existing flags survive).

## Static-analysis pin (TC-KIR-STATIC-001)

`grep` for the literal `kiro)` case label in both `run_agent` and `resume_agent` so a refactor that accidentally drops the branch fails the suite immediately. Same pattern as TC-GEM-STATIC-001.

## Out of scope

- **Wrapper-side hallucination guard** — even with `--trust-all-tools`, a future kiro release could re-introduce a deny path. Defense against that is a wrapper-level concern (assert at least one successful `tool_use` event before accepting exit 0), separate issue.
- **E2E reproduction against real kiro-cli with a tool-denying policy** — the empirical reproducer was recorded during issue triage (#102 R5 round). In-suite reproduction would require a live kiro environment with denied tools, unavailable in CI.
- **Changing `KIRO_AGENT_NAME` default to `default`** — orthogonal axis, deferred per the issue body's "optional, can skip for this PR" note.
