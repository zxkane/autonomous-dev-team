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
# [INV-65] Two-dir resolution. _LIB_AGENT_REAL_DIR is the REAL path (readlink
# -f of this lib's own BASH_SOURCE) used to source the sibling lib-config.sh
# from the skill tree, so the project no longer needs a per-lib symlink for it
# (#227). For CONF lookup we MUST use the entry's project-side dir, NOT this
# lib's own dir: once an entry sources us via its LIB_DIR (the skill tree),
# ${BASH_SOURCE[0]} here IS the skill-tree path, so _LIB_AGENT_DIR would point
# away from the project's scripts/ where autonomous.conf lives. The entry
# therefore exports AUTONOMOUS_CONF_DIR (its UNRESOLVED dir) for us to use;
# we fall back to our own unresolved dir when it's unset (direct/legacy
# sourcing) — preserving [INV-14] across both paths.
_LIB_AGENT_SELF="${BASH_SOURCE[0]:-$0}"
_LIB_AGENT_DIR="$(cd "$(dirname "$_LIB_AGENT_SELF")" && pwd)"
_LIB_AGENT_REAL_DIR="$(cd "$(dirname "$(readlink -f "$_LIB_AGENT_SELF")")" && pwd)"
# shellcheck source=lib-config.sh
source "${_LIB_AGENT_REAL_DIR}/lib-config.sh"
load_autonomous_conf "${AUTONOMOUS_CONF_DIR:-$_LIB_AGENT_DIR}" || true

# Ensure PROJECT_DIR is an absolute path to the repo root.
# autonomous.conf may use a relative BASH_SOURCE trick that can resolve
# incorrectly when sourced indirectly. Fall back to <conf-dir>/../../.. —
# anchored on the entry's project-side conf dir (AUTONOMOUS_CONF_DIR), not this
# lib's skill-tree dir, so the fallback still lands at the project root under
# [INV-65] LIB_DIR sourcing. (This only fires when PROJECT_DIR is unset in conf.)
_LIB_AGENT_CONF_DIR="${AUTONOMOUS_CONF_DIR:-$_LIB_AGENT_DIR}"
PROJECT_DIR="${PROJECT_DIR:-$(cd "${_LIB_AGENT_CONF_DIR}/../../.." && pwd)}"

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
    # [INV-72] config-class abort at source time. Peek `--issue` from the
    # wrapper's "$@" (in scope in this sourced file) and SURFACE on the issue
    # when known, else dispatcher-alert. The wrappers source lib-error.sh first.
    if command -v error_surface >/dev/null 2>&1; then
      error_surface "$(error_peek_issue_arg "$@")" ADT_CFG_LAUNCHER_PARSE \
        "AGENT_LAUNCHER does not tokenize as a shell argv list" \
        "AGENT_LAUNCHER='${_orig_launcher}' has unbalanced quotes / invalid shell words" \
        "Fix AGENT_LAUNCHER in scripts/autonomous.conf to a valid shell argv (e.g. 'cc --role dev'), then re-dispatch" \
        "docs/pipeline/errors.md#configuration-class-class-config" || true
    fi
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
    if command -v error_surface >/dev/null 2>&1; then
      error_surface "$(error_peek_issue_arg "$@")" ADT_CFG_LAUNCHER_PARSE \
        "AGENT_DEV_LAUNCHER does not tokenize as a shell argv list" \
        "AGENT_DEV_LAUNCHER='${_orig_dev_launcher}' has unbalanced quotes / invalid shell words" \
        "Fix AGENT_DEV_LAUNCHER in scripts/autonomous.conf to a valid shell argv (e.g. 'cc --role dev'), then re-dispatch" \
        "docs/pipeline/errors.md#configuration-class-class-config" || true
    fi
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
    if command -v error_surface >/dev/null 2>&1; then
      error_surface "$(error_peek_issue_arg "$@")" ADT_CFG_LAUNCHER_PARSE \
        "AGENT_REVIEW_LAUNCHER does not tokenize as a shell argv list" \
        "AGENT_REVIEW_LAUNCHER='${_orig_review_launcher}' has unbalanced quotes / invalid shell words" \
        "Fix AGENT_REVIEW_LAUNCHER in scripts/autonomous.conf to a valid shell argv (e.g. 'cc --role review'), then re-dispatch" \
        "docs/pipeline/errors.md#configuration-class-class-config" || true
    fi
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
  # [INV-72] config-class failure. This guard runs at source time; lib-agent.sh
  # is sourced with the wrapper's positional params in scope, so peek `--issue`
  # from "$@" and SURFACE on the issue when known (else dispatcher-alert). The
  # wrappers source lib-error.sh before lib-agent.sh; command -v keeps any other
  # sourcing path (e.g. the dispatcher) safe.
  if command -v error_surface >/dev/null 2>&1; then
    error_surface "$(error_peek_issue_arg "$@")" ADT_CFG_LAUNCHER_CLI_MISMATCH \
      "AGENT_DEV_LAUNCHER is set with a non-claude dev CLI (INV-38)" \
      "AGENT_DEV_LAUNCHER is non-empty but AGENT_DEV_CMD=${AGENT_DEV_CMD}" \
      "Unset AGENT_DEV_LAUNCHER (or AGENT_LAUNCHER if it sources the dev-side default), or set AGENT_DEV_CMD=claude, then re-dispatch" \
      "docs/pipeline/errors.md#configuration-class-class-config" || true
  fi
  echo "[lib-agent] ERROR: AGENT_DEV_LAUNCHER is only supported with AGENT_DEV_CMD=claude (got AGENT_DEV_CMD=${AGENT_DEV_CMD}). Either unset AGENT_DEV_LAUNCHER (or AGENT_LAUNCHER if it's the source of the dev-side default) or write a launcher tailored to your CLI." >&2
  return 1 2>/dev/null || exit 1
fi
if [[ ${#AGENT_REVIEW_LAUNCHER_ARGV[@]} -gt 0 && "$AGENT_REVIEW_CMD" != "claude" ]]; then
  if command -v error_surface >/dev/null 2>&1; then
    error_surface "$(error_peek_issue_arg "$@")" ADT_CFG_LAUNCHER_CLI_MISMATCH \
      "AGENT_REVIEW_LAUNCHER is set with a non-claude review CLI (INV-38)" \
      "AGENT_REVIEW_LAUNCHER is non-empty but AGENT_REVIEW_CMD=${AGENT_REVIEW_CMD}" \
      "Unset AGENT_REVIEW_LAUNCHER (or AGENT_LAUNCHER if it sources the review-side default), or set AGENT_REVIEW_CMD=claude, then re-dispatch" \
      "docs/pipeline/errors.md#configuration-class-class-config" || true
  fi
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

  # [INV-79] Agent env scrub. build_agent_env_argv (lib-auth.sh) emits an `env`
  # argv-prefix that gives the agent subtree ONLY the scoped installation token
  # (GH_TOKEN=<scoped>) and strips the wrapper's full-write credential
  # (GH_TOKEN_FILE / GITHUB_PERSONAL_ACCESS_TOKEN / GH_USER_PAT). PATH is left
  # intact so the agent's bare `gh` still resolves the per-run gh shim (which,
  # with GH_TOKEN_FILE unset, execs real gh under the scoped GH_TOKEN — #234
  # review [P1]). CLI-agnostic: applied here, it wraps EVERY adapter's
  # invocation uniformly (claude/codex/gemini/kiro/opencode/agy/generic) and the
  # launcher (the `cc` function) too — `env VAR=x …` sets the env for the command
  # AND all descendants. Emits an EMPTY array (no prefix) in PAT mode /
  # app-mode-mint-failure, so behavior is byte-identical when no scoped token is
  # armed. Guarded on the helper existing so a unit harness that sources lib-agent
  # without lib-auth still runs (no scrub).
  local _agent_env_prefix=()
  if declare -F build_agent_env_argv >/dev/null 2>&1; then
    build_agent_env_argv _agent_env_prefix
  fi

  # Order: [timeout] <env-scrub> <launcher> <agent argv>. The scrub `env …`
  # prefix MUST come BEFORE the launcher (#234 review [P1]): the launcher form
  # is an argv prefix that EXECs the real CLI with its trailing args verbatim
  # (`cc "$@"` / `bash -c '… claude "$@"' --`), so a scrub placed AFTER the
  # launcher is passed to the launcher as positional `$@` and forwarded to
  # `claude` as LITERAL arguments — `env` never runs, the scrub silently no-ops
  # (the agent keeps the full-write credential) AND the bogus `env …` args can
  # make claude fail before it starts. Placing `env …` first runs the LAUNCHER
  # (and thus the agent it execs, and the whole subtree) under the scrubbed
  # environment, which is the intent. With no launcher the order is unchanged in
  # effect (`<env-scrub> <agent argv>`); the claude adapter's own
  # `env -u CLAUDECODE` (launcher-less path A) simply chains after our `env …`,
  # which is valid (the second env inherits the first's modified environment).
  cmd+=("${_agent_env_prefix[@]}" "${AGENT_LAUNCHER_ARGV[@]}" "$@")

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

# _agent_launch_binary — the binary that run_agent/resume_agent will actually
# exec for the active AGENT_CMD. For most CLIs that is AGENT_CMD itself; kiro is
# the one alias (the wrapper invokes `kiro-cli`, not `kiro`). Echoes the binary
# name on stdout. Echoes empty when a launcher is configured — in that case the
# launcher (a `cc` shell function / `bash -c …`) owns binary resolution and a
# misconfigured launcher is already a separate config-class abort (INV-38 /
# ADT_CFG_LAUNCHER_*), so this preflight stands down rather than uselessly
# checking `bash`.
_agent_launch_binary() {
  # A launcher wraps the real CLI — don't preflight here (see above).
  if [[ ${#AGENT_LAUNCHER_ARGV[@]} -gt 0 ]]; then
    echo ""
    return 0
  fi
  # [INV-75] The binary an adapter exec may differ from its id (kiro → kiro-cli).
  # An adapter declares the alias via adapter_binary_<cli>; the default is the id.
  if declare -F "adapter_binary_${AGENT_CMD}" >/dev/null 2>&1; then
    "adapter_binary_${AGENT_CMD}"
  else
    echo "$AGENT_CMD"
  fi
}

# preflight_agent_binary — [INV-72] config-class preflight: confirm the resolved
# agent CLI binary is actually on PATH BEFORE launching/resuming, so a missing
# binary surfaces an operator error envelope instead of failing through
# _run_with_timeout as an opaque rc 127 / generic session failure (the issue
# #231 "missing binary / node-resolution" config-class path). On a miss it posts
# ADT_CFG_AGENT_BINARY_MISSING via error_surface "$ISSUE_NUMBER" (issue context
# from the wrapper's global; `-` → dispatcher-alert) and returns 1; the caller
# (run_agent / resume_agent) returns that as a config failure rather than
# launching a non-existent command. Returns 0 (proceed) when the binary resolves
# OR when a launcher is configured (binary resolution delegated to the launcher).
preflight_agent_binary() {
  local bin; bin="$(_agent_launch_binary)"
  # Launcher configured (empty bin) → skip; nothing to preflight here.
  [[ -z "$bin" ]] && return 0
  if command -v "$bin" >/dev/null 2>&1; then
    return 0
  fi
  if command -v error_surface >/dev/null 2>&1; then
    error_surface "${ISSUE_NUMBER:--}" ADT_CFG_AGENT_BINARY_MISSING \
      "The configured agent CLI binary '${bin}' is not on PATH" \
      "AGENT_CMD=${AGENT_CMD} resolves to the launch binary '${bin}', which 'command -v' cannot find on the execution host's PATH" \
      "Install '${bin}' on the execution host (or fix PATH / AGENT_CMD in scripts/autonomous.conf), then re-dispatch" \
      "docs/pipeline/errors.md#configuration-class-class-config" || true
  fi
  echo "[lib-agent] ERROR: agent CLI binary '${bin}' (AGENT_CMD=${AGENT_CMD}) not found on PATH; aborting before launch (ADT_CFG_AGENT_BINARY_MISSING)." >&2
  return 1
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

# ---------------------------------------------------------------------------
# Per-CLI adapters ([INV-75]). All per-CLI argv assembly, session-handle
# capture/recall, model validation, the per-CLI review lane(s), and the
# drop-reason scrapers live in adapters/<cli>.sh — sourced here so run_agent /
# resume_agent (below) can dispatch to adapter_invoke_<cli>. This file (the
# CLI-agnostic plumbing) carries NO per-CLI review logic itself. Adapters call
# the shared primitives this file defines (_run_with_timeout, _parse_extra_args,
# pid_dir_for_project, preflight_agent_binary) at CALL time, so source order is
# safe. Adapters never re-source lib-agent.sh (would recurse).
#
# [INV-14]/[INV-65]: source by the REAL dir (readlink -f of this lib's own
# BASH_SOURCE) so the adapters resolve from the same skill tree this lib loads
# lib-config.sh from — independent of any per-project scripts/ symlink.
for _adapter in claude codex gemini kiro opencode agy; do
  # shellcheck source=/dev/null
  source "${_LIB_AGENT_REAL_DIR}/adapters/${_adapter}.sh"
done
unset _adapter

# Acquire PID guard: prevent duplicate instances for the same (issue, mode)
# with an ATOMIC acquire (issue #360 / 302a). Checks for symlink attacks,
# then serializes the "is a peer already running? / write my PID" check
# behind an `flock` exclusive lock on `${pid_file}.lock` before touching
# pid_file. flock is atomic at the kernel level (a single syscall grants or
# denies the lock) AND self-releasing: the kernel drops it the instant the
# holder's file descriptor closes — on a clean return, on `exit`, or on the
# process being killed — so there is no "stale lock" state to detect or
# reclaim, and therefore no separate reclaim code path that could itself
# race (an earlier `mkdir`-lock-dir draft had exactly that problem: two
# racers could each decide a lock was stale and `rmdir` it, with the second
# `rmdir` deleting the FIRST racer's freshly-reacquired lock instead of the
# stale one — verified empirically to allow multiple concurrent "winners").
# This closes the pre-#360 TOCTOU window: the old check-then-write read
# pid_file, ran `kill -0`, and only THEN wrote — two wrappers dispatched 1-2s
# apart (a duplicate-dispatch race, see #302/#298) could both pass the
# `kill -0` probe before either wrote, so both proceeded to fan out (the
# #298/PR #300 duplicate-review incident this closes).
#
# The lock's role is scoped to the read-check-write itself (held for a few
# syscalls), NOT the wrapper's lifetime — the lock fd is explicitly closed
# on every exit path below (win or lose), which releases the flock
# immediately rather than waiting for process exit. R1 hard constraint: the
# PID file's read-side semantics (path, content = winner's PID) are
# UNCHANGED — pid_alive (lib-dispatch.sh) and liveness-check-remote-aws-ssm.sh
# keep reading the exact same file. The atomicity lives entirely in HOW the
# file is written (the flock guarding the write), not in a new file format.
#
# R2: the loser of the acquire exits 0 (not an error), logs exactly one
# line, writes nothing, and (since this returns before the caller's
# fan-out/spawn logic ever runs) fans out nothing.
#
# Args: $1=pid_file, $2=label (e.g. "autonomous-dev"), $3=issue_number
acquire_pid_guard() {
  local pid_file="$1" label="$2" issue_num="$3"
  [[ -L "$pid_file" ]] && { echo "Error: PID file is a symlink — possible attack" >&2; exit 1; }

  # flock (util-linux) is required for the atomic acquire below. Fail loud
  # rather than silently falling back to the pre-#360 racy check-then-write —
  # a silent degrade would defeat the entire point of this fix. util-linux is
  # universal on the Linux/Ubuntu dispatcher fleet this project targets (the
  # same assumption _run_with_timeout's setsid dependency already makes).
  if ! command -v flock >/dev/null 2>&1; then
    echo "[$label] ERROR: 'flock' (util-linux) is required by acquire_pid_guard but not found on PATH; aborting before start to avoid the pre-#360 duplicate-start race." >&2
    exit 1
  fi

  local lock_file="${pid_file}.lock"
  # CWE-59 (Link Following), same defense as the pid_file check above
  # (INV-02): reject a symlinked lock sidecar BEFORE the `exec {fd}>` below,
  # which otherwise follows the symlink and truncates whatever it points at
  # — a same-user attacker could pre-plant `${pid_file}.lock` as a symlink
  # to an arbitrary file and have the next wrapper invocation clobber it
  # before flock ever runs (codex review finding on PR #365). Checked on
  # every call (not just when the file is missing) so a symlink planted
  # between two invocations is still caught.
  [[ -L "$lock_file" ]] && { echo "Error: lock file is a symlink — possible attack" >&2; exit 1; }

  local wait_s="${ACQUIRE_PID_GUARD_LOCK_WAIT_SECONDS:-2}"
  local _lock_fd

  exec {_lock_fd}>"$lock_file"
  if ! flock -w "$wait_s" "$_lock_fd"; then
    echo "[$label] Another instance for issue #${issue_num} is already starting (start lock held). Exiting." >&2
    exec {_lock_fd}>&-
    exit 0
  fi

  # Lock held from here to the end of this function. Every exit path below
  # explicitly closes the fd first (releasing the flock) — `exit` does not
  # run a RETURN trap, so we cannot rely on one.
  if [[ -f "$pid_file" ]]; then
    local existing_pid
    existing_pid=$(cat "$pid_file" 2>/dev/null)
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      exec {_lock_fd}>&-
      echo "[$label] Another instance for issue #${issue_num} is already running (PID $existing_pid). Exiting." >&2
      exit 0
    fi
  fi
  # Test-only hook (issue #360 regression coverage): widen the window between
  # the liveness check above and the write below so a concurrent-acquire test
  # can assert the lock — not scheduling luck — is what prevents a double
  # write. No-op (unset) in every real dispatch.
  [[ -n "${_ACQUIRE_PID_GUARD_TEST_DELAY_SECONDS:-}" ]] && sleep "$_ACQUIRE_PID_GUARD_TEST_DELAY_SECONDS"
  echo $$ > "$pid_file"
  exec {_lock_fd}>&-
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

  # [INV-72] Preflight the resolved agent CLI binary so a missing binary
  # surfaces an envelope instead of an opaque rc 127. Returns non-zero (config
  # failure) without launching when the binary is absent.
  preflight_agent_binary || return $?

  # [INV-75] Thin dispatch: every per-CLI argv/flag detail lives in
  # adapters/<cli>.sh::adapter_invoke_<cli> (each parses its own EXTRA_ARGS,
  # assembles its argv, feeds the prompt on stdin per INV-34, and returns the
  # CLI's rc). The ONLY CLI condition here is the dispatch selection + the
  # CLI-agnostic generic fallback for an unknown CLI.
  case "$AGENT_CMD" in
    claude|codex|gemini|kiro|opencode|agy)
      adapter_invoke_"$AGENT_CMD" dev-new "$session_id" "$prompt" "$model" "$session_name"
      ;;
    *)
      # Generic fallback: assume `<cli> -p` (with no value) reads from
      # stdin. The `-p` token is preserved so a downstream CLI that
      # actually requires a flag still gets one; if the unknown CLI
      # rejects unknown flags, the failure is loud. If the unknown CLI
      # silently ignores `-p` AND doesn't read stdin, the prompt is
      # silently truncated to empty — emit a one-time warning so the
      # operator knows to verify stdin support before relying on this
      # branch. (`AGENT_CMD` matches none of the adapter cases above.)
      local extra_args=()
      _parse_extra_args AGENT_DEV_EXTRA_ARGS extra_args
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

  # [INV-72] Preflight the resolved agent CLI binary (same rationale as
  # run_agent). The codex/kiro fresh-session fallbacks inside the adapters
  # re-enter run_agent, which preflights again — harmless (command -v is cheap).
  preflight_agent_binary || return $?

  # [INV-75] Thin dispatch: per-CLI resume semantics live in
  # adapters/<cli>.sh::adapter_invoke_<cli> dev-resume — claude/gemini use
  # --resume; codex/opencode/agy recall a captured session handle and fall back
  # to a fresh run on a sidecar miss; kiro has no usable resume and starts fresh
  # (the adapter handles each). The ONLY CLI condition here is the dispatch
  # selection + the CLI-agnostic generic fallback (fresh run for an unknown CLI).
  case "$AGENT_CMD" in
    claude|codex|gemini|kiro|opencode|agy)
      adapter_invoke_"$AGENT_CMD" dev-resume "$session_id" "$prompt" "$model" "$session_name"
      ;;
    *)
      # Agents without resume support start a new session.
      run_agent "$session_id" "$prompt" "$model" "$session_name"
      ;;
  esac
}
