#!/bin/bash
# autonomous-review.sh — Wrapper for autonomous review agent tasks.
#
# Reviews a PR linked to an issue, then either merges (pass) or sends back (fail).
# Uses a lighter model by default to avoid quota contention with dev tasks.
# Called by dispatcher via SSM or manually.
#
# Usage:
#   scripts/autonomous-review.sh --issue <number>
#
# Exit codes:
#   0 — Review completed (pass or fail)
#   1 — Review process error

set -euo pipefail

# [INV-14] Use BASH_SOURCE[0] (NOT readlink -f) so a project-side symlink
# at <project>/scripts/autonomous-review.sh resolves SCRIPT_DIR to the
# project's scripts/. lib-agent.sh's load_autonomous_conf then finds
# autonomous.conf via tier-2 (same dir).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "${SCRIPT_DIR}/lib-agent.sh"
source "${SCRIPT_DIR}/lib-auth.sh"
# shellcheck source=lib-review-bots.sh
source "${SCRIPT_DIR}/lib-review-bots.sh"
# shellcheck source=lib-review-verdict.sh
source "${SCRIPT_DIR}/lib-review-verdict.sh"
# shellcheck source=lib-review-aggregate.sh
# INV-40 (#166): unanimous-PASS aggregation over multiple verdict-reaching
# agents. Inert for the single-agent default; only consumed when
# AGENT_REVIEW_AGENTS lists more than one CLI.
source "${SCRIPT_DIR}/lib-review-aggregate.sh"
# shellcheck source=lib-review-resolve.sh
# INV-41 (#168): per-agent model / extra-args resolution for the fan-out.
# Inert for the all-unset default (resolves to the shared AGENT_REVIEW_MODEL /
# AGENT_REVIEW_EXTRA_ARGS); only diverges when a per-agent
# AGENT_REVIEW_MODEL_<AGENT> / AGENT_REVIEW_EXTRA_ARGS_<AGENT> key is set.
source "${SCRIPT_DIR}/lib-review-resolve.sh"
# shellcheck source=lib-review-poll.sh
# INV-43 (#172): command-mode-aware verdict-poll budget. The verdict poll loop
# below scales its attempt count with E2E_COMMAND_TIMEOUT_SECONDS when
# E2E_MODE=command, so a review agent that faithfully runs the (slow)
# command-mode E2E is not dropped as `unavailable` for taking as long as the
# E2E it was asked to run. Inert (legacy 30 s window) for every non-command mode.
source "${SCRIPT_DIR}/lib-review-poll.sh"
# shellcheck source=lib-review-mergeable.sh
# INV-44 (#176): wrapper-enforced mergeable hard gate. After verdict
# aggregation and before acting on a PASS, the wrapper re-checks the PR's
# `mergeable` status; a CONFLICTING (or persistently-UNKNOWN) PR can never reach
# `approved`, regardless of whether the review agent ran its Step-0 pre-review
# rebase prompt. _classify_mergeable_gate is the pure decision half (the gh
# query + UNKNOWN-retry loop stays in the wrapper). Inert on the FAIL path.
source "${SCRIPT_DIR}/lib-review-mergeable.sh"
# shellcheck source=lib-review-e2e.sh
# INV-46 (#182): run E2E ONCE in a dedicated lane, sequentially, BEFORE the
# review fan-out — not once per fan-out review agent. The command-mode lane is a
# pure shell subshell (setsid+timeout, token-free); browser-mode stays ONE
# LLM-driven lane. _classify_e2e_gate is the pure dual-signal decision; the lane
# helpers (_run_command_e2e_lane / _fetch_sha_evidence) live there so they are
# unit-testable in isolation. Inert when E2E_MODE=none.
source "${SCRIPT_DIR}/lib-review-e2e.sh"
# shellcheck source=lib-review-codex.sh
# INV-51 (#189): codex-specific review auto-resume loop. `codex exec` runs ONE
# agentic turn that on a large diff is consumed by context-gathering (git diff,
# file reads) before posting a verdict, so codex was dropped as `unavailable`.
# _run_codex_review_with_resume watches codex's JSONL event stream and resumes
# the same thread while turns end gather-only (bounded by CODEX_REVIEW_MAX_RESUMES
# + the AGENT_REVIEW_TIMEOUT wall-clock). Only the codex fan-out branch calls it;
# every other CLI keeps the bare run_agent path. Inert unless a fan-out agent is
# codex.
source "${SCRIPT_DIR}/lib-review-codex.sh"
# Per-side AGENT_CMD override (INV-37). See autonomous-dev.sh for the
# matching dev-side override. Together they let one project run dev
# and review on different agent CLIs (e.g. claude for dev, agy for
# review). Default (no operator override) is byte-for-byte unchanged.
#
# MUST come AFTER `source lib-auth.sh` — lib-auth.sh transitively sources
# lib-config.sh::load_autonomous_conf which re-sources autonomous.conf,
# and conf's unconditional `AGENT_CMD="claude"` line would otherwise
# overwrite this rebind. Same ordering is applied in autonomous-dev.sh.
AGENT_CMD="$AGENT_REVIEW_CMD"
# Per-side AGENT_LAUNCHER override (INV-38). Mirrors the dev-side
# rebind in autonomous-dev.sh. Default (operator hasn't set
# AGENT_REVIEW_LAUNCHER) is byte-identical to AGENT_LAUNCHER.
AGENT_LAUNCHER_ARGV=("${AGENT_REVIEW_LAUNCHER_ARGV[@]}")

# Per-side review wall-clock timeout (INV-48, #185). AGENT_TIMEOUT (INV-13,
# default 4h) is shared by dev and review; a silently-hung review CLI holds a
# wrapper PID slot for the full 4h. Cap the REVIEW side at 1h by default
# (operator-overridable via AGENT_REVIEW_TIMEOUT) so a hung review CLI is reaped
# ~3h sooner. The dev side (autonomous-dev.sh) is untouched and keeps 4h.
#
# MUST come AFTER `source lib-auth.sh` (same reason as the AGENT_CMD rebind
# above): lib-auth.sh re-sources the conf, whose unconditional `AGENT_TIMEOUT="4h"`
# would otherwise clobber this rebind. _run_with_timeout reads the LIVE
# AGENT_TIMEOUT at call time (lib-agent.sh), and agy reads it via
# `--print-timeout "$AGENT_TIMEOUT"`, so rebinding here applies to every review
# fan-out agent with no change to lib-agent.sh's invocation sites.
#
# Capture the original (conf) value FIRST — it is the default for the browser-E2E
# cap below (a slow preview deploy must not be killed at the aggressive 1h review
# cap). E2E_BROWSER_TIMEOUT_SECONDS is symmetric with command-mode's
# E2E_COMMAND_TIMEOUT_SECONDS; the browser lane (one run_agent LLM lane, INV-46
# Phase A) rebinds AGENT_TIMEOUT to it locally and restores afterward.
#
# Capture the RAW operator-supplied E2E_BROWSER_TIMEOUT_SECONDS before folding in
# the default — startup validation below validates the RAW value, NOT the resolved
# default. The default is `_ORIG_AGENT_TIMEOUT` (the conf's AGENT_TIMEOUT), which
# the dev side accepts UNVALIDATED; GNU `timeout` also accepts fractional /
# `infinity` durations that _is_positive_timeout_value rejects, so validating the
# resolved default would crash the review wrapper on a conf the dev side runs fine
# (e.g. AGENT_TIMEOUT="1.5h"). Validate only what the operator opted into.
# AGENT_REVIEW_TIMEOUT needs no raw-capture: line below leaves it unmodified.
_ORIG_AGENT_TIMEOUT="$AGENT_TIMEOUT"
_E2E_BROWSER_TIMEOUT_RAW="${E2E_BROWSER_TIMEOUT_SECONDS:-}"
AGENT_TIMEOUT="${AGENT_REVIEW_TIMEOUT:-1h}"
E2E_BROWSER_TIMEOUT_SECONDS="${E2E_BROWSER_TIMEOUT_SECONDS:-$_ORIG_AGENT_TIMEOUT}"

# Multi-agent review fan-out list (INV-40, #166). AGENT_REVIEW_AGENTS is a
# space-separated list of verdict-reaching CLIs (e.g. "agy kiro"). When
# empty/unset, REVIEW_AGENTS_LIST collapses to ("$AGENT_CMD") — exactly one
# element equal to the already-rebound per-side review CLI ($AGENT_REVIEW_CMD)
# — so the N=1 path is byte-for-byte the legacy single-agent behavior.
#
# This is DISTINCT from REVIEW_BOTS: REVIEW_BOTS triggers external GitHub
# bots (/q review, /codex review) whose comments are read as INPUT by the
# verdict agent(s); AGENT_REVIEW_AGENTS runs N independent verdict-reaching
# agents and gates the merge on their unanimous agreement.
declare -a REVIEW_AGENTS_LIST
# shellcheck disable=SC2206 # intentional word-splitting of the space-separated list
REVIEW_AGENTS_LIST=(${AGENT_REVIEW_AGENTS:-})
# Collapse empty OR whitespace-only AGENT_REVIEW_AGENTS to the N=1 default.
# Word-splitting a value of only spaces yields a zero-length array, so guard
# on the resolved element count (not just `-n`) — that keeps the N=1 path
# byte-for-byte legacy even for a stray `AGENT_REVIEW_AGENTS=" "`.
if [[ ${#REVIEW_AGENTS_LIST[@]} -eq 0 ]]; then
  REVIEW_AGENTS_LIST=("$AGENT_CMD")
fi

# Validate required config (loaded by lib-agent.sh from autonomous.conf)
: "${PROJECT_ID:?Set PROJECT_ID in autonomous.conf}"
: "${REPO:?Set REPO in autonomous.conf}"
: "${REPO_OWNER:?Set REPO_OWNER in autonomous.conf}"
: "${REPO_NAME:?Set REPO_NAME in autonomous.conf}"
: "${PROJECT_DIR:?Set PROJECT_DIR in autonomous.conf}"

# Validate REVIEW_BOTS at startup so a typo (e.g. REVIEW_BOTS="q codx")
# fails fast with a clear error instead of silently dropping the bot.
# Empty REVIEW_BOTS is allowed — the bot-review section is omitted from
# the prompt entirely and the review agent proceeds without bot
# enforcement.
REVIEW_BOTS_VALIDATED=$(parse_review_bots "${REVIEW_BOTS:-}") || exit 1

# ---------------------------------------------------------------------------
# GitHub authentication
# ---------------------------------------------------------------------------
if [[ "$GH_AUTH_MODE" == "app" ]]; then
  if [[ -z "${REVIEW_AGENT_APP_ID:-}" || -z "${REVIEW_AGENT_APP_PEM:-}" ]]; then
    echo "Error: GH_AUTH_MODE=app requires REVIEW_AGENT_APP_ID and REVIEW_AGENT_APP_PEM" >&2
    exit 1
  fi
  setup_github_auth "${REVIEW_AGENT_APP_ID}" "${REVIEW_AGENT_APP_PEM}"
else
  setup_github_auth
fi

# ---------------------------------------------------------------------------
# E2E config validation (issue #161)
#
# E2E_MODE accepts: none (default), browser (existing), command (new).
# E2E_ENABLED=true requires E2E_MODE to be set explicitly — projects must
# opt into a specific mode rather than implicitly inheriting "browser".
# ---------------------------------------------------------------------------
validate_e2e_config() {
  local mode="${E2E_MODE:-none}"

  # E2E_ENABLED=true with no mode set is the most common upgrade footgun:
  # projects that were on the old wrapper had only E2E_ENABLED. Fail loud
  # with the three accepted values listed.
  if [[ "${E2E_ENABLED:-false}" == "true" ]] && [[ -z "${E2E_MODE:-}" ]]; then
    echo "Error: E2E_ENABLED=true requires E2E_MODE to be set explicitly." >&2
    echo "  Accepted values for E2E_MODE: none, browser, command" >&2
    echo "  - none:    no E2E section in review prompt (equivalent to E2E_ENABLED=false)" >&2
    echo "  - browser: existing Chrome DevTools MCP UI smoke test (set E2E_PREVIEW_URL_PATTERN, E2E_TEST_USER_EMAIL, E2E_TEST_USER_PASSWORD)" >&2
    echo "  - command: project-supplied command for backend / CLI / pipeline projects (set E2E_COMMAND, E2E_COMMAND_EVIDENCE_PARSER)" >&2
    return 1
  fi

  case "$mode" in
    none|browser)
      # In the non-command modes the command-mode fields must NOT be
      # set. Catches the "operator filled in E2E_COMMAND but forgot to
      # set E2E_MODE=command" footgun — without this guard the fields
      # would be silently ignored and the operator would think
      # command-mode was wired up.
      if [[ -n "${E2E_COMMAND:-}" || -n "${E2E_COMMAND_EVIDENCE_PARSER:-}" || -n "${E2E_COMMAND_PRE_HOOKS:-}" ]]; then
        echo "Error: E2E_COMMAND* fields are set but E2E_MODE='${mode}', not 'command'." >&2
        echo "  Either set E2E_MODE=command or unset E2E_COMMAND / E2E_COMMAND_PRE_HOOKS / E2E_COMMAND_EVIDENCE_PARSER." >&2
        return 1
      fi
      ;;
    command)
      if [[ -z "${E2E_COMMAND:-}" ]]; then
        echo "Error: E2E_MODE=command requires E2E_COMMAND to be set." >&2
        echo "  Example: E2E_COMMAND='bash scripts/e2e-pr-stage.sh \${PR_NUMBER}'" >&2
        return 1
      fi
      if [[ -z "${E2E_COMMAND_EVIDENCE_PARSER:-}" ]]; then
        echo "Error: E2E_MODE=command requires E2E_COMMAND_EVIDENCE_PARSER to be set." >&2
        echo "  The parser MUST output a markdown evidence block ending with the" >&2
        echo "  literal marker: <!-- e2e-evidence: complete sha=\"<HEAD>\" -->" >&2
        echo "  See references/e2e-command-mode.md for the contract." >&2
        return 1
      fi
      # Reject unbraced $PR_NUMBER in command-mode fields. The wrapper only
      # substitutes the BRACED form ${PR_NUMBER}; a bare $PR_NUMBER would
      # silently render as empty (PR_NUMBER is not exported), potentially
      # targeting the wrong stage or the prod stage. This guard catches
      # the typo at config-validation time. Match \$PR_NUMBER NOT followed
      # by '{' or alphanum (so we don't false-fire on `${PR_NUMBER}` or
      # `$PR_NUMBER_FOO`).
      for _field in E2E_COMMAND E2E_COMMAND_PRE_HOOKS E2E_COMMAND_EVIDENCE_PARSER; do
        local _value="${!_field:-}"
        if [[ "$_value" =~ \$PR_NUMBER([^A-Za-z0-9_{]|$) ]]; then
          echo "Error: ${_field} contains unbraced \$PR_NUMBER." >&2
          echo "  Use \${PR_NUMBER} (with braces) so the wrapper can substitute it." >&2
          echo "  Found in: ${_field}=${_value}" >&2
          return 1
        fi
      done
      ;;
    *)
      echo "Error: invalid E2E_MODE='${mode}'." >&2
      echo "  Accepted values for E2E_MODE: none, browser, command" >&2
      return 1
      ;;
  esac
  return 0
}

validate_e2e_config || exit 1

# ---------------------------------------------------------------------------
# Review-timeout config validation (INV-48, #185)
#
# Fail loud at startup (mirrors validate_e2e_config) if AGENT_REVIEW_TIMEOUT or
# E2E_BROWSER_TIMEOUT_SECONDS is not a positive coreutils-`timeout` value. The
# zero case is called out explicitly: GNU `timeout 0` DISABLES the wall-clock
# bound, so a stray `AGENT_REVIEW_TIMEOUT=0` would silently un-cap the review
# side — the exact opposite of this feature's intent.
#
# Both are validated ONLY for the value the OPERATOR supplied — never the resolved
# default. AGENT_REVIEW_TIMEOUT is its own raw var (the rebind left it untouched);
# the browser cap uses the raw-captured _E2E_BROWSER_TIMEOUT_RAW. The resolved
# defaults are trusted-by-construction: the review default is the literal `1h`,
# and the browser default is `_ORIG_AGENT_TIMEOUT` (the conf's AGENT_TIMEOUT) —
# which the dev side honors UNVALIDATED and which GNU `timeout` may legitimately
# accept in forms this stricter predicate rejects (fractional, `infinity`).
# Validating the resolved browser default would hard-fail the review wrapper on a
# conf the dev side runs fine — a back-compat regression. So validate intent only.
validate_review_timeout_config() {
  if [[ -n "${AGENT_REVIEW_TIMEOUT:-}" ]] && ! _is_positive_timeout_value "$AGENT_REVIEW_TIMEOUT"; then
    echo "Error: AGENT_REVIEW_TIMEOUT='${AGENT_REVIEW_TIMEOUT}' is not a positive coreutils-timeout value." >&2
    echo "  Accepted: a positive integer optionally suffixed s/m/h/d (e.g. 3600, 90m, 2h, 1d)." >&2
    echo "  Rejected: 0 (GNU 'timeout 0' DISABLES the cap), fractions, negatives, other units." >&2
    return 1
  fi
  if [[ -n "${_E2E_BROWSER_TIMEOUT_RAW:-}" ]] && ! _is_positive_timeout_value "$_E2E_BROWSER_TIMEOUT_RAW"; then
    echo "Error: E2E_BROWSER_TIMEOUT_SECONDS='${_E2E_BROWSER_TIMEOUT_RAW}' is not a positive coreutils-timeout value." >&2
    echo "  Accepted: a positive integer optionally suffixed s/m/h/d (e.g. 3600, 90m, 2h, 4h)." >&2
    echo "  Rejected: 0 (GNU 'timeout 0' DISABLES the cap), fractions, negatives, other units." >&2
    return 1
  fi
  return 0
}

# Validate the OPERATOR-SUPPLIED values (the raw vars captured BEFORE the rebind
# block folded in defaults), so an invalid value never reaches a fan-out agent
# (or the browser lane) because we exit — while a previously-valid conf whose
# AGENT_TIMEOUT only flows through to the browser DEFAULT is never re-validated.
validate_review_timeout_config || exit 1

# Derived flag: true when E2E_MODE is one of {browser, command}. Used by
# downstream blocks that need to know whether E2E is producing output
# (for the decision-gate language and env-var export). The legacy
# E2E_ENABLED toggle is preserved for back-compat in autonomous.conf
# but the wrapper internally drives off E2E_MODE — that's the source
# of truth.
case "${E2E_MODE:-none}" in
  browser|command) E2E_ACTIVE="true" ;;
  *)               E2E_ACTIVE="false" ;;
esac

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
ISSUE_NUMBER=""
VALIDATE_CONFIG_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)
      [[ $# -ge 2 ]] || { echo "Error: --issue requires argument" >&2; exit 1; }
      ISSUE_NUMBER="$2"; shift 2 ;;
    --validate-config-only)
      # Exit cleanly after config validation; used by tests/unit/test-e2e-mode-command.sh.
      VALIDATE_CONFIG_ONLY=1; shift ;;
    *)
      echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ "$VALIDATE_CONFIG_ONLY" -eq 1 ]]; then
  exit 0
fi

if [[ -z "$ISSUE_NUMBER" ]]; then
  echo "Usage: $0 --issue <number>" >&2
  exit 1
fi

# Validate ISSUE_NUMBER is a positive integer (prevents injection in jq regex/file paths)
if ! [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Error: --issue must be a positive integer, got '$ISSUE_NUMBER'" >&2
  exit 1
fi

# Ensure we're in the project directory (needed when called directly, not just via SSM)
cd "$PROJECT_DIR" || { echo "Error: cannot cd to $PROJECT_DIR" >&2; exit 1; }

# Bot identity for downstream telemetry / cost attribution.
# Picked up by AGENT_LAUNCHER (e.g. user's `cc` shell function) when set;
# harmless extra env when AGENT_LAUNCHER is empty.
export CC_USER="${CC_USER:-autonomous-review-bot}"
export CC_ROLE_KIND="${CC_ROLE_KIND:-review}"

LOG_FILE="/tmp/agent-${PROJECT_ID}-review-${ISSUE_NUMBER}.log"
# PID file lives in the per-user PID dir (closes #72). pid_dir_for_project
# is in lib-config.sh, sourced transitively via lib-agent.sh.
PID_DIR=$(pid_dir_for_project) || { echo "ERROR: cannot resolve PID dir" >&2; exit 1; }
PID_FILE="${PID_DIR}/review-${ISSUE_NUMBER}.pid"

# Create log file with restrictive permissions (sensitive agent output)
# Note: log file is created by nohup redirect in dispatch-local.sh.
# Do NOT truncate it here (install -m 600 /dev/null would destroy nohup output).

# Forward dispatcher TERM to the agent's process group (#109).
# Without this, the timeout/agent subtree gets reparented to PID 1 when
# the wrapper exits and the next tick can't reach it through PID_FILE.
# install_agent_sigterm_trap (lib-agent.sh) sets RECEIVED_SIGTERM=1 and
# group-kills via _AGENT_RUN_PID. Review doesn't read RECEIVED_SIGTERM
# anywhere (no INV-15 equivalent here), but the contract is shared with
# autonomous-dev.sh so the trap is identical.
install_agent_sigterm_trap

# PID guard: prevent duplicate instances for the same issue.
# acquire_pid_guard writes $$ as a placeholder; _run_with_timeout
# rewrites the file with the agent's session-leader PID (== PGID).
acquire_pid_guard "$PID_FILE" "autonomous-review" "$ISSUE_NUMBER"
export AGENT_PID_FILE="$PID_FILE"

# Heartbeat: refresh PID-file mtime on a timer so the dispatcher's
# pid_alive mtime fallback (#111 Part B) can distinguish a transient
# `kill -0` race from a genuinely dead wrapper. Disabled when
# HEARTBEAT_INTERVAL_SECONDS=0.
install_agent_heartbeat

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[autonomous-review] $(date -u +%H:%M:%S) $*"; }

# Track whether normal result parsing completed (set at end of script)
RESULT_PARSED=false

cleanup() {
  local exit_code=$?

  # Tear down the heartbeat loop fast (parent-pid watchdog would also
  # take it down within HEARTBEAT_INTERVAL_SECONDS, but explicit is
  # cheaper). The kill is allowed to fail — the loop may already have
  # exited on its own.
  if [[ -n "${_AGENT_HEARTBEAT_PID:-}" ]]; then
    command kill "$_AGENT_HEARTBEAT_PID" 2>/dev/null || true
  fi

  # Cleanup PID file and heartbeat sibling (INV-29) always.
  rm -f "$PID_FILE" "${PID_FILE%.pid}.heartbeat" 2>/dev/null || true

  # If result was already parsed by the main script, labels are handled there
  if [[ "$RESULT_PARSED" == "true" ]]; then
    cleanup_github_auth
    return
  fi

  # Crash path: review agent died before parsing results — transition labels
  if [[ $exit_code -ne 0 ]]; then
    log "Review process crashed (exit $exit_code). Updating issue labels..."

    # Refresh token for cleanup (app mode)
    if [[ "$GH_AUTH_MODE" == "app" ]]; then
      if command -v get_gh_app_token &>/dev/null; then
        GH_TOKEN=$(get_gh_app_token "${REVIEW_AGENT_APP_ID}" "${REVIEW_AGENT_APP_PEM}" "$REPO_OWNER" "$REPO_NAME") || {
          log "WARNING: Failed to refresh GitHub App token for cleanup"
        }
        export GH_TOKEN
        export GITHUB_PERSONAL_ACCESS_TOKEN="$GH_TOKEN"
      fi
    fi

    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "Review process crashed (exit code: ${exit_code}). Moving back to development for retry." 2>/dev/null || true
    # INV-35: emit verdict trailer so dispatcher Step 4b.5.1 routes a
    # completed-session crash to the substantive recovery path (a wrapper
    # crash isn't a transient bot/CI/transport blip — it requires a fresh
    # dev session, not a re-review).
    emit_verdict_trailer "$ISSUE_NUMBER" "$REPO" "failed-substantive" "" 2>/dev/null || true
    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
      --remove-label "reviewing" \
      --add-label "pending-dev" 2>/dev/null || true

    log "Issue #${ISSUE_NUMBER} moved to pending-dev due to crash."
  fi

  cleanup_github_auth
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Find PR linked to this issue
# ---------------------------------------------------------------------------
# Resolved review wall-clock cap (INV-48): the rebound AGENT_TIMEOUT applies to
# every review fan-out agent; the browser-E2E lane runs under its own
# (typically larger) cap so a slow preview deploy is not killed at the review
# cap. Logged once at startup for operator visibility.
# Source of the resolved review cap, for the operator-facing log only: an
# explicit AGENT_REVIEW_TIMEOUT, or the 1h default when unset/empty. Computed
# separately (not inline `:+`/`:-`, which both fire when the var is set and
# double-print the value).
if [[ -n "${AGENT_REVIEW_TIMEOUT:-}" ]]; then
  _review_cap_source="AGENT_REVIEW_TIMEOUT=${AGENT_REVIEW_TIMEOUT}"
else
  _review_cap_source="AGENT_REVIEW_TIMEOUT unset → 1h default"
fi
log "Review CLI wall-clock cap: ${AGENT_TIMEOUT} (${_review_cap_source}); browser-E2E cap: ${E2E_BROWSER_TIMEOUT_SECONDS}; dev side unaffected (${_ORIG_AGENT_TIMEOUT})."
log "Finding PR for issue #${ISSUE_NUMBER}..."

# Method 1: Search PRs that reference the issue
PR_NUMBER=$(gh pr list --repo "$REPO" --state open --json number,body \
  -q "[.[] | select(.body | test(\"#${ISSUE_NUMBER}[^0-9]\") or test(\"#${ISSUE_NUMBER}$\"))] | .[0].number // empty" 2>/dev/null || true)

# Method 2: Extract PR number from issue comments
if [[ -z "$PR_NUMBER" ]]; then
  PR_NUMBER=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json comments \
    -q '[.comments[].body | capture("(?:PR|pull)[/ #]*(?P<pr>[0-9]+)"; "g") | .pr] | last // empty' 2>/dev/null || true)
fi

# Method 3: Search PRs mentioning the issue number
if [[ -z "$PR_NUMBER" ]]; then
  PR_NUMBER=$(gh pr list --repo "$REPO" --state open --search "issue ${ISSUE_NUMBER}" --json number \
    -q '.[0].number // empty' 2>/dev/null || true)
fi

if [[ -z "$PR_NUMBER" ]]; then
  log "ERROR: No PR found for issue #${ISSUE_NUMBER}"
  gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
    --body "Review failed: no PR found linked to this issue. Please ensure the PR description contains 'Closes #${ISSUE_NUMBER}'." 2>/dev/null || true
  # INV-35: no-pr-found is a non-substantive failure — the prior dev session
  # may have completed cleanly but its PR-create call failed (transport,
  # token expiry). The dispatcher should re-route to review on the next tick
  # rather than burning a dev retry.
  emit_verdict_trailer "$ISSUE_NUMBER" "$REPO" "failed-non-substantive" "no-pr-found" 2>/dev/null || true
  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
    --remove-label "reviewing" \
    --add-label "pending-dev" 2>/dev/null || true
  exit 1
fi

log "Found PR #${PR_NUMBER} for issue #${ISSUE_NUMBER}"

# ---------------------------------------------------------------------------
# Extract PR preview URL (conditional on E2E config)
# ---------------------------------------------------------------------------
PREVIEW_URL=""

if [[ "${E2E_ACTIVE:-false}" == "true" && -n "${E2E_PREVIEW_URL_PATTERN:-}" ]]; then
  log "Extracting preview URL for PR #${PR_NUMBER}..."

  # Build expected URL from config, replacing {N} with PR number
  PREVIEW_URL="${E2E_PREVIEW_URL_PATTERN//\{N\}/$PR_NUMBER}"

  # Also try to extract from PR comments (may contain a more specific URL)
  COMMENT_URL=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json comments \
    -q '[.comments[].body | select(contains("Preview"))] | last' 2>/dev/null \
    | grep -oP 'https://[^\s"]+' | head -1 || true)
  PREVIEW_URL="${COMMENT_URL:-$PREVIEW_URL}"

  if [[ -n "$PREVIEW_URL" ]]; then
    log "Found preview URL: ${PREVIEW_URL}"
  else
    log "WARNING: No preview URL found"
  fi
else
  log "E2E verification disabled or no preview URL pattern configured."
fi

# ---------------------------------------------------------------------------
# Screenshot upload availability
# ---------------------------------------------------------------------------
if [[ "${E2E_SCREENSHOT_UPLOAD:-false}" == "true" && -x "${PROJECT_DIR}/skills/autonomous-review/scripts/upload-screenshot.sh" ]]; then
  SCREENSHOT_UPLOAD_AVAILABLE="true"
  log "Screenshot upload script available"
else
  SCREENSHOT_UPLOAD_AVAILABLE="false"
  if [[ "${E2E_ACTIVE:-false}" == "true" ]]; then
    log "WARNING: Screenshot upload not available (set E2E_SCREENSHOT_UPLOAD=true and ensure upload-screenshot.sh is executable)"
  fi
fi

# ---------------------------------------------------------------------------
# Build review prompt
# ---------------------------------------------------------------------------
PR_BRANCH=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefName -q '.headRefName' 2>/dev/null || true)
PR_HEAD_SHA=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefOid -q '.headRefOid' 2>/dev/null || true)
log "PR branch: ${PR_BRANCH:-UNKNOWN} (HEAD: ${PR_HEAD_SHA:0:7})"

# Verdict-detection bindings: actor + time window + body-trailer
# presence. Replaces the prior session-id-only binding (which depended
# on the agent echoing the wrapper's UUID verbatim).
#
# WRAPPER_START_TS — ISO-8601 UTC captured BEFORE run_agent. Verdict
# comments older than this are stale (prior tick) and ignored.
WRAPPER_START_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# BOT_LOGIN — the bot identity this wrapper authenticates as. We need
# the diagnostic on failure (token expired, GH App perms reduced, rate
# limit, etc.) so the operator can debug, but we deliberately limit
# what we log: a 200-char head of stderr only, no full body. `gh api`
# stderr is a JSON error body which is generally safe to log, but
# truncation is defense-in-depth against a future gh release that
# might surface request-context headers.
_bot_login_raw=$(gh api user --jq '.login' 2>&1) && BOT_LOGIN="$_bot_login_raw" || {
  log "WARNING: gh api user failed; verdict detector falling back to session-id binding. stderr (truncated): ${_bot_login_raw:0:200}"
  BOT_LOGIN=""
}
# A literal "null" string can come back from `--jq '.login'` if /user
# returns null (rare App-token misconfig). Treat as failure.
if [[ "$BOT_LOGIN" == "null" || -z "$BOT_LOGIN" ]]; then
  [[ "$BOT_LOGIN" == "null" ]] && log "WARNING: gh api user returned null login; falling back to session-id binding"
  BOT_LOGIN=""
fi
if [[ -n "$BOT_LOGIN" ]]; then
  log "Verdict will bind to actor=${BOT_LOGIN}, createdAt >= ${WRAPPER_START_TS}, body must contain 'Review Session'"
fi

# E2E_MODE=command: substitute the literal `${PR_NUMBER}` placeholder in
# command-mode fields so the agent receives a fully-resolved command
# string. Operators write the placeholder in autonomous.conf with single
# quotes to defer expansion (e.g.
# E2E_COMMAND='bash scripts/e2e.sh pr-${PR_NUMBER}').
#
# `:-` defaults are required: under `set -u`, `${VAR//pat/repl}` against
# an unset VAR aborts the wrapper. E2E_COMMAND_PRE_HOOKS is documented
# as optional; without the default an operator who simply omits the
# line crashes the wrapper before the agent ever runs.
E2E_COMMAND_RENDERED=""
E2E_COMMAND_PRE_HOOKS_RENDERED=""
E2E_COMMAND_EVIDENCE_PARSER_RENDERED=""
if [[ "${E2E_MODE:-none}" == "command" ]]; then
  if [[ -z "$PR_NUMBER" ]]; then
    log "ERROR: E2E_MODE=command but PR_NUMBER is empty — refusing to render"
    log "       a placeholder-substituted command that would target the wrong PR."
    exit 1
  fi
  E2E_COMMAND_RENDERED="${E2E_COMMAND:-}"
  E2E_COMMAND_RENDERED="${E2E_COMMAND_RENDERED//\$\{PR_NUMBER\}/${PR_NUMBER}}"
  E2E_COMMAND_PRE_HOOKS_RENDERED="${E2E_COMMAND_PRE_HOOKS:-}"
  E2E_COMMAND_PRE_HOOKS_RENDERED="${E2E_COMMAND_PRE_HOOKS_RENDERED//\$\{PR_NUMBER\}/${PR_NUMBER}}"
  E2E_COMMAND_EVIDENCE_PARSER_RENDERED="${E2E_COMMAND_EVIDENCE_PARSER:-}"
  E2E_COMMAND_EVIDENCE_PARSER_RENDERED="${E2E_COMMAND_EVIDENCE_PARSER_RENDERED//\$\{PR_NUMBER\}/${PR_NUMBER}}"
fi

# build_review_prompt <agent_name> <agent_session_id>
#
# Renders the full review prompt for ONE review agent. Echoes the prompt on
# stdout. Parameterized (INV-40, #166) so each agent in a multi-agent fan-out
# gets:
#   - its OWN Review Session UUID (the second arg) — distinct per agent so
#     verdict comments don't collapse under a shared GitHub identity;
#   - a `Review Agent: <agent_name>` discriminator instruction so the wrapper
#     can attribute that agent's verdict comment via a per-agent jq query
#     (INV-40 / amended INV-20);
#   - the correct checklist branch for ITS CLI (the kiro branch keys on the
#     per-agent name, not the global $AGENT_CMD, so a mixed "agy kiro" list
#     gives kiro the kiro checklist and agy the full checklist).
#
# For the single-agent default (REVIEW_AGENTS_LIST=("$AGENT_CMD")), this is
# called once with the wrapper's lone agent + session id.
#
# INV-46 (#182): the prompt NO LONGER contains any E2E EXECUTION block. The
# wrapper runs E2E ONCE in a dedicated lane before the fan-out (Phase A) and
# posts the evidence as a PR comment; this prompt instead tells the agent to READ
# that posted evidence as input. Review agents are PURE code reviewers — they do
# not run, and are not told to run, E2E.
build_review_prompt() {
  local _agent_name="$1"
  local _agent_session_id="$2"
  cat <<EOF
You are reviewing PR #${PR_NUMBER} for issue #${ISSUE_NUMBER} in the ${REPO} project.
PR branch: ${PR_BRANCH:-UNKNOWN}

## Step 0: Merge Conflict Resolution — MANDATORY PRE-REVIEW

Before doing anything else, check the PR mergeable status and rebase if needed.

Quick reference:
1. Check: \`gh pr view ${PR_NUMBER} --repo ${REPO} --json mergeable -q '.mergeable'\`
2. If "MERGEABLE" — proceed to the review checklist below
3. If "CONFLICTING" — rebase the PR branch onto main:
   \`\`\`bash
   git fetch origin main ${PR_BRANCH}
   git worktree add /tmp/rebase-pr-${PR_NUMBER} ${PR_BRANCH}
   cd /tmp/rebase-pr-${PR_NUMBER}
   git rebase origin/main
   # If rebase succeeds:
   git push --force-with-lease origin ${PR_BRANCH}
   cd -
   git worktree remove /tmp/rebase-pr-${PR_NUMBER}
   # Wait for CI to restart
   sleep 10
   gh pr checks ${PR_NUMBER} --watch --interval 30
   \`\`\`
4. If rebase fails (conflicts) — FAIL the review with "[BLOCKING] Merge conflict with main".
   Include the list of conflicting files and step-by-step instructions for the dev agent:
   \`git fetch origin main\`, \`git rebase origin/main\`, resolve conflicts, \`git rebase --continue\`,
   \`git push --force-with-lease origin ${PR_BRANCH}\`. Then exit.
5. If "UNKNOWN" — wait 10s and retry up to 3 times

## Step 0.5: Requirement Drift Detection — MANDATORY PRE-REVIEW

**Before reading the PR diff**, read ALL comments on issue #${ISSUE_NUMBER} to detect requirement changes posted after implementation:

\`\`\`bash
gh issue view ${ISSUE_NUMBER} --repo ${REPO} --json comments \\
  -q '.comments[] | "\\(.author.login) [\\(.createdAt)]: \\(.body[0:500])"'
\`\`\`

Look for:
- Scope changes ("remove", "no longer", "drop", "don't support", "instead of")
- New requirements added after the original issue
- Corrections or clarifications from the repo owner (@${REPO_OWNER})
- Explicit instructions to the dev agent that may not yet be reflected in the PR code

**If any requirement change is found that the PR code does NOT reflect, this is a [BLOCKING] Requirement drift finding.** Quote the comment and list the specific code that needs updating.

## Review Checklist
Verify ALL of the following were completed:

1. [ ] Design canvas created (docs/designs/ or docs/plans/)
2. [ ] Git worktree used (branch name starts with feat/, fix/, etc.)
3. [ ] Test cases documented (docs/test-cases/)
4. [ ] Unit tests written and passing
5. [ ] E2E tests written/updated if UI changes
6. [ ] CI checks all passing
$(if [[ "${_agent_name:-claude}" != "kiro" ]]; then cat <<'CHECKLIST_EXTRA'
7. [ ] code-simplifier review passed
8. [ ] PR review agent review passed
9. [ ] Reviewer bot findings addressed
10. [ ] PR description follows template
CHECKLIST_EXTRA
else cat <<'CHECKLIST_KIRO'
7. [ ] Reviewer bot findings addressed
8. [ ] PR description follows template
CHECKLIST_KIRO
fi)

## Acceptance Criteria Verification — MANDATORY
Read the issue body for an \`## Acceptance Criteria\` section. For EACH criterion:
1. Verify whether the PR implementation satisfies it (check code, tests, build output)
2. If verified, mark the checkbox as complete using the mark-issue-checkbox script:
   \`\`\`bash
   bash scripts/mark-issue-checkbox.sh ${REPO_OWNER} ${REPO_NAME} ${ISSUE_NUMBER} "the exact checkbox text"
   \`\`\`
3. If NOT verified, leave unchecked and include it in your review findings

## Review Process
1. Read the issue body to understand requirements
2. Read ALL issue comments to detect requirement changes (Step 0.5 above)
3. Read the PR diff to verify implementation
4. Verify acceptance criteria (see above)
5. Check that CI checks are passing: gh pr checks ${PR_NUMBER}
6. Verify test coverage and quality
7. Check for security issues, code quality, and best practices
8. Trigger and verify configured review bots (see below)$(if [[ -z "$REVIEW_BOTS_VALIDATED" ]]; then printf '\n   (REVIEW_BOTS is empty — bot-review enforcement is disabled for this project.)'; fi)

$(render_bot_review_section "$REVIEW_BOTS_VALIDATED" "$PR_NUMBER" "$REPO")

$(if [[ "${E2E_ACTIVE:-false}" == "true" ]]; then
  # INV-49 (#183): when the command-mode E2E lane produced a VALIDATED structured
  # AC-coverage artifact, prefer the DETERMINISTIC map over LLM-parsing the
  # free-form markdown table — the latter is the weak link (re-worded header /
  # merged cell / truncated row → a missed failing criterion). An empty/absent/
  # rejected sidecar (parser didn't emit one, or it was malformed, or the lane
  # disarmed it) yields the exact #182 free-form double-check below — no change.
  #
  # TOCTOU defense (INV-49 sub-rule 5): the sidecar is a predictable, exported
  # /tmp path that PR-controlled E2E/parser code could overwrite AFTER the lane
  # validated it. So DO NOT trust its bytes with a plain `cat` — re-run the SAME
  # jq validation here, at prompt-read time, and interpolate only the freshly
  # re-validated, canonicalized object. _revalidate_ac_coverage_file echoes EMPTY
  # for an unset var / missing-empty file / now-malformed-or-replaced content.
  _ac_map=$(_revalidate_ac_coverage_file)
  if [[ -n "$_ac_map" ]]; then cat <<E2E_AC_STRUCTURED
## E2E Evidence — READ AS INPUT (the wrapper already ran E2E once, INV-46)

**You do NOT run E2E.** The wrapper ran the project's E2E verification ONCE in a
dedicated lane BEFORE this review and posted the evidence as a PR comment. Your
job is to double-check acceptance-criteria coverage — not to re-run any build,
deploy, verify command, or browser flow.

### Structured AC-coverage map (INV-49) — PREFER THIS over the markdown table

The wrapper's evidence parser emitted a machine-readable AC-coverage map. Verify
each acceptance criterion from THIS map (deterministic) — do NOT LLM-parse the
free-form markdown table for criteria the map already covers:

\`\`\`json
${_ac_map}
\`\`\`

1. For EACH \`## Acceptance Criteria\` item in the issue body, find its entry in
   the map (match by criterion id or text). A value of \`"fail"\` is a review
   finding; \`"pass"\` is covered.
2. If an acceptance criterion is NOT present as a key in the map, fall back to
   cross-checking it against the posted free-form evidence comment:
   \`\`\`bash
   gh pr view ${PR_NUMBER} --repo ${REPO} --json comments \\
     -q '[.comments[].body | select(test("e2e-evidence: complete"))] | last'
   \`\`\`
3. Do NOT FAIL the review merely because you cannot re-run E2E yourself — the
   wrapper's E2E hard gate (INV-46) already decided pass/fail, and a gate FAIL
   would have prevented this review from running. Treat the map + evidence as
   authoritative input; raise findings only for a \`"fail"\` entry, an
   uncovered-and-contradicted criterion, or code-quality / requirement-drift.
E2E_AC_STRUCTURED
  else cat <<'E2E_EVIDENCE_INPUT'
## E2E Evidence — READ AS INPUT (the wrapper already ran E2E once, INV-46)

**You do NOT run E2E.** The wrapper ran the project's E2E verification ONCE in a
dedicated lane BEFORE this review and posted the evidence as a PR comment. Your
job is to READ that posted evidence and double-check it against the issue's
acceptance criteria — not to re-run any build, deploy, verify command, or
browser flow.

1. Fetch the posted E2E evidence comment from the PR:
   \`\`\`bash
   gh pr view ${PR_NUMBER} --repo ${REPO} --json comments \\
     -q '[.comments[].body | select(test("e2e-evidence: complete"))] | last'
   \`\`\`
2. Cross-check the evidence's results table against EACH \`## Acceptance Criteria\`
   item in the issue body. If a criterion that names a verifiable artifact
   (file path, S3 key, DDB row state, log line, count, screenshot) is NOT
   covered by — or is contradicted by — the evidence, that is a review finding.
3. Do NOT FAIL the review merely because you cannot re-run E2E yourself — the
   wrapper's E2E hard gate (INV-46) already decided pass/fail on the lane's exit
   code + the posted evidence, and a gate FAIL would have prevented this review
   from running at all. Treat the evidence as authoritative input; raise
   findings only for genuine gaps between the evidence and the acceptance
   criteria, or for code-quality / requirement-drift issues.
E2E_EVIDENCE_INPUT
  fi
fi)

## Decision
After thorough review:

**CRITICAL — verdict phrasing**: the wrapper script polls for your
verdict comment by matching specific keywords. If your comment doesn't
contain one of the recognized phrasings, the wrapper falls through to
the FAILED branch and the dispatcher will eventually mark the issue
\`stalled\` after \`MAX_RETRIES\` (closes #95). Use the EXACT prefix
shown below — alternative phrasings like "APPROVED FOR MERGE" or "LGTM"
also work, but stick to the canonical form when possible.

**CRITICAL — verdict attribution**: your verdict comment MUST end with
BOTH of these trailer lines, each on its OWN line:

  > Review Session: \`${_agent_session_id}\`
  > Review Agent: ${_agent_name}

The \`Review Agent: ${_agent_name}\` line is load-bearing — when more than
one review agent runs against this same PR under the same GitHub identity,
the wrapper attributes each verdict to its agent by matching the
\`Review Agent: <name>\` discriminator (INV-40). Do NOT omit it, do NOT
rename it, do NOT change \`${_agent_name}\`.

- If ALL checklist items pass AND code quality is good$(if [[ "${E2E_ACTIVE:-false}" == "true" ]]; then echo " AND the wrapper-posted E2E evidence covers the acceptance criteria"; fi) AND no requirement drift detected:
  Post a comment on issue #${ISSUE_NUMBER} starting with the exact text
  **\`Review PASSED\`** on the FIRST LINE, like:

  > Review PASSED - All checklist items verified, code quality good.$(if [[ "${E2E_ACTIVE:-false}" == "true" ]]; then echo " E2E evidence reviewed (run once by the wrapper, INV-46)."; fi) No requirement drift.
  > Review Session: \`${_agent_session_id}\`
  > Review Agent: ${_agent_name}

  Then exit.

- If ANY item fails$(if [[ "${E2E_ACTIVE:-false}" == "true" ]]; then echo " OR the posted E2E evidence does NOT cover an acceptance criterion"; fi) OR requirement drift is detected:
  Post a comment on issue #${ISSUE_NUMBER} starting with the exact text
  **\`Review findings:\`** on the FIRST LINE, followed by a numbered list
  of each failing item with specific remediation instructions.$(if [[ "${E2E_ACTIVE:-false}" == "true" ]]; then echo "
  For any E2E gap, quote the relevant row of the posted evidence comment (the wrapper ran E2E once — do NOT re-run it)."; fi)
  End the comment with these two lines:
  \`Review Session: \\\`${_agent_session_id}\\\`\`
  \`Review Agent: ${_agent_name}\`
  Then exit.

IMPORTANT: Work autonomously. Be thorough but fair. Focus on correctness and compliance.
$(if [[ "${E2E_ACTIVE:-false}" == "true" ]]; then echo "Reviewing the wrapper-posted E2E evidence against the acceptance criteria is MANDATORY — do NOT skip it, do NOT treat it as optional. You do NOT re-run E2E (the wrapper ran it once, INV-46)."; fi)
EOF
}

# ---------------------------------------------------------------------------
# Run review agent(s) — multi-agent fan-out (INV-40, #166)
# ---------------------------------------------------------------------------
# REVIEW_AGENTS_LIST is ("$AGENT_CMD") in the single-agent default (N=1) and
# the full list (e.g. agy kiro) when AGENT_REVIEW_AGENTS is set. We fan out
# one parallel subshell per agent, each with its OWN minted SESSION_ID, its
# OWN per-agent AGENT_CMD override, its OWN log, and (INV-38) the launcher
# neutralized for non-claude members. The single shared review-N.pid file and
# the `reviewing` label are NOT touched by the fan-out — they remain the
# wrapper's, so the dispatcher's PID model and the state machine are unchanged.
#
# Export E2E credentials as env vars (not in prompt) for agent to read at runtime
if [[ "${E2E_ACTIVE:-false}" == "true" ]]; then
  export E2E_TEST_USER_EMAIL="${E2E_TEST_USER_EMAIL:-}"
  export E2E_TEST_USER_PASSWORD="${E2E_TEST_USER_PASSWORD:-}"
fi

# Command-mode: export PR_NUMBER and PR_HEAD_SHA so the project's
# E2E_COMMAND / parser scripts can read them. This is required by the
# evidence-block contract (parser must embed PR_HEAD_SHA in the marker
# for stale-evidence guard) and convenient for verify commands that use
# the unbraced shell form `$PR_NUMBER` after a future opt-in. Today
# unbraced is rejected at config-validation time, but parsers commonly
# read these.
if [[ "${E2E_MODE:-none}" == "command" ]]; then
  export PR_NUMBER="${PR_NUMBER}"
  export PR_HEAD_SHA="${PR_HEAD_SHA:-}"
  # INV-49 (#183): the command-mode E2E lane writes the OPTIONAL structured
  # AC-coverage artifact (validated JSON, or empty when the parser doesn't emit
  # one / it's malformed) to this per-round sidecar. The review fan-out reads it
  # to verify acceptance criteria DETERMINISTICALLY instead of LLM-parsing the
  # free-form evidence comment; an empty/absent sidecar falls back to the #182
  # free-form double-check. Browser mode does not set this (free-form by nature).
  export E2E_AC_COVERAGE_FILE="/tmp/e2e-ac-coverage-${PR_NUMBER}.json"
fi

# ---------------------------------------------------------------------------
# PHASE A: run E2E ONCE, sequentially, before the review fan-out (INV-46, #182)
# ---------------------------------------------------------------------------
# Pre-#182 the E2E execution block lived in EVERY review agent's prompt, so an
# AGENT_REVIEW_AGENTS fan-out of N CLIs ran the full E2E N times (N× pre-hooks,
# N× verify, N× evidence) racing each other on shared stage state. Now the
# WRAPPER runs the E2E lane once — the command-mode lane is a pure shell subshell
# (token-free, setsid+timeout), browser-mode is ONE LLM lane — computes a hard
# gate from the result, and only fans out the PURE code-review agents on a gate
# pass. A gate FAIL short-circuits to the FAIL route WITHOUT spawning the N
# review agents (saves N review runs on a known-bad PR).
#
# The lane runs synchronously here, before the fan-out below. Its setsid PGID
# (_E2E_LANE_PGID, set by the lane) is added to the _reap_fanout_processes arg
# list so a lingering verify subtree is group-killed when verdicts resolve,
# exactly like a fan-out agent's PGID. During Phase A itself the SIGTERM trap
# (install_agent_sigterm_trap) also reaches the lane's setsid child via its
# `pkill -TERM -P $$` fallback (the lane's `setsid … &` is a direct child of the
# wrapper shell), so a dispatcher SIGTERM mid-E2E is forwarded promptly.
#
# E2E_GATE ∈ { pass | fail | block-nonsubstantive | inactive }:
#   inactive             — E2E_ACTIVE=false (E2E_MODE=none); no lane, no gate.
#   pass                 — fan out the review agents (Phase B).
#   fail                 — substantive E2E failure; route −reviewing +pending-dev
#                          WITHOUT fan-out.
#   block-nonsubstantive — rc==0 but no SHA-matching evidence visible after the
#                          bounded re-fetch (crash-after-parser / transient
#                          GitHub); re-queue non-substantive (NOT a dev bounce).
E2E_GATE="inactive"
# Set to the E2E lane's setsid PGID (command-mode verify subtree, or the browser
# lane's run_agent group) so the post-fan-out reaper and SIGTERM trap can group-
# kill a lingering verify subtree. Empty when E2E is inactive or no PGID was set.
_AGENT_PGIDS_E2E=""
if [[ "${E2E_ACTIVE:-false}" == "true" ]]; then
  _E2E_LANE_DIR=$(mktemp -d "/tmp/agent-review-e2e-${ISSUE_NUMBER}-XXXXXX")
  _E2E_RC_FILE="${_E2E_LANE_DIR}/e2e.rc"
  log "INV-46: running the E2E lane ONCE before the review fan-out (mode=${E2E_MODE})."
  case "${E2E_MODE:-none}" in
    command)
      _run_command_e2e_lane "$_E2E_RC_FILE"
      ;;
    browser)
      # ONE LLM-driven browser lane (NOT replicated across review agents). The
      # wrapper stamps the SHA marker after the lane posts its report.
      _e2e_session_id=$(uuidgen)
      _e2e_log="/tmp/agent-${PROJECT_ID}-review-${ISSUE_NUMBER}-e2e-browser.log"
      _e2e_prompt=$(build_browser_e2e_prompt)
      _e2e_rc=0
      # Browser lane runs under run_agent; its setsid PGID lands in
      # _AGENT_RUN_PID. Point AGENT_PID_FILE at a private sidecar so it does NOT
      # rewrite the shared review-N.pid, then capture the PGID for the reaper.
      #
      # INV-48 (#185): the browser lane is an LLM run_agent lane, so it would
      # inherit the (aggressive 1h) review AGENT_TIMEOUT. A real browser smoke
      # test against a freshly-deployed preview can legitimately exceed 1h (slow
      # preview build / cold start), so rebind AGENT_TIMEOUT to the browser cap
      # for THIS lane only. The rebind is inside the lane's subshell, so it is
      # naturally scoped — the parent's review cap is unchanged for the fan-out
      # below (no manual restore needed). Symmetric with command-mode, whose
      # verify already runs under timeout ${E2E_COMMAND_TIMEOUT_SECONDS}.
      (
        AGENT_TIMEOUT="$E2E_BROWSER_TIMEOUT_SECONDS"
        AGENT_PID_FILE="${_E2E_LANE_DIR}/e2e.pgid"
        run_agent "$_e2e_session_id" "$_e2e_prompt" "${AGENT_REVIEW_MODEL:-sonnet}" \
          "review-e2e-pr-${PR_NUMBER}-issue-${ISSUE_NUMBER}" >>"$_e2e_log" 2>&1
      ) || _e2e_rc=$?
      # Wrapper-stamp the SHA marker ONTO the lane's posted '## E2E Verification
      # Report' comment so the gate anchor is deterministic (the LLM never
      # transcribes the SHA) AND the gate's evidence-present signal resolves to
      # the REAL report (tables/screenshots/AC), not a marker-only comment. Stamp
      # ONLY when the lane exited clean. If the lane exited 0 but posted no
      # report comment to stamp (_stamp_browser_evidence_marker returns 1), force
      # _e2e_rc non-zero so the gate fails closed — a clean exit with no evidence
      # report must NOT pass on a fabricated marker (codex review, #182).
      if [[ "$_e2e_rc" -eq 0 && -n "${PR_HEAD_SHA:-}" ]]; then
        if ! _stamp_browser_evidence_marker; then
          log "INV-46: browser lane exited 0 but had no stampable E2E report comment — forcing E2E FAIL (no marker-only pass)."
          _e2e_rc=1
        fi
      fi
      printf '%s\n' "$_e2e_rc" > "$_E2E_RC_FILE"
      [[ -f "${_E2E_LANE_DIR}/e2e.pgid" ]] && _E2E_LANE_PGID=$(head -n1 "${_E2E_LANE_DIR}/e2e.pgid" 2>/dev/null || true)
      ;;
  esac

  # Read the lane's composite rc, then re-fetch the SHA-matching evidence comment
  # (bounded retry — the post may still be propagating) for the dual-signal gate.
  _e2e_lane_rc=$(head -n1 "$_E2E_RC_FILE" 2>/dev/null || echo 1)
  [[ "$_e2e_lane_rc" =~ ^[0-9]+$ ]] || _e2e_lane_rc=1
  _e2e_evidence=$(_fetch_sha_evidence 3 5)
  _e2e_evidence_present=0
  [[ -n "$_e2e_evidence" ]] && _e2e_evidence_present=1
  E2E_GATE=$(_classify_e2e_gate "$_e2e_lane_rc" "$_e2e_evidence_present")
  log "INV-46: E2E hard gate: lane_rc=${_e2e_lane_rc}, evidence_present=${_e2e_evidence_present} → gate=${E2E_GATE}"

  # Capture the lane PGID for the reaper / SIGTERM trap (alongside fan-out PGIDs).
  if [[ "${_E2E_LANE_PGID:-}" =~ ^[0-9]+$ ]] && [[ "${_E2E_LANE_PGID}" -gt 0 ]]; then
    _AGENT_PGIDS_E2E="${_E2E_LANE_PGID}"
  fi
  rm -rf "$_E2E_LANE_DIR" 2>/dev/null || true

  # E2E gate fail / block → route WITHOUT fanning out the review agents.
  if [[ "$E2E_GATE" == "fail" ]]; then
    log "INV-46: E2E hard gate FAIL — overriding to FAIL WITHOUT review fan-out (saves ${#REVIEW_AGENTS_LIST[@]} review run(s))."
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "Review findings:

Findings->Decision Gate: 1 blocking finding(s) -- FAIL.

1. **[BLOCKING] E2E verification failed** — the wrapper ran the project E2E once before review (INV-46) and it did NOT pass (lane exit code ${_e2e_lane_rc}). See the E2E failure comment on PR #${PR_NUMBER}. The review agents were NOT run because a failing E2E is a hard gate. Fix the failure and push; the next review round re-runs E2E." 2>/dev/null || true
    emit_verdict_trailer "$ISSUE_NUMBER" "$REPO" "failed-substantive" "" 2>/dev/null || true
    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
      --remove-label "reviewing" --add-label "pending-dev" 2>/dev/null || true
    log "Issue #${ISSUE_NUMBER} moved to pending-dev (E2E hard gate fail — no fan-out)."
    RESULT_PARSED=true
    exit 0
  elif [[ "$E2E_GATE" == "block-nonsubstantive" ]]; then
    log "INV-46: E2E lane exited clean but no SHA-matching evidence visible after re-fetch — re-queuing (non-substantive), NO fan-out."
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "Review held: the wrapper ran E2E once (INV-46) and it exited clean, but no SHA-matching e2e-evidence comment for HEAD \`${PR_HEAD_SHA:0:7}\` is visible (likely transient — comment-post or GitHub propagation). The PR is NOT auto-reviewed while the evidence is missing; it will be re-reviewed on the next dispatch tick." 2>/dev/null || true
    emit_verdict_trailer "$ISSUE_NUMBER" "$REPO" "failed-non-substantive" "e2e-evidence-missing" 2>/dev/null || true
    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
      --remove-label "reviewing" --add-label "pending-dev" 2>/dev/null || true
    log "Issue #${ISSUE_NUMBER} moved to pending-dev (E2E evidence missing — re-queue, no fan-out)."
    RESULT_PARSED=true
    exit 0
  fi
  # gate == pass → fall through to Phase B (review fan-out) below.
fi

# Per-agent state captured for the collection step.
declare -a AGENT_NAMES=()        # CLI name per index (parallel arrays)
declare -a AGENT_SESSION_IDS=()  # minted SESSION_ID per index
declare -A AGENT_LAUNCH_RC=()    # CLI exit code per session id (sidecar-read)
# PIDs of the backgrounded per-agent subshells. We MUST `wait` these specific
# PIDs — never a bare `wait`. A bare `wait` blocks on ALL background jobs of
# this shell, which includes the long-lived gh-token-refresh-daemon (started
# by lib-auth.sh) and the heartbeat sleep loop (_AGENT_HEARTBEAT_PID); neither
# ever exits, so a bare `wait` would hang the wrapper FOREVER after the agents
# finish — stranding the issue in `reviewing` with no aggregation, no verdict
# trailer, and no label transition. See INV-40.
declare -a _fanout_pids=()
# PGIDs of each agent's setsid process group (INV-43, #172) — the value
# _run_with_timeout writes to the per-agent PGID sidecar. Read out of the
# sidecars before _FANOUT_DIR is removed, then consumed by
# _reap_fanout_processes to group-kill any agent still running after its
# verdict can no longer count. Empty when no sidecar was written (agent died
# pre-spawn).
declare -a _AGENT_PGIDS=()
# A per-run temp dir holds each subshell's launch-rc sidecar AND its PGID
# sidecar (the subshell cannot mutate the parent's variables). Mode 700;
# cleaned up after collection.
_FANOUT_DIR=$(mktemp -d "/tmp/agent-review-fanout-${ISSUE_NUMBER}-XXXXXX")

# _reap_fanout_processes is defined in lib-review-poll.sh (INV-43, #172) so it
# can be unit-tested in isolation against real setsid process groups. It takes
# the agents' setsid PGIDs as positional args and group-kills any still alive.
# We pass the collected _AGENT_PGIDS — see the call site after verdict
# resolution and the array's declaration above.

# Reports the SHARED model default; a per-agent AGENT_REVIEW_MODEL_<AGENT>
# override (INV-41) may diverge per agent — each agent's effective model is
# visible in its own log (/tmp/agent-${PROJECT_ID}-review-${N}-${agent}.log).
log "Fanning out ${#REVIEW_AGENTS_LIST[@]} review agent(s): ${REVIEW_AGENTS_LIST[*]} (shared model: ${AGENT_REVIEW_MODEL:-sonnet})"

# INV-46 (#182): these are PURE code-review agents. The E2E ran ONCE in Phase A
# above and its evidence is already posted as a PR comment; the review prompt
# tells each agent to READ that posted evidence as input (it no longer contains
# any E2E execution instructions). The old multi-agent sibling-evidence re-check
# (INV-43 "duplicated pre-hook shrink") is therefore gone — the wrapper's
# single-run E2E lane is the strong guarantee that supersedes it.

for _agent in "${REVIEW_AGENTS_LIST[@]}"; do
  _agent_session_id=$(uuidgen)
  AGENT_NAMES+=("$_agent")
  AGENT_SESSION_IDS+=("$_agent_session_id")
  _agent_log="/tmp/agent-${PROJECT_ID}-review-${ISSUE_NUMBER}-${_agent}.log"
  _agent_prompt=$(build_review_prompt "$_agent" "$_agent_session_id")
  _agent_rc_file="${_FANOUT_DIR}/${_agent_session_id}.rc"

  (
    # Per-subshell AGENT_CMD override so run_agent dispatches to THIS CLI.
    AGENT_CMD="$_agent"
    # INV-42 (#173): per-agent launcher resolution. If the operator set an
    # AGENT_REVIEW_LAUNCHER_<AGENT> key (suffix = uppercased name with every
    # non-alphanumeric char → `_`, same transform as the model/extra-args
    # keys), apply it as THIS agent's launcher — tokenized with `eval` (the
    # same trust model lib-agent.sh uses for AGENT_LAUNCHER). Setting the key
    # is the operator asserting "this launcher fits THIS CLI", so it bypasses
    # the INV-38 claude-only guard for this agent specifically (the guard
    # still governs the SHARED AGENT_REVIEW_LAUNCHER default at startup — see
    # lib-agent.sh). A tokenize failure logs a clear line and falls back to
    # naked rather than crashing the subshell.
    #
    # When no per-agent key is set, _resolve_review_agent_launcher returns
    # empty and we fall through to the INV-38 behavior: a claude-only launcher
    # (cc bridge etc.) must not wrap a non-claude CLI, so neutralize the
    # launcher for non-claude members; a claude member keeps its rebound
    # AGENT_LAUNCHER_ARGV. Scope is THIS subshell only — never leaks across
    # fan-out members or to the dev side.
    _per_agent_launcher=$(_resolve_review_agent_launcher "$_agent")
    if [[ -n "$_per_agent_launcher" ]]; then
      # Validate the array assignment PARSES before eval'ing it. A syntax
      # error inside `eval` (e.g. an unbalanced quote from an operator typo)
      # is NOT caught by `if ! eval ... 2>/dev/null` — a parse error aborts the
      # current shell context, which here is THIS fan-out subshell, so the
      # agent would silently die before run_agent with no log and no sidecar.
      # `bash -n -c` parses without executing, so a malformed value is caught
      # cleanly and we degrade to naked + a clear log line.
      if bash -n -c "AGENT_LAUNCHER_ARGV=($_per_agent_launcher)" 2>/dev/null; then
        eval "AGENT_LAUNCHER_ARGV=($_per_agent_launcher)"
      else
        log "ERROR: AGENT_REVIEW_LAUNCHER_<$_agent> failed to tokenize as a shell argv list; running naked. Value: $_per_agent_launcher"
        AGENT_LAUNCHER_ARGV=()
      fi
    elif [[ "$_agent" != "claude" ]]; then
      AGENT_LAUNCHER_ARGV=()
    fi
    # The wrapper owns the single review-N.pid; per-agent run_agent must NOT
    # rewrite it (the _run_with_timeout PID-file write is keyed on
    # AGENT_PID_FILE). Point AGENT_PID_FILE at a PRIVATE per-agent PGID sidecar
    # (NOT the shared review-N.pid) so each agent's setsid PGID — the
    # _AGENT_RUN_PID captured in _run_with_timeout — is recorded for
    # _reap_fanout_processes (INV-43, #172) WITHOUT thrashing the dispatcher's
    # liveness model. The subshell PID is NOT a process-group leader (no `set
    # -m` here), so the reaper must group-kill THIS PGID, not the subshell PID.
    AGENT_PID_FILE="${_FANOUT_DIR}/${_agent_session_id}.pgid"
    # INV-41 (#168): per-agent model + extra-args resolution. Each resolves
    # the per-agent override key (AGENT_REVIEW_MODEL_<AGENT> /
    # AGENT_REVIEW_EXTRA_ARGS_<AGENT>, suffix = uppercased name with
    # non-alphanumeric→`_`) else the shared AGENT_REVIEW_MODEL /
    # AGENT_REVIEW_EXTRA_ARGS. Scope is THIS subshell only — never leaks to
    # the dev side or to a sibling agent's subshell. With no per-agent key
    # set, _agent_model == AGENT_REVIEW_MODEL so the run_agent model arg below
    # is identical to the legacy `${AGENT_REVIEW_MODEL:-sonnet}`.
    _agent_model=$(_resolve_review_agent_model "$_agent")
    # run_agent (a fresh session) tokenizes AGENT_DEV_EXTRA_ARGS, NOT
    # AGENT_REVIEW_EXTRA_ARGS (only resume_agent reads the latter, and the
    # review wrapper never resumes). So assign the RESOLVED review extra-args
    # to AGENT_DEV_EXTRA_ARGS inside this subshell — that's the var
    # lib-agent.sh::_parse_extra_args actually consumes on the review path.
    # The resolver reads the operator-facing review knobs, so operators still
    # configure AGENT_REVIEW_EXTRA_ARGS[_<AGENT>].
    AGENT_DEV_EXTRA_ARGS=$(_resolve_review_agent_extra_args "$_agent")
    _agent_session_name="review-pr-${PR_NUMBER}-issue-${ISSUE_NUMBER}-${_agent}"
    # Capture the rc explicitly: the subshell inherits `set -e`, so a non-zero
    # run_agent (the exact case the sidecar records — a CLI launch failure)
    # would abort the subshell BEFORE the printf if we read `$?` on the next
    # line. `|| _rc=$?` suppresses set -e and preserves the true exit code
    # (124 timeout / 137 kill / real launch error) for forensic logging.
    _rc=0
    if [[ "$AGENT_CMD" == "codex" ]]; then
      # INV-51 (#189): codex's single `codex exec` turn is often consumed by
      # context-gathering on a large diff, ending gather-only with no verdict —
      # so route codex through the auto-resume controller, which watches codex's
      # JSONL event stream (the same $_agent_log this invocation writes) and
      # resumes the thread while turns are gather-only, bounded by
      # CODEX_REVIEW_MAX_RESUMES + the AGENT_REVIEW_TIMEOUT wall-clock. The
      # controller's internal run_agent/resume_agent calls inherit this
      # redirect, so CODEX_REVIEW_LOG points at the very file they append to.
      # On bound exhaustion (no verdict) codex falls back to today's behavior:
      # the comment poller below resolves it `unavailable` (INV-40). Every other
      # CLI keeps the bare run_agent path (else branch) — byte-for-byte unchanged.
      CODEX_REVIEW_LOG="$_agent_log" \
        _run_codex_review_with_resume "$_agent_session_id" "$_agent_prompt" "${_agent_model:-sonnet}" "$_agent_session_name" \
        >>"$_agent_log" 2>&1 || _rc=$?
    else
      run_agent "$_agent_session_id" "$_agent_prompt" "${_agent_model:-sonnet}" "$_agent_session_name" \
        >>"$_agent_log" 2>&1 || _rc=$?
    fi
    printf '%s\n' "$_rc" > "$_agent_rc_file"
  ) &
  # Collect THIS subshell's PID so we wait only the fan-out agents below —
  # not the token-refresh daemon / heartbeat (which never exit). See the
  # _fanout_pids declaration above and INV-40.
  _fanout_pids+=("$!")
done

# Wait for the fanned-out review agents to finish — by their COLLECTED PIDs
# only. A bare `wait` here would also block on the gh-token-refresh-daemon and
# the heartbeat loop and hang forever (the bug this guards against).
#
# `|| true`: bash's single-PID `wait` (the N=1 fan-out) propagates the
# subshell's exit code, which under `set -e` would abort the wrapper BEFORE
# aggregation if that subshell exited non-zero (only reachable if the
# sidecar `printf` itself failed — e.g. a full tmpfs; run_agent's own rc is
# already captured into the sidecar via `|| _rc=$?`). We suppress that so the
# wrapper always proceeds to read the sidecars and aggregate; a missing/
# unwritten sidecar is then handled as a launch failure (rc=1) below. The
# multi-PID `wait` already returns 0 regardless of child rc.
wait "${_fanout_pids[@]}" || true

# Read each agent's launch exit code AND its setsid PGID from the sidecars
# (INV-43: the PGID must be captured before _FANOUT_DIR is removed below — the
# reaper runs later, after verdict resolution).
for _i in "${!AGENT_NAMES[@]}"; do
  _sid="${AGENT_SESSION_IDS[$_i]}"
  _rc_file="${_FANOUT_DIR}/${_sid}.rc"
  if [[ -f "$_rc_file" ]]; then
    AGENT_LAUNCH_RC["$_sid"]=$(head -n1 "$_rc_file" 2>/dev/null || echo 1)
  else
    # Subshell never wrote a sidecar (crashed before the printf) — treat as
    # a launch failure.
    AGENT_LAUNCH_RC["$_sid"]=1
  fi
  # PGID sidecar (written by run_agent → _run_with_timeout via AGENT_PID_FILE).
  # Missing/empty/non-numeric → no PGID to reap for this agent (it may have
  # died before the setsid spawn).
  _pgid_file="${_FANOUT_DIR}/${_sid}.pgid"
  if [[ -f "$_pgid_file" ]]; then
    _pgid_val=$(head -n1 "$_pgid_file" 2>/dev/null || true)
    [[ "$_pgid_val" =~ ^[0-9]+$ ]] && [[ "$_pgid_val" -gt 0 ]] && _AGENT_PGIDS+=("$_pgid_val")
  fi
  log "Review agent '${AGENT_NAMES[$_i]}' (session ${_sid}) exited with code: ${AGENT_LAUNCH_RC[$_sid]}"
done
rm -rf "$_FANOUT_DIR" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Collect per-agent verdicts and aggregate (INV-40)
# ---------------------------------------------------------------------------
log "Parsing review results from issue comments (per agent)..."

# Verdict-keyword regex (closes #95): canonical phrasings plus drift variants.
# Read by _fetch_agent_verdict_body (lib-review-poll.sh) when building the jq
# finder. Keep in sync with _classify_verdict_body — this is the UNION of its
# fail-bucket and pass-bucket patterns (the finder must match anything the
# classifier can bucket).
_VERDICT_RE='Review PASSED|Review APPROVED|APPROVED FOR MERGE|LGTM|Review PASS|Review findings:|Review FAILED|Review REJECTED|Changes requested'

# The verdict classifier (_classify_verdict_body, pass|fail FAIL-first, #95), the
# per-round decision (_classify_unresolved_agent, #180), the per-agent verdict
# fetch (_fetch_agent_verdict_body), and the poll loop itself
# (_run_verdict_poll_loop) all live in lib-review-poll.sh (sourced above) so the
# single verdict-classification + polling rule is shared and unit-testable in
# isolation.

# Per-agent verdict polling. The authenticity binding (INV-20) is unchanged —
# actor (BOT_LOGIN) + time window (WRAPPER_START_TS) + the `Review Session`
# trailer presence — EXCEPT we add a per-agent discriminator so N verdict
# comments posted under the SAME GitHub identity don't collapse to one
# (INV-40). The discriminator is the `Review Agent: <name>` line each agent's
# prompt instructs it to emit; the wrapper takes `last` per agent.
#
# Fallback (BOT_LOGIN empty): drop the actor layer, keep the time window, and
# narrow on that agent's own `Review Session.*<session-id>` UUID.
#
# Poll budget (INV-43, #172): the attempt count is resolved from
# _resolve_verdict_poll_attempts — the legacy 6 (30s) for every non-command
# mode, and max(6, ceil(E2E_COMMAND_TIMEOUT_SECONDS/5)) when E2E_MODE=command,
# so a review agent that faithfully runs the (slow) command-mode E2E is not
# dropped as `unavailable` for taking as long as the E2E it was asked to run.
# The loop still stops EARLY once every agent has a verdict, so the happy path
# settles in one round (~5s) regardless of budget.
#
# No early non-zero-rc drop (INV-43 sibling clarification, #180): this loop runs
# AFTER the fan-out `wait`, so every agent CLI has already exited and
# AGENT_LAUNCH_RC is fully populated before round 1. A non-zero CLI exit must
# NOT, by itself, drop an agent while the poll window is still open — the verify
# command can exit non-zero on a soft path, the CLI can exit non-zero just after
# the agent posted its `Review PASSED` verdict, or the verdict comment is still
# propagating to the comments API. So a no-verdict agent keeps being polled
# REGARDLESS of rc (_classify_unresolved_agent returns `keep`) for the full
# INV-43-scaled window — the window IS the propagation grace (#180 Fix 2: no
# separate post-exit grace timer). A verdict the agent DID post wins over the rc
# (INV-40). An agent with no verdict when the window expires is resolved
# `unavailable` by the post-window sweep below — same terminal outcome as before
# #180, just no longer pre-empted on round 1.
_VERDICT_POLL_ATTEMPTS=$(_resolve_verdict_poll_attempts)
log "Verdict-poll budget: ${_VERDICT_POLL_ATTEMPTS} attempt(s) × 5s (E2E_MODE=${E2E_MODE:-none}, command-timeout=${E2E_COMMAND_TIMEOUT_SECONDS:-n/a})"
declare -a AGENT_VERDICTS=()        # pass | fail | unavailable, per index
declare -a AGENT_VERDICT_BODIES=()  # the matched comment body (or empty)
for _i in "${!AGENT_NAMES[@]}"; do
  AGENT_VERDICTS+=("")        # filled in below
  AGENT_VERDICT_BODIES+=("")
done

# The loop body lives in lib-review-poll.sh (_run_verdict_poll_loop) so the
# round-by-round behavior — not just the per-round decision — is unit-testable
# (#180 regression test stubs the per-agent verdict fetch to return a passing
# verdict only on round ≥2 and asserts a non-zero-rc agent is still counted
# `pass`). It reads AGENT_NAMES / AGENT_SESSION_IDS / AGENT_LAUNCH_RC /
# _VERDICT_POLL_ATTEMPTS and fills AGENT_VERDICTS / AGENT_VERDICT_BODIES.
_run_verdict_poll_loop

# Any agent still unresolved after the poll window is terminally resolved here
# (no verdict comment within the window). This is the SINGLE terminal resolution
# point for a no-verdict agent (#180): whether the CLI exited clean (rc 0) or
# non-zero, the loop kept polling it for the full budget; only here, at window
# expiry, is it resolved.
#
# INV-48 (#185) splits that resolution by launch rc via _classify_noverdict_agent:
#   - rc 124 (timeout) / 137 (kill-after KILL) → `timed-out` → a DECIDING FAIL
#     in _aggregate_review_verdicts (the merge is VETOED). A review agent reaped
#     by the 1h review cap must be loud, not silently dropped — otherwise a 1h
#     cap could turn a slow-but-legit review (e.g. a >1h CI queue) into a pass.
#   - any other no-verdict rc (0 clean-but-silent, 1 launch failure, …) →
#     `unavailable` → dropped from the vote, exactly as before #185.
# A verdict the agent DID post already won in the poll loop (INV-40 precedence),
# so this sweep only ever runs for genuinely no-verdict agents.
for _i in "${!AGENT_NAMES[@]}"; do
  [[ -n "${AGENT_VERDICTS[$_i]}" ]] && continue
  AGENT_VERDICTS[$_i]=$(_classify_noverdict_agent "${AGENT_LAUNCH_RC[${AGENT_SESSION_IDS[$_i]}]:-1}")
done

# INV-43 (#172): reap any fan-out agent process group that is still alive now
# that verdicts are resolved — a dropped/undecided agent's CLI must not outlive
# its review round (orphaned-process side effect). No-op when every agent
# already exited (the common case, since the fan-out `wait` returned above).
# Pass the collected setsid PGIDs (NOT the subshell PIDs — those are not group
# leaders without job control; see _reap_fanout_processes in lib-review-poll.sh).
# INV-46 (#182): also pass the E2E lane's PGID so a lingering command-mode
# verify subtree (e.g. a long `--watch`) is group-killed here too — the lane ran
# synchronously in Phase A, so it has normally already exited (no-op), but a
# subtree the lane backgrounded and orphaned is reaped on this pass.
_reap_fanout_processes "${_AGENT_PGIDS[@]:-}" "${_AGENT_PGIDS_E2E:-}"

# Aggregate under the unanimous-PASS rule (INV-40). Map the aggregate onto the
# existing PASSED_VERDICT / LATEST_COMMENT / AGENT_EXIT variables so the
# downstream PASS / FAIL / crash branches and the six emit_verdict_trailer
# call sites run UNCHANGED — exactly ONE aggregated INV-35 trailer and ONE
# INV-04 Reviewed-HEAD trailer per review run.
AGGREGATE=$(_aggregate_review_verdicts "${AGENT_VERDICTS[@]}")
log "Per-agent verdicts: ${AGENT_VERDICTS[*]} → aggregate: ${AGGREGATE}"

# A representative SESSION_ID for the Reviewed-HEAD trailer (INV-04) and the
# BOT_LOGIN-empty fallback predicate downstream. Use the first agent's id; in
# the N=1 case this IS the lone agent's session.
SESSION_ID="${AGENT_SESSION_IDS[0]}"

# Identify deciding (verdict-producing OR timed-out-veto) vs dropped
# (unavailable) agents for the human-visible summary on partial unavailability.
# A `timed-out` agent (INV-48) is DECIDING — it cast a veto — so it lands in
# _deciding_agents, NOT _dropped_agents, and is also tracked separately for the
# loud veto breadcrumb below.
_dropped_agents=""
_deciding_agents=""
_timed_out_agents=""
for _i in "${!AGENT_NAMES[@]}"; do
  case "${AGENT_VERDICTS[$_i]}" in
    unavailable)
      _dropped_agents+="${AGENT_NAMES[$_i]} "
      ;;
    timed-out)
      _deciding_agents+="${AGENT_NAMES[$_i]}(timed-out) "
      _timed_out_agents+="${AGENT_NAMES[$_i]} "
      ;;
    *)
      _deciding_agents+="${AGENT_NAMES[$_i]}(${AGENT_VERDICTS[$_i]}) "
      ;;
  esac
done

# Loud timeout-veto breadcrumb (INV-48): a review agent reaped by its wall-clock
# cap (rc 124/137) with no verdict VETOES the merge. Post ONE human-visible
# finding so the FAIL is attributable to the timeout (not a silent drop) — this
# also guarantees LATEST_COMMENT is non-empty below even when EVERY deciding
# agent was a timeout (no posted bodies), so the run routes as a substantive
# FAIL with an explanatory comment rather than the empty-comment crash branch.
if [[ -n "$_timed_out_agents" ]]; then
  log "INV-48: review agent(s) timed out (rc 124/137, no verdict) — VETO (deciding FAIL): ${_timed_out_agents%% }"
  gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
    --body "Review findings:

Findings->Decision Gate: 1 blocking finding(s) -- FAIL.

1. **[BLOCKING] Review agent timed out** — agent(s) \`${_timed_out_agents%% }\` were killed by the review wall-clock cap (\`${AGENT_TIMEOUT}\`, INV-48) before posting a verdict (CLI exit 124/137). A timed-out reviewer VETOES the merge rather than being dropped from the vote. Raise \`AGENT_REVIEW_TIMEOUT\` if reviews legitimately need longer, or investigate why the agent hung (e.g. a >1h CI queue the agent watched). The PR was NOT approved." 2>/dev/null || true
fi

# LATEST_COMMENT drives (a) the Reviewed-HEAD trailer gate (post only when a
# verdict exists) and (b) the FAIL-vs-crash branch below. Synthesize it from
# the deciding agents' bodies so multi-agent FAIL findings flow to dev. For
# all-unavailable, LATEST_COMMENT stays empty.
LATEST_COMMENT=""
for _i in "${!AGENT_NAMES[@]}"; do
  if [[ -n "${AGENT_VERDICT_BODIES[$_i]}" ]]; then
    LATEST_COMMENT+="${AGENT_VERDICT_BODIES[$_i]}"$'\n\n'
  fi
done
# INV-48: a timed-out agent posts no body, but its veto is a deciding FAIL. Mark
# LATEST_COMMENT non-empty so this run is treated as a verdict-reaching FAIL (the
# Reviewed-HEAD trailer is posted, and the downstream FAIL branch takes the
# substantive path, not the empty-comment crash path). Only matters when there
# are NO other deciding bodies (e.g. every deciding agent timed out).
if [[ -z "$LATEST_COMMENT" && -n "$_timed_out_agents" ]]; then
  LATEST_COMMENT="Review FAILED: agent(s) timed out (review wall-clock cap, INV-48): ${_timed_out_agents%% }"$'\n\n'
fi

case "$AGGREGATE" in
  pass)
    PASSED_VERDICT=true
    AGENT_EXIT=0
    ;;
  fail)
    PASSED_VERDICT=false
    AGENT_EXIT=0  # the agent(s) ran and produced a verdict — not a crash
    ;;
  all-unavailable)
    # No deciding agent. Fall back to today's single-agent FAIL path verbatim.
    # The legacy single-agent wrapper distinguished two no-verdict cases by
    # AGENT_EXIT, and we preserve that distinction so the N=1 path stays
    # byte-for-byte (the downstream FAIL branch reads `$AGENT_EXIT -ne 0`):
    #   - any agent's CLI actually crashed (rc != 0) → AGENT_EXIT=1 → the
    #     crash-fallback comment + `failed-non-substantive other` trailer
    #     (genuine transport/mid-stream crash).
    #   - every agent exited cleanly (rc == 0) but posted no verdict comment
    #     → AGENT_EXIT=0 → no crash comment, `failed-substantive` trailer
    #     (the agent ran fine but didn't reach a verdict — a code-side miss,
    #     matching legacy single-agent semantics exactly).
    PASSED_VERDICT=false
    LATEST_COMMENT=""
    AGENT_EXIT=0
    for _i in "${!AGENT_NAMES[@]}"; do
      if [[ "${AGENT_LAUNCH_RC[${AGENT_SESSION_IDS[$_i]}]:-1}" -ne 0 ]]; then
        AGENT_EXIT=1
        break
      fi
    done
    log "All ${#REVIEW_AGENTS_LIST[@]} review agent(s) unavailable — falling back to single-agent FAIL path (AGENT_EXIT=${AGENT_EXIT})."
    ;;
esac

# Partial unavailability (some but not all dropped): post ONE human-visible
# summary comment listing dropped vs deciding agents and log a WARN. The
# decision was made on the deciding agents under the unanimous-PASS rule.
if [[ -n "$_dropped_agents" && "$AGGREGATE" != "all-unavailable" ]]; then
  log "WARNING: review agent(s) dropped (unavailable): ${_dropped_agents%% }; decided on: ${_deciding_agents%% }"
  gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
    --body "Multi-agent review: dropped (unavailable) agent(s): \`${_dropped_agents%% }\`. Decision made on: \`${_deciding_agents%% }\`. (INV-40: unavailable = CLI launch failure or no verdict within the poll window.)" 2>/dev/null || true
fi

# Post a "Reviewed HEAD" trailer comment so the dispatcher can detect whether
# new commits have landed since the last review. The dispatcher uses this to
# decide between routing a dead-with-PR transition to pending-review (new code
# to review) vs. pending-dev (no new code, retry dev).
# Only emitted when the agent produced a verdict comment — a missing verdict
# already routes to pending-dev via the FAILED branch below.
if [[ -n "$LATEST_COMMENT" && -n "$PR_HEAD_SHA" ]]; then
  # Capture stderr so token/permission/rate-limit failures are diagnosable.
  # If this post fails persistently the dispatcher cannot detect SHA-match,
  # so the WARNING is the only operator-visible breadcrumb (see SKILL.md
  # Step 5 empty-trailer fallthrough).
  # Trailer carries `agent` / `model` for forensic attribution in
  # multi-CLI deployments where AGENT_CMD is rotated between rounds
  # (#128). Option A from the issue: write ${AGENT_REVIEW_MODEL}
  # directly rather than `${...:-<default>}`. lib-agent.sh:43 already
  # defaults the variable to `sonnet`, so a `:-<default>` here would
  # render dead code — the trailer renders the live, current value.
  # The dispatcher's last_reviewed_head parser anchors only on the
  # leading `Reviewed HEAD: \`<sha>\`` (INV-04), so the trailing
  # parenthesised metadata is purely human-attribution.
  _trailer_err=$(gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
    --body "Reviewed HEAD: \`${PR_HEAD_SHA}\` (issue #${ISSUE_NUMBER}, session \`${SESSION_ID}\`, agent \`${AGENT_CMD:-claude}\`, model \`${AGENT_REVIEW_MODEL}\`)" \
    2>&1 >/dev/null) \
    || log "WARNING: Failed to post Reviewed HEAD trailer (non-fatal): ${_trailer_err}"
fi

# ---------------------------------------------------------------------------
# Mergeable hard gate (INV-44, #176)
# ---------------------------------------------------------------------------
# A CONFLICTING PR can never reach `approved`, regardless of whether the review
# agent ran its Step-0 pre-review rebase prompt. This is the WRAPPER-level
# enforcement of "mergeable != MERGEABLE → blocking finding → FAIL"; the agent's
# Step-0 prompt is best-effort, this gate is mechanical.
#
# Runs ONLY when the aggregate was PASS — a FAIL / all-unavailable aggregate
# already routes to pending-dev below, so re-checking mergeable there would be
# redundant work and an extra gh call on the failure path.
#
# The gate queries `mergeable` (retrying while GitHub reports UNKNOWN, since the
# field is computed asynchronously), then calls the pure
# _classify_mergeable_gate helper (lib-review-mergeable.sh). On a block it is
# self-contained — posts its own finding/marker, emits its own INV-35 trailer,
# flips the label, and exits — so every existing PASS/FAIL/crash branch stays
# byte-for-byte unchanged.
if [[ "$PASSED_VERDICT" == "true" ]]; then
  # Poll mergeable while UNKNOWN (GitHub computes it asynchronously). The
  # tightened UNKNOWN handling (#176): a value that never settles out of
  # UNKNOWN is NOT treated as MERGEABLE — it routes to pending-dev as a
  # non-substantive re-queue, closing the stale-UNKNOWN pass-through.
  MERGEABLE_RETRIES="${MERGEABLE_RETRIES:-3}"
  MERGEABLE_STATUS=""
  for _mg_attempt in $(seq 1 "$MERGEABLE_RETRIES"); do
    MERGEABLE_STATUS=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json mergeable -q '.mergeable' 2>/dev/null || echo "")
    [[ "${MERGEABLE_STATUS^^}" != "UNKNOWN" && -n "$MERGEABLE_STATUS" ]] && break
    # Only sleep when another attempt will follow — no point waiting after the
    # final probe (the loop is about to exit and classify the settled value).
    if [[ "$_mg_attempt" -lt "$MERGEABLE_RETRIES" ]]; then
      log "PR #${PR_NUMBER} mergeable status is '${MERGEABLE_STATUS:-<empty>}' (attempt ${_mg_attempt}/${MERGEABLE_RETRIES}); waiting for GitHub to settle..."
      sleep 10
    fi
  done

  MERGEABLE_GATE=$(_classify_mergeable_gate "$MERGEABLE_STATUS")
  log "Mergeable hard gate: PR #${PR_NUMBER} mergeable='${MERGEABLE_STATUS:-<empty>}' → gate=${MERGEABLE_GATE}"

  if [[ "$MERGEABLE_GATE" == "block-substantive" ]]; then
    # Real conflict — the unanimous-PASS verdict is overridden. Dev must rebase.
    log "BLOCKING: PR #${PR_NUMBER} is CONFLICTING — overriding PASS verdict, routing to pending-dev for rebase."

    # [BLOCKING] finding on the ISSUE with dev-actionable rebase instructions
    # (mirrors references/merge-conflict-resolution.md).
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "Review findings:

Findings->Decision Gate: 1 blocking finding(s) -- FAIL.

1. **[BLOCKING] Merge conflict with main** — PR #${PR_NUMBER} (\`${PR_BRANCH:-the PR branch}\`) is \`CONFLICTING\` with the base branch and cannot be merged. The review agent's PASS verdict is overridden by the wrapper-enforced mergeable gate (INV-44).
   - Dev agent must rebase before re-review:
     1. \`git fetch origin main\`
     2. \`git rebase origin/main\`
     3. Resolve conflicts, then \`git rebase --continue\`
     4. \`git push --force-with-lease origin ${PR_BRANCH:-<PR_BRANCH>}\`" 2>/dev/null || true

    # Reuse the dev-resume rebase hook: autonomous-dev.sh greps issue-level PR
    # comments for a body starting "Auto-merge failed:" and prepends a
    # mandatory rebase pre-step to the resume prompt. Posting the marker here
    # gives the conflict a deterministic owner (the next dev session) instead
    # of letting it fall through the cracks.
    gh pr comment "$PR_NUMBER" --repo "$REPO" \
      --body "Auto-merge failed: PR is CONFLICTING with main (mergeable gate, INV-44). Re-dispatching dev agent to rebase onto main." 2>/dev/null || true

    # INV-35: a merge conflict is a real, dev-actionable finding — substantive.
    emit_verdict_trailer "$ISSUE_NUMBER" "$REPO" "failed-substantive" "" 2>/dev/null || true

    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
      --remove-label "reviewing" \
      --add-label "pending-dev" 2>/dev/null || true

    log "Issue #${ISSUE_NUMBER} moved to pending-dev (merge conflict — dev must rebase)."
    RESULT_PARSED=true
    exit 0
  elif [[ "$MERGEABLE_GATE" == "block-nonsubstantive" ]]; then
    # mergeable never settled out of UNKNOWN (or the gh query failed). Do NOT
    # auto-approve — GitHub may still be computing, and an actual conflict that
    # is still being computed must not be silently treated as mergeable. Route
    # back as a non-substantive re-queue so the next dispatcher tick re-reviews
    # once the status settles. No PR rebase marker: there may be no real
    # conflict, so we must not trigger an unnecessary rebase.
    log "BLOCKING: PR #${PR_NUMBER} mergeable is UNKNOWN past the retry budget — re-queuing (not auto-approving)."

    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "Review held: PR #${PR_NUMBER} mergeable status is \`${MERGEABLE_STATUS:-UNKNOWN}\` (GitHub has not finished computing mergeability after ${MERGEABLE_RETRIES} attempts). Per the mergeable hard gate (INV-44) the PR is NOT auto-approved while mergeability is unresolved; it will be re-reviewed on the next dispatch tick." 2>/dev/null || true

    # INV-35: not a code issue — GitHub-side transient. Re-route through review.
    emit_verdict_trailer "$ISSUE_NUMBER" "$REPO" "failed-non-substantive" "mergeable-unknown" 2>/dev/null || true

    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
      --remove-label "reviewing" \
      --add-label "pending-dev" 2>/dev/null || true

    log "Issue #${ISSUE_NUMBER} moved to pending-dev (mergeable UNKNOWN — re-queue)."
    RESULT_PARSED=true
    exit 0
  fi
  # gate == proceed → fall through to the existing PASS branch unchanged.
fi

# PASSED_VERDICT was set by the unanimous-PASS aggregation above (INV-40).
# Per-agent FAIL-first classification (#95) lives in _classify_verdict_body,
# and the aggregate (`_aggregate_review_verdicts`) collapses the per-agent
# verdicts under the unanimous rule. The downstream PASS / FAIL / crash
# branches below are byte-for-byte the single-agent paths.
if [[ "$PASSED_VERDICT" == "true" ]]; then
  log "Review PASSED for PR #${PR_NUMBER}."
  # INV-35: emit `passed` trailer; dispatcher's Step 4b.5.1 treats it as a
  # race window if the issue subsequently reappears as `pending-dev`
  # (no-op + WARN, Step 0 hygiene reconciles).
  emit_verdict_trailer "$ISSUE_NUMBER" "$REPO" "passed" "" 2>/dev/null || true

  # ---------------------------------------------------------------------------
  # Guard: verify PR is still open before approving/merging.
  # A concurrent review (e.g. manual `/q review` + dispatcher) may have already
  # approved and merged the PR while this review was running.
  # ---------------------------------------------------------------------------
  PR_STATE=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")
  if [[ "$PR_STATE" != "OPEN" ]]; then
    log "PR #${PR_NUMBER} is no longer open (state: ${PR_STATE}). Skipping approve/merge — another review likely completed first."
    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
      --remove-label "reviewing" 2>/dev/null || true
    RESULT_PARSED=true
    exit 0
  fi

  # Formal PR approval from review agent
  if ! refresh_token_env; then
    log "ERROR: Token refresh failed — token daemon may have crashed. Attempting approval with current token..."
  fi
  log "Submitting PR approval for PR #${PR_NUMBER}..."
  if gh pr review "$PR_NUMBER" --repo "$REPO" --approve \
    --body "All acceptance criteria verified.$(if [[ "${E2E_ACTIVE:-false}" == "true" ]]; then echo " E2E verification passed."; fi)" 2>&1; then
    log "PR #${PR_NUMBER} approved successfully."
  else
    log "ERROR: Failed to submit PR approval for PR #${PR_NUMBER}."
    log "Falling back to manual review notification."
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "Review PASSED but formal PR approval failed (permission issue?). @${REPO_OWNER} please approve and merge PR #${PR_NUMBER} manually." 2>/dev/null || true
    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
      --remove-label "reviewing" \
      --add-label "approved" 2>/dev/null || true
    log "Issue #${ISSUE_NUMBER} marked as approved. Manual merge required due to approval failure."
    exit 0
  fi

  # Check if issue has the 'no-auto-close' label
  HAS_NO_AUTO_CLOSE=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json labels \
    -q '[.labels[].name] | any(. == "no-auto-close")' 2>/dev/null || echo "false")

  if [[ "$HAS_NO_AUTO_CLOSE" == "true" ]]; then
    log "Issue has 'no-auto-close' label — skipping auto-merge."

    # Notify project owner to merge manually
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "Review PASSED — this issue has the 'no-auto-close' label. @${REPO_OWNER} please review and merge PR #${PR_NUMBER} when ready." 2>/dev/null || true

    # Update labels: remove reviewing, add approved (keep no-auto-close and autonomous)
    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
      --remove-label "reviewing" \
      --add-label "approved" 2>/dev/null || true

    log "Issue #${ISSUE_NUMBER} marked as approved. Awaiting manual merge."
  else
    log "Merging PR #${PR_NUMBER}..."

    # Capture merge stdout+stderr so the failure-path PR comment can
    # surface the merge error to the dev re-dispatch (#145).
    set +e
    MERGE_OUT=$(gh pr merge "$PR_NUMBER" --repo "$REPO" --squash --delete-branch 2>&1)
    MERGE_RC=$?
    set -e
    [[ -n "$MERGE_OUT" ]] && log "gh pr merge output: ${MERGE_OUT}"

    if [[ $MERGE_RC -eq 0 ]]; then
      log "PR #${PR_NUMBER} merged successfully."

      # INV-33: never close the issue directly — GitHub auto-closes it
      # via the PR's `Closes #N` keyword on merge. See docs/pipeline/invariants.md.
      gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
        --remove-label "reviewing" --remove-label "autonomous" \
        --add-label "approved" 2>/dev/null || true

      log "Issue #${ISSUE_NUMBER} marked approved; auto-close handled by GitHub via 'Closes #N' resolution."
    else
      # Auto-merge failed (#145). Post the marker on the PR (dev re-dispatch
      # detects it via /issues/<n>/comments to trigger rebase), then flip the
      # issue to pending-dev while keeping `autonomous` so the dispatcher's
      # Step 4 selector picks it up next tick. Never close, never approve.
      _err_excerpt="${MERGE_OUT:0:500}"
      log "WARNING: Auto-merge failed (rc=${MERGE_RC}): ${_err_excerpt}"

      if ! _comment_err=$(gh pr comment "$PR_NUMBER" --repo "$REPO" \
        --body "Auto-merge failed: ${_err_excerpt}

Re-dispatching dev agent to rebase onto main." 2>&1 >/dev/null); then
        log "WARNING: Failed to post auto-merge-failure marker on PR #${PR_NUMBER} (non-fatal — label transition still proceeds): ${_comment_err}"
      fi
      # INV-35: auto-merge-failure is a non-substantive cause; the dev
      # session's code is fine, only the merge step couldn't complete.
      # Routes back through review on the next tick once the rebase lands.
      emit_verdict_trailer "$ISSUE_NUMBER" "$REPO" "failed-non-substantive" "merge-conflict-unresolvable" 2>/dev/null || true

      # Capture stderr so a failed label transition is diagnosable from logs —
      # otherwise the issue would silently stick in `reviewing` and the next
      # dispatcher tick wouldn't re-dispatch dev.
      if ! _edit_err=$(gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
        --remove-label "reviewing" \
        --add-label "pending-dev" 2>&1 >/dev/null); then
        log "WARNING: Failed to flip issue #${ISSUE_NUMBER} to pending-dev (issue may stay stuck in reviewing): ${_edit_err}"
      else
        log "Issue #${ISSUE_NUMBER} flipped to pending-dev for rebase re-dispatch (autonomous label retained)."
      fi
    fi
  fi
else
  log "Review FAILED or inconclusive. Sending back to dev."

  # If agent crashed without posting a comment, add a fallback
  if [[ $AGENT_EXIT -ne 0 ]] && [[ -z "$LATEST_COMMENT" ]]; then
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "Review process encountered an error (agent exit code: ${AGENT_EXIT}). Moving back to development for investigation." 2>/dev/null || true
    # INV-35: agent crash without verdict comment — non-substantive
    # (transport / mid-stream failure, not a code issue identified by the
    # agent). Cause `other` because we don't have a more specific signal.
    emit_verdict_trailer "$ISSUE_NUMBER" "$REPO" "failed-non-substantive" "other" 2>/dev/null || true
  else
    # INV-35: agent posted a verdict comment but the verdict was FAILED
    # (or pattern-matched only fail keywords). This is a substantive
    # finding — agent identified code issues to address.
    emit_verdict_trailer "$ISSUE_NUMBER" "$REPO" "failed-substantive" "" 2>/dev/null || true
  fi

  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
    --remove-label "reviewing" \
    --add-label "pending-dev" 2>/dev/null || true

  log "Issue #${ISSUE_NUMBER} moved to pending-dev."
fi

RESULT_PARSED=true
log "Review complete."
exit 0
