#!/bin/bash
# liveness-check-remote-aws-ssm.sh — Synchronous SSM-driven liveness
# probe for the dispatcher's pid_alive under EXECUTION_BACKEND=remote-aws-ssm
# (#137, INV-30).
#
# Closes the structural false-DEAD bug where lib-dispatch.sh::pid_alive
# runs on the dispatcher box but the wrapper writes its PID file +
# heartbeat sibling on a different box. Reproduced on a downstream
# consumer's #182 (2026-05-16 02:15–04:10 UTC).
#
# Usage:
#   bash liveness-check-remote-aws-ssm.sh <kind> <issue_num>
#     kind: issue | review
#
# Stdout:
#   ALIVE / DEAD / empty                    — the original tri-state (unchanged)
#   DEFERRED\n<age_s>                       — [Lane-GC PR-6 / INV-119] a FOURTH
#     verdict, two lines: the literal token `DEFERRED` on line 1, the defer
#     marker's age in whole seconds on line 2. Emitted when the wrapper
#     host's own back-pressure admission gate (dispatch-local.sh) most
#     recently REFUSED to spawn for this exact (kind, issue_num) AND that
#     refusal is still the LATEST dispatch attempt on this host for this
#     (kind, issue_num) — see the freshness comparison below. Checked
#     BEFORE the ALIVE/DEAD tiers: a gate refusal means NO new PID file
#     was ever written for this dispatch attempt, so a stale PID/heartbeat
#     from an unrelated prior run must never outrank a fresh defer signal.
#
# [review P1-1] Freshness comparison (NOT a bare age window as originally
# shipped): `dispatch-local.sh` — which runs ON THE WRAPPER HOST for every
# single dispatch attempt, local or remote-via-SSM — writes a
# `.attempt-<kind>-<issue>` token at the very start of EVERY invocation,
# before its own gate even runs. This token is the verifiable-on-this-host
# anchor for "when did the dispatcher LAST attempt to dispatch this exact
# (kind, issue)" that the design's preferred mechanism calls for (the
# controller-side dispatch-marker/token machinery from #361/[INV-108] is
# NOT usable here: it lives on the DISPATCHER host, and under
# remote-aws-ssm the dispatcher and wrapper hosts are different machines —
# this snippet, which runs entirely on the wrapper host with no GitHub API
# access, can never read it).
#
# DEFER_MARKER mtime >= ATTEMPT_MARKER mtime → DEFERRED (the defer marker
#   was written by the SAME attempt this token records — nothing has
#   superseded it; `>=`, not `>`, because both files land within the same
#   dispatch invocation and stat's 1s granularity routinely makes their
#   mtimes EQUAL).
# DEFER_MARKER mtime STRICTLY OLDER than ATTEMPT_MARKER mtime → the
#   defer marker is IGNORED ENTIRELY, falling straight through to the
#   ALIVE/DEAD tiers below — a stale defer from a PRIOR attempt must never
#   shadow whatever this attempt's real PID-file/heartbeat state says,
#   even if that state says DEAD. An inconclusive comparison (attempt
#   marker missing/unstattable) also falls through — never trusts a
#   defer marker it cannot freshness-check.
# DEFER_MARKER_MAX_AGE_SECONDS (default 900s) is retained ONLY as a
#   secondary sanity ceiling for the case where the freshness comparison
#   itself is unavailable (the attempt marker is missing — e.g. a
#   pre-upgrade wrapper host that has never run the updated
#   dispatch-local.sh) — it is no longer the primary mechanism.
#
# Exit codes:
#   0 — definitive verdict (printed ALIVE, DEAD, or DEFERRED\n<age_s>)
#   1 — input/env validation failure
#   2 — indeterminate: SSM transport fault, timeout, parse error, or
#       remote shell returned anything other than ALIVE/DEAD/DEFERRED.
#       Caller (pid_alive) biases this toward ALIVE (INV-30) so a
#       flaky transport never produces a false crash declaration.
#
# Required env (mirrors dispatch-remote-aws-ssm.sh):
#   SSM_INSTANCE_ID         — EC2 instance ID running the wrapper
#   SSM_REMOTE_PROJECT_DIR  — absolute project root on the remote box
#   SSM_REMOTE_PROJECT_ID   — project_id used in remote PID/log paths
#
# Optional env (with defaults):
#   SSM_REGION         (default: ap-southeast-1)
#   SSM_REMOTE_USER    (default: ubuntu)
#   SSM_REMOTE_SHELL   (default: bash)
#   SSM_REMOTE_PROFILE (default: empty, no source)
#   HEARTBEAT_INTERVAL_SECONDS (default: 120; sized for INV-29)
#   SSM_COMMAND_TIMEOUT_SECONDS — SSM-side cap (default 30, lib-ssm.sh;
#                                  AWS's --timeout-seconds hard minimum)
#   REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS — dispatcher-side poll cap
#                                            (default 8, lib-ssm.sh)
#   DEFER_MARKER_MAX_AGE_SECONDS — [Lane-GC PR-6 / INV-119] (default: 900,
#     15 min) secondary sanity ceiling used ONLY when the attempt-marker
#     freshness comparison above is unavailable — see the comparison
#     description above for the PRIMARY mechanism.
#
# See docs/pipeline/remote-backend.md for the full backend contract.

set -uo pipefail

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
KIND="${1:-}"
ISSUE_NUM="${2:-}"

if [[ -z "$KIND" || -z "$ISSUE_NUM" ]]; then
  echo "ERROR: usage: liveness-check-remote-aws-ssm.sh <issue|review> <issue_num>" >&2
  exit 1
fi

if ! [[ "$KIND" =~ ^(issue|review)$ ]]; then
  echo "ERROR: kind must be 'issue' or 'review', got: '$KIND'" >&2
  exit 1
fi

if ! [[ "$ISSUE_NUM" =~ ^[0-9]+$ ]]; then
  echo "ERROR: issue_num must be a positive integer, got: '$ISSUE_NUM'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Required env validation (no aws calls until past these gates)
# ---------------------------------------------------------------------------
: "${SSM_INSTANCE_ID:?SSM_INSTANCE_ID required for remote-aws-ssm liveness check}"
: "${SSM_REMOTE_PROJECT_DIR:?SSM_REMOTE_PROJECT_DIR required (absolute path on remote box)}"
: "${SSM_REMOTE_PROJECT_ID:?SSM_REMOTE_PROJECT_ID required (project_id on remote box)}"

# ---------------------------------------------------------------------------
# Source shared helpers
# ---------------------------------------------------------------------------
# Use parameter expansion `${path%/*}` instead of `dirname` so PATH-scrubbed
# test invocations keep working (parity with dispatch-remote-aws-ssm.sh).
# [INV-65] This entry sources lib-ssm.sh from its OWN unresolved dir
# (${BASH_SOURCE[0]%/*}, readlink-free — TC-EB-008 runs it under a scrubbed
# PATH). It is reached via lib-dispatch.sh::_remote_pid_alive_query, which
# invokes `${BASH_SOURCE[0]%/*}/liveness-check-remote-aws-ssm.sh` — and
# lib-dispatch.sh is itself sourced from the skill tree (the dispatcher's
# LIB_DIR), so that path lands in the skill tree where lib-ssm.sh is a real
# adjacent file. The installer no longer symlinks lib-*.sh project-side, so a
# project-side invocation would NOT resolve lib-ssm.sh — but no caller does
# that. Same rationale as dispatch-remote-aws-ssm.sh.
_THIS_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="${_THIS_SCRIPT_PATH%/*}"
# shellcheck source=lib-ssm.sh
source "${SCRIPT_DIR}/lib-ssm.sh"

# ---------------------------------------------------------------------------
# Operator-controlled value validation (CWE-78)
# ---------------------------------------------------------------------------
# Project ID: alphanumeric + dashes only; reaches the remote shell
# inside the inner-cmd as $PROJECT_ID.
if ! [[ "$SSM_REMOTE_PROJECT_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: SSM_REMOTE_PROJECT_ID contains unsafe characters: '$SSM_REMOTE_PROJECT_ID'" >&2
  exit 1
fi

if [[ "$SSM_REMOTE_PROJECT_DIR" != /* ]] || _has_shell_metachar "$SSM_REMOTE_PROJECT_DIR"; then
  echo "ERROR: SSM_REMOTE_PROJECT_DIR must be an absolute path with no shell metachars: '$SSM_REMOTE_PROJECT_DIR'" >&2
  exit 1
fi

SSM_REGION="${SSM_REGION:-ap-southeast-1}"
SSM_REMOTE_USER="${SSM_REMOTE_USER:-ubuntu}"
SSM_REMOTE_SHELL="${SSM_REMOTE_SHELL:-bash}"
SSM_REMOTE_PROFILE="${SSM_REMOTE_PROFILE:-}"

if ! [[ "$SSM_REMOTE_USER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: SSM_REMOTE_USER contains unsafe characters: '$SSM_REMOTE_USER'" >&2
  exit 1
fi
if ! [[ "$SSM_REMOTE_SHELL" =~ ^(bash|zsh|sh)$ ]]; then
  echo "ERROR: SSM_REMOTE_SHELL must be bash, zsh, or sh; got: '$SSM_REMOTE_SHELL'" >&2
  exit 1
fi

if [[ -n "$SSM_REMOTE_PROFILE" ]]; then
  if [[ "$SSM_REMOTE_PROFILE" != /* ]] || _has_shell_metachar "$SSM_REMOTE_PROFILE"; then
    echo "ERROR: SSM_REMOTE_PROFILE must be an absolute path with no shell metachars: '$SSM_REMOTE_PROFILE'" >&2
    exit 1
  fi
fi

HBI="${HEARTBEAT_INTERVAL_SECONDS:-120}"
[[ "$HBI" =~ ^[0-9]+$ ]] || HBI=120

# [Lane-GC PR-6 / INV-119]
DEFER_MAX_AGE="${DEFER_MARKER_MAX_AGE_SECONDS:-900}"
[[ "$DEFER_MAX_AGE" =~ ^[0-9]+$ ]] || DEFER_MAX_AGE=900

# ---------------------------------------------------------------------------
# Build the remote snippet
# ---------------------------------------------------------------------------
# `set -u` forces an explicit failure on undefined-var typos so a partial
# probe failure produces `DEAD` only when ALL tiers genuinely missed.
# Each I/O call (cat, stat, pgrep, kill -0) keeps `2>/dev/null || true`
# so a transient OS error during one probe doesn't synthesize a false
# DEAD verdict.
#
# Verdict order (checked top to bottom, first match wins): DEFERRED
# (back-pressure gate refusal marker, [Lane-GC PR-6 / INV-119]) → kill -0 →
# process-group walk → PID-file mtime → heartbeat sibling mtime. PGID =
# setsid leader = PID file content (INV-23).
#
# LANE_DIR is DELIBERATELY a SEPARATE computation from PIDFILE/HBFILE's
# DIR below — it must match lib-lane.sh's own `ADT_STATE_ROOT` canonical-
# ization (`${ADT_STATE_ROOT:-$HOME/.local/state}`, NEVER `XDG_RUNTIME_DIR`
# — design §4-C1's explicit "XDG_STATE_HOME is deliberately ignored"
# rationale extends to XDG_RUNTIME_DIR too: the lane registry has always
# used one canonical anchor regardless of which shell/session wrote it),
# whereas PIDFILE/HBFILE below preserve their PRE-EXISTING
# `${XDG_RUNTIME_DIR:-$HOME/.local/state}` resolution (pid_dir_for_project's
# own duality, unchanged by this PR) — the two roots can legitimately
# diverge on a host where XDG_RUNTIME_DIR is set, and conflating them would
# make this probe look in the wrong place for one or the other.
profile_prefix=""
if [[ -n "$SSM_REMOTE_PROFILE" ]]; then
  profile_prefix="source ${SSM_REMOTE_PROFILE}; "
fi

INNER_CMD=$(cat <<EOF
${profile_prefix}set -u
PROJECT_ID="${SSM_REMOTE_PROJECT_ID}"
KIND="${KIND}"
N="${ISSUE_NUM}"
HBI="${HBI}"
DEFER_MAX_AGE="${DEFER_MAX_AGE}"
LANE_DIR="\${ADT_STATE_ROOT:-\$HOME/.local/state}/autonomous-\${PROJECT_ID}/lanes"
DEFER_MARKER="\${LANE_DIR}/.defer-\${KIND}-\${N}"
ATTEMPT_MARKER="\${LANE_DIR}/.attempt-\${KIND}-\${N}"
DIR="\${XDG_RUNTIME_DIR:-\$HOME/.local/state}/autonomous-\${PROJECT_ID}"
PIDFILE="\${DIR}/\${KIND}-\${N}.pid"
HBFILE="\${DIR}/\${KIND}-\${N}.heartbeat"

# [review P1-1] Freshness comparison: DEFER_MARKER authorized as DEFERRED
# ONLY when (a) it is NOT superseded by a later dispatch attempt - at or
# after the last dot-attempt-kind-N token dispatch-local.sh writes at
# the START of every attempt on this host (never strictly newer-than: the
# attempt marker is written FIRST, the defer marker moments later, both
# inside the SAME script run - at 1-second stat granularity the two
# routinely share an identical mtime, so a strict newer-than test would
# incorrectly treat THIS run's own defer as already-stale the instant it
# is written) - AND (b) it is still within DEFER_MARKER_MAX_AGE_SECONDS
# of "now" - this
# second bound is NOT merely a fallback for a missing attempt marker: it
# is what eventually un-sticks an issue that keeps re-deferring under
# sustained box pressure — since nothing re-dispatches an already-active
# issue automatically, condition (a) alone would hold indefinitely once
# the box has been under pressure even ONCE, and DEFERRED would never
# expire into the existing crash-declare -> pending-dev -> retry recovery
# cycle that (b) preserves. An inconclusive freshness comparison (attempt
# marker missing/unstattable — e.g. a pre-upgrade wrapper host) degrades
# condition (a) to vacuously true, leaving (b) as the sole gate — the
# exact pre-fix bare-age-window behavior, now scoped to the one case it
# was always meant to cover.
if [ -f "\$DEFER_MARKER" ] && [ ! -L "\$DEFER_MARKER" ]; then
  DEFER_M=\$(stat -c %Y "\$DEFER_MARKER" 2>/dev/null || stat -f %m "\$DEFER_MARKER" 2>/dev/null || echo "")
  ATTEMPT_M=""
  if [ -f "\$ATTEMPT_MARKER" ] && [ ! -L "\$ATTEMPT_MARKER" ]; then
    ATTEMPT_M=\$(stat -c %Y "\$ATTEMPT_MARKER" 2>/dev/null || stat -f %m "\$ATTEMPT_MARKER" 2>/dev/null || echo "")
  fi
  if [ -n "\$DEFER_M" ]; then
    DEFER_NOW=\$(date -u +%s)
    DEFER_AGE=\$((DEFER_NOW - DEFER_M))
    NOT_SUPERSEDED=1
    if [ -n "\$ATTEMPT_M" ] && [ "\$DEFER_M" -lt "\$ATTEMPT_M" ]; then
      NOT_SUPERSEDED=0
    fi
    if [ "\$NOT_SUPERSEDED" -eq 1 ] && [ "\$DEFER_AGE" -ge 0 ] && [ "\$DEFER_AGE" -lt "\$DEFER_MAX_AGE" ]; then
      echo DEFERRED
      echo "\$DEFER_AGE"
      exit 0
    fi
  fi
fi

PID=\$(cat "\$PIDFILE" 2>/dev/null || true)

if [ -n "\$PID" ] && kill -0 "\$PID" 2>/dev/null; then echo ALIVE; exit 0; fi

if [ -n "\$PID" ] && command -v pgrep >/dev/null 2>&1 && pgrep -g "\$PID" >/dev/null 2>&1; then
  echo ALIVE; exit 0
fi

NOW=\$(date -u +%s)
THR=\$((HBI * 3))
for f in "\$PIDFILE" "\$HBFILE"; do
  [ -f "\$f" ] && [ ! -L "\$f" ] || continue
  M=\$(stat -c %Y "\$f" 2>/dev/null || echo "")
  [ -n "\$M" ] && [ \$((NOW - M)) -lt "\$THR" ] && { echo ALIVE; exit 0; }
done
echo DEAD
EOF
)

# Wrap in sudo + login shell so the remote profile (when set) is loaded.
FULL_CMD="sudo -u ${SSM_REMOTE_USER} ${SSM_REMOTE_SHELL} -l -c '${INNER_CMD}'"

# ---------------------------------------------------------------------------
# Execute via shared helper, parse verdict
# ---------------------------------------------------------------------------
remote_stdout=$(_ssm_run_remote_command "$SSM_INSTANCE_ID" "$SSM_REGION" "$FULL_CMD")
helper_rc=$?

if [[ "$helper_rc" -ne 0 ]]; then
  exit 2
fi

# [Lane-GC PR-6 / INV-119] DEFERRED is checked FIRST and BEFORE the
# whitespace-stripping below: it is the one verdict that carries a SECOND
# line (the age), which `tr -d '[:space:]'` would collapse into an
# unparseable "DEFERRED45" glob. Line 1 must be the EXACT literal token
# (not merely `DEFERRED*`-prefixed — a coincidental remote stdout that
# happens to start with the word, e.g. future free-text, must not
# false-positive), line 2 must be a plain non-negative integer, and there
# must be EXACTLY two non-empty lines — nothing after (review P2-2:
# trailing garbage past the age line was previously silently ignored
# because only lines 1-2 were ever inspected; anchor it with the same
# rigor the pre-existing ALIVE/DEAD branch below already applies via its
# own exact-match `case`). Anything else falls through to the
# indeterminate branch below rather than fabricating a DEFERRED verdict
# with garbage/truncated data.
_verdict_nonempty_lines=$(printf '%s\n' "$remote_stdout" | sed '/^[[:space:]]*$/d')
_verdict_line1=$(printf '%s\n' "$_verdict_nonempty_lines" | sed -n '1p' | tr -d '[:space:]')
if [[ "$_verdict_line1" == "DEFERRED" ]]; then
  _verdict_age=$(printf '%s\n' "$_verdict_nonempty_lines" | sed -n '2p' | tr -d '[:space:]')
  _verdict_line_count=$(printf '%s\n' "$_verdict_nonempty_lines" | grep -c '.' || true)
  if [[ "$_verdict_age" =~ ^[0-9]+$ ]] && [[ "$_verdict_line_count" -eq 2 ]]; then
    printf 'DEFERRED\n%s\n' "$_verdict_age"
    exit 0
  fi
  echo "[liveness-check] WARN: remote returned DEFERRED with an unparseable age line or trailing content (line_count=${_verdict_line_count}): '${remote_stdout}'" >&2
  exit 2
fi

# Trim whitespace; accept exactly ALIVE or DEAD on its own line.
verdict=$(printf '%s' "$remote_stdout" | tr -d '[:space:]')
case "$verdict" in
  ALIVE) printf 'ALIVE\n'; exit 0 ;;
  DEAD)  printf 'DEAD\n';  exit 0 ;;
  *)
    # Anything else — including empty stdout — is indeterminate. Per
    # INV-30, the caller will bias this toward ALIVE. The driver itself
    # MUST NOT print DEAD on any uncertainty path.
    echo "[liveness-check] WARN: remote returned unexpected stdout: '${remote_stdout}'" >&2
    exit 2
    ;;
esac
