# Antigravity CLI (`agy`) — Agent Backend Support

Spec for adding **Antigravity 2.0 CLI** (binary name `agy`, Google's
successor to / replacement for the Gemini CLI in the autonomous
pipeline) as a supported value of `AGENT_CMD` in
`skills/autonomous-dispatcher/scripts/lib-agent.sh`.

This doc is the authoritative contract for the `agy` branch in
`run_agent` / `resume_agent`. Verified against **agy 1.0.2** (May 2026).

Related: [`dev-agent-flow.md`](dev-agent-flow.md) (consumer of
`run_agent` / `resume_agent`), [`invariants.md`](invariants.md)
([INV-13], [INV-34]) for the cross-cutting rules this branch upholds.

## CLI shape (verified, agy 1.0.2)

`agy` ships a small surface area compared to the other supported CLIs.
Probed via `agy --help` and a live `-p` invocation:

| Flag | Role |
|------|------|
| `-p` / `--print` / `--prompt` | Headless single-prompt mode. With no positional, reads prompt from **stdin**. |
| `--print-timeout <duration>` | Internal cap on print-mode wait. **Default 5m** — far below our `AGENT_TIMEOUT` (default 4h), so we MUST override. |
| `--continue` / `-c` | Resume the **most recent** conversation. Not concurrency-safe — discarded. |
| `--conversation <UUID>` | Resume a specific conversation by ID. The deterministic resume primitive. |
| `--dangerously-skip-permissions` | Auto-approve all tool permission requests. **Load-bearing** for headless tool execution; without it, every tool call denies and the agent silently fabricates results (same failure mode that gemini's `--approval-mode yolo` and kiro's `--trust-all-tools` fix). |
| `--log-file <path>` | Override CLI log file path. **The only programmatic channel for the conversation UUID** — agy does not emit a JSON event stream and does not print the UUID on stdout. |
| `--add-dir`, `--sandbox`, `--prompt-interactive` (`-i`) | Not used by the wrapper. |

**Crucial absences** (vs. peer CLIs):

- No `--session-id <UUID>` for caller-minted IDs (vs. claude / gemini).
- No `--model` flag — model selection is configured in
  `~/.gemini/antigravity-cli/settings.json`. `AGENT_DEV_MODEL` /
  `AGENT_REVIEW_MODEL` cannot be honored on the CLI side.
- No JSON event stream output (vs. codex `--json`, opencode `--format
  json`, gemini `--output-format stream-json`). The conversation UUID
  is emitted only to the log file.

## Session model — sidecar pattern (mirrors codex / opencode)

agy mints conversation UUIDs **internally**. The dispatcher's
`session_id` cannot be used as the conversation id directly. The
wrapper must capture the UUID after each `run_agent` and persist it
keyed by `session_id`, then feed it back on `resume_agent`.

This is the same shape used by codex (`thread.started` JSON event) and
opencode (`sessionID` field on every event). The only difference is the
**capture channel**: agy publishes the UUID to its log file, not to
stdout.

```
run_agent (session_id S)
  ├─ pid_dir/agy-log-<S>.log    ← --log-file directs agy here
  ├─ agy mints conversation UUID U
  ├─ writes "Print mode: conversation=U" to log
  ├─ run finishes
  └─ post-step: grep log → write pid_dir/agy-conversation-<S> = U

resume_agent (session_id S)
  ├─ read pid_dir/agy-conversation-<S> → U
  ├─ agy --conversation U -p ...
  └─ continues conversation U with new prompt
```

If the sidecar is missing (log line not emitted, agy upgrade changed
the format, sidecar pruned between dispatches), `resume_agent` falls
back to a fresh `run_agent` — same defensive pattern as codex and
opencode. The fallback is degraded (loses conversation continuity) but
non-fatal — the next `run_agent` re-establishes a sidecar.

## `run_agent` contract — agy branch

```bash
agy)
  # WARN once if model passed (agy doesn't accept --model). Continue.
  if [[ -n "$model" && -z "${_LIB_AGENT_AGY_MODEL_WARNED:-}" ]]; then
    echo "[lib-agent] WARN: AGENT_CMD=agy does not support --model flag; ignoring AGENT_DEV_MODEL=${model}. Configure model via ~/.gemini/antigravity-cli/settings.json instead." >&2
    export _LIB_AGENT_AGY_MODEL_WARNED=1
  fi

  local agy_log
  agy_log=$(_agy_log_file "$session_id") || return 1

  printf '%s' "$prompt" \
    | _run_with_timeout "$AGENT_CMD" \
        -p \
        --dangerously-skip-permissions \
        --print-timeout "$AGENT_TIMEOUT" \
        --log-file "$agy_log" \
        "${extra_args[@]}"
  local rc=$?

  _agy_capture_conversation "$session_id" "$agy_log"

  return $rc
  ;;
```

Why each flag is structural (not operator-tunable, not in
`AGENT_DEV_EXTRA_ARGS`):

- `-p` — invocation mode. Without it agy enters interactive TUI and
  the wrapper hangs forever.
- `--dangerously-skip-permissions` — without it, every tool call
  denies in headless mode. Same load-bearing role as kiro's
  `--trust-all-tools` (see [INV-31] for the rationale on what counts
  as structural vs. operator-tunable).
- `--print-timeout "$AGENT_TIMEOUT"` — agy's internal default is 5
  minutes. Leaving it unset means every wrapper run dies in 5m
  regardless of the outer `AGENT_TIMEOUT`. Pass-through ensures the
  outer wall-clock is the dominant cap, with `_run_with_timeout`'s
  SIGKILL escalation as the hard ceiling 30s after.
- `--log-file "$agy_log"` — the only channel for the conversation
  UUID. Cannot be defaulted to a shared path (would race across
  concurrent issues) or to a discarded path (would lose resume
  capability).

Operator-tunable additions go in `AGENT_DEV_EXTRA_ARGS` /
`AGENT_REVIEW_EXTRA_ARGS` per [INV-31], appended via `extra_args[@]`.

## `resume_agent` contract — agy branch

```bash
agy)
  local _agy_cid
  if _agy_cid=$(_agy_conversation_id "$session_id"); then
    local agy_log
    agy_log=$(_agy_log_file "$session_id") || return 1
    printf '%s' "$prompt" \
      | _run_with_timeout "$AGENT_CMD" \
          --conversation "$_agy_cid" \
          -p \
          --dangerously-skip-permissions \
          --print-timeout "$AGENT_TIMEOUT" \
          --log-file "$agy_log" \
          "${extra_args[@]}"
    local rc=$?
    _agy_capture_conversation "$session_id" "$agy_log"
    return $rc
  else
    echo "[lib-agent] no captured agy conversation_id for session $session_id; starting a new agy session" >&2
    run_agent "$session_id" "$prompt" "$model" "$session_name"
  fi
  ;;
```

`_agy_capture_conversation` re-runs after resume as a self-healing
step: under normal operation the captured UUID equals `_agy_cid` (agy
keeps the conversation id on `--conversation <id>` resume), so the
write is a no-op overwrite. If a future agy version ever rotates the
id on resume, the sidecar tracks the live one without a code change.

The fallback branch reuses `run_agent` (not `_LIB_AGENT_GENERIC_WARNED`
or a separate code path) so the new-session policy stays in one place.

## Helper trio

Drop-in mirrors of `_codex_thread_file` / `_codex_capture_thread` /
`_codex_thread_id`, with two differences: (1) two paths instead of
one (log file + conversation sidecar), (2) capture channel is `grep
log_file` instead of `awk JSON stream`.

```bash
_agy_log_file() {
  local session_id="$1" pid_dir
  pid_dir=$(pid_dir_for_project) || return 1
  printf '%s/agy-log-%s.log\n' "$pid_dir" "$session_id"
}

_agy_conversation_file() {
  local session_id="$1" pid_dir
  pid_dir=$(pid_dir_for_project) || return 1
  printf '%s/agy-conversation-%s\n' "$pid_dir" "$session_id"
}

_agy_capture_conversation() {
  local session_id="$1" log_file="$2" conv_file uuid
  conv_file=$(_agy_conversation_file "$session_id") || return 0
  [[ -f "$log_file" ]] || return 0
  # Anchor the capture to canonical RFC-4122 UUID shape (8-4-4-4-12)
  # so a future agy log-format change cannot push pathological values
  # like `---` into the sidecar.
  uuid=$(grep -oE 'Print mode: conversation=[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' "$log_file" \
    | head -1 | sed 's/.*=//')
  [[ -n "$uuid" ]] || return 0
  # CWE-59 defense — same pattern as _codex_capture_thread.
  [[ -L "$conv_file" ]] && {
    echo "[lib-agent] WARN: $conv_file is a symlink; refusing to write." >&2
    return 0
  }
  # Trailing `|| true` + `return 0`: printf may fail (read-only fs, full
  # disk); INV-36 promises capture is best-effort, never gate run_agent.
  printf '%s\n' "$uuid" > "$conv_file" || true
  return 0
}

_agy_conversation_id() {
  local session_id="$1" conv_file uuid
  conv_file=$(_agy_conversation_file "$session_id") || return 1
  # Symlink-defense: refuse to read through a symlink (CWE-59);
  # mirrors _codex_thread_id.
  [[ -L "$conv_file" ]] && return 1
  [[ -f "$conv_file" ]] || return 1
  uuid=$(cat "$conv_file" 2>/dev/null)
  # Format-validate against canonical UUID shape — anything else means
  # corruption, partial write, or attacker-planted content; treat as
  # missing and let resume_agent fall back to a fresh run_agent.
  [[ "$uuid" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] || return 1
  printf '%s\n' "$uuid"
}
```

Capture is **best-effort**: missing log, missing match, write-failure
all return 0. The sidecar's job is to enable resume optimization, not
to gate run_agent's success — gating on capture would convert a
log-format change into a hard outage.

The grep pattern anchors on `Print mode: conversation=<UUID>` which
agy's `printmode.go:130` emits on every print-mode invocation. Format
is currently stable but undocumented — [INV-36](invariants.md#inv-36-agy-conversation-id-capture-is-best-effort)
formalizes the best-effort contract.

## Failure-mode table

| Failure | Behavior |
|---|---|
| `agy` not on PATH | `_run_with_timeout` exec fails, non-zero rc → wrapper sees failure → existing retry path engages. Same as missing claude/codex. |
| `--log-file` path unwritable | agy fails loud, non-zero rc; sidecar not written. |
| Log line format changes (agy upgrade renames "Print mode") | grep miss → sidecar absent → next `resume_agent` falls back to fresh `run_agent`. Conversation continuity lost; pipeline still progresses. |
| Sidecar pruned between run and resume | Same fallback. |
| `agy --conversation <bad-uuid>` (corrupted sidecar) | agy fails loud → wrapper non-zero rc → retry → fresh `run_agent` overwrites sidecar. |
| `model` parameter passed by caller | One-time WARN to stderr; execution continues. Non-fatal per design decision (operator-correctable, not pipeline-breaking). |
| Concurrent dispatch to same session_id | Blocked upstream by [INV-23] PID-guard before reaching the sidecar layer. |

## Differences from peer CLIs

| Property | claude | codex | gemini | kiro | opencode | **agy** |
|---|---|---|---|---|---|---|
| Session id source | caller (UUID) | CLI (thread_id) | caller (UUID) | none | CLI (sessionID) | **CLI (UUID)** |
| Capture channel | n/a | stdout JSON | n/a | n/a | stdout JSON | **log file (grep)** |
| Sidecar required? | no | yes | no | no | yes | **yes** |
| Resume primitive | `--resume <id>` | `exec resume <id>` | `--resume <id>` | n/a (new session) | `run --session <id>` | **`--conversation <id>`** |
| Headless trust flag | (none required) | (none required) | `--approval-mode yolo` (operator) | `--trust-all-tools` (operator) | (none required) | **`--dangerously-skip-permissions` (structural)** |
| JSON event stream | `--output-format json` | `--json` | `--output-format stream-json` (operator) | n/a | `--format json` | **none** |
| `--model` honored? | yes | yes | yes | yes | yes | **no — WARN** |

## Operator-facing config (`autonomous.conf` snippet)

`autonomous.conf.example` gains an `# agy block` mirroring the existing
`# gemini block` / `# kiro block`:

```bash
# AGENT_CMD="agy"                          # Antigravity 2.0 CLI (Google)
#
# agy does not accept --model on the CLI; configure model selection
# via ~/.gemini/antigravity-cli/settings.json. AGENT_DEV_MODEL /
# AGENT_REVIEW_MODEL are ignored with a one-time WARN.
#
# Structural flags managed by lib-agent.sh and NOT to be added here:
#   -p, --dangerously-skip-permissions, --print-timeout, --log-file
# Operator-tunable additions (per INV-31) — none currently required.
# AGENT_DEV_EXTRA_ARGS=""
# AGENT_REVIEW_EXTRA_ARGS=""
```

The structural-flag list is documented inline because the agy
operator-tunable surface is currently empty (vs. gemini / kiro which
have load-bearing tunables); making the structural set visible
prevents operators from "helpfully" duplicating them in EXTRA_ARGS.

## Test coverage

New file `tests/unit/test-lib-agent-agy.sh`, mirroring
`test-lib-agent-codex.sh` / `test-lib-agent-opencode.sh`. All tests use
an `agy` stub (a shell script that writes a fixed log file and exits
0); no live agy invocation.

| Test | Asserts |
|---|---|
| AGY-S1 | Structural — all four sidecar helpers (`_agy_log_file`, `_agy_conversation_file`, `_agy_capture_conversation`, `_agy_conversation_id`) are defined |
| AGY-S2 | `_agy_capture_conversation` writes the UUID from a fixture log into the sidecar at the expected path |
| AGY-S3 | Log without `Print mode:` line leaves sidecar absent (best-effort capture, INV-36) |
| AGY-01 | `run_agent` feeds prompt to stub via stdin (upholds [INV-34]) |
| AGY-02 | `run_agent` passes `--dangerously-skip-permissions --print-timeout $AGENT_TIMEOUT --log-file <pid_dir>/agy-log-<sid>.log` to the stub |
| AGY-03 | After stub writes fake log with `Print mode: conversation=<UUID>`, sidecar `agy-conversation-<sid>` exists with the UUID |
| AGY-04 | `resume_agent` with sidecar present invokes stub with `--conversation <UUID>` |
| AGY-05 | `resume_agent` with sidecar absent falls back to `run_agent` (no `--conversation` flag in stub argv) |
| AGY-06 | Non-empty `model` arg → WARN on stderr, execution continues, exit code from stub is propagated |
| AGY-07 | Log file lacking the `Print mode:` line → sidecar not created, `run_agent` rc still propagates |
| AGY-S4 | Sidecar path is a pre-existing symlink → capture refuses to write and emits CWE-59 WARN. Write-side guard, helper-level test from Task 1; covers what the original spec called AGY-08. |
| AGY-S5 | Sidecar path is a symlink OR sidecar contains non-UUID content → `_agy_conversation_id` returns rc 1 without echoing leaked content. Read-side guard. |

## New invariant (lands in `invariants.md`)

This spec adds **INV-36: agy conversation id capture is best-effort**.
The full text below is appended to `invariants.md` in the same PR;
duplicated here so this file is self-contained for readers tracing
the agy branch:

> **Statement.** `_agy_capture_conversation` MUST NOT gate `run_agent`'s
> exit code on capture success. A grep miss, missing log file, or
> unwritable sidecar path returns 0 from the helper and leaves the
> sidecar absent. `resume_agent` MUST handle sidecar-absent by falling
> back to a fresh `run_agent`.
>
> **Why.** agy's "Print mode: conversation=…" log line is
> undocumented. A future agy version may rename the log message,
> change the log format, or move the channel entirely. Gating
> `run_agent` on capture would convert a documentation drift into a
> pipeline outage. The sidecar pattern already includes a
> degraded-but-functional fallback (fresh run loses conversation
> continuity but preserves pipeline progress) — INV-36 makes that
> explicit so future maintainers don't "helpfully" promote capture
> failure to a hard error.
>
> **Enforcement.** `tests/unit/test-lib-agent-agy.sh` AGY-07 (log
> lacks the Print-mode line) and AGY-S4 (symlink sidecar refused
> at capture time) both assert `run_agent` rc passes through and
> the wrapper does not raise. AGY-S5 covers the read-side symlink
> + corrupted-content guard in `_agy_conversation_id`.

## Cross-references

- [INV-13] — outer wall-clock timeout via `_run_with_timeout`. agy's
  internal `--print-timeout` is set to the same value to prevent
  premature SIGKILL from the inner cap.
- [INV-31] — operator-tunable per-CLI flags live in conf, not in
  `lib-agent.sh`. agy's structural set (-p, --dangerously-skip-
  permissions, --print-timeout, --log-file) is *not* operator-tunable;
  the empty `AGENT_*_EXTRA_ARGS` defaults reflect that.
- [INV-34] — agent prompt is fed via stdin, never as a single argv
  element. agy's `-p` (no value) reads from stdin, same as
  claude/gemini/kiro.
- `dev-agent-flow.md` and `review-agent-flow.md` are consumers — no
  changes required; both use the abstract `run_agent` /
  `resume_agent` interface and remain CLI-agnostic.

[INV-13]: invariants.md#inv-13-wall-clock-cap-on-agent-invocations
[INV-23]: invariants.md#inv-23-pid_file-points-at-a-process-whose-death-reaps-the-entire-agent-subtree
[INV-31]: invariants.md#inv-31-operator-tunable-per-cli-flags-live-in-conf-not-in-lib-agentsh
[INV-34]: invariants.md#inv-34-agent-prompt-is-fed-via-stdin-never-as-a-single-argv-element
