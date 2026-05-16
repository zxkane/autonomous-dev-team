#!/bin/bash
# lib-agent.sh — Agent CLI abstraction layer.
#
# Supports: claude (default), codex, gemini, kiro, opencode, and generic
# fallback. Source this file in autonomous-dev.sh and autonomous-review.sh.
#
# Session-id semantics differ across CLIs:
#   claude   — caller pre-mints `--session-id <UUID>`; same id used for
#              both run and resume. Cleanest fit for the dispatcher's
#              session_id.
#   codex    — CLI mints its own thread_id per `codex exec` invocation.
#              We capture it from `--json` stdout via
#              _codex_capture_thread and persist a sidecar under
#              pid_dir_for_project() keyed by the dispatcher's
#              session_id, then feed it back to
#              `codex exec resume <thread_id>` on resume.
#   gemini   — caller pre-mints `--session-id <UUID>`; same id round-trips
#              via the stream-json `init` event and is directly usable
#              for `gemini --resume <UUID>`. Verified empirically against
#              gemini CLI 0.42.0 (#134). claude-style replay model — no
#              sidecar required, simpler than codex/opencode. The
#              load-bearing `--approval-mode yolo` flag is mandatory:
#              without it every shell/write tool defaults to ask_user
#              which is treated as deny in headless mode (the silent
#              fabrication failure mode reproduced in #102).
#   kiro     — no session model; every invocation is a fresh conversation.
#              resume_agent falls back to run_agent.
#   opencode — same CLI-minted-session-id wrinkle as codex but with a
#              `sessionID` field on every JSON event. Captured the same
#              way (_opencode_capture_session) and fed back to
#              `opencode run --session <id>` on resume.
#   *        — generic <cli> -p <prompt> fallback; resume falls back to
#              a fresh run.

# Load project config via the shared helper (closes #58).
# Note: ${BASH_SOURCE[0]:-$0} (NOT readlink -f) so the symlink-vendor
# pattern resolves to the project's scripts/ rather than the skill
# installation dir.
_LIB_AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib-config.sh
source "${_LIB_AGENT_DIR}/lib-config.sh"
load_autonomous_conf "${_LIB_AGENT_DIR}" || true

# Ensure PROJECT_DIR is an absolute path to the repo root.
# autonomous.conf may use a relative BASH_SOURCE trick that can resolve
# incorrectly when sourced indirectly. Fall back to _LIB_AGENT_DIR/../../..
PROJECT_DIR="${PROJECT_DIR:-$(cd "${_LIB_AGENT_DIR}/../../.." && pwd)}"

# Agent configuration (overridable via env or autonomous.conf)
AGENT_CMD="${AGENT_CMD:-claude}"
AGENT_DEV_MODEL="${AGENT_DEV_MODEL:-}"
AGENT_REVIEW_MODEL="${AGENT_REVIEW_MODEL:-sonnet}"
AGENT_PERMISSION_MODE="${AGENT_PERMISSION_MODE:-auto}"
KIRO_AGENT_NAME="${KIRO_AGENT_NAME:-autonomous-dev}"

# AGENT_LAUNCHER — optional launcher prefix wrapped around every agent
# invocation in run_agent / resume_agent (prepended inside _run_with_timeout
# so a hung launcher is still bounded by AGENT_TIMEOUT). Empty by default.
# See autonomous.conf.example for the operator-facing usage and rationale.
#
# We tokenize the launcher string into AGENT_LAUNCHER_ARGV[] once via `eval`
# at load time. This trusts autonomous.conf (same trust level as the
# wrapper itself) but fails loudly on a malformed value rather than
# silently corrupting argv.
AGENT_LAUNCHER="${AGENT_LAUNCHER:-}"
declare -a AGENT_LAUNCHER_ARGV=()
if [[ -n "$AGENT_LAUNCHER" ]]; then
  # Preserve the original value for diagnostics — we clear AGENT_LAUNCHER
  # on parse failure (belt-and-suspenders for future callers that source
  # without `set -e`), so the error message must read from the snapshot.
  _orig_launcher="$AGENT_LAUNCHER"
  if ! eval "AGENT_LAUNCHER_ARGV=($AGENT_LAUNCHER)" 2>/dev/null; then
    # Explicit reset: if a future caller sources this without `set -e`,
    # the `return 1` is silently swallowed and we'd otherwise leave a
    # half-tokenized array. Empty = safe degraded state.
    AGENT_LAUNCHER=""
    AGENT_LAUNCHER_ARGV=()
    echo "[lib-agent] ERROR: AGENT_LAUNCHER failed to parse as a shell argv list. Value: ${_orig_launcher}" >&2
    unset _orig_launcher
    return 1 2>/dev/null || exit 1
  fi
  # `eval` succeeded but produced an empty array — almost certainly an
  # operator typo (stray `;`, leading whitespace + comment). Warn so it
  # doesn't silently degrade to "launcher-less" without a breadcrumb.
  if [[ ${#AGENT_LAUNCHER_ARGV[@]} -eq 0 ]]; then
    echo "[lib-agent] WARN: AGENT_LAUNCHER non-empty but tokenized to zero argv elements. Treating as unset. Value: ${_orig_launcher}" >&2
  fi
  unset _orig_launcher
fi

# AGENT_LAUNCHER is only supported with AGENT_CMD=claude today. The
# canonical launcher (a `cc` shell function ending in `$CLAUDE_CMD "$@"`)
# is hardcoded to invoke claude, so pointing it at codex/kiro/opencode
# would produce `claude codex ...` and fail. Refuse the combination
# rather than crashing 5 seconds into the next dispatch.
if [[ ${#AGENT_LAUNCHER_ARGV[@]} -gt 0 && "$AGENT_CMD" != "claude" ]]; then
  echo "[lib-agent] ERROR: AGENT_LAUNCHER is only supported with AGENT_CMD=claude (got AGENT_CMD=${AGENT_CMD}). Either unset AGENT_LAUNCHER or write a launcher tailored to your CLI." >&2
  return 1 2>/dev/null || exit 1
fi

# Wall-clock cap on agent invocations (INV-13, closes #60).
# Wraps run_agent / resume_agent in coreutils `timeout` so a hung CLI cannot
# eat indefinite wall time (observed: claude --resume against a completed
# session sat in epoll_wait for 8h, #59).
#
# AGENT_TIMEOUT accepts the same units as `timeout(1)` (s/m/h/d). Default 4h
# is generous — the longest healthy real run we have observed is ~6h, and
# the hang case sat for 8h+. Override per-deployment in autonomous.conf.
#
# We resolve the binary once at source time (not per-call): on macOS users
# install GNU coreutils via Homebrew, which provides `gtimeout`. If neither
# is available we fall through to an unwrapped invocation with a one-time
# WARN log — no hard requirement.
AGENT_TIMEOUT="${AGENT_TIMEOUT:-4h}"
_AGENT_TIMEOUT_CMD="$(command -v timeout || command -v gtimeout || true)"
if [[ -z "$_AGENT_TIMEOUT_CMD" ]]; then
  echo "[lib-agent] WARN: neither 'timeout' nor 'gtimeout' found on PATH; agent invocations will run without a wall-clock bound. Install coreutils to enable INV-13." >&2
fi

# _run_with_timeout — invoke "$@" under timeout if available, otherwise run
# directly. AGENT_LAUNCHER_ARGV (if set) is prepended to the command inside
# the timeout boundary so a hung launcher is still killed.
# --kill-after=30s escalates to SIGKILL if the agent ignores the initial
# SIGTERM (some MCP children trap TERM and need the harder push).
# --signal=TERM lets the agent flush any final SSE bytes before dying.
# Exit codes: passthrough on normal exit; 124 on TERM-timeout; 137 on KILL.
#
# Process-group ownership (closes #109):
# We launch the command under `setsid` so the agent and every descendant
# share a new process group. The session-leader PID — which equals the
# new PGID — is captured in `_AGENT_RUN_PID`. If `AGENT_PID_FILE` is
# exported by the caller, we write `_AGENT_RUN_PID` to it before
# wait'ing, so a subsequent dispatcher tick can `kill -TERM -- -<pgid>`
# and reap the entire subtree atomically. Without this the wrapper
# shell's `$$` ended up in PID_FILE while the timeout/agent subtree
# outlived the shell — see #109 for the full failure narrative.
_AGENT_RUN_PID=""
_run_with_timeout() {
  local cmd=()
  if [[ -n "$_AGENT_TIMEOUT_CMD" ]]; then
    cmd+=("$_AGENT_TIMEOUT_CMD" --kill-after=30s --signal=TERM "$AGENT_TIMEOUT")
  fi
  cmd+=("${AGENT_LAUNCHER_ARGV[@]}" "$@")

  # Prepend setsid when available so the agent gets its own session+PGID.
  # On the rare host without it (no util-linux), the agent runs in the
  # wrapper's group; the dispatcher's `pgrep -f` fallback in
  # kill_stale_wrapper still picks up orphans.
  local launcher=()
  command -v setsid >/dev/null 2>&1 && launcher=(setsid)
  "${launcher[@]}" "${cmd[@]}" &
  _AGENT_RUN_PID=$!

  if [[ -n "${AGENT_PID_FILE:-}" && ! -L "$AGENT_PID_FILE" ]]; then
    # Symlink-defence (CWE-59): refuse to follow a symlink. We don't
    # remove it either — acquire_pid_guard rejects symlinks at entry, so
    # we only get here if one was planted between guard and spawn
    # (extremely narrow race). Skip the write rather than expand the
    # attack surface.
    printf '%s\n' "$_AGENT_RUN_PID" > "$AGENT_PID_FILE" 2>/dev/null || true
  fi

  wait "$_AGENT_RUN_PID"
}

# install_agent_sigterm_trap — install the standard SIGTERM-to-PGID trap
# in the calling wrapper shell (closes #109). Used by autonomous-dev.sh
# and autonomous-review.sh so the two share the contract: forward TERM
# to the agent's process group (set by _run_with_timeout) plus a direct-
# children fallback for the pre-spawn race window.
#
# Callers may set RECEIVED_SIGTERM=0 first if they need to read the flag
# in their cleanup() trap (autonomous-dev.sh does for INV-15 / #67); the
# trap installed here writes RECEIVED_SIGTERM=1 either way.
install_agent_sigterm_trap() {
  trap '
    RECEIVED_SIGTERM=1
    if [[ -n "${_AGENT_RUN_PID:-}" ]]; then
      kill -TERM -- "-${_AGENT_RUN_PID}" 2>/dev/null || true
    fi
    pkill -TERM -P $$ 2>/dev/null || true
  ' TERM
}

# install_agent_heartbeat — spawn a background loop that touches
# AGENT_PID_FILE and a sibling `<base>.heartbeat` file every
# HEARTBEAT_INTERVAL_SECONDS (#111 Part B + INV-29). The loop is
# parent-pid-watched: when the wrapper shell exits, `kill -0 <parent>`
# fails and the loop terminates. No orphan heartbeats after wrapper exit.
#
# Sets _AGENT_HEARTBEAT_PID so the wrapper's cleanup() trap can SIGTERM
# the heartbeat at exit (defense in depth — the parent-pid watchdog is
# the primary lifecycle gate, but explicit teardown is faster).
#
# HEARTBEAT_INTERVAL_SECONDS=0 disables heartbeat entirely (no spawn) —
# the regression-safety knob for ops who hit edge cases.
#
# AGENT_PID_FILE must exist before calling this helper. The loop is
# tolerant of a missing or symlinked file (skips touch silently); the
# wrapper's acquire_pid_guard / spawn path remains the authoritative
# writer.
#
# Sibling heartbeat file (INV-29, closes #129): we ALSO maintain
# `${AGENT_PID_FILE%.pid}.heartbeat`. Its lifecycle is owned by the
# wrapper alone — the cleanup trap removes it at exit; the dispatcher's
# `kill_stale_wrapper` does NOT touch it. The dispatcher's `pid_alive`
# mtime fallback consults EITHER file's mtime, so a spurious deletion of
# the PID file (e.g. by a buggy stale-cleaner — see #129) cannot strand
# the liveness probe. We continue to touch the PID file too so a mixed-
# version dispatcher (older `pid_alive` that only knows about the PID
# file) still gets accurate readings during a rolling upgrade.
install_agent_heartbeat() {
  local interval="${HEARTBEAT_INTERVAL_SECONDS:-120}"
  # Defensive numeric guard: a typo'd config would otherwise raise an
  # arithmetic error under set -e. Treat non-numeric as "disabled".
  [[ "$interval" =~ ^[0-9]+$ ]] || return 0
  [[ "$interval" -gt 0 ]] || return 0
  [[ -n "${AGENT_PID_FILE:-}" ]] || return 0

  local parent_pid=$$
  local pid_file="$AGENT_PID_FILE"
  local hb_file="${pid_file%.pid}.heartbeat"

  (
    while command kill -0 "$parent_pid" 2>/dev/null; do
      # Re-check parent liveness immediately before each touch. The outer
      # `while` test fires only once per iteration, but the wrapper can
      # exit during the `sleep` below and its cleanup trap can delete
      # both files before this loop wakes. Without the inner kill -0,
      # the loop's `touch` would resurrect the heartbeat sibling with a
      # fresh mtime, leaving the dispatcher seeing a fake-ALIVE wrapper
      # for up to HEARTBEAT_INTERVAL_SECONDS * 3. The check is cheap and
      # closes the resurrection race documented in #129's review pass.
      command kill -0 "$parent_pid" 2>/dev/null || break
      if [[ -f "$pid_file" && ! -L "$pid_file" ]]; then
        touch "$pid_file" 2>/dev/null || true
      fi
      # Heartbeat sibling: create-on-demand and refresh. Same CWE-59
      # symlink defence as the PID file — if a symlink is planted at the
      # path, skip silently rather than follow it. `touch` creates the
      # file when missing, so a single touch covers both first-call and
      # post-deletion cases.
      if [[ ! -L "$hb_file" ]]; then
        touch "$hb_file" 2>/dev/null || true
      fi
      sleep "$interval"
    done
  ) &
  _AGENT_HEARTBEAT_PID=$!
  disown "$_AGENT_HEARTBEAT_PID" 2>/dev/null || true
}

# Codex thread-id capture/recall.
#
# Codex `exec` mints its own thread (UUID) per invocation and does NOT accept
# a caller-provided ID — unlike Claude Code, which lets us pre-mint
# `--session-id <UUID>`. To resume a codex session correctly we must capture
# the CLI-assigned thread_id after `run_agent` and feed it into
# `codex exec resume <id>` on `resume_agent`. We persist it in a sidecar
# under pid_dir_for_project() (mode 0700, per-user, already used for PID
# files) keyed by the dispatcher's session_id.

_codex_thread_file() {
  local session_id="$1"
  local pid_dir
  pid_dir=$(pid_dir_for_project) || return 1
  printf '%s/codex-thread-%s\n' "$pid_dir" "$session_id"
}

# _codex_capture_thread <session_id>
#
# Pipeline filter: streams stdin → stdout unchanged so the wrapper still sees
# every JSON event for logging, and as a side effect writes the first
# observed thread_id to the sidecar. Robust to:
#   - thread.started not being literally the first line (we keep scanning)
#   - the agent crashing before any thread_id arrives (sidecar stays empty
#     → resume_agent falls back to a fresh run_agent, same pattern as kiro)
#   - re-runs against the same dispatcher session_id (we overwrite, not
#     append)
#
# Why awk and not jq: jq is not a hard dependency of this lib; awk is
# universal. Codex `--json` emits one event per line (JSONL), and the
# `thread.started` event has the shape `{"type":"thread.started",
# "thread_id":"<UUID>"}` — a single line with no embedded newlines.
_codex_capture_thread() {
  local session_id="$1"
  local thread_file
  thread_file=$(_codex_thread_file "$session_id") || { cat; return 0; }
  awk -v out="$thread_file" '
    BEGIN {
      # Tracked together with the regex below so length math stays correct
      # if either is edited later. prefix matches the literal lead-in of a
      # codex thread.started JSON line; the inner [a-f0-9-]+ is the part we
      # want to extract.
      prefix = "\"thread_id\":\""
    }
    {
      print
      fflush()
      if (!captured && /"type":"thread.started"/) {
        if (match($0, /"thread_id":"[a-f0-9-]+"/)) {
          # Strip the prefix and the trailing closing quote.
          tid = substr($0, RSTART + length(prefix), RLENGTH - length(prefix) - 1)
          # Symlink-defense: refuse to clobber an existing symlink at the
          # sidecar path. pid_dir is mode 0700 so this is defense in depth,
          # but cheap to keep (CWE-59).
          cmd = "test -L \"" out "\" && exit 0; printf \"%s\\n\" \"" tid "\" > \"" out "\""
          system(cmd)
          captured = 1
        }
      }
    }'
}

# _codex_thread_id <session_id>
#
# Read the captured thread_id from the sidecar, validating the format.
# Echo the id and rc=0 on hit; echo nothing and rc=1 on miss / malformed.
# The UUID-only regex protects against a future bug overwriting the sidecar
# with attacker-controlled data — pid_dir is 0700 so the surface is small,
# but the explicit failure mode is worth the two extra lines.
_codex_thread_id() {
  local session_id="$1"
  local thread_file tid
  thread_file=$(_codex_thread_file "$session_id") || return 1
  [[ -L "$thread_file" ]] && return 1
  [[ -f "$thread_file" ]] || return 1
  tid=$(head -n1 "$thread_file" 2>/dev/null)
  [[ "$tid" =~ ^[a-f0-9-]+$ ]] || return 1
  printf '%s\n' "$tid"
}

# Opencode session-id capture/recall.
#
# opencode `run` mints its own session id (`ses_<base62>`) per invocation
# and accepts `--session <id>` only for resuming an existing one — same
# CLI-minted-id wrinkle as codex. Mirror the codex helpers, with two
# differences:
#   - Field name is `sessionID` (camelCase, capital ID), not `thread_id`.
#   - The id is on EVERY event in the JSON stream, not gated on a single
#     event type. We still capture the first occurrence, which arrives in
#     the very first event.

_opencode_session_file() {
  local session_id="$1"
  local pid_dir
  pid_dir=$(pid_dir_for_project) || return 1
  printf '%s/opencode-session-%s\n' "$pid_dir" "$session_id"
}

# _opencode_capture_session <dispatcher_session_id>
#
# Pipeline filter: pass-through awk filter that streams stdin → stdout
# unchanged and writes the first observed sessionID to a sidecar. Same
# pattern + safety properties as _codex_capture_thread.
#
# opencode emits one JSON event per line with a `"sessionID":"ses_..."`
# field on every event. Format verified against opencode v1.14.46 output.
_opencode_capture_session() {
  local session_id="$1"
  local sess_file
  sess_file=$(_opencode_session_file "$session_id") || { cat; return 0; }
  awk -v out="$sess_file" '
    BEGIN {
      # opencode session ids look like `ses_<base62>` (e.g. ses_1ee2d8d...).
      # Tracked together with the regex below so the math stays in sync.
      prefix = "\"sessionID\":\""
    }
    {
      print
      fflush()
      if (!captured) {
        if (match($0, /"sessionID":"ses_[A-Za-z0-9]+"/)) {
          sid = substr($0, RSTART + length(prefix), RLENGTH - length(prefix) - 1)
          # Same CWE-59 defense as _codex_capture_thread.
          cmd = "test -L \"" out "\" && exit 0; printf \"%s\\n\" \"" sid "\" > \"" out "\""
          system(cmd)
          captured = 1
        }
      }
    }'
}

# _opencode_session_id <dispatcher_session_id>
#
# Read the captured opencode sessionID from the sidecar. Echo + rc=0 on
# hit, echo nothing + rc=1 on miss/malformed. The `^ses_[A-Za-z0-9]+$`
# regex matches the documented opencode format and protects the
# downstream `opencode run --session <id>` invocation from injection.
_opencode_session_id() {
  local session_id="$1"
  local sess_file sid
  sess_file=$(_opencode_session_file "$session_id") || return 1
  [[ -L "$sess_file" ]] && return 1
  [[ -f "$sess_file" ]] || return 1
  sid=$(head -n1 "$sess_file" 2>/dev/null)
  [[ "$sid" =~ ^ses_[A-Za-z0-9]+$ ]] || return 1
  printf '%s\n' "$sid"
}

# Acquire PID guard: prevent duplicate instances for the same issue.
# Checks for symlink attacks, running processes, then writes current PID.
# Args: $1=pid_file, $2=label (e.g. "autonomous-dev"), $3=issue_number
acquire_pid_guard() {
  local pid_file="$1" label="$2" issue_num="$3"
  [[ -L "$pid_file" ]] && { echo "Error: PID file is a symlink — possible attack" >&2; exit 1; }
  if [[ -f "$pid_file" ]]; then
    local existing_pid
    existing_pid=$(cat "$pid_file" 2>/dev/null)
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      echo "[$label] Another instance for issue #${issue_num} is already running (PID $existing_pid). Exiting." >&2
      exit 0
    fi
  fi
  echo $$ > "$pid_file"
}

# Run agent with a new session.
# Args: $1=session_id, $2=prompt, $3=model (optional), $4=session_name (optional)
run_agent() {
  local session_id="$1"
  local prompt="$2"
  local model="${3:-}"
  local session_name="${4:-}"

  case "$AGENT_CMD" in
    claude)
      # Flag list is identical across both invocation paths — only the
      # command prefix differs (see below).
      local claude_args=(
        --session-id "$session_id"
        ${session_name:+--name "$session_name"}
        --permission-mode "$AGENT_PERMISSION_MODE"
        ${model:+--model "$model"}
        -p "$prompt"
        --output-format json
      )
      # Two invocation paths:
      #
      # (A) No AGENT_LAUNCHER → wrapper drives claude directly.
      #     `env -u CLAUDECODE` strips a parent-process env var that
      #     would otherwise make claude refuse to start (it treats
      #     CLAUDECODE-set parents as "already inside a Claude session").
      #     Only relevant when an operator runs the wrapper from inside
      #     an interactive claude — dispatcher's nohup path doesn't have it.
      #
      # (B) AGENT_LAUNCHER set → launcher invokes claude itself.
      #     The launcher (e.g. `cc` shell function) ends with
      #     `$CLAUDE_CMD "$@"`, so we pass ONLY flags + prompt as "$@" —
      #     NOT the binary name and NOT `env -u`. If we passed
      #     `env -u CLAUDECODE claude --session-id ...`, the launcher
      #     would invoke `claude env -u CLAUDECODE claude --session-id`
      #     and claude rejects `-u` as an unknown option. CLAUDECODE
      #     handling is delegated to the launcher (nohup-spawned bash -c
      #     subshells generally don't inherit it anyway).
      if [[ ${#AGENT_LAUNCHER_ARGV[@]} -gt 0 ]]; then
        _run_with_timeout "${claude_args[@]}"
      else
        _run_with_timeout env -u CLAUDECODE "$AGENT_CMD" "${claude_args[@]}"
      fi
      ;;
    codex)
      # Codex CLI: headless invocation is `codex exec [PROMPT]` (positional
      # prompt). The legacy `-p` flag now means `--profile` and would parse
      # the prompt as a TOML config profile name — silent breakage.
      #
      # `--json` streams JSONL events to stdout, including the
      # `thread.started` event from which we capture the thread_id for
      # resume_agent. We pipe through _codex_capture_thread (pass-through
      # filter) to keep the wrapper's stdout consumption untouched while
      # writing the sidecar.
      #
      # PIPESTATUS[0] surfaces codex's exit code (the awk filter at the end
      # of the pipeline is well-behaved and rc=0 on every input).
      _run_with_timeout "$AGENT_CMD" exec --json \
        ${model:+--model "$model"} \
        "$prompt" \
        | _codex_capture_thread "$session_id"
      return "${PIPESTATUS[0]}"
      ;;
    gemini)
      # Gemini CLI: headless invocation per https://geminicli.com/docs/cli/headless/.
      #
      # --approval-mode yolo is LOAD-BEARING. Per
      # https://geminicli.com/docs/reference/policy-engine/, every
      # write/shell tool defaults to `ask_user` which is treated as
      # `deny` in non-interactive environments. Without yolo, every
      # `run_shell_command` / `write_file` is silently denied while the
      # CLI still produces a fluent textual answer and exits 0 — the
      # fabrication failure mode reproduced in #102 (zxkane/llm-wiki#6,
      # 2026-05-15: 31-min run, exit 0, "I have completed the work…",
      # zero commits, zero PR).
      #
      # --output-format stream-json emits JSONL events (init / message /
      # tool_use / tool_result / error / result). The wrapper's
      # regex-based observability matches this stream; --output-format
      # json would emit a single end-of-run blob and defeat heartbeat
      # liveness signals.
      #
      # --session-id <UUID> round-trips: the dispatcher's session_id
      # appears in the `init` event verbatim and is directly usable
      # for `gemini --resume <same-UUID>` later (verified empirically
      # against CLI 0.42.0, #134). claude-style replay — no sidecar
      # capture needed, unlike codex/opencode which mint their own ids.
      #
      # --allowed-tools is deprecated per `gemini --help`; do not reach
      # for it. Admin-level policy in ~/.gemini/policy.json can override
      # yolo for ops who want tighter gating; the wrapper doesn't care.
      _run_with_timeout "$AGENT_CMD" \
        --output-format stream-json \
        --approval-mode yolo \
        --session-id "$session_id" \
        ${model:+--model "$model"} \
        -p "$prompt"
      ;;
    kiro)
      # Kiro CLI does not support named sessions (session_id is ignored).
      # Each invocation starts a new conversation in the current directory.
      # --agent ensures the workspace agent (with TDD hooks) is used.
      # Tool trust is handled by allowedTools in .kiro/agents/default.json.
      _run_with_timeout kiro-cli chat \
        --agent "$KIRO_AGENT_NAME" \
        --no-interactive \
        ${model:+--model "$model"} \
        "$prompt"
      ;;
    opencode)
      # opencode `run [message..]` is the headless invocation. opencode
      # mints its own session id and emits it on every event in the JSON
      # event stream, so we capture it the same way as codex.
      #
      # The session_name we got from the dispatcher is passed to --title
      # so opencode's session list shows a human-readable handle alongside
      # the ses_<base62> id.
      _run_with_timeout "$AGENT_CMD" run --format json \
        ${model:+--model "$model"} \
        ${session_name:+--title "$session_name"} \
        "$prompt" \
        | _opencode_capture_session "$session_id"
      return "${PIPESTATUS[0]}"
      ;;
    *)
      _run_with_timeout "$AGENT_CMD" -p "$prompt"
      ;;
  esac
}

# Resume an existing agent session.
# Args: $1=session_id, $2=prompt, $3=model (optional), $4=session_name (optional)
# Note: --name may not update the display name on resume (session was already
# named at creation). It is still passed through for kiro/fallback paths that
# start a new session instead of resuming.
resume_agent() {
  local session_id="$1"
  local prompt="$2"
  local model="${3:-}"
  local session_name="${4:-}"

  case "$AGENT_CMD" in
    claude)
      # See run_agent above for the (A) direct vs. (B) launcher rationale.
      # --name is omitted on resume — the session retains the name set
      # at creation.
      local claude_args=(
        --resume "$session_id"
        --permission-mode "$AGENT_PERMISSION_MODE"
        ${model:+--model "$model"}
        -p "$prompt"
        --output-format json
      )
      if [[ ${#AGENT_LAUNCHER_ARGV[@]} -gt 0 ]]; then
        _run_with_timeout "${claude_args[@]}"
      else
        _run_with_timeout env -u CLAUDECODE "$AGENT_CMD" "${claude_args[@]}"
      fi
      ;;
    codex)
      # Codex `exec resume <thread_id> [PROMPT]` resumes the conversation.
      # The dispatcher's session_id and codex's thread_id are NOT the same:
      # codex mints its own UUID and we capture it during run_agent into a
      # sidecar keyed by our session_id. Read it back here.
      #
      # If the sidecar is missing (run_agent crashed before thread.started,
      # or this resume_agent is being called without a prior run_agent),
      # fall back to a fresh new-session run — same defensive pattern as
      # the kiro branch, since resuming-a-nonexistent-thread is worse UX
      # than starting clean with the full prompt.
      local _codex_tid
      if _codex_tid=$(_codex_thread_id "$session_id"); then
        _run_with_timeout "$AGENT_CMD" exec resume "$_codex_tid" --json \
          ${model:+--model "$model"} \
          "$prompt" \
          | _codex_capture_thread "$session_id"
        return "${PIPESTATUS[0]}"
      else
        echo "[lib-agent] no captured codex thread_id for session $session_id; starting a new codex session" >&2
        run_agent "$session_id" "$prompt" "$model" "$session_name"
      fi
      ;;
    gemini)
      # Gemini `--resume <UUID>` reads back the conversation history that
      # was created with `--session-id <UUID>` on the original run.
      # Empirically verified against CLI 0.42.0 (#134) — no sidecar
      # needed because gemini's --session-id round-trips. If the original
      # run never happened (e.g. operator-initiated resume on a fresh
      # issue), gemini still starts cleanly because there's simply no
      # history to replay; safer than kiro's fresh-run fallback.
      #
      # Same load-bearing flags as run_agent: --approval-mode yolo and
      # --output-format stream-json. Without yolo, even resume-mode
      # tool calls hit the headless ask_user→deny path.
      _run_with_timeout "$AGENT_CMD" \
        --resume "$session_id" \
        --output-format stream-json \
        --approval-mode yolo \
        ${model:+--model "$model"} \
        -p "$prompt"
      ;;
    kiro)
      # Kiro CLI --resume cannot inject new review feedback effectively —
      # the resumed context sees "all done" and exits immediately.
      # Fall back to a new session so the full prompt (with review findings)
      # is treated as fresh instructions.
      run_agent "$session_id" "$prompt" "$model" "$session_name"
      ;;
    opencode)
      # `opencode run --session <id> [PROMPT]` resumes the conversation.
      # Same pattern as the codex branch: read the captured opencode
      # session id from the sidecar, fall back to a new run if missing
      # (run_agent crashed before the first JSON event reached us).
      local _opencode_sid
      if _opencode_sid=$(_opencode_session_id "$session_id"); then
        _run_with_timeout "$AGENT_CMD" run --format json --session "$_opencode_sid" \
          ${model:+--model "$model"} \
          "$prompt" \
          | _opencode_capture_session "$session_id"
        return "${PIPESTATUS[0]}"
      else
        echo "[lib-agent] no captured opencode sessionID for session $session_id; starting a new opencode session" >&2
        run_agent "$session_id" "$prompt" "$model" "$session_name"
      fi
      ;;
    *)
      # Agents without resume support start a new session
      run_agent "$session_id" "$prompt" "$model" "$session_name"
      ;;
  esac
}
