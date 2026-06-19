#!/bin/bash
# status.sh — one-command operator view of an issue's pipeline state. Issue #235
# / [INV-81]. READ-ONLY: issues NO label edits, NO comments, NO merges.
#
# Usage:
#   scripts/status.sh <issue> [--project <id>]
#
# Answers, for a single issue, "why is it stuck and what will the next dispatcher
# tick do?" by sourcing the dispatcher's REAL predicate functions (lib-dispatch.sh)
# — NOT a reimplementation. Predicate parity is the whole point: a divergent
# answer here would be a NEW false-signal source, worse than no tool (issue #235
# Design Considerations). So the four "next tick" verdicts below are derived from
# the SAME pid_alive / dev_near_success / review_near_success / count_retries /
# fetch_pr_for_issue functions the tick calls.
#
# Surfaces: labels, open PR + reviewDecision, lease/PID liveness, retry count,
# last 3 run-ids (#235 run dirs) with outcomes, last drop reasons, and the
# derived next-dispatcher-action.

set -euo pipefail

# [INV-65] Two-dir resolution (mirrors dispatcher-tick.sh): SCRIPT_DIR is the
# UNRESOLVED dirname so a project-side symlink keeps it on the project's scripts/
# where autonomous.conf lives [INV-14]; LIB_DIR is the REAL path so sibling libs
# source from the skill tree regardless of per-project symlink coverage (#227).
_SELF="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
LIB_DIR="$(cd "$(dirname "$(readlink -f "$_SELF")")" && pwd)"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
ISSUE_NUMBER=""
PROJECT_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      [[ $# -ge 2 ]] || { echo "Error: --project requires argument" >&2; exit 2; }
      PROJECT_OVERRIDE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 <issue> [--project <id>]" >&2; exit 0 ;;
    -*)
      echo "Unknown option: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$ISSUE_NUMBER" ]]; then ISSUE_NUMBER="$1"; shift
      else echo "Error: unexpected argument '$1'" >&2; exit 2; fi ;;
  esac
done

if [[ -z "$ISSUE_NUMBER" ]] || ! [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Usage: $0 <issue> [--project <id>]   (issue must be a positive integer)" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Load config + the REAL predicate libs (same order dispatcher-tick.sh uses).
# ---------------------------------------------------------------------------
# shellcheck source=lib-config.sh
source "${LIB_DIR}/lib-config.sh"
load_autonomous_conf "${SCRIPT_DIR}" || true

# --project overrides PROJECT_ID AFTER the conf load (conf sets PROJECT_ID).
[[ -n "$PROJECT_OVERRIDE" ]] && PROJECT_ID="$PROJECT_OVERRIDE"

# lib-dispatch.sh has top-level `: "${REPO:?}"` / `${REPO_OWNER:?}` /
# `${PROJECT_ID:?}` guards. Preflight so a missing key is a clean error, not a
# raw bash abort.
for _req in REPO REPO_OWNER PROJECT_ID; do
  if [[ -z "${!_req:-}" ]]; then
    echo "Error: ${_req} is unset — run from a project dir with scripts/autonomous.conf, or pass --project <id>." >&2
    exit 2
  fi
done

# shellcheck source=lib-run-artifacts.sh
source "${LIB_DIR}/lib-run-artifacts.sh" 2>/dev/null || true
# shellcheck source=lib-dispatch.sh
source "${LIB_DIR}/lib-dispatch.sh"

MAX_RETRIES="${MAX_RETRIES:-3}"

# ---------------------------------------------------------------------------
# Gather state (read-only gh + lib predicates)
# ---------------------------------------------------------------------------
ISSUE_JSON="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json state,labels,title 2>/dev/null || echo '{}')"
ISSUE_STATE="$(jq -r '.state // "UNKNOWN"' <<<"$ISSUE_JSON")"
ISSUE_TITLE="$(jq -r '.title // ""' <<<"$ISSUE_JSON")"
LABELS="$(jq -r '[.labels[].name] | join(" ")' <<<"$ISSUE_JSON" 2>/dev/null || echo "")"
has_label() { [[ " $LABELS " == *" $1 "* ]]; }

# Open PR + reviewDecision (via the dispatcher's own fetch_pr_for_issue helper).
# `body` MUST be in the field list — fetch_pr_for_issue's -q filters on
# `.body` matching `#<issue>` (#148), so omitting it returns nothing.
PR_JSON="$(fetch_pr_for_issue "$ISSUE_NUMBER" "number,reviewDecision,mergeable,state,body" 2>/dev/null || echo "")"
PR_NUMBER=""; PR_REVIEW_DECISION=""; PR_MERGEABLE=""
if [[ -n "$PR_JSON" ]]; then
  PR_NUMBER="$(jq -r '.number // empty' <<<"$PR_JSON" 2>/dev/null || echo "")"
  PR_REVIEW_DECISION="$(jq -r '.reviewDecision // "NONE"' <<<"$PR_JSON" 2>/dev/null || echo "")"
  PR_MERGEABLE="$(jq -r '.mergeable // "UNKNOWN"' <<<"$PR_JSON" 2>/dev/null || echo "")"
fi

# Lease / PID liveness via the REAL pid_alive + get_pid — query both the dev
# (kind=issue) and review (kind=review) leases so the render shows whichever is live.
DEV_PID="$(get_pid issue "$ISSUE_NUMBER" 2>/dev/null || echo "")"
REVIEW_PID="$(get_pid review "$ISSUE_NUMBER" 2>/dev/null || echo "")"
DEV_ALIVE="no";    pid_alive issue  "$ISSUE_NUMBER" >/dev/null 2>&1 && DEV_ALIVE="yes"
REVIEW_ALIVE="no"; pid_alive review "$ISSUE_NUMBER" >/dev/null 2>&1 && REVIEW_ALIVE="yes"

# Retry count via the REAL count_retries (same value the Step-4 stall gate uses).
RETRIES="$(count_retries "$ISSUE_NUMBER" 2>/dev/null || echo "?")"

# ---------------------------------------------------------------------------
# Run dirs: last 3 run-ids + outcomes, last drop reasons (#235 durable state).
# ---------------------------------------------------------------------------
RUNS_PARENT=""
if declare -F _runs_parent >/dev/null 2>&1; then
  RUNS_PARENT="$(_runs_parent 2>/dev/null || echo "")"
fi

# _run_sort_epoch <dir> — echo a NUMERIC epoch sort key for a run dir: the
# `meta.json.started_at` ISO timestamp converted to epoch when present+parseable,
# else the dir's mtime, else 0. Both `_recent_runs` and `_latest_review_drops`
# use this so ISO-backed and mtime-fallback dirs compare on the SAME numeric axis
# — a lexical compare would rank an ISO string (`2026-…`) above a 10-digit epoch
# (`17…`) regardless of real time, so a newer mtime-only run could sort behind an
# older ISO-backed run (#235 review [P1]).
_run_sort_epoch() {
  local d="$1" iso="" key=""
  if [[ -f "$d/meta.json" ]] && command -v jq >/dev/null 2>&1; then
    iso="$(jq -r '.started_at // empty' "$d/meta.json" 2>/dev/null || echo "")"
    [[ -n "$iso" ]] && key="$(date -u -d "$iso" +%s 2>/dev/null || echo "")"
  fi
  [[ -n "${key:-}" ]] || key="$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null || echo 0)"
  [[ "$key" =~ ^[0-9]+$ ]] || key=0
  printf '%s\n' "$key"
}

# Echo the up-to-3 most recent run dirs for THIS issue, newest first. The sort key
# is the NUMERIC epoch from `_run_sort_epoch` (NOT the raw started_at string), so
# `sort -t'|' -k1,1nr` (numeric, on the epoch field) orders ISO-backed and
# mtime-fallback dirs consistently.
_recent_runs() {
  [[ -n "$RUNS_PARENT" && -d "$RUNS_PARENT" ]] || return 0
  local d epoch rc ended outcome name
  local -a rows=()
  for d in "$RUNS_PARENT/${PROJECT_ID}-${ISSUE_NUMBER}-dev-"* \
           "$RUNS_PARENT/${PROJECT_ID}-${ISSUE_NUMBER}-review-"*; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    rc=""; ended=""
    if [[ -f "$d/meta.json" ]] && command -v jq >/dev/null 2>&1; then
      rc="$(jq -r '.rc // empty' "$d/meta.json" 2>/dev/null || echo "")"
      ended="$(jq -r '.ended_at // empty' "$d/meta.json" 2>/dev/null || echo "")"
    fi
    epoch="$(_run_sort_epoch "$d")"
    if [[ -z "$ended" ]]; then outcome="in-flight (no end marker)"
    elif [[ "$rc" == "0" ]]; then outcome="rc=0 (success)"
    elif [[ -n "$rc" ]]; then outcome="rc=${rc} (failure)"
    else outcome="ended (rc unknown)"; fi
    rows+=("${epoch}|${name}|${outcome}")
  done
  [[ ${#rows[@]} -gt 0 ]] || return 0
  # Numeric sort on the epoch field (field 1, `|`-separated), newest first.
  printf '%s\n' "${rows[@]}" | sort -t'|' -k1,1nr | head -3 \
    | awk -F'|' '{printf "  %s  —  %s\n", $2, $3}'
}

# Echo the drop reasons from the NEWEST review run dir — but only if THAT run
# actually has a `drops.jsonl`. Selecting the newest run FIRST (regardless of
# whether it has drops) and rendering only its file avoids showing stale drops
# from an OLDER review when the newest review had none (#235 review [P1]).
_latest_review_drops() {
  [[ -n "$RUNS_PARENT" && -d "$RUNS_PARENT" ]] || return 0
  local d latest="" latest_key=-1 key
  for d in "$RUNS_PARENT/${PROJECT_ID}-${ISSUE_NUMBER}-review-"*; do
    [[ -d "$d" ]] || continue   # consider EVERY review run, not only those with drops
    key="$(_run_sort_epoch "$d")"
    if [[ "$key" -gt "$latest_key" ]]; then latest="$d"; latest_key="$key"; fi
  done
  [[ -n "$latest" ]] || return 0
  # Render the newest review run's drops ONLY if that run has the file; a newest
  # run with no drops correctly shows nothing (not an older run's stale drops).
  [[ -f "$latest/drops.jsonl" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '"  " + .agent + ": " + .reason + "  (" + (.ts // "") + ")"' "$latest/drops.jsonl" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Derive "what the next dispatcher tick will do" — SAME predicates as the tick.
# ---------------------------------------------------------------------------
_next_action() {
  if [[ "$ISSUE_STATE" != "OPEN" ]]; then
    echo "none — issue is ${ISSUE_STATE} (terminal)."; return
  fi
  if has_label stalled; then
    echo "none — \`stalled\` is terminal (retry budget MAX_RETRIES=${MAX_RETRIES} exhausted); operator intervention required."; return
  fi
  if has_label approved; then
    if has_label no-auto-close; then
      echo "none — \`approved\` + \`no-auto-close\`: review passed but auto-merge is gated; operator merges manually."
    else
      echo "none — \`approved\` is terminal (auto-close handled by GitHub via the PR's Closes #N on merge)."
    fi
    return
  fi
  if has_label reviewing; then
    if [[ "$REVIEW_ALIVE" == "yes" ]]; then
      echo "Step 5a: leave alone — review wrapper lease is ALIVE (review has its own polling/timeout)."
    elif review_near_success "$ISSUE_NUMBER" >/dev/null 2>&1; then
      echo "Step 5b: DEFER crash declaration — pid_alive miss but review_near_success signal positive ([INV-24]); re-checks next tick."
    else
      echo "Step 5b: declare review crash → swap \`reviewing\`→\`pending-dev\` (then Step 4 re-evaluates; retry ${RETRIES}/${MAX_RETRIES})."
    fi
    return
  fi
  if has_label in-progress; then
    if [[ "$DEV_ALIVE" == "yes" ]]; then
      if [[ -n "$PR_NUMBER" ]]; then
        echo "Step 5a: dev lease ALIVE with PR #${PR_NUMBER} present — if CI is green AND PR idle >300s, SIGTERM the dev wrapper and swap \`in-progress\`→\`pending-review\`; else leave alone."
      else
        echo "Step 5a: leave alone — dev lease ALIVE, no PR yet."
      fi
    elif dev_near_success "$ISSUE_NUMBER" >/dev/null 2>&1; then
      echo "Step 5b: DEFER crash declaration — pid_alive miss but dev_near_success signal positive ([INV-27]); re-checks next tick."
    else
      echo "Step 5b: declare dev crash (\"Task appears to have crashed (no PR found)\") → swap \`in-progress\`→\`pending-dev\` (retry ${RETRIES}/${MAX_RETRIES})."
    fi
    return
  fi
  if has_label pending-review; then
    echo "Step 3: dispatch review → swap \`pending-review\`→\`reviewing\` (subject to MAX_CONCURRENT)."; return
  fi
  if has_label pending-dev; then
    if [[ "$RETRIES" =~ ^[0-9]+$ ]] && [[ "$RETRIES" -ge "$MAX_RETRIES" ]]; then
      echo "Step 4: retries (${RETRIES}) ≥ MAX_RETRIES (${MAX_RETRIES}) → mark_stalled (swap \`pending-dev\`→\`stalled\`)."
    elif [[ -n "$PR_NUMBER" ]]; then
      echo "Step 4: PR #${PR_NUMBER} exists → if HEAD advanced, swap \`pending-dev\`→\`pending-review\`; else stale-verdict re-poll. (retry ${RETRIES}/${MAX_RETRIES})"
    else
      echo "Step 4: dispatch dev-resume → swap \`pending-dev\`→\`in-progress\` (retry ${RETRIES}/${MAX_RETRIES}), subject to MAX_CONCURRENT."
    fi
    return
  fi
  if has_label autonomous; then
    echo "Step 2: dispatch dev-new → swap to \`in-progress\` (once ## Dependencies are resolved + MAX_CONCURRENT allows)."; return
  fi
  echo "none — issue is not \`autonomous\`; the dispatcher ignores it."
}

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------
echo "════════════════════════════════════════════════════════════════"
echo " issue #${ISSUE_NUMBER} — ${ISSUE_TITLE}"
echo " project: ${PROJECT_ID}   repo: ${REPO}   state: ${ISSUE_STATE}"
echo "════════════════════════════════════════════════════════════════"
echo "labels:        ${LABELS:-<none>}"
if [[ -n "$PR_NUMBER" ]]; then
  echo "open PR:       #${PR_NUMBER}  reviewDecision=${PR_REVIEW_DECISION:-NONE}  mergeable=${PR_MERGEABLE:-UNKNOWN}"
else
  echo "open PR:       <none linked>"
fi
echo "lease (dev):   pid=${DEV_PID:-<none>}    alive=${DEV_ALIVE}"
echo "lease (review):pid=${REVIEW_PID:-<none>} alive=${REVIEW_ALIVE}"
echo "retry count:   ${RETRIES} / ${MAX_RETRIES}   (count_retries, the Step-4 stall gate input)"

echo ""
echo "── last run-ids (newest first) ───────────────────────────────────"
_runs_out="$(_recent_runs)"
if [[ -n "$_runs_out" ]]; then echo "$_runs_out"; else echo "  no runs recorded under ${RUNS_PARENT:-<run dir unresolved>}"; fi

echo ""
echo "── last drop reasons (latest review run) ─────────────────────────"
_drops_out="$(_latest_review_drops)"
if [[ -n "$_drops_out" ]]; then echo "$_drops_out"; else echo "  none recorded"; fi

echo ""
echo "── next dispatcher tick ──────────────────────────────────────────"
echo "  $(_next_action)"
echo "════════════════════════════════════════════════════════════════"
