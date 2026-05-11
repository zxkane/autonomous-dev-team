#!/bin/bash
# dispatcher-tick.sh — single entry point for one autonomous-dispatcher tick.
#
# Replaces the 224 lines of bash that used to live in
# `skills/autonomous-dispatcher/SKILL.md` with a single script the dispatcher
# agent calls once per cron cycle. Pure refactor (PR-3) — behavior identical
# to the prior SKILL.md tick.
#
# Usage: bash dispatcher-tick.sh
#   Reads autonomous.conf via lib-dispatch.sh (sourced).
#   Maintains JUST_DISPATCHED tick-local across Steps 2/3/4 → Step 5.
#
# See docs/pipeline/dispatcher-flow.md for the spec.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Self-heal exec bits on the directly-invoked sibling scripts (closes #97).
# Some installs strip +x — git mode 100644 propagated through the skills CLI
# in earlier versions, and consumer-side tooling under restrictive umasks
# can also drop it. If +x is missing, dispatch-local.sh's
# `nohup .../autonomous-{dev,review}.sh` fails with `Permission denied`
# before the agent even starts, the dispatcher misclassifies it as a crash,
# and after MAX_RETRIES the issue stalls.
#
# Scoped narrowly to the two scripts dispatch-local.sh actually invokes —
# sourced-only siblings (lib-*.sh) are deliberately left alone. Best-effort
# (`|| true`) so a chmod failure on a read-only mount never aborts a tick.
for _need_exec in autonomous-dev.sh autonomous-review.sh; do
  if [[ -f "$SCRIPT_DIR/$_need_exec" && ! -x "$SCRIPT_DIR/$_need_exec" ]]; then
    chmod +x "$SCRIPT_DIR/$_need_exec" 2>/dev/null || true
  fi
done
unset _need_exec

# Load config via the shared helper (closes #58 for the dispatcher path).
# Must run before sourcing lib-dispatch.sh — lib-dispatch.sh enforces
# REPO/REPO_OWNER/PROJECT_ID via `: "${VAR:?...}"`.
# shellcheck source=lib-config.sh
source "${SCRIPT_DIR}/lib-config.sh"
load_autonomous_conf "${SCRIPT_DIR}" || true

# shellcheck source=lib-dispatch.sh
source "${SCRIPT_DIR}/lib-dispatch.sh"

: "${PROJECT_DIR:?PROJECT_DIR must be set in autonomous.conf}"

log() { echo "[dispatcher-tick] $(date -u +%H:%M:%S) $*"; }

# Validate EXECUTION_BACKEND ONCE upfront, before any label transitions.
# H1 (PR-9 review): if dispatch() returned 1 from inside a step body, the
# step had already swapped the issue's label to in-progress and posted a
# comment — leaving a stuck issue + burning retries every tick. Catching
# the typo here aborts the tick before any side effect.
case "${EXECUTION_BACKEND:-local}" in
  local|remote-aws-ssm) ;;
  *)
    echo "[dispatcher-tick] FATAL: unknown EXECUTION_BACKEND='${EXECUTION_BACKEND}'. Allowed: local, remote-aws-ssm." >&2
    exit 1
    ;;
esac

# Validate REVIEW_BOTS upfront for the same reason: a typo (e.g.
# REVIEW_BOTS="q codx") would let the tick swap labels to `reviewing` and
# spawn the review wrapper, which then exits 1 at startup — burning a
# retry slot every tick until the issue hits MAX_RETRIES. Catching the
# typo here aborts the entire tick before any side-effect, with no retry
# counted. Empty REVIEW_BOTS is allowed (bot enforcement disabled).
# shellcheck source=lib-review-bots.sh
source "${SCRIPT_DIR}/lib-review-bots.sh"
if ! parse_review_bots "${REVIEW_BOTS:-}" >/dev/null; then
  echo "[dispatcher-tick] FATAL: REVIEW_BOTS validation failed (see error above). Fix autonomous.conf before the next tick." >&2
  exit 1
fi

# Generate a GitHub App installation token for the dispatcher when
# GH_AUTH_MODE=app (closes #91). Pre-fix, the dispatcher's `gh` calls fell
# back to the user's `gh auth login` token, so issue comments + label
# changes appeared as the user instead of the bot identity.
#
# A single token covers the whole tick (valid 1h, scope: this repo only).
# We don't run gh-token-refresh-daemon here — that's for long-lived agent
# wrappers; the tick completes in <1 min.
#
# Fail-fast on misconfig (missing id/pem, token API failure, empty result):
# silently falling back to user auth is precisely the bug being closed.
if [[ "${GH_AUTH_MODE:-token}" == "app" ]]; then
  if [[ -z "${DISPATCHER_APP_ID:-}" || -z "${DISPATCHER_APP_PEM:-}" ]]; then
    echo "[dispatcher-tick] FATAL: GH_AUTH_MODE=app requires DISPATCHER_APP_ID and DISPATCHER_APP_PEM (one or both are empty)." >&2
    exit 1
  fi
  # Auto-derive REPO_NAME from REPO when an older path-entry autonomous.conf
  # forgot to set it. Inline projects already do this in tick_inline_project;
  # mirror it here so set -u doesn't trip on `"$REPO_NAME"` below.
  : "${REPO_NAME:=${REPO##*/}}"
  # shellcheck source=gh-app-token.sh
  source "${SCRIPT_DIR}/gh-app-token.sh"
  _dispatcher_token=$(get_gh_app_token \
    "$DISPATCHER_APP_ID" "$DISPATCHER_APP_PEM" \
    "$REPO_OWNER" "$REPO_NAME") || {
    echo "[dispatcher-tick] FATAL: failed to generate GitHub App token for ${REPO_OWNER}/${REPO_NAME}." >&2
    exit 1
  }
  if [[ -z "$_dispatcher_token" ]]; then
    echo "[dispatcher-tick] FATAL: gh-app-token returned an empty token for ${REPO_OWNER}/${REPO_NAME}." >&2
    exit 1
  fi
  export GH_TOKEN="$_dispatcher_token"
  unset _dispatcher_token
fi

# dispatch — route a wrapper-spawn request to the configured backend (#62 axis 2).
# Backends today: "local" (default — same-box dispatch-local.sh) and
# "remote-aws-ssm" (sends an `aws ssm send-command` to a remote dev box).
# Other backends (k8s, gha-runner) can be added with one case arm here.
# The unknown-backend case is unreachable because we validate above; the
# `*)` arm is a defensive assertion in case allowed-list values get out of
# sync between the upfront check and the runtime dispatch.
#
# Args: <type> <issue_num> [session_id]   — passed through verbatim.
dispatch() {
  case "${EXECUTION_BACKEND:-local}" in
    local)
      bash "$PROJECT_DIR/scripts/dispatch-local.sh" "$@"
      ;;
    remote-aws-ssm)
      bash "$SCRIPT_DIR/dispatch-remote-aws-ssm.sh" "$@"
      ;;
    *)
      # Should never reach here because of the upfront check, but be loud
      # if invariants drift.
      echo "[dispatcher-tick] BUG: dispatch() reached unknown EXECUTION_BACKEND='${EXECUTION_BACKEND}' at runtime" >&2
      exit 1
      ;;
  esac
}

# Tick-local state. JUST_DISPATCHED holds issue numbers dispatched in
# Steps 2/3/4 of this tick, so Step 5 can skip them ([INV-09]).
JUST_DISPATCHED=()

# ---------------------------------------------------------------------------
# Step 1: Concurrency gate
# ---------------------------------------------------------------------------
ACTIVE=$(count_active)
if [ "$ACTIVE" -ge "$MAX_CONCURRENT" ]; then
  log "Concurrency limit reached ($ACTIVE/$MAX_CONCURRENT). Aborting tick."
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 2: scan-new
# ---------------------------------------------------------------------------
log "Step 2: scanning for new autonomous issues..."
new_issues=$(list_new_issues)
new_count=$(jq 'length' <<<"$new_issues")
log "  found $new_count new issue(s)"

for i in $(seq 0 $((new_count - 1))); do
  ACTIVE=$(count_active)
  if [ "$ACTIVE" -ge "$MAX_CONCURRENT" ]; then
    log "  concurrency reached during scan-new ($ACTIVE/$MAX_CONCURRENT) — stopping"
    break
  fi

  issue_num=$(jq -r ".[$i].number" <<<"$new_issues")

  if ! check_deps_resolved "$issue_num"; then
    log "  issue #${issue_num} has unresolved dependencies — skipping silently"
    continue
  fi

  log "  dispatching dev-new for issue #${issue_num}"
  label_swap "$issue_num" "" "in-progress"
  gh issue comment "$issue_num" --repo "$REPO" \
    --body "Dispatching autonomous development..."
  dispatch dev-new "$issue_num"
  JUST_DISPATCHED+=("$issue_num")
done

# ---------------------------------------------------------------------------
# Step 3: scan-pending-review
# ---------------------------------------------------------------------------
log "Step 3: scanning for issues pending review..."
pending_review=$(list_pending_review)
pr_count=$(jq 'length' <<<"$pending_review")
log "  found $pr_count pending-review issue(s)"

for i in $(seq 0 $((pr_count - 1))); do
  ACTIVE=$(count_active)
  if [ "$ACTIVE" -ge "$MAX_CONCURRENT" ]; then
    log "  concurrency reached during scan-pending-review ($ACTIVE/$MAX_CONCURRENT) — stopping"
    break
  fi

  issue_num=$(jq -r ".[$i].number" <<<"$pending_review")

  log "  dispatching review for issue #${issue_num}"
  label_swap "$issue_num" "pending-review" "reviewing"
  gh issue comment "$issue_num" --repo "$REPO" \
    --body "Dispatching autonomous review..."
  dispatch review "$issue_num"
  JUST_DISPATCHED+=("$issue_num")
done

# ---------------------------------------------------------------------------
# Step 4: scan-pending-dev (resume)
# ---------------------------------------------------------------------------
log "Step 4: scanning for issues pending dev resume..."
pending_dev=$(list_pending_dev)
pd_count=$(jq 'length' <<<"$pending_dev")
log "  found $pd_count pending-dev issue(s)"

for i in $(seq 0 $((pd_count - 1))); do
  ACTIVE=$(count_active)
  if [ "$ACTIVE" -ge "$MAX_CONCURRENT" ]; then
    log "  concurrency reached during scan-pending-dev ($ACTIVE/$MAX_CONCURRENT) — stopping"
    break
  fi

  issue_num=$(jq -r ".[$i].number" <<<"$pending_dev")

  retry_count=$(count_retries "$issue_num")
  if [ "$retry_count" -ge "$MAX_RETRIES" ]; then
    log "  issue #${issue_num} retry exhausted ($retry_count/$MAX_RETRIES) — marking stalled"
    mark_stalled "$issue_num"
    continue
  fi

  session_id=$(extract_dev_session_id "$issue_num")

  # [INV-12] Skip resume if the prior session ended normally (closes #59).
  # Resuming a completed claude session attaches to the SSE stream forever.
  # Don't auto-recover: leave the issue in pending-dev so an operator decides
  # whether to flip to pending-review (PR present) or close (work done).
  #
  # Idempotency: only post the operator notice the FIRST time the gate fires
  # for a given session-id. Without this, every 5-min tick posts the same
  # comment (~288/day) since the issue stays in pending-dev.
  if [ -n "$session_id" ] && is_session_completed "$issue_num"; then
    log "  issue #${issue_num} session ${session_id} already completed — skipping resume"
    notice_marker="INV-12-completed:${session_id}"
    if gh issue view "$issue_num" --repo "$REPO" --json comments \
        -q "[.comments[].body | select(contains(\"${notice_marker}\"))] | length" \
        2>/dev/null | grep -q '^0$'; then
      gh issue comment "$issue_num" --repo "$REPO" \
        --body "Session \`${session_id}\` already ended (stop_reason=end_turn, terminal_reason=completed). Resume would hang on idle SSE — skipping. Manually transition to \`pending-review\` if a PR exists, or close the issue if work is done. (\`${notice_marker}\`)"
    fi
    JUST_DISPATCHED+=("$issue_num")
    continue
  fi

  log "  dispatching dev-resume for issue #${issue_num} (session: ${session_id:-<none>})"
  label_swap "$issue_num" "pending-dev" "in-progress"
  gh issue comment "$issue_num" --repo "$REPO" \
    --body "Resuming development (session: ${session_id})..."
  dispatch dev-resume "$issue_num" "$session_id"
  JUST_DISPATCHED+=("$issue_num")
done

# ---------------------------------------------------------------------------
# Step 5: stale detection
# ---------------------------------------------------------------------------
log "Step 5: stale detection..."

# Export JUST_DISPATCHED so was_just_dispatched() in lib-dispatch.sh can read.
JUST_DISPATCHED_STR="${JUST_DISPATCHED[*]:-}"
export JUST_DISPATCHED="$JUST_DISPATCHED_STR"

candidates=$(list_stale_candidates)
cand_count=$(jq 'length' <<<"$candidates")
log "  $cand_count active issue(s) to evaluate"

for i in $(seq 0 $((cand_count - 1))); do
  issue_num=$(jq -r ".[$i].number" <<<"$candidates")
  labels=$(jq -r ".[$i].labels[].name" <<<"$candidates")

  # Skip freshly dispatched ([INV-09]).
  if was_just_dispatched "$issue_num"; then
    log "  issue #${issue_num} just dispatched this tick — skipping"
    continue
  fi

  # Determine which active label and corresponding PID file kind.
  if grep -q "^in-progress$" <<<"$labels"; then
    kind="issue"
  elif grep -q "^reviewing$" <<<"$labels"; then
    kind="review"
  else
    # Should not happen given list_stale_candidates filter, but defensive.
    continue
  fi

  if pid_alive "$kind" "$issue_num"; then
    # ALIVE branch — only Step 5a applies (and only for in-progress; review
    # wrappers are bounded by their own polling, no SIGTERM logic).
    if [ "$kind" != "issue" ]; then
      continue
    fi

    pid=$(get_pid "$kind" "$issue_num")

    # Step 5a: ALIVE + PR ready for review.
    pr_info=$(fetch_pr_for_issue "$issue_num" "number,body,updatedAt")
    if [ -z "$pr_info" ]; then
      # No PR — agent still developing, leave alone.
      continue
    fi

    pr_num=$(jq -r '.number // empty' <<<"$pr_info")
    pr_updated_at=$(jq -r '.updatedAt // empty' <<<"$pr_info")

    # Validate jq outputs (schema drift / partial JSON guard).
    if ! [[ "$pr_num" =~ ^[0-9]+$ ]] || [ -z "$pr_updated_at" ]; then
      echo "WARN: malformed PR info for issue ${issue_num} (PR_NUM='$pr_num', PR_UPDATED_AT='$pr_updated_at'); leaving as-is" >&2
      continue
    fi

    if ! ci_is_green "$pr_num"; then
      # CI not green — agent still working.
      continue
    fi

    idle_seconds=$(pr_idle_seconds "$pr_updated_at")
    if [ -z "$idle_seconds" ]; then
      echo "WARN: cannot parse PR.updatedAt='${pr_updated_at}' for issue ${issue_num}; leaving as-is" >&2
      continue
    fi

    # [INV-10] strict > 300s.
    if [ "$idle_seconds" -le 300 ]; then
      # Recent activity — agent may be cleaning up. Leave alone.
      continue
    fi

    # Re-verify PID is still alive (could have exited between the original
    # probe and now; if reassigned we'd SIGTERM an unrelated process).
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "INFO: wrapper PID ${pid} for issue ${issue_num} exited between checks; deferring to next cycle" >&2
      continue
    fi

    # Fire SIGTERM and transition to pending-review.
    if kill "$pid" 2>/dev/null; then
      kill_note="Sent SIGTERM to PID ${pid}"
    else
      kill_note="PID ${pid} already gone"
    fi
    gh issue comment "$issue_num" --repo "$REPO" \
      --body "Dev process still alive but PR #${pr_num} is ready (all CI checks passed, idle ${idle_seconds}s). ${kill_note}. Moving to pending-review."
    label_swap "$issue_num" "in-progress" "pending-review"

  else
    # DEAD branch — Step 5b.
    if [ "$kind" = "issue" ]; then
      # DEAD + in-progress: branch on whether a PR exists, and if it does,
      # branch again on whether its HEAD has new commits since the last
      # review trailer ([INV-04], [INV-07]).
      pr_info=$(fetch_pr_for_issue "$issue_num" "number,body,headRefOid")

      if [ -z "$pr_info" ]; then
        # No PR — dev didn't finish, retry.
        gh issue comment "$issue_num" --repo "$REPO" \
          --body "Task appears to have crashed (no PR found). Moving to pending-dev for retry."
        label_swap "$issue_num" "in-progress" "pending-dev"
        continue
      fi

      current_head=$(jq -r '.headRefOid // empty' <<<"$pr_info")
      last_head=$(last_reviewed_head "$issue_num")

      if [ -n "$last_head" ] && [ -n "$current_head" ] && [ "$current_head" = "$last_head" ]; then
        # No new commits since last review — retry dev so it can act on
        # existing review feedback. ([INV-06] keyword guard: avoid
        # "crashed" / "process not found" so Step 4a doesn't count this.)
        gh issue comment "$issue_num" --repo "$REPO" \
          --body "Dev process exited (no new commits since last review at \`${last_head}\`). Moving to pending-dev for retry."
        label_swap "$issue_num" "in-progress" "pending-dev"
      else
        # PR has new commits OR no prior trailer — let review assess
        # ([INV-07] empty-trailer fallthrough).
        gh issue comment "$issue_num" --repo "$REPO" \
          --body "Dev process exited (PR found). Moving to pending-review for assessment."
        label_swap "$issue_num" "in-progress" "pending-review"
      fi
    else
      # DEAD + reviewing: review wrapper crashed without its own trap firing.
      gh issue comment "$issue_num" --repo "$REPO" \
        --body "Review process appears to have crashed. Moving to pending-dev for retry."
      label_swap "$issue_num" "reviewing" "pending-dev"
    fi
  fi
done

log "Tick complete. Dispatched: ${JUST_DISPATCHED[*]:-<none>}"
