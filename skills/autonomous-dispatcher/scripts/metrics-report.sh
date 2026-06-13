#!/bin/bash
# metrics-report.sh — INV-70 baseline metrics aggregator for the autonomous
# pipeline (issue #228).
#
# Reads the append-only metrics.jsonl event log(s) written by lib-metrics.sh and
# prints the four baseline numbers the stability redesign's stop-rule and
# checkpoints consume:
#
#   1. Pipeline incidents/month, by failure class.
#   2. Cost-per-merged-PR (avg / p50 / p90, where token data exists).
#   3. Quota-failure rate per agent CLI.
#   4. TTHW — issue labeled → first PR, and issue labeled → merged
#      (avg / p50 / p90).
#
# This is the LOUD-to-report half of INV-70: gaps in the data (no token usage, a
# CLI with zero runs, a PR that never merged) are surfaced as `n/a` / explicit
# counts rather than silently coerced to zero, so a broken emitter is visible.
#
# Usage:
#   metrics-report.sh [--since <YYYY-MM-DD>] [--project <id>] \
#                     [--prune-days N] [--dir <path>] [--file <path>]
#
# Resolution of the input event log(s), in order:
#   --file <path>   : read exactly that file.
#   --dir <path>    : read <path>/metrics.jsonl.
#   --project <id>  : resolve via lib-metrics.sh::metrics_dir for that project.
#   (none)          : resolve via metrics_dir using $PROJECT_ID from the env.
#
# `--prune-days N` runs lib-metrics.sh::metrics_prune on the resolved file(s)
# BEFORE aggregating (retention is built into the collector; default off here so
# a read-only report never mutates data unless asked).

set -uo pipefail

# [INV-65] Source siblings from the REAL path so a project that symlinks only
# the entry script still finds the libs in the skill tree.
_SELF="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
LIB_DIR="$(cd "$(dirname "$(readlink -f "$_SELF")")" && pwd)"
export AUTONOMOUS_CONF_DIR="${AUTONOMOUS_CONF_DIR:-$SCRIPT_DIR}"
# Load autonomous.conf (best-effort) so the no-arg invocation can resolve the
# default project's PROJECT_ID from the project's scripts/ dir [INV-14]. The
# storage-path math itself lives entirely in lib-metrics.sh (no pid_dir dep).
# shellcheck source=lib-config.sh
if source "${LIB_DIR}/lib-config.sh" 2>/dev/null; then
  load_autonomous_conf "${AUTONOMOUS_CONF_DIR}" 2>/dev/null || true
fi
# shellcheck source=lib-metrics.sh
source "${LIB_DIR}/lib-metrics.sh"

command -v jq >/dev/null 2>&1 || { echo "metrics-report: jq is required" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
SINCE=""
PROJECT_FILTER=""
PRUNE_DAYS=""
DIR_OVERRIDE=""
FILE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)      SINCE="${2:-}"; shift 2 ;;
    --project)    PROJECT_FILTER="${2:-}"; shift 2 ;;
    --prune-days) PRUNE_DAYS="${2:-}"; shift 2 ;;
    --dir)        DIR_OVERRIDE="${2:-}"; shift 2 ;;
    --file)       FILE_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help)
      grep '^#' "$_SELF" | sed 's/^# \{0,1\}//' | head -40
      exit 0 ;;
    *) echo "metrics-report: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# `--since` to an epoch (start-of-day UTC). Empty → 0 (no lower bound).
SINCE_EPOCH=0
if [[ -n "$SINCE" ]]; then
  SINCE_EPOCH="$(date -u -d "$SINCE" +%s 2>/dev/null)" || {
    echo "metrics-report: invalid --since date '$SINCE'" >&2; exit 2; }
fi

# ---------------------------------------------------------------------------
# Resolve the input file
# ---------------------------------------------------------------------------
METRICS_FILE=""
if [[ -n "$FILE_OVERRIDE" ]]; then
  METRICS_FILE="$FILE_OVERRIDE"
elif [[ -n "$DIR_OVERRIDE" ]]; then
  METRICS_FILE="${DIR_OVERRIDE}/metrics.jsonl"
else
  _dir="$(metrics_dir "${PROJECT_FILTER:-${PROJECT_ID:-}}" 2>/dev/null)" || true
  [[ -n "$_dir" ]] && METRICS_FILE="${_dir}/metrics.jsonl"
fi

if [[ -z "$METRICS_FILE" ]]; then
  echo "metrics-report: could not resolve a metrics.jsonl (set --file/--dir/--project or PROJECT_ID)" >&2
  exit 2
fi

if [[ -n "$PRUNE_DAYS" && -f "$METRICS_FILE" ]]; then
  metrics_prune "$PRUNE_DAYS" "$METRICS_FILE"
fi

if [[ ! -s "$METRICS_FILE" ]]; then
  echo "# Metrics report"
  echo "# source: ${METRICS_FILE}"
  echo "# (no events — empty or missing log)"
  echo
  echo "Incidents/month by class: n/a"
  echo "Cost-per-merged-PR:       n/a"
  echo "Quota-failure rate / CLI: n/a"
  echo "TTHW (labeled→first-PR):  n/a"
  echo "TTHW (labeled→merged):    n/a"
  exit 0
fi

# Parse all events once into a filtered, normalized newline-delimited stream.
# Each surviving event is a compact JSON object. Filters: valid JSON, ts present
# and >= SINCE_EPOCH, and (when --project given) matching project.
EVENTS="$(jq -c -R --argjson since "$SINCE_EPOCH" --arg proj "$PROJECT_FILTER" '
    (try fromjson catch null) as $o
    | select($o != null and ($o.ts // "") != "")
    | ((try ($o.ts | fromdateiso8601) catch null)) as $epoch
    | select($epoch != null and $epoch >= $since)
    | select($proj == "" or ($o.project // "") == $proj)
    | $o
  ' "$METRICS_FILE" 2>/dev/null)"

if [[ -z "$EVENTS" ]]; then
  echo "# Metrics report"
  echo "# source: ${METRICS_FILE}"
  echo "# (no events after --since/--project filtering)"
  exit 0
fi

# percentiles <p50|p90> — read whitespace/newline-separated numbers on stdin,
# echo the requested percentile (nearest-rank). Echoes nothing on empty input.
_percentile() {
  local p="$1"
  awk -v p="$p" '
    { a[n++] = $1 }
    END {
      if (n == 0) { exit }
      # insertion sort (small n)
      for (i = 1; i < n; i++) { v = a[i]; j = i - 1; while (j >= 0 && a[j] > v) { a[j+1] = a[j]; j-- } a[j+1] = v }
      rank = int((p/100.0) * n + 0.999999)   # nearest-rank, ceil
      if (rank < 1) rank = 1
      if (rank > n) rank = n
      printf "%d", a[rank-1]
    }'
}

_avg() {
  awk '{ s += $1; n++ } END { if (n == 0) { exit } printf "%d", (s/n) + 0.5 }'
}

# Render a duration in seconds as a compact human string (e.g. 2h3m, 45s).
_fmt_dur() {
  local s="${1:-}"
  [[ -n "$s" && "$s" =~ ^[0-9]+$ ]] || { printf 'n/a'; return; }
  local d=$((s/86400)) h=$(((s%86400)/3600)) m=$(((s%3600)/60)) sec=$((s%60))
  if   [[ $d -gt 0 ]]; then printf '%dd%dh' "$d" "$h"
  elif [[ $h -gt 0 ]]; then printf '%dh%dm' "$h" "$m"
  elif [[ $m -gt 0 ]]; then printf '%dm%ds' "$m" "$sec"
  else printf '%ds' "$sec"; fi
}

echo "# Metrics report"
echo "# source: ${METRICS_FILE}"
[[ -n "$SINCE" ]]          && echo "# since:   ${SINCE}"
[[ -n "$PROJECT_FILTER" ]] && echo "# project: ${PROJECT_FILTER}"
echo "# total events: $(printf '%s\n' "$EVENTS" | grep -c .)"
echo

# ===========================================================================
# 1. Incidents/month by failure class
# ===========================================================================
# An "incident" is any event that records a pipeline failure: an agent_drop, a
# verdict==all-unavailable, a failed merge, or a dispatch_stale. Each carries a
# failure class (agent_drop / merge / dispatch_stale via their `reason` /
# `failure_class` field; all-unavailable verdicts are class verdict-absent).
echo "== 1. Incidents per month, by failure class =="
INCIDENTS="$(printf '%s\n' "$EVENTS" | jq -r '
    if .event == "agent_drop" then
      [(.ts[0:7]), (.reason // "agent-unavailable:transient")]
    elif .event == "verdict" and .verdict == "all-unavailable" then
      [(.ts[0:7]), "verdict-absent"]
    elif .event == "merge" and .result == "failure" then
      [(.ts[0:7]), (.failure_class // "infra")]
    elif .event == "dispatch_stale" then
      [(.ts[0:7]), (.failure_class // "false-stall")]
    else empty end
    | @tsv
  ')"

if [[ -z "$INCIDENTS" ]]; then
  echo "  (no incidents)"
else
  printf '%s\n' "$INCIDENTS" | sort | uniq -c | \
    awk '{ printf "  %-8s %-32s %d\n", $2, $3, $1 }'
  echo "  ----"
  printf '%s\n' "$INCIDENTS" | wc -l | awk '{ printf "  total incidents: %d\n", $1 }'
fi
echo

# ===========================================================================
# 2. Cost-per-merged-PR (token usage, where the CLI reported it)
# ===========================================================================
# Each merged PR is keyed by its ISSUE (the join key both `merge` and
# `token_usage` events carry — the dev wrapper that emits token_usage knows the
# issue number, NOT the PR number, so `issue` is the only stable join). For each
# merged issue, sum every token_usage.total_tokens for that issue. Issues whose
# token_usage events carry NO numeric total_tokens are EXCLUDED (never counted
# as 0). Report avg / p50 / p90 over the included issues.
echo "== 2. Cost-per-merged-PR (total tokens) =="
MERGED_ISSUES="$(printf '%s\n' "$EVENTS" | jq -r '
    select(.event == "merge" and .result == "success" and ((.issue // "") | tostring) != "") | (.issue | tostring)' | sort -u)"

PR_COSTS=""
if [[ -n "$MERGED_ISSUES" ]]; then
  while IFS= read -r _iss; do
    [[ -n "$_iss" ]] || continue
    # Sum only token_usage rows that actually carry a numeric total_tokens for
    # this issue. `--argjson n` counts the contributing rows so an issue with
    # token_usage events but no total_tokens stays EXCLUDED (not a synthetic 0).
    _cost="$(printf '%s\n' "$EVENTS" | jq -r --arg iss "$_iss" '
        select(.event == "token_usage" and ((.issue // "") | tostring) == $iss)
        | (.total_tokens // empty)' \
        | awk '{ s += $1; n++ } END { if (n>0) print s }')"
    [[ -n "$_cost" ]] && PR_COSTS+="${_cost}"$'\n'
  done <<< "$MERGED_ISSUES"
fi

_n_merged="$(printf '%s\n' "$MERGED_ISSUES" | grep -c .)"
_n_costed="$(printf '%s\n' "$PR_COSTS" | grep -c .)"
if [[ "$_n_costed" -eq 0 ]]; then
  echo "  merged PRs: ${_n_merged}; with token data: 0 → n/a"
else
  _avg_c="$(printf '%s' "$PR_COSTS" | _avg)"
  _p50_c="$(printf '%s' "$PR_COSTS" | _percentile 50)"
  _p90_c="$(printf '%s' "$PR_COSTS" | _percentile 90)"
  echo "  merged PRs: ${_n_merged}; with token data: ${_n_costed}"
  echo "  avg=${_avg_c} tokens  p50=${_p50_c}  p90=${_p90_c}"
fi
echo

# ===========================================================================
# 3. Quota-failure rate per agent CLI
# ===========================================================================
# numerator   = agent_drop events with reason agent-unavailable:quota, per CLI
# denominator = PER-FAN-OUT-MEMBER review runs (review_agent_run, per agent_name)
#               — NOT wrapper_end side=review, which carries only the wrapper's
#               default AGENT_CMD and so under-counts non-default CLIs in a
#               multi-agent fan-out (#228 finding 3). A pre-finding-3 log with no
#               review_agent_run events falls back to wrapper_end so old data
#               still reports rather than showing every CLI as n/a.
# A CLI with zero runs prints n/a (no div-by-zero).
echo "== 3. Quota-failure rate per CLI =="
# Whether the (newer) per-agent run events are present at all.
_HAS_AGENT_RUN="$(printf '%s\n' "$EVENTS" | jq -r 'select(.event == "review_agent_run") | "x"' | grep -c . || true)"
# All CLIs that appear in any run signal or as a drop.
CLIS="$(printf '%s\n' "$EVENTS" | jq -r '
    if .event == "review_agent_run" then (.agent_name // "")
    elif .event == "wrapper_end" and .side == "review" then (.agent // "")
    elif .event == "agent_drop" then (.agent_name // "")
    else empty end | select(. != "")' | sort -u)"

if [[ -z "$CLIS" ]]; then
  echo "  (no review runs or drops recorded)"
else
  while IFS= read -r _cli; do
    [[ -n "$_cli" ]] || continue
    if [[ "${_HAS_AGENT_RUN:-0}" -gt 0 ]]; then
      _runs="$(printf '%s\n' "$EVENTS" | jq -r --arg c "$_cli" '
          select(.event == "review_agent_run" and (.agent_name // "") == $c) | "x"' | grep -c .)"
    else
      _runs="$(printf '%s\n' "$EVENTS" | jq -r --arg c "$_cli" '
          select(.event == "wrapper_end" and .side == "review" and (.agent // "") == $c) | "x"' | grep -c .)"
    fi
    _quota="$(printf '%s\n' "$EVENTS" | jq -r --arg c "$_cli" '
        select(.event == "agent_drop" and (.agent_name // "") == $c and (.reason // "") == "agent-unavailable:quota") | "x"' | grep -c .)"
    if [[ "$_runs" -eq 0 ]]; then
      printf "  %-10s quota=%d runs=0 → n/a\n" "$_cli" "$_quota"
    else
      _rate="$(awk -v q="$_quota" -v r="$_runs" 'BEGIN { printf "%.0f", (q/r)*100 }')"
      printf "  %-10s quota=%d runs=%d → %s%%\n" "$_cli" "$_quota" "$_runs" "$_rate"
    fi
  done <<< "$CLIS"
fi
echo

# ===========================================================================
# 4. TTHW — issue labeled → first PR, issue labeled → merged
# ===========================================================================
# Endpoints come from events: issue_labeled (prefers labeled_at — the real
# autonomous-label time from the GitHub timeline — over ts, the dispatch instant,
# so queued wait is counted; #228 finding 4), pr_opened (prefers pr_opened_at —
# the real PR createdAt — over ts, the wrapper-cleanup instant, so a PR opened
# before cleanup isn't overstated; #228 round-7 finding 2), merge result==success
# (ts). Missing endpoint → that issue is excluded from the affected statistic
# (no synthetic zero).
echo "== 4. TTHW =="
# Per-issue earliest labeled, earliest pr_opened, earliest successful merge.
ISSUE_TS="$(printf '%s\n' "$EVENTS" | jq -r '
    select((.issue // "") != "") |
    if .event == "issue_labeled" then [(.issue|tostring), "labeled", (((.labeled_at // .ts))|fromdateiso8601)]
    elif .event == "pr_opened" then [(.issue|tostring), "pr", (((.pr_opened_at // .ts))|fromdateiso8601)]
    elif .event == "merge" and .result == "success" then [(.issue|tostring), "merged", (.ts|fromdateiso8601)]
    else empty end | @tsv' \
  | awk '
      { key=$1"\t"$2; if (!(key in min) || $3 < min[key]) min[key]=$3 }
      END { for (k in min) print k"\t"min[k] }')"

# Reduce to per-issue: labeled, pr, merged epochs.
TTHW_PAIRS="$(printf '%s\n' "$ISSUE_TS" | awk '
    { issue=$1; kind=$2; ts=$3; v[issue"|"kind]=ts; seen[issue]=1 }
    END {
      for (i in seen) {
        lab = v[i"|labeled"]; pr = v[i"|pr"]; mg = v[i"|merged"]
        print i, (lab==""?"-":lab), (pr==""?"-":pr), (mg==""?"-":mg)
      }
    }')"

FIRSTPR_DELTAS=""
MERGED_DELTAS=""
if [[ -n "$TTHW_PAIRS" ]]; then
  while read -r _iss _lab _pr _mg; do
    [[ "$_lab" == "-" ]] && continue
    [[ "$_pr" != "-" && "$_pr" -ge "$_lab" ]] 2>/dev/null && FIRSTPR_DELTAS+="$((_pr - _lab))"$'\n'
    [[ "$_mg" != "-" && "$_mg" -ge "$_lab" ]] 2>/dev/null && MERGED_DELTAS+="$((_mg - _lab))"$'\n'
  done <<< "$TTHW_PAIRS"
fi

_report_tthw() {
  local label="$1" data="$2"
  local n; n="$(printf '%s' "$data" | grep -c .)"
  if [[ "$n" -eq 0 ]]; then
    printf "  %-26s n/a (no complete pairs)\n" "$label"
    return
  fi
  local a p50 p90
  a="$(printf '%s' "$data" | _avg)"
  p50="$(printf '%s' "$data" | _percentile 50)"
  p90="$(printf '%s' "$data" | _percentile 90)"
  printf "  %-26s n=%d avg=%s p50=%s p90=%s\n" \
    "$label" "$n" "$(_fmt_dur "$a")" "$(_fmt_dur "$p50")" "$(_fmt_dur "$p90")"
}

_report_tthw "labeled→first-PR:" "$FIRSTPR_DELTAS"
_report_tthw "labeled→merged:" "$MERGED_DELTAS"
