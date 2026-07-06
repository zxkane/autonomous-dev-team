# Supported Agent CLIs

The pipeline spawns dev/review agents through a pluggable abstraction layer
(`scripts/lib-agent.sh` + `adapters/<cli>.sh`). Configure via `AGENT_CMD` in
`scripts/autonomous.conf`.

## Support matrix

| Agent CLI | Command | New Session | Resume | Status |
|-----------|---------|-------------|--------|--------|
| Claude Code | `claude` | `--session-id <UUID>` | `--resume <id>` | Full support |
| Codex CLI | `codex` | `exec --json "<prompt>"` | `exec resume <thread-id>` (captured from JSON stream) | Full support |
| Kiro CLI | `kiro-cli` | `chat --no-interactive [--agent <name>]` | (falls back to new) | Basic support |
| Cursor Agent | `agent` | `-p "<prompt>"` | `--resume=<chat-id>` | Generic fallback (untested explicit branch) |
| Antigravity CLI | `agy` | `-p "<prompt>" --log-file <path>` (conversation UUID grepped from the log) | `--conversation <UUID>` | Full support |
| opencode | `opencode` | `run --format json [PROMPT]` | `run --session <sessionID>` (captured from JSON stream) | Full support † |

The `claude`, `codex`, `agy`, `kiro`, and `opencode` rows have explicit
adapters; the others run through the generic `<cli> -p <prompt>` fallback.
Any CLI not listed should still work if it accepts a `-p <prompt>`
non-interactive flag — the abstraction layer is intentionally permissive.

> **Gemini CLI is retired upstream** and no longer has an adapter row here.
> Antigravity CLI (`agy`) is the replacement for Gemini-family models — it
> ships its own conversation-UUID session model (grepped from `--log-file`,
> not the `--session-id`/`--resume` pair Gemini CLI used) and `--model`
> validation against `agy models` (see the EXTRA_ARGS table below).

## Per-CLI required EXTRA_ARGS (post-#102 / #140)

The #102 multi-CLI test exercised every supported CLI end-to-end. #140 then
collapsed the per-CLI safety flags out of `lib-agent.sh` into operator conf
via `AGENT_DEV_EXTRA_ARGS` / `AGENT_REVIEW_EXTRA_ARGS`. The minimum conf
snippet per CLI:

| AGENT_CMD | E2E verified (#102) | Required EXTRA_ARGS | Why |
|-----------|---------------------|---------------------|-----|
| `claude` | R1 | (none — `--permission-mode` is structural) | claude's tool-trust knob is an existing structural flag |
| `codex` | R3 | (none) | `exec --json` is structural; no operator-tunable trust default |
| `agy` | — | (none — `--dangerously-skip-permissions --print-timeout "$AGENT_TIMEOUT"` are structural, hardcoded in the adapter) | Without `--dangerously-skip-permissions` headless mode blocks on every tool-use prompt (agy's counterpart to kiro's `--trust-all-tools`); `--print-timeout` overrides agy's internal 5m default cap |
| `kiro` | R5 / R5' | `--trust-all-tools` | Stock kiro installs deny every coding tool in `--no-interactive` mode without the trust flag (silent fabrication failure mode) |
| `opencode` | R4 | (none) | `run --format json` is structural; provider/model selector handled via `AGENT_DEV_MODEL` |

The `EXTRA_ARGS` mechanism is operator-tunable (reach for it to add
`--debug`, alternate output formats, etc.). The values above are the
empirically-validated minimum for each CLI to function in autonomous mode.
See `scripts/autonomous.conf.example` for the full per-CLI block.

## † opencode prerequisites

Unlike Claude Code (Anthropic-bound) or Codex CLI (OpenAI-bound), opencode is
provider-agnostic — it has no default model and no built-in credentials.
Before setting `AGENT_CMD=opencode`:

1. **Authenticate a provider.** Run `opencode providers login` once on the
   dispatcher box (or every box that runs the wrapper if
   `EXECUTION_BACKEND=remote-aws-ssm`). Without this, the agent enters a
   session but produces no output and the pipeline silently makes no
   progress.
2. **Set an explicit model.** opencode's `--model` argument expects
   `provider/model` form (e.g. `anthropic/claude-sonnet-4-6`,
   `openai/gpt-5.4`). The wrapper forwards `AGENT_DEV_MODEL` /
   `AGENT_REVIEW_MODEL` from `autonomous.conf`; leave them empty and opencode
   will either error out or wait for interactive selection (which never
   arrives in headless mode). Recommended:
   ```bash
   AGENT_DEV_MODEL="anthropic/claude-sonnet-4-6"
   AGENT_REVIEW_MODEL="anthropic/claude-haiku-4-5"
   ```
3. **`AGENT_PERMISSION_MODE=bypassPermissions` is not yet wired** to
   opencode's `--dangerously-skip-permissions` flag (same gap as the codex
   branch — tracked as a follow-up). For now, run opencode in a sandboxed
   environment where the missing permission flag is acceptable.

## Multiple review agents

By default the wrapper runs one verdict-reaching review agent
(`AGENT_REVIEW_CMD`, default `claude`). Set `AGENT_REVIEW_AGENTS` to a
space-separated CLI list to run several **independent** review agents in
parallel against the same PR and require their agreement before merging:

```bash
AGENT_REVIEW_AGENTS="agy kiro"   # both must PASS for an auto-merge
```

The single review wrapper fans out internally — one parallel subshell per
agent, each with its own session id and log, each ending its verdict comment
with a `Review Agent: <name>` discriminator the wrapper uses to attribute
verdicts. Aggregation rules ([INV-40](pipeline/invariants.md)):

- **Unanimous PASS** — the PR is approved/merged only if **every available
  agent** passed; any single FAIL sends the issue back to `pending-dev`.
- **Warn on partial unavailability** — an agent that produces no verdict
  comment within the poll window (because its CLI failed to launch, or
  launched but stayed silent) is dropped from the vote with a WARN; a FAIL it
  *did* post still counts. The decision is made on the remaining agents.
- **All unavailable → legacy fallback** — if no agent produces a verdict, the
  wrapper falls back to the single-agent FAIL path (`−reviewing
  +pending-dev`), preserving the legacy crash-vs-clean-but-silent
  distinction.

The fan-out is internal to the wrapper: the dispatcher, the `review-<N>.pid`
file, and the `reviewing` label are unchanged, so the rest of the pipeline
sees one review per issue exactly as before.

### Per-agent model / extra-args overrides

By default every fanned-out agent shares `AGENT_REVIEW_MODEL` /
`AGENT_REVIEW_EXTRA_ARGS` ([INV-41](pipeline/invariants.md)). When the listed
CLIs use **incompatible model namespaces** (e.g. kiro wants
`claude-sonnet-4.6` while a claude-family agent wants `sonnet[1m]` — each CLI
rejects the other's id), give an agent its own value via a per-agent key: the
agent name uppercased, every non-alphanumeric char mapped to `_`
(`agy`→`AGY`, `kiro`→`KIRO`, `claude-code`→`CLAUDE_CODE`):

```bash
AGENT_REVIEW_AGENTS="kiro agy"
AGENT_REVIEW_MODEL="sonnet[1m]"               # shared default (agy keeps this)
AGENT_REVIEW_MODEL_KIRO="claude-sonnet-4.6"   # kiro gets its own id
AGENT_REVIEW_EXTRA_ARGS_KIRO="--trust-all-tools"   # kiro-only flag
```

Precedence is per-agent key → shared value → lib default. With no per-agent
key set the behavior is byte-for-byte the shared-value default. See
`scripts/autonomous.conf.example` for the worked example.

> **Distinct from `REVIEW_BOTS`.** `REVIEW_BOTS` triggers *external* review
> bots (`/q review`, `/codex review`, `@claude review` — GitHub lane) whose
> comments the verdict agent reads as **input**. `AGENT_REVIEW_AGENTS` runs N
> **independent verdict-reaching** agents that each reach their own
> approve/pushback decision. The two are orthogonal and can be combined.
