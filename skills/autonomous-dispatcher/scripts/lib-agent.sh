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
# install GNU coreutils via Homebrew, which provides `gtimeout`. This
# resolution is SHARED between the dev (AGENT_TIMEOUT, 4h default) and review
# (AGENT_REVIEW_TIMEOUT, 1h default) call sites — binary presence is
# orthogonal to which duration value is in effect, so there is exactly one
# detection path, not one per timeout value.
AGENT_TIMEOUT="${AGENT_TIMEOUT:-4h}"
_AGENT_TIMEOUT_CMD="$(command -v timeout || command -v gtimeout || true)"

# AGENT_TIMEOUT_WATCHDOG_FALLBACK (#451) — opt-in escape valve for a host
# missing BOTH coreutils `timeout` and macOS `gtimeout`. Default OFF: the
# safer default (below) is fail-closed, since AGENT_TIMEOUT/_AGENT_TIMEOUT_CMD
# is the ONLY hard per-run bound in the system (no --max-turns, no token
# gate) — silently proceeding unbounded here would remove the last
# containment for a runaway agent. Set to "true" in autonomous.conf to accept
# a pure-shell sleep+kill watchdog (targeting the same setsid PGID
# _run_with_timeout already establishes) instead of refusing to launch.
AGENT_TIMEOUT_WATCHDOG_FALLBACK="${AGENT_TIMEOUT_WATCHDOG_FALLBACK:-false}"

# [INV-126] Fail-closed default when neither binary is found (closes #451).
# Mirrors the INV-38 launcher-mismatch guard shape exactly: this runs at
# lib-agent.sh SOURCE TIME, so it fires on whichever host actually executes
# the wrapper (the execution host under EXECUTION_BACKEND=local OR
# remote-aws-ssm) — never at dispatcher-tick.sh, which may be a different
# host entirely. A pre-arg-parse `error_surface "$(error_peek_issue_arg "$@")"`
# call (the wrapper's own "$@" is in scope while sourced) surfaces on the
# issue when known, else as a dispatcher-alert, exactly like the launcher
# guards above.
if [[ -n "$_AGENT_TIMEOUT_CMD" ]]; then
  echo "[lib-agent] Wall-clock timeout mechanism: $(basename "$_AGENT_TIMEOUT_CMD") (AGENT_TIMEOUT=${AGENT_TIMEOUT})" >&2
elif [[ "$AGENT_TIMEOUT_WATCHDOG_FALLBACK" == "true" ]] && command -v setsid >/dev/null 2>&1; then
  echo "[lib-agent] WARN: neither 'timeout' nor 'gtimeout' found on PATH; falling back to the opt-in pure-shell watchdog (AGENT_TIMEOUT_WATCHDOG_FALLBACK=true). Wall-clock timeout mechanism: watchdog-fallback (AGENT_TIMEOUT=${AGENT_TIMEOUT})." >&2
elif [[ "$AGENT_TIMEOUT_WATCHDOG_FALLBACK" == "true" ]]; then
  # The watchdog's kill targets the setsid-established process GROUP
  # (_run_with_timeout's `setsid` call, below) — without `setsid` on PATH,
  # _AGENT_RUN_PID is an ordinary PID, not a session leader/PGID, so the
  # watchdog's group-form kill silently finds nothing to signal and the
  # agent would run unbounded despite the opt-in. This is exactly the
  # platform combination most likely in practice (a macOS host lacking
  # coreutils often lacks `setsid` too), so it is not a hypothetical edge
  # case — it is treated the same as the plain fail-closed branch below
  # (PR #469 review [P1]: warn-and-proceed here left the run genuinely
  # unbounded, defeating the opt-in's own purpose).
  if command -v error_surface >/dev/null 2>&1; then
    error_surface "$(error_peek_issue_arg "$@")" ADT_CFG_TIMEOUT_TOOL_MISSING \
      "Neither 'timeout' nor 'gtimeout' is available, and AGENT_TIMEOUT_WATCHDOG_FALLBACK=true cannot compensate because 'setsid' is also missing on the host that sources lib-agent.sh" \
      "AGENT_TIMEOUT (INV-13) is the only wall-clock bound on an agent run; the opt-in watchdog fallback requires 'setsid' to establish a killable process group, and without it the watchdog's kill would silently target nothing, leaving the run unbounded" \
      "Install coreutils so 'timeout'/'gtimeout' is on PATH (macOS: 'brew install coreutils'), or install util-linux so 'setsid' is on PATH to make the watchdog fallback effective, then re-dispatch" \
      "docs/pipeline/errors.md#configuration-class-class-config" || true
  fi
  echo "[lib-agent] ERROR: neither 'timeout' nor 'gtimeout' found on PATH, and 'setsid' is also missing so the opt-in watchdog fallback (AGENT_TIMEOUT_WATCHDOG_FALLBACK=true) cannot establish a killable process group; refusing to launch an agent unbounded (ADT_CFG_TIMEOUT_TOOL_MISSING). Wall-clock timeout mechanism: fail-closed-abort. Install coreutils, or install util-linux so 'setsid' is on PATH." >&2
  return 1 2>/dev/null || exit 1
else
  if command -v error_surface >/dev/null 2>&1; then
    error_surface "$(error_peek_issue_arg "$@")" ADT_CFG_TIMEOUT_TOOL_MISSING \
      "Neither 'timeout' nor 'gtimeout' is available on the host that sources lib-agent.sh" \
      "AGENT_TIMEOUT (INV-13) is the only wall-clock bound on an agent run; coreutils 'timeout' (Linux) or 'gtimeout' (macOS, via 'brew install coreutils') is required to enforce it and neither was found on PATH" \
      "Install coreutils so 'timeout'/'gtimeout' is on PATH (macOS: 'brew install coreutils'), or set AGENT_TIMEOUT_WATCHDOG_FALLBACK=true in autonomous.conf to opt into a pure-shell watchdog bound instead, then re-dispatch" \
      "docs/pipeline/errors.md#configuration-class-class-config" || true
  fi
  echo "[lib-agent] ERROR: neither 'timeout' nor 'gtimeout' found on PATH; refusing to launch an agent unbounded (ADT_CFG_TIMEOUT_TOOL_MISSING). Wall-clock timeout mechanism: fail-closed-abort. Install coreutils, or set AGENT_TIMEOUT_WATCHDOG_FALLBACK=true to opt into a watchdog fallback." >&2
  return 1 2>/dev/null || exit 1
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

# _timeout_value_to_seconds <value> — convert a coreutils-`timeout`-style
# duration to whole seconds, for the watchdog fallback's `sleep` (#451). GNU
# `sleep` accepts the same s/m/h/d suffixes as `timeout`, but the watchdog
# fallback exists PRECISELY for hosts lacking GNU coreutils, where `sleep`
# may be the BSD/macOS variant that only accepts a plain integer — so we
# convert ourselves rather than assuming GNU `sleep` semantics. Falls back to
# the INV-13 4h default (14400s) on a value that fails
# `_is_positive_timeout_value` (defensive only; AGENT_TIMEOUT is normally
# either the literal default or an operator-set valid value).
_timeout_value_to_seconds() {
  local v="${1:-}"
  if [[ "$v" =~ ^([1-9][0-9]*)([smhd])?$ ]]; then
    local n="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]:-s}"
    case "$unit" in
      s) echo "$n" ;;
      m) echo $((n * 60)) ;;
      h) echo $((n * 3600)) ;;
      d) echo $((n * 86400)) ;;
    esac
  else
    echo 14400
  fi
}

# _run_with_timeout — invoke "$@" under timeout if available, otherwise (with
# AGENT_TIMEOUT_WATCHDOG_FALLBACK=true, #451) under a pure-shell watchdog.
# AGENT_LAUNCHER_ARGV (if set) is prepended to the command inside the timeout
# boundary so a hung launcher is still killed.
# --kill-after=30s escalates to SIGKILL if the agent ignores the initial
# SIGTERM (some MCP children trap TERM and need the harder push).
# --signal=TERM lets the agent flush any final SSE bytes before dying.
# Exit codes: passthrough on normal exit; 124 on TERM-timeout; 137 on KILL.
# The watchdog fallback path (PR #469 review round-2) mirrors this exactly —
# it normalizes the wrapped command's raw signal-death status to 124 (TERM
# reaped it) or 137 (grace expired, KILL reaped it) rather than leaking a
# bare `wait`-reported value like 143, so downstream consumers that key off
# the 124/137 contract (INV-48 review-veto aggregation, count_agent_failures'
# 124/137 exclusions) see a watchdog expiry exactly like a coreutils
# `timeout` expiry. Only a command that finishes on its own, before the
# watchdog ever fires, passes through its own unmodified exit code.
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
  # [Lane-GC PR-5 / INV-118] FD hygiene: close the inherited guardian write-
  # fd in THIS spawn's fd table before exec'ing into setsid/the agent CLI —
  # `{ADT_GUARD_FD}` fds are NOT close-on-exec by default (verified
  # empirically: they survive across exec() into any binary), so every
  # background spawn site must close its own inherited copy or the
  # guardian's fifo never reaches EOF even after the wrapper itself closes
  # its copy in cleanup(). Wrapped in a subshell (not an inline `cmd
  # {ADT_GUARD_FD}>&-` redirect) because bash treats a redirect naming an
  # UNSET brace-fd variable as an "ambiguous redirect" hard failure — the
  # guarded `[[ -n ]] && exec …` form inside the subshell is a no-op when no
  # guardian was installed this run, and the `exec` on the following line
  # (not a plain invocation) means the subshell process is REPLACED by the
  # command rather than kept around as an extra wrapper layer, so `$!`
  # below still resolves to the actual agent CLI's own PID/PGID (setsid
  # makes it the session leader = the PGID the rest of this function
  # already relies on). stdin is unaffected (the subshell inherits the
  # calling function's stdin exactly like the un-subshelled form did).
  (
    [[ -n "${ADT_GUARD_FD:-}" ]] && exec {ADT_GUARD_FD}>&-
    exec "${launcher[@]}" "${cmd[@]}"
  ) &
  _AGENT_RUN_PID=$!

  # Watchdog fallback (#451, opt-in via AGENT_TIMEOUT_WATCHDOG_FALLBACK):
  # neither 'timeout' nor 'gtimeout' is on PATH (the fail-closed default at
  # source time already refused to get here unless the operator opted in).
  # A pure-shell `sleep $AGENT_TIMEOUT && kill -TERM -- -<pgid>` stands in for
  # coreutils `timeout`, targeting the SAME PGID `setsid` established above
  # (never a lone PID — a single-PID kill would leave orphaned descendants
  # the PGID-based kill_stale_wrapper/lane-GC machinery is designed to
  # reap). Isolated in its own `setsid` (when available) so it is never a
  # member of the group it is about to signal.
  #
  # Deliberately NOT `disown`ed (PR #469 review round-3 [P1]): the
  # reconciliation block below needs `wait "$_watchdog_pid"` to actually
  # BLOCK until the watchdog's own escalation finishes — bash's `wait <pid>`
  # on a disowned job returns immediately with rc 0 without waiting for it
  # (verified against bash 5.3; a disowned PID is dropped from the shell's
  # job table, and an untracked job can't be waited on). Leaving it un-
  # disowned does NOT make `wait "$_AGENT_RUN_PID"` below block on it too —
  # `wait` given an explicit PID targets only that PID, regardless of what
  # else is running in the job table.
  #
  # Self-contained TERM→30s-grace→KILL body (not a delegate to the shared
  # `_kill_group_escalate`, lib-lane.sh): the caller below needs to know
  # WHETHER the watchdog actually fired and WHICH signal finally reaped the
  # group, and `_kill_group_escalate` exposes neither (it always returns 0).
  # `$3` is a result-marker file path, written (via atomic tmp+mv) — "124"
  # for the TERM step, overwritten with "137" if the grace window elapses
  # and KILL is needed.
  #
  # Ordering is load-bearing (TC-TIMEOUTGUARD-025): the marker is written
  # BEFORE `kill -TERM` is sent, not after. `_run_with_timeout`'s own `wait`
  # on the wrapped command races the watchdog's own script independently —
  # if the marker write came AFTER the kill, a TERM-obeying leader could die
  # from the signal and unblock that `wait` before the watchdog's next
  # statement (the marker write) ever executed, so the caller could observe
  # "command exited" with no marker on disk yet and wrongly keep the raw
  # signal-death rc. Writing the marker first closes that window; if the
  # kill then turns out to be a no-op (group already gone — the command
  # finished naturally at the same instant the watchdog woke, a coincidence
  # any timeout mechanism can race), the marker is removed again so the
  # caller correctly keeps its own already-captured natural exit code.
  local _watchdog_pid="" _wd_result_file=""
  if [[ -z "$_AGENT_TIMEOUT_CMD" && "${AGENT_TIMEOUT_WATCHDOG_FALLBACK:-false}" == "true" ]]; then
    local _wd_secs; _wd_secs="$(_timeout_value_to_seconds "$AGENT_TIMEOUT")"
    # AGENT_TIMEOUT accepts values coreutils `timeout` supports but this
    # helper does not model exactly (e.g. `1.5h`, `infinity` — both
    # documented as legitimate dev-side values elsewhere in the codebase):
    # those silently fall through to the 14400s (4h) default inside
    # _timeout_value_to_seconds. Surface that divergence instead of leaving
    # it silent, since a watchdog bound that doesn't match the operator's
    # configured AGENT_TIMEOUT is exactly the kind of drift this feature
    # exists to prevent.
    if ! _is_positive_timeout_value "$AGENT_TIMEOUT"; then
      echo "[lib-agent] WARN: AGENT_TIMEOUT='${AGENT_TIMEOUT}' is not an integer+unit value the watchdog fallback can parse; using the 14400s (4h) default bound instead." >&2
    fi
    _wd_result_file="$(mktemp 2>/dev/null)" || _wd_result_file=""
    local _wd_setsid=()
    command -v setsid >/dev/null 2>&1 && _wd_setsid=(setsid)
    # _AGENT_WATCHDOG_GRACE_SECS — test-only seam (never read anywhere else,
    # never documented to operators) to shrink the 30s TERM->KILL grace
    # window so unit tests can exercise the KILL-escalation path without a
    # real 30s sleep.
    local _wd_grace="${_AGENT_WATCHDOG_GRACE_SECS:-30}"
    # _AGENT_WATCHDOG_TERM_DELAY_SECS — test-only seam (never read anywhere
    # else, never documented to operators), same spirit as
    # _AGENT_WATCHDOG_GRACE_SECS above: widens the window between the marker
    # write and the `kill -TERM` attempt so a unit test can deterministically
    # land a natural finish inside it (TC-TIMEOUTGUARD-028 — the round-4
    # rescinded-marker race). Zero in production, so no behavior change.
    local _wd_term_delay="${_AGENT_WATCHDOG_TERM_DELAY_SECS:-0}"
    # _AGENT_WATCHDOG_WAKE_DELAY_SECS — test-only seam (never read anywhere
    # else, never documented to operators): widens the window between the
    # watchdog's deadline `sleep "$1"` returning and its marker write, so a
    # unit test can deterministically land the leader's natural exit AND the
    # parent's `wait "$_AGENT_RUN_PID"` unblocking inside that window —
    # before any marker exists on disk (TC-TIMEOUTGUARD-029, the round-5
    # boundary-tie race: the reconciliation's cancel-vs-wait decision must
    # not rely on marker presence alone). Zero in production, so no
    # behavior change.
    local _wd_wake_delay="${_AGENT_WATCHDOG_WAKE_DELAY_SECS:-0}"
    # Watchdog body ("$1"=sleep seconds, "$2"=setsid PGID, "$3"=result-marker
    # path, "$4"=grace seconds, "$5"=marker-to-kill test delay, "$6"=wake-to-
    # marker test delay). Kept a full single-quoted literal so
    # `$1`/`$2`/`$3`/`$4`/`$5`/`$6`/`${ADT_GUARD_FD}` expand inside the
    # spawned shell, not out here.
    local _wd_body='
      [[ -n "${ADT_GUARD_FD:-}" ]] && exec {ADT_GUARD_FD}>&-
      sleep "$1"
      sleep "$6"
      if [[ -n "$3" ]]; then
        printf "%s" 124 > "$3.tmp" && mv -f "$3.tmp" "$3"
      fi
      sleep "$5"
      if ! kill -TERM -- "-$2" 2>/dev/null; then
        # Group already gone: a natural-finish race (the wrapped command
        # exited on its own the instant the watchdog woke up). Our signal
        # never landed, so take back the marker — the caller must keep its
        # own already-captured natural exit code, not a fabricated 124.
        [[ -n "$3" ]] && rm -f "$3" "$3.tmp" 2>/dev/null
        exit 0
      fi
      for ((i = 0; i < "$4"; i++)); do
        kill -0 -- "-$2" 2>/dev/null || exit 0
        sleep 1
      done
      kill -KILL -- "-$2" 2>/dev/null || true
      if [[ -n "$3" ]]; then
        printf "%s" 137 > "$3.tmp" && mv -f "$3.tmp" "$3"
      fi
    '
    "${_wd_setsid[@]}" bash -c "$_wd_body" _ "$_wd_secs" "$_AGENT_RUN_PID" "$_wd_result_file" "$_wd_grace" "$_wd_term_delay" "$_wd_wake_delay" &
    _watchdog_pid=$!
  fi

  # [Lane-GC PR-2 / INV-110] Append this spawn's PGID to the lane registry
  # (durable — survives ANY sidecar tmpdir being rm -rf'd, unlike
  # AGENT_PID_FILE above). ADT_LANE_DIR is exported by the wrapper after
  # lane_install; every _run_with_timeout call site (dev run_agent/
  # resume_agent, each review fan-out subshell, smoke probes, the browser E2E
  # lane) therefore gets covered from this ONE chokepoint with no per-call-site
  # plumbing. ADT_LANE_ROLE defaults to "agent" (the dev-side / single-lane
  # case); fan-out/smoke/E2E subshells override it before calling run_agent.
  # Best-effort: lane_record_pgid itself already no-ops on a missing/unset
  # lane dir, so this never affects _run_with_timeout's own contract.
  if declare -F lane_record_pgid >/dev/null 2>&1; then
    lane_record_pgid "${ADT_LANE_DIR:-}" "$_AGENT_RUN_PID" "${ADT_LANE_ROLE:-agent}"
  fi

  if [[ -n "${AGENT_PID_FILE:-}" && ! -L "$AGENT_PID_FILE" ]]; then
    # Symlink-defence (CWE-59): refuse to follow a symlink. We don't
    # remove it either — acquire_pid_guard rejects symlinks at entry, so
    # we only get here if one was planted between guard and spawn
    # (extremely narrow race). Skip the write rather than expand the
    # attack surface.
    printf '%s\n' "$_AGENT_RUN_PID" > "$AGENT_PID_FILE" 2>/dev/null || true
  fi

  local _rc
  wait "$_AGENT_RUN_PID"
  _rc=$?

  # Reconcile with the watchdog (PR #469 review round-2, both [P1]s):
  #
  # 1. If the watchdog has ALREADY signalled the group (result-marker file
  #    non-empty), do NOT cancel it — let it run its own grace-then-KILL
  #    escalation to completion before we return. Cancelling here on the
  #    leader's `wait` alone was the bug: a TERM-ignoring descendant that
  #    outlives the leader needs the watchdog's still-pending 30s-grace →
  #    KILL step to actually be reaped, and killing the watchdog job the
  #    instant the LEADER dies abandoned that pending KILL, leaving the
  #    descendant to survive indefinitely past this function's return.
  #    The watchdog writes its marker BEFORE calling `kill -TERM` (not
  #    after), so there is no race window here: the only way this `wait`
  #    can unblock AS A RESULT OF the watchdog's TERM is if the marker was
  #    already written first (sequential within the watchdog's own script).
  # 2. Normalize `_rc` to the marker's 124 (TERM) / 137 (KILL) value instead
  #    of the raw signal-death status `wait` reports (e.g. 143 for a plain
  #    SIGTERM death) — the rest of the pipeline's timeout contract
  #    (INV-48 review-veto aggregation via _classify_noverdict_agent,
  #    count_agent_failures' 124/137 exclusions) keys off exactly 124/137;
  #    an un-normalized 143 previously fell through to the "unavailable /
  #    dropped" path (or "real failure") instead of the timeout veto a
  #    watchdog-expired review is supposed to trigger.
  # 3. If the watchdog has NOT fired yet (empty marker), it's genuinely safe
  #    to cancel immediately — the original TC-TIMEOUTGUARD-022 fast-finish
  #    case (a deferred kill left armed against a PGID a later spawn could
  #    reuse).
  # 4. Rescind race (PR #469 review round-4 [P1]): the watchdog writes its
  #    124 marker BEFORE `kill -TERM`, so we can observe a non-empty marker
  #    here even when the wrapped command finished naturally the instant the
  #    watchdog woke — the watchdog's own `kill -TERM` then finds the group
  #    already gone and rescinds by deleting the marker file (see the
  #    watchdog body above). If our post-`wait` re-read fails because the
  #    file is GONE (rescinded), that is authoritative proof of a natural
  #    finish — keep the natural `_rc` already captured at the `wait
  #    "$_AGENT_RUN_PID"` above. Falling back to the stale pre-wait
  #    `_wd_marker` value here (the prior bug) would relabel a genuine
  #    natural exit as a fabricated 124 timeout.
  # 5. Boundary-tie race (PR #469 review round-5 [P1]): the marker is not
  #    written until AFTER the watchdog's own `sleep "$1"` returns, so if
  #    the wrapped command's leader exits naturally at essentially the same
  #    instant `AGENT_TIMEOUT` elapses, this `wait "$_AGENT_RUN_PID"` can
  #    unblock BEFORE the watchdog has gotten around to writing anything —
  #    the marker read below (step 3's empty-marker "safe to cancel" case)
  #    would then wrongly treat "watchdog hasn't fired" as "nothing left to
  #    protect" and kill the watchdog job outright, abandoning any
  #    TERM-ignoring descendant that outlived the leader. Marker presence is
  #    only a PROXY for "is anything left to reap" — the process GROUP's own
  #    liveness (`kill -0 -- "-$_AGENT_RUN_PID"`) is the authoritative
  #    signal and is checked directly here as well: an empty marker is only
  #    treated as "safe to cancel" when the group is ALSO already empty. A
  #    still-alive group defers to the watchdog exactly like a fired marker
  #    would — even though the marker hasn't landed on disk yet, the
  #    watchdog is either about to write it or already past the sleep and
  #    mid-write, so blocking here converges on the same outcome without
  #    the race. This also makes reconciliation robust to a `mktemp`
  #    failure (`_wd_result_file=""`, no marker ever possible) — group
  #    liveness alone is enough to decide whether a still-alive descendant
  #    needs the watchdog's escalation, independent of the marker file.
  if [[ -n "$_watchdog_pid" ]]; then
    local _wd_marker=""
    [[ -n "$_wd_result_file" && -s "$_wd_result_file" ]] && _wd_marker="$(cat "$_wd_result_file" 2>/dev/null)"
    if [[ -n "$_wd_marker" ]] || kill -0 -- "-$_AGENT_RUN_PID" 2>/dev/null; then
      wait "$_watchdog_pid" 2>/dev/null || true
      # Re-read: the watchdog may have escalated 124 -> 137 while we were
      # waiting on it just now, OR rescinded (removed the file) if its
      # kill turned out to be a no-op — only trust a marker that still
      # exists post-wait; a missing file means "keep the natural _rc".
      if [[ -s "$_wd_result_file" ]]; then
        _rc="$(cat "$_wd_result_file" 2>/dev/null)"
      fi
    else
      kill "$_watchdog_pid" 2>/dev/null || true
      wait "$_watchdog_pid" 2>/dev/null || true
    fi
    rm -f "$_wd_result_file" "${_wd_result_file}.tmp" 2>/dev/null || true
  fi

  return "$_rc"
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

# _probe_user_install_dirs <bin> — [#458] on a `command -v` miss, check a small
# fixed list of common user-level install dirs before concluding the binary is
# genuinely absent. Read-only (a handful of `[[ -x ... ]]` checks) — never
# mutates PATH; that fix is the operator's call. Echoes the first matching
# directory's binary path on stdout and returns 0; returns 1 (no output) when
# not found in any probed dir (including when `$HOME` is unset/empty, in
# which case there is nothing to probe under `set -u`). Order: ~/.local/bin,
# ~/bin, ~/.npm-global/bin, then the first EXECUTABLE match across all nvm
# shim dirs (nvm installs one copy per node version under
# ~/.nvm/versions/node/<v>/bin — a stale/non-executable copy under one
# version must not shadow a valid one under another, so every glob match is
# checked in turn rather than only the first). `-f` alongside `-x` excludes a
# same-named directory (which passes a bare `-x` test but isn't a launchable
# binary).
_probe_user_install_dirs() {
  local bin="$1" dir nvm_hit
  [[ -z "${HOME:-}" ]] && return 1
  for dir in "$HOME/.local/bin" "$HOME/bin" "$HOME/.npm-global/bin"; do
    if [[ -f "$dir/$bin" && -x "$dir/$bin" ]]; then
      echo "$dir/$bin"
      return 0
    fi
  done
  while IFS= read -r nvm_hit; do
    if [[ -n "$nvm_hit" && -f "$nvm_hit" && -x "$nvm_hit" ]]; then
      echo "$nvm_hit"
      return 0
    fi
  done < <(compgen -G "$HOME/.nvm/versions/node/*/bin/$bin" 2>/dev/null)
  return 1
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
#
# [#458] A `command -v` miss does not necessarily mean "not installed" — a
# binary living under a user-level install dir (~/.local/bin, an nvm shim,
# etc.) is invisible to a non-login shell's PATH (cron / SSM / nohup), and the
# original single remediation ("Install '<bin>'...") steered operators at a
# perfectly fine install. Before composing the envelope, probe those dirs
# (_probe_user_install_dirs) and branch the cause/remediation: found there →
# name the found path and point at PATH/launcher/absolute-AGENT_CMD fixes;
# not found anywhere → keep the install-focused remediation, but now also
# include the effective $PATH (or the literal "<unset>" marker if $PATH
# itself is unbound, so composing this cause text can never crash under
# `set -u`) so the operator can see what a fresh install would need to land on.
preflight_agent_binary() {
  local bin; bin="$(_agent_launch_binary)"
  # Launcher configured (empty bin) → skip; nothing to preflight here.
  [[ -z "$bin" ]] && return 0
  if command -v "$bin" >/dev/null 2>&1; then
    return 0
  fi
  local found_path
  if found_path=$(_probe_user_install_dirs "$bin"); then
    if command -v error_surface >/dev/null 2>&1; then
      error_surface "${ISSUE_NUMBER:--}" ADT_CFG_AGENT_BINARY_MISSING \
        "The configured agent CLI binary '${bin}' is not on PATH" \
        "AGENT_CMD=${AGENT_CMD} resolves to the launch binary '${bin}'; it exists at ${found_path} but that directory is not on the wrapper's PATH (non-login shell — cron/SSM/nohup do not source the interactive profile)" \
        "Extend PATH in the dispatcher/wrapper environment to include $(dirname "$found_path"), use an AGENT_LAUNCHER that sources the user profile, or set AGENT_CMD to the absolute path ${found_path}, then re-dispatch" \
        "docs/pipeline/errors.md#configuration-class-class-config" || true
    fi
    echo "[lib-agent] ERROR: agent CLI binary '${bin}' (AGENT_CMD=${AGENT_CMD}) found at ${found_path} but not on PATH; aborting before launch (ADT_CFG_AGENT_BINARY_MISSING)." >&2
    return 1
  fi
  if command -v error_surface >/dev/null 2>&1; then
    local _probe_note="also checked ~/.local/bin, ~/bin, ~/.npm-global/bin, and nvm shim dirs"
    [[ -z "${HOME:-}" ]] && _probe_note="HOME is unset/empty, so the user-level install dirs could not be probed"
    error_surface "${ISSUE_NUMBER:--}" ADT_CFG_AGENT_BINARY_MISSING \
      "The configured agent CLI binary '${bin}' is not on PATH" \
      "AGENT_CMD=${AGENT_CMD} resolves to the launch binary '${bin}', which 'command -v' cannot find on the execution host's PATH (${_probe_note}); effective PATH=${PATH:-<unset>}" \
      "Install '${bin}' on the execution host (or fix PATH / AGENT_CMD in scripts/autonomous.conf), then re-dispatch" \
      "docs/pipeline/errors.md#configuration-class-class-config" || true
  fi
  echo "[lib-agent] ERROR: agent CLI binary '${bin}' (AGENT_CMD=${AGENT_CMD}) not found on PATH; aborting before launch (ADT_CFG_AGENT_BINARY_MISSING)." >&2
  return 1
}

# _agent_sigterm_handler — the trap body install_agent_sigterm_trap installs
# (kept as a real function, not an inline trap string, so `local` and the
# backgrounded escalator below both work correctly; a bare trap string runs
# in the top-level shell context, where `local` is a silent no-op).
#
# [Lane-GC PR-3 / INV-114] TERM's target set is every REGISTRY-RECORDED pgid
# in `${ADT_LANE_DIR}/pgids`, not just `_AGENT_RUN_PID` — this closes the
# review-side dead arm: the review wrapper's own agents run inside
# per-fan-out-member `( … ) &` subshells, so `_AGENT_RUN_PID` in the MAIN
# shell (where this trap fires) is ALWAYS empty on the review side — only
# each fan-out subshell's OWN local variable was ever set. The durable
# `pgids` file is the one place every spawn (dev run_agent, every review
# fan-out member, E2E, smoke) is recorded regardless of which shell spawned
# it, so reading it here reaches all of them, dev and review alike.
#
# Each recorded pgid escalates via the shared `_kill_group_escalate`
# (lib-lane.sh, INV-106/INV-114) in its OWN backgrounded job — TERM now,
# KILL after a bounded grace if the group is still reachable — so N groups'
# grace windows run CONCURRENTLY and the trap handler itself returns
# immediately (the wrapper's own EXIT-trap cleanup() must never be delayed
# waiting out an inline grace here). Falls back to an inline TERM+backgrounded-
# KILL pair when `_kill_group_escalate` is unavailable (lib-lane.sh failed to
# source, or a unit harness sources lib-agent.sh in isolation) so escalation
# degrades gracefully rather than silently vanishing.
#
# Ordering pin (found empirically while building this trap — a genuine bug,
# not a style choice): the direct-children `pkill -TERM -P $$` fallback MUST
# run BEFORE any escalator job is backgrounded, never after. Each backgrounded
# escalator (`_kill_group_escalate … &`) is itself a direct child of THIS
# shell (`$$`), so a `pkill -P $$` issued after backgrounding would TERM the
# escalator subshell mid-grace-wait and silently abort its KILL follow-through
# — the escalated group would then survive forever past its grace window,
# defeating the very escalation this trap exists to guarantee.
_agent_sigterm_handler() {
  RECEIVED_SIGTERM=1

  # Direct-children fallback for the pre-spawn race window (pre-#109
  # behavior, unchanged). Pinned narrow to `-P $$` — [INV-114] grep-pin:
  # NEVER widen to `-f <script-name>` (widening would cross-kill sibling
  # lanes on a multi-issue/multi-project host sharing the same wrapper
  # script name). Runs FIRST — see the ordering pin above.
  pkill -TERM -P $$ 2>/dev/null || true

  local -a _term_pgids=()
  [[ -n "${_AGENT_RUN_PID:-}" ]] && _term_pgids+=("$_AGENT_RUN_PID")
  local _pgids_file=""
  [[ -n "${ADT_LANE_DIR:-}" ]] && _pgids_file="${ADT_LANE_DIR}/pgids"
  if [[ -n "$_pgids_file" && -f "$_pgids_file" ]]; then
    local _pg _rest _already _s
    while read -r _pg _rest; do
      [[ "$_pg" =~ ^[0-9]+$ ]] || continue
      _already=0
      for _s in "${_term_pgids[@]:-}"; do [[ "$_s" == "$_pg" ]] && { _already=1; break; }; done
      [[ "$_already" -eq 1 ]] && continue
      _term_pgids+=("$_pg")
    done < "$_pgids_file"
  fi

  # [Lane-GC PR-3 / INV-114] Escalator process-group isolation (review
  # round-5 [P1], reproduced empirically): a backgrounded escalator that is a
  # DIRECT CHILD of this trap's own shell — with no `setsid` of its own —
  # shares THIS WRAPPER's own pgid. That is fatal to the escalator's own
  # grace window whenever the wrapper's OWN pgid later receives a group-form
  # signal from someone else while the escalator is still asleep — and that
  # happens routinely in production: a wrapper can legitimately receive a
  # SECOND TERM (kill_stale_wrapper's legacy PID-file path always sends
  # group-form then individual-form TERM to the same old_pid; the
  # dispatcher's Step 5a SIGTERM race, [INV-15], is another), and if the
  # wrapper's main body still hasn't exited after ITS OWN grace,
  # kill_stale_wrapper escalates to a GROUP-FORM SIGKILL against old_pid's
  # pgid — the same pgid an unisolated escalator still lives in. That
  # SIGKILL collaterally kills the escalator mid-grace, permanently
  # discarding its pending SIGKILL follow-through for any TERM-resistant
  # registry member — a real, reproducible leak (verified: a TERM-trapping
  # registry pgid survived indefinitely past this exact sequence, with no
  # escalator ever completing; a plain `trap '' TERM` on the escalator does
  # NOT fix this, since SIGKILL cannot be trapped — the escalator must be
  # OUT of the reachable pgid entirely). Each pgid escalates in its OWN
  # `setsid`-isolated subshell (one per pgid, so N groups' grace windows
  # still run CONCURRENTLY — the pre-existing per-pgid-backgrounded-job
  # shape is preserved) — no signal aimed at the wrapper's pgid (or any
  # OTHER kill site's pgid) can ever reach an isolated escalator; only the
  # target pgid it's escalating against, and its own bounded
  # sleep-then-KILL sequence, decide its lifetime. `_kill_group_escalate`
  # itself has no internal function calls, so (unlike `_bounded_call`,
  # whose own doc comment rejects `export -f` for exactly this reason)
  # `export -f` safely carries it across the `setsid bash -c` boundary —
  # the shared primitive stays the single source of truth for the
  # TERM→grace→KILL body rather than a second inlined copy of it.
  local _setsid=()
  command -v setsid >/dev/null 2>&1 && _setsid=(setsid)
  local _pg
  # [Lane-GC PR-5 / INV-118] FD hygiene: these escalators are short-lived
  # (bounded at ~5s) and NOT in the design's explicit fd-hygiene spawn list
  # (§4-C3 names `_run_with_timeout`, heartbeat, token daemons, fan-out/E2E/
  # smoke — long-lived spawns), so a forgotten close here would only ever
  # degrade the guardian's EOF by a few seconds (design §10's accepted
  # "subtree died, not wrapper died" degradation) — closed anyway since the
  # fix is one line per branch and this function is already being touched.
  if declare -F _kill_group_escalate >/dev/null 2>&1; then
    export -f _kill_group_escalate
    for _pg in "${_term_pgids[@]:-}"; do
      "${_setsid[@]}" bash -c '[[ -n "${ADT_GUARD_FD:-}" ]] && exec {ADT_GUARD_FD}>&-; _kill_group_escalate "$1" "$2"' _ "$_pg" 5 &
      disown 2>/dev/null || true
    done
  else
    for _pg in "${_term_pgids[@]:-}"; do
      kill -TERM -- "-${_pg}" 2>/dev/null || true
    done
    if [[ "${#_term_pgids[@]}" -gt 0 ]]; then
      "${_setsid[@]}" bash -c '
        [[ -n "${ADT_GUARD_FD:-}" ]] && exec {ADT_GUARD_FD}>&-
        sleep 5
        for pg in "$@"; do
          kill -0 -- "-${pg}" 2>/dev/null && kill -KILL -- "-${pg}" 2>/dev/null || true
        done
      ' _ "${_term_pgids[@]}" &
      disown 2>/dev/null || true
    fi
  fi
}

# install_agent_sigterm_trap — install the standard SIGTERM-to-PGID trap
# in the calling wrapper shell (closes #109). Used by autonomous-dev.sh
# and autonomous-review.sh so the two share the contract: forward TERM
# to every registry-recorded process group plus a direct-children fallback
# for the pre-spawn race window.
#
# Callers may set RECEIVED_SIGTERM=0 first if they need to read the flag
# in their cleanup() trap (autonomous-dev.sh does for INV-15 / #67); the
# trap installed here writes RECEIVED_SIGTERM=1 either way.
install_agent_sigterm_trap() {
  trap '_agent_sigterm_handler' TERM
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
    # [Lane-GC PR-5 / INV-118] FD hygiene: close the inherited guardian
    # write-fd — this subshell backgrounds a long-lived loop (never exec's
    # away), so a bare `[[ -n ]] && exec {ADT_GUARD_FD}>&-` at the top
    # closes it in THIS subshell's own fd table without affecting the
    # wrapper's copy.
    [[ -n "${ADT_GUARD_FD:-}" ]] && exec {ADT_GUARD_FD}>&-
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
  # CWE-59 (Link Following) defense-in-depth, same posture as the pid_file
  # check above (INV-02): reject an OBVIOUSLY symlinked lock sidecar before
  # even trying to open it. This is belt-and-suspenders, NOT the load-bearing
  # fix — see the `>>` note below for why: a HARD link shares the target's
  # inode and is never reported by `-L` (a hard-linked sidecar sails through
  # this check untouched; PR #365 review finding), so a symlink-only guard is
  # incomplete on its own.
  [[ -L "$lock_file" ]] && { echo "Error: lock file is a symlink — possible attack" >&2; exit 1; }

  # Load-bearing (PR #365 review finding, round 3): reject a lock path that
  # EXISTS but is not a regular file — a FIFO, socket, character/block
  # device, or directory. `-f` follows a symlink (already excluded above)
  # and true for a hard link to a regular file, so this correctly allows
  # both while catching everything else. Without this, `exec {fd}>>` on a
  # FIFO with no reader BLOCKS INSIDE THE OPEN ITSELF — before `flock -w`
  # ever gets a chance to run its bounded wait — so a same-user process (or
  # stale artifact) that leaves `${pid_file}.lock` as a FIFO hangs the
  # wrapper indefinitely; the `wait_s` timeout below is never reached
  # because the redirection never returns. Reproduced with `mkfifo` +
  # `timeout 3 acquire_pid_guard …` → rc 124 (never returns) before this
  # check existed. A MISSING lock_file is fine — `>>` creates a fresh
  # regular file — so the check is scoped to "exists AND is not a regular
  # file", not "must already exist as a regular file".
  if [[ -e "$lock_file" && ! -f "$lock_file" ]]; then
    echo "Error: lock file exists but is not a regular file (FIFO/socket/device/directory) — possible attack or stale artifact; refusing to open it" >&2
    exit 1
  fi

  local wait_s="${ACQUIRE_PID_GUARD_LOCK_WAIT_SECONDS:-2}"
  local _lock_fd

  # Load-bearing fix: open in APPEND mode (`>>`, O_CREAT|O_APPEND, no
  # O_TRUNC), never plain `>` (O_CREAT|O_TRUNC). `>` truncates the target on
  # open BEFORE flock ever runs — the exact vector a symlinked OR hard-linked
  # lock sidecar exploits: a same-user attacker pre-plants
  # `${pid_file}.lock` as a symlink or hard link to an arbitrary victim file,
  # and the next wrapper invocation zeroes it just by opening it, regardless
  # of whether it ever acquires the lock. `>>` never truncates on open
  # (verified: neither via a symlinked nor a hard-linked target) — this
  # closes the ENTIRE class (symlink AND hard link), not just the symlink
  # case the `-L` check above already caught. We never write through this
  # fd (the PID goes to `pid_file`, not `lock_file`), so append-vs-truncate
  # semantics make no functional difference to the lock itself — `flock`
  # behaves identically on an append-mode fd.
  exec {_lock_fd}>>"$lock_file"
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
