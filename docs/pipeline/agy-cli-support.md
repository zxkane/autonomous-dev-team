# Antigravity CLI (`agy`) — Agent Backend Support

Spec for adding **Antigravity 2.0 CLI** (binary name `agy`, Google's
successor to / replacement for the Gemini CLI in the autonomous
pipeline) as a supported value of `AGENT_CMD` in
`skills/autonomous-dispatcher/scripts/lib-agent.sh`.

This doc is the authoritative contract for the `agy` branch in
`run_agent` / `resume_agent`. Originally verified against **agy 1.0.2**
(May 2026), which had no `--model` flag. **A current agy build adds
`--model`** (issue #190); the wrapper now forwards it after validating
against `agy models` — see [`--model` support](#--model-support-issue-190-inv-50)
and [INV-50](invariants.md#inv-50-agy---model-is-validated-against-agy-models-before-forwarding).

Related: [`dev-agent-flow.md`](dev-agent-flow.md) (consumer of
`run_agent` / `resume_agent`), [`invariants.md`](invariants.md)
([INV-13], [INV-34]) for the cross-cutting rules this branch upholds.

## CLI shape (verified)

`agy` ships a small surface area compared to the other supported CLIs.
Probed via `agy --help` and a live `-p` invocation:

| Flag | Role |
|------|------|
| `-p` / `--print` / `--prompt` | Headless single-prompt mode. With no positional, reads prompt from **stdin**. |
| `--print-timeout <duration>` | Internal cap on print-mode wait. **Default 5m** — far below our `AGENT_TIMEOUT` (default 4h), so we MUST override. |
| `--model <name>` | Select the model for the session. **Present and used** (issue #190). The value MUST be a name from `agy models` (spaces/parens included, e.g. `"Gemini 3.5 Flash (High)"`). agy accepts *any* string at rc 0 and silently falls back to its default for an unknown id, so the wrapper validates against `agy models` before forwarding — see [`--model` support](#--model-support-issue-190-inv-50). |
| `--continue` / `-c` | Resume the **most recent** conversation. Not concurrency-safe — discarded. |
| `--conversation <UUID>` | Resume a specific conversation by ID. The deterministic resume primitive. |
| `--dangerously-skip-permissions` | Auto-approve all tool permission requests. **Load-bearing** for headless tool execution; without it, every tool call denies and the agent silently fabricates results (same failure mode that gemini's `--approval-mode yolo` and kiro's `--trust-all-tools` fix). |
| `--log-file <path>` | Override CLI log file path. **The only programmatic channel for the conversation UUID** — agy does not emit a JSON event stream and does not print the UUID on stdout. |
| `agy models` (subcommand) | Print the model names agy accepts, one per line (spaces/parens in names). Used by the wrapper to validate `--model` before forwarding. |
| `--add-dir`, `--sandbox`, `--prompt-interactive` (`-i`) | Not used by the wrapper. |

**Crucial absences** (vs. peer CLIs):

- No `--session-id <UUID>` for caller-minted IDs (vs. claude / gemini).
- No JSON event stream output (vs. codex `--json`, opencode `--format
  json`, gemini `--output-format stream-json`). The conversation UUID
  is emitted only to the log file.

## `--model` support (issue #190, [INV-50])

A current agy build honors `--model`, so the wrapper forwards it like the
other CLIs — **but with a validation gate the others do not need.** The
empirically-verified fact that forces this:

```
$ printf 'say OK' | agy -p --model "claude-sonnet-4.6"        → OK   rc=0   (ran as agy's DEFAULT model)
$ printf 'say OK' | agy -p --model "totally-not-a-model-xyz"  → OK   rc=0   (ran as agy's DEFAULT model)
$ agy -p --model "Gemini 3.1 Pro (Low)"  → "I am based on the Gemini 3.1 Pro model."
```

`agy -p --model "<x>"` returns **rc 0 for any string** and silently falls
back to its default model — it does **not** fail on an invalid id. So
"pass `--model` verbatim and let agy self-error" would make an un-keyed
agy review member that inherits a non-agy shared `AGENT_REVIEW_MODEL`
(e.g. kiro's `claude-sonnet-4.6`) **silently review with the wrong
model**, and that verdict still counts toward the [INV-40] unanimous-PASS
merge gate. Silent wrong-model in the merge path is worse than the old
documented no-op. Validation is the only way to make a misconfiguration
observable.

The wrapper therefore validates the resolved model against `agy models`
(via `_agy_known_model`, cached once per process, fixed-string whole-line
match) and resolves the `--model` argv as:

| Resolved model | `--model` forwarded? | Side effect |
|---|---|---|
| Known agy model (in `agy models`) | **yes** — `--model "<name>"` (single argv element) | — |
| Enumerated, but not in the list | **no** — omitted; agy runs its configured default | one-time WARN naming the value + `AGENT_REVIEW_MODEL_AGY` |
| `agy models` enumeration failed | **yes** — `--model "<value>"` (best-effort; can't prove invalid) | — |
| Empty / unset | **no** | — |

The per-agent key `AGENT_REVIEW_MODEL_AGY` ([INV-41]) is the way to give
agy a valid agy-namespace model when the shared `AGENT_REVIEW_MODEL`
belongs to another CLI's namespace.

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
  # Validated --model (issue #190, INV-50): forward only a known agy model;
  # omit + WARN for an unknown id; best-effort pass-through if `agy models`
  # can't be enumerated. Policy lives in _agy_build_model_args.
  local agy_model_args
  _agy_build_model_args "$model" agy_model_args

  local agy_log
  agy_log=$(_agy_log_file "$session_id") || return 1

  printf '%s' "$prompt" \
    | _run_with_timeout "$AGENT_CMD" \
        -p \
        --dangerously-skip-permissions \
        --print-timeout "$AGENT_TIMEOUT" \
        --log-file "$agy_log" \
        "${agy_model_args[@]}" \
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

`agy_model_args` is **not** structural — it carries the validated
`--model` (or nothing) resolved from the caller's `model` arg per
[INV-50]. See [`--model` support](#--model-support-issue-190-inv-50).

Operator-tunable additions go in `AGENT_DEV_EXTRA_ARGS` /
`AGENT_REVIEW_EXTRA_ARGS` per [INV-31], appended via `extra_args[@]`.

## `resume_agent` contract — agy branch

```bash
agy)
  local _agy_cid
  if _agy_cid=$(_agy_conversation_id "$session_id"); then
    local agy_log
    agy_log=$(_agy_log_file "$session_id") || return 1
    # Validated --model on resume too (INV-50), via the shared helper.
    # agy may bind the model from the original conversation and ignore a
    # late --model — worst case a harmless no-op (confirmed non-fatal in
    # the AGY-06c test).
    local agy_model_args
    _agy_build_model_args "$model" agy_model_args
    printf '%s' "$prompt" \
      | _run_with_timeout "$AGENT_CMD" \
          --conversation "$_agy_cid" \
          -p \
          --dangerously-skip-permissions \
          --print-timeout "$AGENT_TIMEOUT" \
          --log-file "$agy_log" \
          "${agy_model_args[@]}" \
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

The sidecar-absent fallback calls `run_agent "$session_id" "$prompt"
"$model" …`, which forwards the validated `--model` itself — so the
model is threaded through the fallback path without extra code here
(pinned by the AGY-06d test).

`_agy_capture_conversation` re-runs after resume as a self-healing
step: under normal operation the captured UUID equals `_agy_cid` (agy
keeps the conversation id on `--conversation <id>` resume), so the
write is a no-op overwrite. If a future agy version ever rotates the
id on resume, the sidecar tracks the live one without a code change.

The fallback branch reuses `run_agent` (not `_LIB_AGENT_GENERIC_WARNED`
or a separate code path) so the new-session policy stays in one place.

## Helpers

The sidecar trio (`_agy_log_file` / `_agy_conversation_file` /
`_agy_capture_conversation` / `_agy_conversation_id`) are drop-in mirrors
of `_codex_thread_file` / `_codex_capture_thread` / `_codex_thread_id`,
with two differences: (1) two paths instead of one (log file +
conversation sidecar), (2) capture channel is `grep log_file` instead of
`awk JSON stream`. The model-validation pair (`_agy_known_model` /
`_agy_build_model_args`) is agy-specific (issue #190, [INV-50]) and shown
after the trio.

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

Model validation (issue #190, [INV-50]) — enumerate `agy models` once
per process and answer "is `<model>` a name agy accepts?" via a
fixed-string, whole-line match, then build the `--model` argv:

```bash
_agy_known_model() {
  local model="$1"
  [[ -n "$model" ]] || return 1
  if [[ -z "${_LIB_AGENT_AGY_MODELS_CACHE:-}" ]]; then
    local listing
    if listing=$("${AGENT_CMD:-agy}" models 2>/dev/null) && [[ -n "$listing" ]]; then
      _LIB_AGENT_AGY_MODELS_CACHE="$listing"
    else
      _LIB_AGENT_AGY_MODELS_CACHE=$'\x01enum-failed\x01'   # sentinel
    fi
    export _LIB_AGENT_AGY_MODELS_CACHE
  fi
  [[ "$_LIB_AGENT_AGY_MODELS_CACHE" == $'\x01enum-failed\x01' ]] && return 2  # can't validate
  printf '%s\n' "$_LIB_AGENT_AGY_MODELS_CACHE" | grep -Fxq -- "$model"
}

_agy_build_model_args() {
  local model="$1" out_name="$2"
  eval "$out_name=()"
  [[ -n "$model" ]] || return 0
  _agy_known_model "$model"
  case $? in
    0|2) eval "$out_name=(--model \"\$model\")" ;;   # known OR enum-failed → forward
    *)   # enumerated, model not in the list → skip + warn once.
      if [[ -z "${_LIB_AGENT_AGY_MODEL_WARNED:-}" ]]; then
        echo "[lib-agent] WARN: '${model}' is not a known agy model (see \`agy models\`); omitting --model so agy uses its configured default. Set an agy-namespace model (e.g. AGENT_REVIEW_MODEL_AGY=\"Gemini 3.5 Flash (High)\") to pin one." >&2
        export _LIB_AGENT_AGY_MODEL_WARNED=1
      fi ;;
  esac
}
```

`grep -Fxq` is load-bearing: model names contain spaces and parens, so a
fixed-string (`-F`) whole-line (`-x`) match keeps `"Gemini 3.5 Flash
(High)"` literal and ensures a prefix (`"Gemini 3.5 Flash"`) or a string
with regex metachars never matches. The return-code 2 sentinel keeps
"can't validate" distinct from "validated as unknown" so the two collapse
to *forward* vs. *omit+WARN* respectively. `_LIB_AGENT_AGY_MODEL_WARNED`
is repurposed from the old warn-and-ignore guard to the new
omitted-unknown-model one-time WARN guard.

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
| `model` is a known agy model | Forwarded via `--model "<name>"` (single argv element); agy runs that model. |
| `model` is invalid / cross-namespace (e.g. `claude-sonnet-4.6`) | **NOT forwarded** — omitted; agy runs its configured default. One-time WARN to stderr naming the value + `AGENT_REVIEW_MODEL_AGY`. |
| `agy models` enumeration fails | Best-effort pass-through: `--model "<value>"` forwarded (can't prove it invalid). Mirrors the INV-36 best-effort philosophy. |
| Concurrent dispatch to same session_id | Blocked upstream by [INV-23] PID-guard before reaching the sidecar layer. |

> **agy does NOT fail on an invalid `--model`** — `agy -p --model "<x>"`
> returns rc 0 for any string and silently falls back to its default
> model. That is precisely why the wrapper validates against `agy models`
> rather than relying on agy to self-error: a non-agy id forwarded
> verbatim would put a wrong-model verdict into the [INV-40]
> unanimous-PASS merge gate undetected.

## Differences from peer CLIs

| Property | claude | codex | gemini | kiro | opencode | **agy** |
|---|---|---|---|---|---|---|
| Session id source | caller (UUID) | CLI (thread_id) | caller (UUID) | none | CLI (sessionID) | **CLI (UUID)** |
| Capture channel | n/a | stdout JSON | n/a | n/a | stdout JSON | **log file (grep)** |
| Sidecar required? | no | yes | no | no | yes | **yes** |
| Resume primitive | `--resume <id>` | `exec resume <id>` | `--resume <id>` | n/a (new session) | `run --session <id>` | **`--conversation <id>`** |
| Headless trust flag | (none required) | (none required) | `--approval-mode yolo` (operator) | `--trust-all-tools` (operator) | (none required) | **`--dangerously-skip-permissions` (structural)** |
| JSON event stream | `--output-format json` | `--json` | `--output-format stream-json` (operator) | n/a | `--format json` | **none** |
| `--model` honored? | yes | yes | yes | yes | yes | **yes — validated vs `agy models` (INV-50)** |

## Operator-facing config (`autonomous.conf` snippet)

`autonomous.conf.example` gains an `# agy block` mirroring the existing
`# gemini block` / `# kiro block`:

```bash
# AGENT_CMD="agy"                          # Antigravity 2.0 CLI (Google)
#
# agy accepts --model. The value MUST be a name from `agy models`
# (spaces/parens included — quote them); the wrapper validates against
# that list and OMITS --model with a WARN if the value is not a known
# agy model (agy would otherwise silently run its default — it does not
# reject invalid ids). AGENT_DEV_MODEL / AGENT_REVIEW_MODEL are honored
# when they name a real agy model.
# AGENT_DEV_MODEL="Gemini 3.5 Flash (High)"
# AGENT_REVIEW_MODEL="Gemini 3.5 Flash (High)"
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

`tests/unit/test-lib-agent-agy.sh`, mirroring `test-lib-agent-codex.sh` /
`test-lib-agent-opencode.sh`. All tests use an `agy` stub (a shell script
that answers `agy models` with a fixed listing, writes a fixed log file,
and exits 0); no live agy invocation. The model cases (`AGY-06*`,
`TC-AGYM-KM`) are pinned by `docs/test-cases/agy-model-support.md`.

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
| AGY-06a | Known agy model → `--model "<name>"` in argv as a **single argv element** (multi-word name keeps its quoting); rc 0 |
| AGY-06b | Empty/unset model → no `--model`; rc 0; no WARN |
| AGY-06b2 | Enumerated-but-unknown model → `--model` **omitted** + one-time WARN naming the value and `AGENT_REVIEW_MODEL_AGY`; rc 0 (agy default, not a drop — agy accepts invalid ids silently, so the wrapper is the gate) |
| AGY-06b3 | `agy models` enumeration failure → best-effort pass-through (`--model <value>` forwarded); rc 0 |
| TC-AGYM-KM | `_agy_known_model` unit: known → rc 0; unknown → rc 1; prefix of a listed name → rc 1 (whole-line); regex-metachar arg literal → rc 1; empty → rc 1; `agy models` enumerated once per process (cached) |
| AGY-06c | `resume_agent` `--conversation` path forwards `--model <name>` when a model is passed |
| AGY-06d | `resume_agent` with no sidecar falls back to `run_agent` and the forwarded argv still contains `--model <name>` (model threaded through fallback) |
| AGY-WARN-GONE | Old `does not support --model` WARN string is absent from `lib-agent.sh` (source grep) so the warn-and-ignore can't silently return |
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
- [INV-40] — multi-agent review unanimous-PASS merge gate. A wrong-model
  agy verdict forwarded verbatim would enter this gate undetected, which
  is why [INV-50] validates wrapper-side.
- [INV-41] — per-agent review model resolution. `AGENT_REVIEW_MODEL_AGY`
  is the per-agent key that gives agy a valid agy-namespace model when the
  shared `AGENT_REVIEW_MODEL` belongs to another CLI's namespace.
- [INV-50] — agy `--model` is validated against `agy models` before
  forwarding (the invariant this PR adds).
- `dev-agent-flow.md` and `review-agent-flow.md` are consumers — no
  changes required; both use the abstract `run_agent` /
  `resume_agent` interface and remain CLI-agnostic.

[INV-13]: invariants.md#inv-13-wall-clock-cap-on-agent-invocations
[INV-23]: invariants.md#inv-23-pid_file-points-at-a-process-whose-death-reaps-the-entire-agent-subtree
[INV-31]: invariants.md#inv-31-operator-tunable-per-cli-flags-live-in-conf-not-in-lib-agentsh
[INV-34]: invariants.md#inv-34-agent-prompt-is-fed-via-stdin-never-as-a-single-argv-element
[INV-40]: invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback
[INV-41]: invariants.md#inv-41-per-agent-review-model--extra-args-resolution
[INV-50]: invariants.md#inv-50-agy---model-is-validated-against-agy-models-before-forwarding
