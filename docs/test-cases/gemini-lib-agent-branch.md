# Test cases — gemini case branch in `lib-agent.sh` (#134)

Covers `lib-agent.sh::run_agent` and `resume_agent` gaining a `gemini)`
case so the dispatcher can drive Google Gemini CLI as a first-class
agent rather than the generic `*) <cli> -p <prompt>` fallthrough.

The fallthrough was demonstrated to fail silently in the empirical
multi-CLI test on `zxkane/llm-wiki#6` (2026-05-15): every `run_shell_command`
/ `write_file` tool call was denied by the headless policy engine,
gemini ran 31 minutes, exited 0, and emitted a fluent fabricated
"completion" message — no commits, no PR, no real work.

## Resume strategy decided

**Empirical verification on gemini CLI 0.42.0 confirms `--session-id`
round-trips and `--resume <UUID>` reads back history**:

```text
$ gemini --session-id 6777aebe-d109-4476-8741-bb17795ee89c --output-format stream-json -p "Just say OK"
{"type":"init","timestamp":"...","session_id":"6777aebe-d109-4476-8741-bb17795ee89c","model":"auto-gemini-3"}
{"type":"message","role":"assistant","content":"OK","delta":true}
...

$ gemini --resume 6777aebe-d109-4476-8741-bb17795ee89c -p "What was my previous question?"
{"type":"init","session_id":"6777aebe-d109-4476-8741-bb17795ee89c","model":"auto-gemini-3"}
{"type":"message","role":"assistant","content":"Your previous message was \"Just say OK and nothing else.\""}
```

So gemini is the **claude-style replay model**: pre-mint UUID with
`--session-id`, replay with `--resume <same-UUID>`. **No sidecar
capture is required** — simpler than codex/opencode (which mint
their own session ids and need sidecar persistence). `_gemini_capture_session`
is therefore not implemented; resume_agent reads back the dispatcher's
own session_id directly.

Located in `tests/unit/test-lib-agent-gemini.sh`. Run via:

```bash
bash tests/unit/test-lib-agent-gemini.sh
```

## TC-GEM-001 — `run_agent` invokes gemini with `--approval-mode yolo` (load-bearing)

**Intent**: Pin the load-bearing flag. Without `--approval-mode yolo`,
every `run_shell_command` / `write_file` defaults to `ask_user`, which
is treated as `deny` in non-interactive environments — causing the
silent-fabrication failure mode reproduced in #102. A reflexive
"cleanup" PR that drops this flag re-introduces the bug.

**Setup**:
- Stub `gemini` on PATH that records its argv.
- `AGENT_CMD=gemini`, no model.
- Call `run_agent <session-id> "<prompt>" "" ""`.

**Expected**:
- Recorded argv contains `--approval-mode yolo`.

## TC-GEM-002 — `run_agent` invokes gemini with `--output-format stream-json`

**Intent**: Wrappers' regex-based observability (Session Report
parsers, heartbeat liveness signals) consumes a JSONL event stream;
single-blob `--output-format json` defeats that. Pin `stream-json`.

**Setup**: Same as TC-GEM-001.

**Expected**:
- Recorded argv contains `--output-format stream-json`.

## TC-GEM-003 — `run_agent` passes `--session-id "$session_id"` exactly

**Intent**: Empirical evidence (above) shows the dispatcher's
session_id round-trips via the `init` event and is directly usable
for `--resume`. The exact UUID must reach gemini's argv unchanged.

**Setup**: Same harness, dispatcher-minted UUID
`a1b2c3d4-1111-2222-3333-444444444444`.

**Expected**:
- Recorded argv contains the literal `a1b2c3d4-1111-2222-3333-444444444444`
  immediately after `--session-id`.

## TC-GEM-004 — `run_agent` with `AGENT_DEV_MODEL=gemini-2.5-pro` passes `--model gemini-2.5-pro`

**Intent**: Model overrides from `autonomous.conf` reach the CLI.

**Setup**: `AGENT_CMD=gemini`, call `run_agent <session-id>
"<prompt>" "gemini-2.5-pro" ""`.

**Expected**:
- Recorded argv contains `--model gemini-2.5-pro` (or equivalent
  `--model` / `-m` flag form chosen at implementation time, asserted
  via substring on `gemini-2.5-pro` adjacent to the model flag).

**Note**: per the
[gemini configuration reference](https://geminicli.com/docs/reference/configuration/),
valid model ids are `gemini-3-pro-preview`, `gemini-3-flash-preview`,
`gemini-2.5-pro`, `gemini-2.5-flash`, `gemini-2.5-flash-lite`.
`gemini-3-pro` (without `-preview` suffix) is NOT a valid id.
`autonomous.conf.example` documents this in its `AGENT_DEV_MODEL`
section.

## TC-GEM-005 — `run_agent` with empty `AGENT_DEV_MODEL` does NOT pass `--model`

**Intent**: When the operator hasn't set a model, the CLI should fall
back to its own default (per `~/.gemini/settings.json` or built-in)
rather than us forcing a value. Same `${model:+--model "$model"}`
pattern as the existing claude / codex / opencode branches.

**Setup**: `model=""` (passed as fourth empty positional).

**Expected**:
- Recorded argv contains neither `--model` nor `-m`.

## TC-GEM-006 — `resume_agent` invokes `--resume <session_id>` with the same UUID

**Intent**: The empirical-evidence-driven choice from the issue's
"Open question". Since `--session-id` round-trips, `resume_agent`
can pass the dispatcher's own `session_id` directly to `--resume`
— no sidecar needed.

**Setup**:
- Stub `gemini` recording argv.
- Call `resume_agent <session-id> "<follow-up>" "" ""` with no prior
  `run_agent` (the empirical contract is that gemini accepts
  arbitrary UUIDs even if it has no history yet — the resume path
  effectively replays whatever history it can find).

**Expected**:
- Recorded argv contains `--resume <same-uuid>`.
- Argv contains `--approval-mode yolo` and `--output-format stream-json`
  (regression-pin: resume must keep the load-bearing flags).

## TC-GEM-007 — `resume_agent` with empty `AGENT_DEV_MODEL` does NOT pass `--model`

**Intent**: Symmetry with TC-GEM-005 on the resume side; otherwise a
default-configured deployment would silently force a model id only
on resume invocations.

**Setup**: `model=""` (fourth positional empty), `resume_agent`.

**Expected**:
- Recorded argv contains neither `--model` nor `-m`.

## TC-GEM-008 — capture-filter pass-through preserves tool-denial event sequence (#102 hallucination defense)

**Intent**: Defense in depth against the #102 fabrication failure mode.
Even though no consumer parses gemini's stream-json events today, a
future filter that "cleans up" tool-denial `error` events from the
stdout would hide the very signal a wrapper-level hallucination guard
would need. This regression-pins that whatever capture/passthrough
exists for gemini does NOT swallow `error` events.

**Setup**:
- Stub `gemini` that emits a known JSONL sequence:
  ```json
  {"type":"init","session_id":"...","model":"gemini-2.5-pro"}
  {"type":"tool_use","name":"run_shell_command","args":{"command":"git commit"}}
  {"type":"error","message":"Unauthorized tool call: 'run_shell_command' is not available"}
  {"type":"result","status":"success"}
  ```
- Capture stdout from `run_agent`.

**Expected**:
- Captured stdout contains all four event types verbatim:
  `"type":"init"`, `"type":"tool_use"`, `"type":"error"`, `"type":"result"`.
- Specifically: the `Unauthorized tool call` substring is preserved
  in stdout exactly as emitted.

## Static-analysis pin (TC-GEM-STATIC-001)

`grep` for the literal `gemini)` case label in both `run_agent` and
`resume_agent` so a refactor that accidentally drops the branch fails
the suite immediately. Catches the failure mode where a future PR
moves cases around and an automated rebase silently strips one.

## Out of scope

- `is_session_completed` PTL gate extension for gemini. Per the issue
  body, that belongs to whoever follows #102 with a real PTL fixture.
- E2E reproduction of the original fabrication failure mode against
  a real gemini binary. Empirical verification was performed during
  issue triage (above) and recorded in the PR description; in-suite
  reproduction would require network access and gemini auth, both
  unavailable in CI.
- Wrapper-level hallucination detection (would need to consume the
  stream-json `error` events that TC-GEM-008 pins). Documented as a
  future hook, not implemented here.
