# Design — Wire `AGENT_PERMISSION_MODE=bypassPermissions` to `kiro-cli --trust-all-tools` (#136)

## Problem

`skills/autonomous-dispatcher/scripts/lib-agent.sh` reads `AGENT_PERMISSION_MODE` only in the `claude)` branch (threaded into `--permission-mode "$AGENT_PERMISSION_MODE"`). The `kiro)` branch hardcodes `kiro-cli chat --agent "$KIRO_AGENT_NAME" --no-interactive` with no permission / trust flag at all.

In a stock kiro install (no operator-customized `~/.kiro/agents/<name>.json`), every coding tool (`execute_bash`, `fs_write`, `use_subagent`) is denied in `--no-interactive` mode. kiro then writes a fluent "I cannot proceed…" narrative and exits 0 — the same silent-fabrication failure mode #134 fixed for gemini.

Reproduced empirically against `zxkane/llm-wiki#6` on 2026-05-16 (issue body §"Motivation").

## Fix

Mirror the claude branch: when `AGENT_PERMISSION_MODE=bypassPermissions`, append `--trust-all-tools` to the `kiro-cli chat` invocation. Apply to both `run_agent` and `resume_agent` (kiro has no session model, so resume falls back to a fresh run — but the trust flag still needs to ride along).

### kiro-cli flag (verified against the binary on the dev box)

```text
$ kiro-cli chat --help | head -30
…
  -a, --trust-all-tools
          Allows the model to use any tool to run commands without asking for confirmation
…
```

`-a` / `--trust-all-tools` is the documented escape hatch and matches the operator's daily-driver `kirocli()` shell function (`_proxy_env kiro-cli chat --trust-all-tools "$@"`).

### Why conditional, not always-on

Operators who deliberately ship a restrictive `~/.kiro/agents/<name>.json` (with `allowedTools` set to a curated subset) should be able to keep that posture by setting `AGENT_PERMISSION_MODE=auto` (the default). Always-on `--trust-all-tools` would silently override their intent. Mirror the claude pattern instead: conf knob → CLI flag.

Precedence (documented in the kiro branch comment): CLI flag > agent file. With `--trust-all-tools` set, kiro skips `allowedTools` enforcement; without it, `allowedTools` from the agent file is the authority.

## Implementation sketch

Both branches in `skills/autonomous-dispatcher/scripts/lib-agent.sh`:

```bash
kiro)
  # Tool trust:
  #   * AGENT_PERMISSION_MODE=bypassPermissions  → pass --trust-all-tools
  #   * any other value (auto / plan / unset)    → rely on allowedTools
  #     in ~/.kiro/agents/<KIRO_AGENT_NAME>.json
  # Precedence: CLI flag > agent file. See #136 for the silent-fabrication
  # failure mode on stock kiro installs without this wiring.
  local kiro_args=(
    chat
    --agent "$KIRO_AGENT_NAME"
    --no-interactive
    ${model:+--model "$model"}
  )
  if [[ "$AGENT_PERMISSION_MODE" == "bypassPermissions" ]]; then
    kiro_args+=(--trust-all-tools)
  fi
  kiro_args+=("$prompt")
  _run_with_timeout kiro-cli "${kiro_args[@]}"
  ;;
```

`resume_agent`'s kiro branch already delegates to `run_agent` (kiro has no session resume), so the fix in `run_agent` propagates automatically. The unit-test suite still pins both invocation paths to make refactor regressions loud.

## Top-of-file docstring update

Add a one-liner to the `kiro` row in the per-CLI scope table at the top of `lib-agent.sh`:

```diff
-#   kiro     — no session model; every invocation is a fresh conversation.
-#              resume_agent falls back to run_agent.
+#   kiro     — no session model; every invocation is a fresh conversation.
+#              resume_agent falls back to run_agent. Tool trust is
+#              wired via `--trust-all-tools` when
+#              AGENT_PERMISSION_MODE=bypassPermissions; otherwise the
+#              agent file's allowedTools is the authority (#136).
```

## Out of scope (deliberately deferred)

- **Wrapper-side hallucination guard** — even with `--trust-all-tools`, a future kiro release could re-introduce a deny path. The class-wide defense (assert at least one successful `tool_use` event before accepting exit 0) is a wrapper-level concern, separate issue.
- **Changing `KIRO_AGENT_NAME` default from `autonomous-dev` to `default`** — the issue lists it as optional/low priority. Stock-kiro install ergonomics are improved by changing the default, but it's an orthogonal axis (and could break operators who rely on the current default). Leaving for a follow-up.

## Pipeline doc impact

- `docs/pipeline/state-machine.md` — no change (transitions unaffected).
- `docs/pipeline/invariants.md` — no new INV-NN. The conf-to-CLI wiring is a per-CLI translation detail, not a wrapper invariant.
- `docs/pipeline/dev-agent-flow.md`, `review-agent-flow.md`, `dispatcher-flow.md`, `handoffs.md` — no change (kiro already listed in the actor table).
- `lib-agent.sh` top-of-file scope table — yes, see "Top-of-file docstring update" above. (The scope table lives in the script header, not under `docs/pipeline/`.)

## Testing

`tests/unit/test-lib-agent-kiro-permission.sh` — see `docs/test-cases/kiro-permission-mode-wiring.md` for the full TC-KIR-001..004 list.

Smoke test (manual, recorded in PR description per acceptance criteria): run `autonomous-dev.sh --issue <N> --mode new` with `AGENT_CMD=kiro` and `AGENT_PERMISSION_MODE=bypassPermissions` against a synthetic issue; confirm a real PR is created.
