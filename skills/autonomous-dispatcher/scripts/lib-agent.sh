#!/bin/bash
# lib-agent.sh — Agent CLI abstraction layer.
#
# Supports: claude (default), codex, gemini, kiro, opencode, and generic
# fallback. Source this file in autonomous-dev.sh and autonomous-review.sh.
#
# Operator-tunable per-CLI flags (closes #140):
#   AGENT_DEV_EXTRA_ARGS / AGENT_REVIEW_EXTRA_ARGS — flat strings whose
#   tokens are appended verbatim after the structural arguments of every
#   case branch and before the prompt positional. Defaults are empty.
#   Operators MUST migrate gemini/kiro deployments to set the
#   load-bearing flags via these vars (see autonomous.conf.example
#   migration callout). Tokenization uses `eval`, same trust level as
#   AGENT_LAUNCHER (operator-controlled config).
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
#              sidecar required, simpler than codex/opencode. Required
#              EXTRA_ARGS in conf for headless tool execution
#              (`--approval-mode yolo --output-format stream-json`); see
#              autonomous.conf.example "gemini block".
#   kiro     — no session model; every invocation is a fresh conversation.
#              resume_agent falls back to run_agent. Required EXTRA_ARGS
#              in conf for headless tool trust (`--trust-all-tools`);
#              see autonomous.conf.example "kiro block".
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
# Per-side AGENT_CMD overrides (INV-37). Default to AGENT_CMD so existing
# deployments are unchanged. autonomous-dev.sh and autonomous-review.sh
# each set AGENT_CMD="$AGENT_{DEV,REVIEW}_CMD" right after sourcing this
# file, so the run_agent / resume_agent case statements dispatch to the
# right CLI for each side. See docs/pipeline/per-side-agent-cmd.md.
AGENT_DEV_CMD="${AGENT_DEV_CMD:-$AGENT_CMD}"
AGENT_REVIEW_CMD="${AGENT_REVIEW_CMD:-$AGENT_CMD}"
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

# Per-side AGENT_LAUNCHER overrides (INV-38). Default to AGENT_LAUNCHER
# so existing single-launcher deployments are byte-for-byte unchanged.
# autonomous-dev.sh and autonomous-review.sh each rebind
# AGENT_LAUNCHER_ARGV to their side's array right after sourcing this
# file, so run_agent / resume_agent continue reading AGENT_LAUNCHER_ARGV
# without signature changes. See docs/pipeline/per-side-launcher.md.
AGENT_DEV_LAUNCHER="${AGENT_DEV_LAUNCHER:-$AGENT_LAUNCHER}"
AGENT_REVIEW_LAUNCHER="${AGENT_REVIEW_LAUNCHER:-$AGENT_LAUNCHER}"
declare -a AGENT_DEV_LAUNCHER_ARGV=()
declare -a AGENT_REVIEW_LAUNCHER_ARGV=()

# Tokenize AGENT_DEV_LAUNCHER (mirrors the AGENT_LAUNCHER eval block above).
if [[ -n "$AGENT_DEV_LAUNCHER" ]]; then
  _orig_dev_launcher="$AGENT_DEV_LAUNCHER"
  if ! eval "AGENT_DEV_LAUNCHER_ARGV=($AGENT_DEV_LAUNCHER)" 2>/dev/null; then
    AGENT_DEV_LAUNCHER=""
    AGENT_DEV_LAUNCHER_ARGV=()
    echo "[lib-agent] ERROR: AGENT_DEV_LAUNCHER failed to parse as a shell argv list. Value: ${_orig_dev_launcher}" >&2
    unset _orig_dev_launcher
    return 1 2>/dev/null || exit 1
  fi
  if [[ ${#AGENT_DEV_LAUNCHER_ARGV[@]} -eq 0 ]]; then
    echo "[lib-agent] WARN: AGENT_DEV_LAUNCHER non-empty but tokenized to zero argv elements. Treating as unset. Value: ${_orig_dev_launcher}" >&2
  fi
  unset _orig_dev_launcher
fi

# Tokenize AGENT_REVIEW_LAUNCHER (same shape as AGENT_DEV_LAUNCHER above).
if [[ -n "$AGENT_REVIEW_LAUNCHER" ]]; then
  _orig_review_launcher="$AGENT_REVIEW_LAUNCHER"
  if ! eval "AGENT_REVIEW_LAUNCHER_ARGV=($AGENT_REVIEW_LAUNCHER)" 2>/dev/null; then
    AGENT_REVIEW_LAUNCHER=""
    AGENT_REVIEW_LAUNCHER_ARGV=()
    echo "[lib-agent] ERROR: AGENT_REVIEW_LAUNCHER failed to parse as a shell argv list. Value: ${_orig_review_launcher}" >&2
    unset _orig_review_launcher
    return 1 2>/dev/null || exit 1
  fi
  if [[ ${#AGENT_REVIEW_LAUNCHER_ARGV[@]} -eq 0 ]]; then
    echo "[lib-agent] WARN: AGENT_REVIEW_LAUNCHER non-empty but tokenized to zero argv elements. Treating as unset. Value: ${_orig_review_launcher}" >&2
  fi
  unset _orig_review_launcher
fi

# AGENT_LAUNCHER is gated per-side (INV-38). Each side's launcher is
# checked against THAT side's AGENT_CMD: AGENT_DEV_LAUNCHER non-empty
# requires AGENT_DEV_CMD=claude; AGENT_REVIEW_LAUNCHER non-empty
# requires AGENT_REVIEW_CMD=claude. Side that has no launcher is
# unconstrained. The canonical launcher (a `cc` shell function ending
# in `$CLAUDE_CMD "$@"`) is hardcoded to invoke claude, so pointing it
# at codex/kiro/opencode/agy would produce `claude codex ...` and fail.
# Refuse the combination rather than crashing 5 seconds into the next
# dispatch. The check reads AGENT_DEV_CMD / AGENT_REVIEW_CMD directly
# (not via AGENT_CMD) because the wrapper-level override fires AFTER
# this guard — see docs/pipeline/per-side-launcher.md §Resolution order.
#
# Scope note (INV-42, #173): this guard governs the SHARED, blanket
# AGENT_REVIEW_LAUNCHER default only. The per-agent opt-in
# AGENT_REVIEW_LAUNCHER_<AGENT> is resolved later, inside each fan-out
# subshell in autonomous-review.sh (via _resolve_review_agent_launcher),
# AFTER this startup guard has already run — so a per-agent launcher for a
# non-claude CLI is intentionally NOT subject to this claude-only check.
if [[ ${#AGENT_DEV_LAUNCHER_ARGV[@]} -gt 0 && "$AGENT_DEV_CMD" != "claude" ]]; then
  echo "[lib-agent] ERROR: AGENT_DEV_LAUNCHER is only supported with AGENT_DEV_CMD=claude (got AGENT_DEV_CMD=${AGENT_DEV_CMD}). Either unset AGENT_DEV_LAUNCHER (or AGENT_LAUNCHER if it's the source of the dev-side default) or write a launcher tailored to your CLI." >&2
  return 1 2>/dev/null || exit 1
fi
if [[ ${#AGENT_REVIEW_LAUNCHER_ARGV[@]} -gt 0 && "$AGENT_REVIEW_CMD" != "claude" ]]; then
  echo "[lib-agent] ERROR: AGENT_REVIEW_LAUNCHER is only supported with AGENT_REVIEW_CMD=claude (got AGENT_REVIEW_CMD=${AGENT_REVIEW_CMD}). Either unset AGENT_REVIEW_LAUNCHER (or AGENT_LAUNCHER if it's the source of the review-side default) or write a launcher tailored to your CLI." >&2
  return 1 2>/dev/null || exit 1
fi

# AGENT_DEV_EXTRA_ARGS / AGENT_REVIEW_EXTRA_ARGS (closes #140) — operator-
# tunable per-CLI flags appended after each case branch's structural args.
# Defaults to empty strings. Tokenized per call via _parse_extra_args:
# we use `eval` (same trust model as AGENT_LAUNCHER) so quoted values
# containing spaces survive intact, e.g.
#   AGENT_DEV_EXTRA_ARGS='--policy "/path with spaces/policy.json"'
# Bare `read -ra` cannot honor those quotes — the operator-facing example
# in the conf would otherwise mis-tokenize.
AGENT_DEV_EXTRA_ARGS="${AGENT_DEV_EXTRA_ARGS:-}"
AGENT_REVIEW_EXTRA_ARGS="${AGENT_REVIEW_EXTRA_ARGS:-}"

# _parse_extra_args <varname> <out_array_name>
#
# Tokenize $varname into the array named by $out_array_name. Empty/unset
# input yields an empty array (no leftover empty-string elements). On
# malformed input we log a WARN and degrade to empty so a single typo
# doesn't crash the dispatcher tick.
#
# Bash 4.3+ `declare -n` for the out-param. The fleet ships bash 5.x
# everywhere we run; macOS dev boxes use Homebrew bash 5.x via
# `#!/bin/bash` plus PATH (autonomous.conf documents the requirement).
_parse_extra_args() {
  local var_name="$1"
  local -n _out_array="$2"
  _out_array=()
  local raw="${!var_name:-}"
  [[ -z "$raw" ]] && return 0
  if ! eval "_out_array=($raw)" 2>/dev/null; then
    echo "[lib-agent] WARN: $var_name failed to parse as a shell argv list. Value: ${raw}. Treating as empty." >&2
    _out_array=()
    return 0
  fi
}

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

# _is_positive_timeout_value <value> — true (rc 0) iff <value> is a positive
# coreutils-`timeout` duration: a positive integer optionally suffixed with one
# of s/m/h/d (e.g. 3600, 30s, 90m, 2h, 1d). Rejects the empty string, a bare or
# suffixed zero (GNU `timeout 0` DISABLES the cap — exactly the silent-no-bound
# footgun this validates against), fractions, negatives, and any other unit.
# Pure (no side effects); lives here next to AGENT_TIMEOUT / INV-13 so review
# (AGENT_REVIEW_TIMEOUT) and browser-E2E (E2E_BROWSER_TIMEOUT_SECONDS) caps —
# both `timeout`-unit values — can be validated by the same predicate and
# unit-tested in isolation (INV-48).
_is_positive_timeout_value() {
  local v="${1:-}"
  # Anchored: 1+ digits with a non-zero leading digit, optional single unit.
  [[ "$v" =~ ^[1-9][0-9]*[smhd]?$ ]]
}

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
  #
  # stdin inheritance contract ([INV-34], #144): callers feed the prompt
  # via a leading `printf '%s' "$prompt" |` pipeline stage. Bash inherits
  # the function's stdin into the backgrounded `&` child here, and
  # `setsid` does NOT close fd 0. Do NOT add `< /dev/null` on the spawn
  # below — that would silently zero out the prompt for every CLI
  # branch, breaking the off-argv channel.
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

# _agy_log_file <session_id>
# _agy_conversation_file <session_id>
#
# Sidecar paths under pid_dir_for_project() for the agy branch
# (Antigravity 2.0 CLI). agy mints conversation UUIDs internally and
# exposes them only via the CLI log file (no JSON event stream on
# stdout). We direct agy's log to a per-session path with --log-file,
# then grep the UUID and persist it to a separate per-session file
# for resume.
#
# Pattern mirrors _codex_thread_file / _opencode_session_file. Two
# files instead of one because the log is mostly noise and is not
# the canonical UUID store — only the sidecar is.
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

# _agy_capture_conversation <session_id> <log_file>
#
# Best-effort capture per [INV-36]: grep the log_file for
#   Print mode: conversation=<UUID>
# and write the UUID to the sidecar. Always returns 0 — capture failure
# (missing log, no match, unwritable sidecar, content fails UUID-shape
# check) must not gate run_agent's exit code, because resume_agent
# falls back to a fresh run when the sidecar is absent.
#
# CWE-59 defense via [[ -L ]] — same pattern as _codex_capture_thread.
#
# UUID shape: agy's print-mode logger emits canonical RFC-4122 form
# (8-4-4-4-12 lowercase hex). Anchoring the capture regex to that
# shape — instead of `[a-f0-9-]+` — refuses pathological strings like
# `---` or single-char matches that a future log-format change might
# produce, so we never write garbage that would later survive
# _agy_conversation_id's read-side regex.
_agy_capture_conversation() {
  local session_id="$1" log_file="$2" conv_file uuid
  conv_file=$(_agy_conversation_file "$session_id") || return 0
  [[ -f "$log_file" ]] || return 0
  uuid=$(grep -oE 'Print mode: conversation=[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' "$log_file" \
    | head -1 | sed 's/.*=//')
  [[ -n "$uuid" ]] || return 0
  if [[ -L "$conv_file" ]]; then
    echo "[lib-agent] WARN: $conv_file is a symlink; refusing to write." >&2
    return 0
  fi
  # Trailing return 0: the printf may fail (read-only fs, full disk, etc.);
  # INV-36 promises capture is best-effort, so swallow the rc.
  printf '%s\n' "$uuid" > "$conv_file" || true
  return 0
}

# _agy_conversation_id <session_id>
#
# Read the captured UUID. Missing sidecar returns rc 1 so resume_agent
# can detect it and fall back to a fresh run_agent.
_agy_conversation_id() {
  local session_id="$1" conv_file uuid
  conv_file=$(_agy_conversation_file "$session_id") || return 1
  # Symlink-defense: refuse to read through a symlink (pid_dir is mode 0700,
  # so this is defense-in-depth). Mirrors _codex_thread_id (CWE-59).
  [[ -L "$conv_file" ]] && return 1
  [[ -f "$conv_file" ]] || return 1
  # `cat` (not `head -n1` like _codex_thread_id) is intentional: multi-line
  # content fails the UUID-shape check below rather than silently passing
  # line 1 — `head` would mask a partial-write corruption.
  uuid=$(cat "$conv_file" 2>/dev/null)
  # Format-validate against canonical RFC-4122 form (8-4-4-4-12 lowercase
  # hex). Anything else (corrupted sidecar, partial write, attacker-planted
  # content past the symlink check) returns missing — resume_agent falls
  # back to a fresh run_agent. This is stricter than `[a-f0-9-]+` (which
  # would accept "---" or "a") so a corrupted sidecar can't silently feed
  # `agy --conversation <bogus>` and burn a dispatch cycle.
  [[ "$uuid" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] || return 1
  printf '%s\n' "$uuid"
}

# _agy_known_model <model>
#
# Answer "is <model> a name `agy models` lists?" — the validation gate for
# the agy --model pass-through (issue #190, [INV-50]).
#
# WHY this exists (the load-bearing fact): `agy -p --model "<anything>"`
# returns rc 0 for ANY string and silently falls back to its default model
# (Gemini 3.5 Flash) — it does NOT reject an invalid id. So the wrapper
# cannot rely on agy to self-error on a cross-namespace id (e.g. kiro's
# "claude-sonnet-4.6" inherited via a shared AGENT_REVIEW_MODEL); forwarding
# it verbatim would put a wrong-model review verdict into the [INV-40]
# unanimous-PASS merge gate undetected. Validating wrapper-side is the only
# way to make a misconfiguration observable.
#
# Enumerates `agy models` ONCE per process (cached in the exported global
# _LIB_AGENT_AGY_MODELS_CACHE) and matches FIXED-STRING, WHOLE-LINE
# (`grep -Fxq`) so model names with spaces/parens ("Gemini 3.5 Flash (High)")
# are literal and a prefix ("Gemini 3.5 Flash") never matches.
#
# Returns:
#   0 — <model> is a known agy model (forward it)
#   1 — enumerated, but <model> is NOT in the list (omit + WARN)
#   2 — `agy models` could not be enumerated (best-effort: forward anyway)
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

# _agy_build_model_args <model> <out_array_name>
#
# Populate the named array with the agy `--model` argv (or leave it empty),
# applying [INV-50] validation via _agy_known_model. Shared by the run_agent
# and resume_agent agy branches so the validate-or-WARN policy lives in one
# place. Resolution:
#   known model           → (--model "$model")
#   enumeration failed     → (--model "$model")   # best-effort pass-through
#   enumerated-but-unknown → ()  + one-time WARN   # omit; agy uses its default
#   empty/unset model      → ()                    # no --model
_agy_build_model_args() {
  local model="$1" out_name="$2"
  # Reset the caller's array, then append only when a model should be forwarded.
  eval "$out_name=()"
  [[ -n "$model" ]] || return 0
  _agy_known_model "$model"
  case $? in
    0|2) eval "$out_name=(--model \"\$model\")" ;;
    *)   # enumerated, model not in the list → skip + warn once.
      if [[ -z "${_LIB_AGENT_AGY_MODEL_WARNED:-}" ]]; then
        echo "[lib-agent] WARN: '${model}' is not a known agy model (see \`agy models\`); omitting --model so agy uses its configured default. Set an agy-namespace model (e.g. AGENT_REVIEW_MODEL_AGY=\"Gemini 3.5 Flash (High)\") to pin one." >&2
        export _LIB_AGENT_AGY_MODEL_WARNED=1
      fi ;;
  esac
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
#
# Prompt-channel contract (closes #144 / [INV-34]): the prompt is fed to the
# agent CLI on stdin via a leading `printf '%s' "$prompt" | ...` stage,
# never as a positional argv element. Linux execve(2) caps any single
# argv element at MAX_ARG_STRLEN = 32 * PAGE_SIZE = 131072 bytes; once the
# issue JSON crossed 128 KB the wrapper crashed with `setsid: Argument
# list too long` on every dispatcher tick. stdin has no comparable
# per-element limit. Each CLI's stdin-mode marker is documented in its
# branch below. Pipeline-stage exit propagation:
#   - claude / gemini / kiro / generic — single downstream stage
#     (`_run_with_timeout`); pipefail is on in the wrapper, so the rc
#     propagates correctly.
#   - codex / opencode — two downstream stages (`_run_with_timeout` →
#     capture awk filter); use PIPESTATUS[1] for the CLI rc, since the
#     printf at PIPESTATUS[0] is always 0 and the awk at the tail is
#     well-behaved.
run_agent() {
  local session_id="$1"
  local prompt="$2"
  local model="${3:-}"
  local session_name="${4:-}"

  local extra_args=()
  _parse_extra_args AGENT_DEV_EXTRA_ARGS extra_args

  case "$AGENT_CMD" in
    claude)
      # Flag list is identical across both invocation paths — only the
      # command prefix differs (see below). `-p` is the headless flag;
      # claude reads the prompt from stdin when -p has no value.
      local claude_args=(
        --session-id "$session_id"
        ${session_name:+--name "$session_name"}
        --permission-mode "$AGENT_PERMISSION_MODE"
        ${model:+--model "$model"}
        "${extra_args[@]}"
        -p
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
      #     `$CLAUDE_CMD "$@"`, so we pass ONLY flags as "$@" —
      #     NOT the binary name and NOT `env -u`. CLAUDECODE handling is
      #     delegated to the launcher.
      if [[ ${#AGENT_LAUNCHER_ARGV[@]} -gt 0 ]]; then
        printf '%s' "$prompt" | _run_with_timeout "${claude_args[@]}"
      else
        printf '%s' "$prompt" | _run_with_timeout env -u CLAUDECODE "$AGENT_CMD" "${claude_args[@]}"
      fi
      ;;
    codex)
      # Codex CLI: headless invocation is `codex exec [PROMPT]` (positional
      # prompt). The legacy `-p` flag now means `--profile` and would parse
      # the prompt as a TOML config profile name — silent breakage.
      #
      # Stdin marker: `codex exec -` reads the prompt from stdin instead
      # of the positional. `--json` streams JSONL events to stdout,
      # including the `thread.started` event from which we capture the
      # thread_id for resume_agent. The capture filter is pass-through
      # so the wrapper's stdout consumption is unchanged.
      #
      # PIPESTATUS[1] surfaces codex's exit code: PIPESTATUS[0] is the
      # leading printf (always 0); the trailing awk at PIPESTATUS[2] is
      # well-behaved and rc=0 on every input. Pre-#144 the pipeline had
      # only two stages and we read PIPESTATUS[0]; the off-argv rewrite
      # adds the printf as a new leading stage.
      printf '%s' "$prompt" \
        | _run_with_timeout "$AGENT_CMD" exec --json \
          ${model:+--model "$model"} \
          "${extra_args[@]}" \
          - \
        | _codex_capture_thread "$session_id"
      return "${PIPESTATUS[1]}"
      ;;
    gemini)
      # Gemini CLI: headless invocation per https://geminicli.com/docs/cli/headless/.
      # `-p` with no value reads the prompt from stdin.
      #
      # Operator-tunable flags (closes #140) live in
      # AGENT_DEV_EXTRA_ARGS / AGENT_REVIEW_EXTRA_ARGS. The two
      # load-bearing values from #102/#134:
      #   --approval-mode yolo      — every write/shell tool defaults to
      #                                ask_user→deny without it (silent
      #                                fabrication failure mode #102 R2).
      #   --output-format stream-json — single-blob `--output-format json`
      #                                  defeats heartbeat liveness; we
      #                                  need the per-event JSONL stream.
      # See autonomous.conf.example "gemini block" for the canonical
      # values; without them, gemini will reproduce the silent
      # fabrication failure that #134 originally fixed.
      #
      # --session-id <UUID> is structural and round-trips: the
      # dispatcher's session_id appears in the `init` event verbatim and
      # is directly usable for `gemini --resume <same-UUID>` later
      # (verified empirically against CLI 0.42.0, #134). claude-style
      # replay — no sidecar capture needed, unlike codex/opencode.
      printf '%s' "$prompt" | _run_with_timeout "$AGENT_CMD" \
        --session-id "$session_id" \
        ${model:+--model "$model"} \
        "${extra_args[@]}" \
        -p
      ;;
    kiro)
      # Kiro CLI does not support named sessions (session_id is ignored).
      # Each invocation starts a new conversation in the current directory.
      # --agent ensures the workspace agent (with TDD hooks) is used.
      #
      # Stdin marker: `kiro chat --no-interactive` with no positional
      # message reads the prompt from stdin.
      #
      # Tool trust (closes #140): operator-tunable via AGENT_DEV_EXTRA_ARGS.
      # The load-bearing flag from #102/#136 is `--trust-all-tools`;
      # without it, stock kiro installs deny every coding tool in
      # --no-interactive mode and emit a fluent fabricated success at
      # exit 0 (the #102 R5 silent-fabrication failure mode). See
      # autonomous.conf.example "kiro block" for the canonical value.
      local kiro_args=(
        chat
        --agent "$KIRO_AGENT_NAME"
        --no-interactive
        ${model:+--model "$model"}
        "${extra_args[@]}"
      )
      printf '%s' "$prompt" | _run_with_timeout kiro-cli "${kiro_args[@]}"
      ;;
    opencode)
      # opencode `run [message..]` is the headless invocation. opencode
      # mints its own session id and emits it on every event in the JSON
      # event stream, so we capture it the same way as codex.
      #
      # Stdin marker: `opencode run` reads the prompt from stdin when no
      # positional message is given.
      #
      # The session_name we got from the dispatcher is passed to --title
      # so opencode's session list shows a human-readable handle alongside
      # the ses_<base62> id.
      #
      # PIPESTATUS[1] for the CLI rc — same shape as codex (printf →
      # _run_with_timeout opencode → capture awk).
      printf '%s' "$prompt" \
        | _run_with_timeout "$AGENT_CMD" run --format json \
          ${model:+--model "$model"} \
          ${session_name:+--title "$session_name"} \
          "${extra_args[@]}" \
        | _opencode_capture_session "$session_id"
      return "${PIPESTATUS[1]}"
      ;;
    agy)
      # Antigravity 2.0 CLI (Google). agy mints conversation UUIDs
      # internally and emits them only via the CLI log file (no JSON
      # event stream). We direct the log to a per-session path with
      # --log-file, then capture the UUID into a sidecar for resume.
      # Pattern mirrors codex/opencode but with a grep-based capture
      # channel. See docs/pipeline/agy-cli-support.md and INV-36.
      #
      # Structural flags (NOT operator-tunable, NOT in EXTRA_ARGS):
      #   -p — headless print mode; reads prompt from stdin per INV-34.
      #   --dangerously-skip-permissions — load-bearing in headless mode;
      #     without it agy denies every tool call. Same role as kiro's
      #     --trust-all-tools and gemini's --approval-mode yolo, but
      #     hardcoded here (not in EXTRA_ARGS like those CLIs) because
      #     every headless agy invocation requires it — there is no
      #     valid agy config that runs headless without this flag.
      #   --print-timeout "$AGENT_TIMEOUT" — agy's internal cap defaults
      #     to 5m, far below AGENT_TIMEOUT (default 4h). Without override,
      #     every wrapper would die in 5m regardless of the outer cap.
      #   --log-file — only programmatic channel for the conversation
      #     UUID; per-session path so concurrent issues do not race.
      #
      # `--model` (issue #190, [INV-50]): agy now honors --model, but it
      # accepts ANY string at rc 0 and silently falls back to its default
      # — so we VALIDATE the resolved id against `agy models` wrapper-side
      # (_agy_build_model_args → _agy_known_model) and forward it only when
      # known; an unknown/cross-namespace id is OMITTED with a one-time WARN
      # (forwarding it verbatim would smuggle a wrong-model verdict into the
      # INV-40 merge gate). Enumeration failure degrades to best-effort
      # pass-through. This is the one CLI that does NOT forward --model
      # verbatim — see [INV-50] for why.
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
    *)
      # Generic fallback: assume `<cli> -p` (with no value) reads from
      # stdin. The `-p` token is preserved so a downstream CLI that
      # actually requires a flag still gets one; if the unknown CLI
      # rejects unknown flags, the failure is loud. If the unknown CLI
      # silently ignores `-p` AND doesn't read stdin, the prompt is
      # silently truncated to empty — emit a one-time warning so the
      # operator knows to verify stdin support before relying on this
      # branch. (`AGENT_CMD` matches none of the five known cases above.)
      if [[ -z "${_LIB_AGENT_GENERIC_WARNED:-}" ]]; then
        echo "[lib-agent] WARN: AGENT_CMD=${AGENT_CMD} hits the generic fallback. The wrapper feeds the prompt via stdin to '${AGENT_CMD} -p'. Verify your CLI accepts a stdin prompt under that flag — otherwise the prompt will be silently truncated. Suppress this warning by setting _LIB_AGENT_GENERIC_WARNED=1." >&2
        export _LIB_AGENT_GENERIC_WARNED=1
      fi
      printf '%s' "$prompt" | _run_with_timeout "$AGENT_CMD" "${extra_args[@]}" -p
      ;;
  esac
}

# Resume an existing agent session.
# Args: $1=session_id, $2=prompt, $3=model (optional), $4=session_name (optional)
# Note: --name may not update the display name on resume (session was already
# named at creation). It is still passed through for kiro/fallback paths that
# start a new session instead of resuming.
#
# Same prompt-channel contract as run_agent (closes #144 / [INV-34]): the
# prompt is fed via stdin, never as a positional argv element.
resume_agent() {
  local session_id="$1"
  local prompt="$2"
  local model="${3:-}"
  local session_name="${4:-}"

  local extra_args=()
  _parse_extra_args AGENT_REVIEW_EXTRA_ARGS extra_args

  case "$AGENT_CMD" in
    claude)
      # See run_agent above for the (A) direct vs. (B) launcher rationale
      # and the stdin contract. --name is omitted on resume — the session
      # retains the name set at creation.
      local claude_args=(
        --resume "$session_id"
        --permission-mode "$AGENT_PERMISSION_MODE"
        ${model:+--model "$model"}
        "${extra_args[@]}"
        -p
        --output-format json
      )
      if [[ ${#AGENT_LAUNCHER_ARGV[@]} -gt 0 ]]; then
        printf '%s' "$prompt" | _run_with_timeout "${claude_args[@]}"
      else
        printf '%s' "$prompt" | _run_with_timeout env -u CLAUDECODE "$AGENT_CMD" "${claude_args[@]}"
      fi
      ;;
    codex)
      # Codex `exec resume <thread_id> [PROMPT]` resumes the conversation.
      # The dispatcher's session_id and codex's thread_id are NOT the same:
      # codex mints its own UUID and we capture it during run_agent into a
      # sidecar keyed by our session_id. Read it back here.
      #
      # Stdin marker `-` and PIPESTATUS[1] match the run_agent codex
      # branch — see that branch's comment block for rationale.
      #
      # If the sidecar is missing (run_agent crashed before thread.started,
      # or this resume_agent is being called without a prior run_agent),
      # fall back to a fresh new-session run — same defensive pattern as
      # the kiro branch, since resuming-a-nonexistent-thread is worse UX
      # than starting clean with the full prompt.
      local _codex_tid
      if _codex_tid=$(_codex_thread_id "$session_id"); then
        printf '%s' "$prompt" \
          | _run_with_timeout "$AGENT_CMD" exec resume "$_codex_tid" --json \
            ${model:+--model "$model"} \
            "${extra_args[@]}" \
            - \
          | _codex_capture_thread "$session_id"
        return "${PIPESTATUS[1]}"
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
      # `-p` (no value) reads the prompt from stdin — same channel
      # contract as the run_agent gemini branch.
      #
      # Operator-tunable flags via AGENT_REVIEW_EXTRA_ARGS (closes #140).
      # The same load-bearing values as the dev side apply on resume:
      # without `--approval-mode yolo` even resume-mode tool calls hit
      # the headless ask_user→deny path. See autonomous.conf.example.
      printf '%s' "$prompt" | _run_with_timeout "$AGENT_CMD" \
        --resume "$session_id" \
        ${model:+--model "$model"} \
        "${extra_args[@]}" \
        -p
      ;;
    kiro)
      # Kiro CLI --resume cannot inject new review feedback effectively —
      # the resumed context sees "all done" and exits immediately.
      # Fall back to a new session so the full prompt (with review findings)
      # is treated as fresh instructions.
      run_agent "$session_id" "$prompt" "$model" "$session_name"
      ;;
    opencode)
      # `opencode run --session <id>` (with stdin prompt) resumes the
      # conversation. Same pattern as the codex branch: read the
      # captured opencode session id from the sidecar, fall back to a
      # new run if missing (run_agent crashed before the first JSON
      # event reached us). PIPESTATUS[1] mirrors the run_agent branch.
      local _opencode_sid
      if _opencode_sid=$(_opencode_session_id "$session_id"); then
        printf '%s' "$prompt" \
          | _run_with_timeout "$AGENT_CMD" run --format json --session "$_opencode_sid" \
            ${model:+--model "$model"} \
            "${extra_args[@]}" \
          | _opencode_capture_session "$session_id"
        return "${PIPESTATUS[1]}"
      else
        echo "[lib-agent] no captured opencode sessionID for session $session_id; starting a new opencode session" >&2
        run_agent "$session_id" "$prompt" "$model" "$session_name"
      fi
      ;;
    agy)
      # See run_agent agy branch for structural-flag rationale and
      # sidecar mechanics. resume reads the captured UUID from the
      # sidecar and feeds it back via --conversation <UUID>. If the
      # sidecar is missing (run_agent never ran for this session, or
      # capture failed per INV-36), fall back to a fresh run_agent —
      # same defensive pattern as the codex / opencode branches.
      local _agy_cid
      if _agy_cid=$(_agy_conversation_id "$session_id"); then
        local agy_log
        agy_log=$(_agy_log_file "$session_id") || return 1
        # Validated --model on resume too (issue #190, [INV-50]). agy may
        # bind the model from the original conversation and ignore a late
        # --model — worst case this is a harmless no-op; verified non-fatal
        # in the test plan (AGY-06c). Same validate-or-WARN policy as
        # run_agent via the shared helper.
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
        # Self-healing re-capture: under normal operation the UUID
        # equals _agy_cid (agy keeps the id on resume), so this is a
        # no-op overwrite. If a future agy version rotates IDs on
        # resume, the sidecar tracks the live one without code change.
        _agy_capture_conversation "$session_id" "$agy_log"
        return $rc
      else
        echo "[lib-agent] no captured agy conversation_id for session $session_id; starting a new agy session" >&2
        run_agent "$session_id" "$prompt" "$model" "$session_name"
      fi
      ;;
    *)
      # Agents without resume support start a new session
      run_agent "$session_id" "$prompt" "$model" "$session_name"
      ;;
  esac
}
