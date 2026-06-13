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

# [INV-65] Two-dir resolution. SCRIPT_DIR (the conf dir) is the dirname of the
# UNRESOLVED ${BASH_SOURCE[0]:-$0} so a project-side symlink keeps it pointed at
# the project's scripts/ where autonomous.conf lives [INV-14]; it also resolves
# the project-side STABLE ENTRY scripts dispatch() invokes (dispatch-local.sh,
# dispatch-remote-aws-ssm.sh). LIB_DIR is the REAL path (readlink -f) used for
# sourcing sibling lib-*.sh (lib-config / lib-dispatch / lib-review-bots) and
# gh-app-token.sh from the skill tree — no per-project lib symlink needed (#227).
_SELF="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
LIB_DIR="$(cd "$(dirname "$(readlink -f "$_SELF")")" && pwd)"

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
source "${LIB_DIR}/lib-config.sh"
# conf lookup stays on the UNRESOLVED SCRIPT_DIR (project's scripts/) — INV-14.
load_autonomous_conf "${SCRIPT_DIR}" || true

# shellcheck source=lib-dispatch.sh
source "${LIB_DIR}/lib-dispatch.sh"

# [INV-70] Observe-only metrics emitter. Guarded so a load failure never aborts
# the tick. Provides metrics_emit.
# shellcheck source=lib-metrics.sh
source "${LIB_DIR}/lib-metrics.sh" 2>/dev/null || true

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
source "${LIB_DIR}/lib-review-bots.sh"
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
  source "${LIB_DIR}/gh-app-token.sh"
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
      # [INV-65] Invoke the remote driver via LIB_DIR (the real skill tree),
      # NOT the project-side SCRIPT_DIR. dispatch-remote-aws-ssm.sh sources its
      # sibling lib-ssm.sh from its OWN unresolved dir (${BASH_SOURCE[0]%/*},
      # readlink-free for TC-EB-008's scrubbed PATH); invoking it project-side
      # would set that dir to <project>/scripts/, where the installer no longer
      # symlinks lib-ssm.sh — reintroducing the missing-lib crash. Running it
      # from LIB_DIR keeps its BASH_SOURCE in the skill tree, where lib-ssm.sh
      # is a real adjacent file. (dispatch-local.sh stays project-side: it
      # sources its own libs from its own LIB_DIR, so the path is moot there.)
      bash "$LIB_DIR/dispatch-remote-aws-ssm.sh" "$@"
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
# Step 0: label hygiene pass ([INV-25], issue #115 Bug B)
# ---------------------------------------------------------------------------
# Heal "approved + transitional" and "stalled + transitional" residues
# before any selector reads labels. Without this, an issue in a sticky
# terminal state but still carrying e.g. `pending-review` would be
# re-picked by a future selector that forgets to subtract the terminal
# (Bug A was one such selector — fixed in PR #116; Bug B closes the
# class). Step 0 runs UNCONDITIONALLY: even when concurrency is
# saturated we still want stale residue cleared so Step 5 doesn't
# misclassify on the next tick. Pure label edits — no agent dispatch,
# no retry counting.
log "Step 0: scanning for terminal-label residue..."
run_hygiene_pass

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
  # [INV-70] Metrics: the issue is first picked up for autonomous work — the
  # TTHW "labeled" endpoint. Emitted only on the first (dev-new) dispatch, not
  # on resumes/re-dispatches, so the aggregator's earliest-per-issue reduction
  # is anchored here. Best-effort, observe-only.
  #
  # The event `ts` is THIS dispatch instant, which can lag the real `autonomous`
  # label time by ticks (concurrency cap, unresolved deps). For accurate TTHW we
  # also fetch the actual `autonomous`-label timeline timestamp and emit it as
  # `labeled_at`; the aggregator prefers it over `ts`, so labeled→PR/merge counts
  # the queue wait (#228 review finding 4). The timeline call is best-effort: on
  # any failure `labeled_at` is omitted and the aggregator falls back to `ts`.
  if declare -F metrics_emit >/dev/null 2>&1; then
    _labeled_at="$(gh api "repos/${REPO}/issues/${issue_num}/timeline" \
      --jq 'map(select(.event == "labeled" and .label.name == "autonomous")) | (.[0].created_at // empty)' \
      2>/dev/null || true)"
    if [[ -n "${_labeled_at:-}" ]]; then
      metrics_emit issue_labeled "issue=${issue_num}" "labeled_at=${_labeled_at}" || true
    else
      metrics_emit issue_labeled "issue=${issue_num}" || true
    fi
    unset _labeled_at
  fi
  # Bug 1+2 (#99): write a dispatcher-controlled marker that records the
  # dispatch timestamp ([INV-17]). Step 5 uses this to honor a cold-start
  # grace window before classifying the wrapper as crashed.
  post_dispatch_token "$issue_num" "dev-new"
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
  post_dispatch_token "$issue_num" "review"
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
    # [INV-70] Metrics: retry exhausted → stalled. Best-effort, observe-only.
    if declare -F metrics_emit >/dev/null 2>&1; then
      metrics_emit dispatch_retry "issue=${issue_num}" "retry_count=${retry_count}" stalled=true || true
    fi
    mark_stalled "$issue_num"
    continue
  fi

  # [INV-70] Metrics: a below-limit retry increment. Emitted ONCE here, after the
  # exhaustion gate and before ANY of the downstream pending-dev re-dispatch
  # branches (PR-exists handoff, PTL fresh dev-new, completed-session routing,
  # normal dev-resume), so every retry attempt — not just the final stall — lands
  # in the event trail with `stalled=false` (#228 review: retry history was only
  # recorded at exhaustion). The `stalled=true` event above stays for the
  # exhaustion case. Best-effort, observe-only.
  if declare -F metrics_emit >/dev/null 2>&1; then
    metrics_emit dispatch_retry "issue=${issue_num}" "retry_count=${retry_count}" stalled=false || true
  fi

  # Bug 3 (#99): if a PR already exists for this issue, the agent already
  # finished development — any subsequent crash (e.g. cleanup-time exit
  # non-zero after gh pr create) routed us to pending-dev, but re-developing
  # would just re-do work. Hand off to review instead.
  #
  # #106: when the PR's HEAD already matches the most recent
  # `Reviewed HEAD:` trailer, the prior verdict was FAILED and the dev
  # agent hasn't pushed new commits yet. Re-routing to pending-review
  # would loop the same review against the same code every tick. The
  # helper keeps such issues in pending-dev with an idempotent
  # stale-verdict notice; only NEW commits or first-review issues flip.
  if handle_pending_dev_pr_exists "$issue_num"; then
    JUST_DISPATCHED+=("$issue_num")
    continue
  fi

  session_id=$(extract_dev_session_id "$issue_num")

  # [INV-12] Skip resume if the prior session reached a terminal state
  # that resume cannot recover from. Two cases:
  #   end_turn|completed → operator handoff (closes #59).
  #   *|prompt_too_long  → auto-recover via fresh session (no auto-compact
  #                        in claude -p; the only fix is a new session_id).
  # See lib-dispatch.sh:is_session_completed for the full rationale.
  #
  # Idempotency: post the operator notice at most once per session-id.
  # Without this, every 5-min tick posts the same comment (~288/day) for
  # the COMPLETED case (pending-dev → pending-dev). For the PTL case we
  # flip the label so the comment fires at most once anyway.
  _session_terminal_reason=""
  _session_end_iso=""
  if [ -n "$session_id" ] && is_session_completed "$issue_num" _session_terminal_reason _session_end_iso; then
    if [ "$_session_terminal_reason" = "prompt_too_long" ]; then
      log "  issue #${issue_num} session ${session_id} hit prompt_too_long — clearing for fresh dispatch"
      notice_marker="INV-12-prompt-too-long:${session_id}"
      if gh issue view "$issue_num" --repo "$REPO" --json comments \
          -q "[.comments[].body | select(contains(\"${notice_marker}\"))] | length" \
          2>/dev/null | grep -q '^0$'; then
        gh issue comment "$issue_num" --repo "$REPO" \
          --body "Session \`${session_id}\` exhausted the model context window (terminal_reason=prompt_too_long). \`claude -p\` does not auto-compact, so resume would crash again. Forcing a fresh dev session on the next tick. (\`${notice_marker}\`)"
      fi
      # Truncate the log so the next tick sees an empty/missing log and
      # doesn't re-trigger this is_session_completed branch. The dev-new
      # dispatch below mints a new session_id and writes fresh result lines.
      #
      # If truncation fails (perm drift across deploys, ENOSPC), DO NOT
      # dispatch — otherwise the next tick would re-read the same stale
      # PTL log, the idempotency marker would suppress a fresh notice
      # (it's keyed on the old session_id), and we'd silently dispatch
      # dev-new every tick forever. Stay in pending-dev so the operator
      # sees the issue accumulating retries via mark_stalled instead.
      _ptl_log="/tmp/agent-${PROJECT_ID}-issue-${issue_num}.log"
      if ! : > "$_ptl_log" 2>/dev/null; then
        log "  ERROR: failed to truncate ${_ptl_log} (perm/disk?). Skipping PTL dev-new dispatch to avoid re-detection loop."
        gh issue comment "$issue_num" --repo "$REPO" \
          --body "Could not reset prompt-too-long log at \`${_ptl_log}\` for fresh dispatch (permission or disk error). Operator: please clear the log file and retry. Skipping dispatch to prevent a silent retry loop." 2>/dev/null || true
        continue
      fi
      log "  dispatching dev-new for issue #${issue_num} (fresh after prompt_too_long)"
      label_swap "$issue_num" "pending-dev" "in-progress"
      post_dispatch_token "$issue_num" "dev-new"
      dispatch dev-new "$issue_num"
      JUST_DISPATCHED+=("$issue_num")
      continue
    fi

    # end_turn|completed — INV-35 review-aware routing (carve-out from
    # INV-12). The handler classifies the most recent post-completion
    # review verdict and either:
    #   - emits the original INV-12-completed operator-handoff marker, OR
    #   - flips back to pending-review (non-substantive review failure), OR
    #   - mints a fresh dev-new session via PTL pattern (substantive failure).
    # See docs/pipeline/dispatcher-flow.md § Step 4b.5.1 and INV-35.
    handle_completed_session_routing "$issue_num" "$session_id" "$_session_end_iso"
    JUST_DISPATCHED+=("$issue_num")
    continue
  fi

  log "  dispatching dev-resume for issue #${issue_num} (session: ${session_id:-<none>})"
  label_swap "$issue_num" "pending-dev" "in-progress"
  post_dispatch_token "$issue_num" "dev-resume"
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

  # Bug 1 (#99) [INV-17]: skip stale detection during the cold-start grace
  # window. JUST_DISPATCHED only protects the current tick; a wrapper that
  # hasn't yet written its PID file (session spawn + model first call can
  # take 1–3 min) must not be classified as crashed on the very next tick.
  # Defaults to 10 min via DISPATCH_GRACE_PERIOD_SECONDS=600.
  if is_within_grace_period "$issue_num"; then
    log "  issue #${issue_num} within dispatch grace period — skipping (#99 Bug 1)"
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
        # No PR. Before declaring crashed, cross-check in-flight signals
        # — the dev-side analog of #111's review_near_success (INV-24).
        # dev_near_success returns 0 when ANY of these is true within
        # DEV_NEAR_SUCCESS_WINDOW_SECONDS:
        #   - most recent "Agent Session Report (Dev) ... Exit code: 0"
        #     within window (agent finished cleanly; PR not yet linked)
        #   - most recent "Dev Session ID:" comment within window
        #     (startup confirmed; pid_alive miss is a probe race)
        #   - defensive `kill -0 <pid>` re-check now succeeds
        # When any signal fires, leave `in-progress` alone and defer
        # — the next tick will re-evaluate after either the wrapper
        # exits naturally or the signals all expire ([INV-27]).
        if dev_near_success "$issue_num"; then
          echo "INFO: issue ${issue_num} dev wrapper pid_alive miss but in-flight signal positive; deferring crash declaration ([INV-27])" >&2
          continue
        fi
        # [INV-70] Metrics: dispatcher declared a dev wrapper DEAD with no PR.
        # Class false-stall (the near-success cross-check above already cleared,
        # so this is a real crash declaration, not a probe race). Best-effort.
        if declare -F metrics_emit >/dev/null 2>&1; then
          metrics_emit dispatch_stale "issue=${issue_num}" kind=in-progress failure_class=false-stall || true
        fi
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
      # DEAD + reviewing: review wrapper appears to have crashed.
      #
      # #111 Part A: cross-check PR-state signals before declaring
      # crashed. Long-running review wrappers (15-30 min E2E + multi-bot
      # rounds) routinely hit transient pid_alive races, and the
      # near-success window covers the wrapper's post-verdict / merge
      # tail. review_near_success returns 0 when ANY of these are true
      # within REVIEW_NEAR_SUCCESS_WINDOW_SECONDS:
      #   - PR.mergedAt within window
      #   - most recent APPROVED review within window
      #   - "Review PASSED|findings" comment within window
      #   - defensive `kill -0 <pid>` re-check now succeeds (race)
      # When any signal fires, leave `reviewing` alone and defer to next
      # tick — the wrapper either already finished or is mid-merge.
      if review_near_success "$issue_num"; then
        echo "INFO: issue ${issue_num} review wrapper pid_alive miss but PR-state signal positive; deferring crash declaration (#111 INV-24)" >&2
        continue
      fi
      # [INV-70] Metrics: dispatcher declared a review wrapper DEAD. Class
      # false-stall (the review_near_success cross-check above already cleared).
      if declare -F metrics_emit >/dev/null 2>&1; then
        metrics_emit dispatch_stale "issue=${issue_num}" kind=reviewing failure_class=false-stall || true
      fi
      gh issue comment "$issue_num" --repo "$REPO" \
        --body "Review process appears to have crashed. Moving to pending-dev for retry."
      label_swap "$issue_num" "reviewing" "pending-dev"
    fi
  fi
done

# [INV-70] Retention built into the collector: prune the metrics log once per
# tick (default 90d). The dispatcher runs on a cron cadence, so this is the
# steady drumbeat that bounds the log even for a project whose wrappers rarely
# run. Best-effort — metrics_prune always returns 0, so a prune failure can
# never affect the tick. (#228 review: prune was opt-in via the report only.)
if declare -F metrics_prune >/dev/null 2>&1; then
  metrics_prune "${METRICS_RETENTION_DAYS:-90}" 2>/dev/null || true
fi

log "Tick complete. Dispatched: ${JUST_DISPATCHED[*]:-<none>}"
