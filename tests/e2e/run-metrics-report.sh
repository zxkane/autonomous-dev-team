#!/bin/bash
# run-metrics-report.sh — E2E for the baseline metrics collector (issue #228,
# INV-70). Test ID: TC-METRICS-080.
#
# Synthesizes a deterministic THREE-MONTH metrics.jsonl event log (the kind
# lib-metrics.sh writes across a fleet of dev→review→merge cycles), runs the
# real metrics-report.sh against it, and asserts the four headline numbers
# EXACTLY. This is the fixture-driven E2E required by the issue's acceptance
# criteria — it exercises the full aggregator path with no real CLIs/network.
#
# Run:  bash tests/e2e/run-metrics-report.sh
# CI:   invoked by tests/unit/test-metrics-report-e2e.sh (so the test-*.sh loop
#       runs it) and standalone.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPORT="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/metrics-report.sh"

PASS=0
FAIL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; echo "      $2"; FAIL=$((FAIL + 1)); }
expect() {  # expect <desc> <needle> <haystack>
  [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "needle='$2'"
}

# emit <file> <ts> <k=v...>  (numbers coerced for known keys)
emit() {
  local f="$1" ts="$2"; shift 2
  local out kv k v
  out=$(printf '{"schema_version":1,"ts":"%s","project":"fleet"' "$ts")
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    if [[ "$v" =~ ^-?[0-9]+$ && "$k" =~ ^(issue|pr|total_tokens|input_tokens|output_tokens|rc|duration_s|retry_count)$ ]]; then
      out+=$(printf ',"%s":%s' "$k" "$v")
    else
      out+=$(printf ',"%s":"%s"' "$k" "$v")
    fi
  done
  printf '%s}\n' "$out" >> "$f"
}

FIX="$(mktemp -d)/metrics.jsonl"; mkdir -p "$(dirname "$FIX")"; : > "$FIX"

# === Month 1 (2026-03): 4 issues, all merge cleanly ===
# Each issue: labeled@T, pr@T+1h, review wrapper_end (claude), merge@T+2h,
# token_usage. Issues 1..4 tokens 1000,1500,2000,2500.
m1_tok=(1000 1500 2000 2500)
for n in 1 2 3 4; do
  day=$(printf '%02d' "$((n * 5))")
  emit "$FIX" "2026-03-${day}T00:00:00Z" event=issue_labeled "issue=${n}"
  emit "$FIX" "2026-03-${day}T01:00:00Z" event=pr_opened "issue=${n}"
  emit "$FIX" "2026-03-${day}T01:30:00Z" event=wrapper_end side=review agent=claude rc=0
  emit "$FIX" "2026-03-${day}T02:00:00Z" event=merge result=success "issue=${n}" "pr=$((100 + n))"
  emit "$FIX" "2026-03-${day}T02:00:00Z" event=token_usage side=dev "issue=${n}" "total_tokens=${m1_tok[$((n-1))]}"
done

# === Month 2 (2026-04): 3 issues; 1 quota drop (codex), 1 merge failure ===
m2_tok=(3000 3500 4000)
for n in 5 6 7; do
  day=$(printf '%02d' "$(((n - 4) * 7))")
  emit "$FIX" "2026-04-${day}T00:00:00Z" event=issue_labeled "issue=${n}"
  emit "$FIX" "2026-04-${day}T02:00:00Z" event=pr_opened "issue=${n}"
  emit "$FIX" "2026-04-${day}T02:30:00Z" event=wrapper_end side=review agent=codex rc=0
  emit "$FIX" "2026-04-${day}T03:00:00Z" event=merge result=success "issue=${n}" "pr=$((100 + n))"
  emit "$FIX" "2026-04-${day}T03:00:00Z" event=token_usage side=dev "issue=${n}" "total_tokens=${m2_tok[$((n-5))]}"
done
# A codex quota drop and a merge failure incident in April.
emit "$FIX" "2026-04-10T00:00:00Z" event=agent_drop side=review agent_name=codex reason=agent-unavailable:quota pr=999
emit "$FIX" "2026-04-11T00:00:00Z" event=merge result=failure failure_class=infra pr=998 issue=99

# === Month 3 (2026-05): 2 issues; 1 never merges (open PR), 1 false-stall ===
emit "$FIX" "2026-05-05T00:00:00Z" event=issue_labeled issue=8
emit "$FIX" "2026-05-05T04:00:00Z" event=pr_opened issue=8          # never merged
emit "$FIX" "2026-05-12T00:00:00Z" event=issue_labeled issue=9
emit "$FIX" "2026-05-12T01:00:00Z" event=pr_opened issue=9
emit "$FIX" "2026-05-12T02:00:00Z" event=merge result=success issue=9 pr=109
emit "$FIX" "2026-05-12T02:00:00Z" event=token_usage side=dev issue=9 total_tokens=5000
emit "$FIX" "2026-05-20T00:00:00Z" event=dispatch_stale kind=reviewing failure_class=false-stall

OUT="$(bash "$REPORT" --file "$FIX" 2>&1)"
NORM="$(printf '%s\n' "$OUT" | sed -E 's/[[:space:]]+/ /g')"

echo "== TC-METRICS-080: three-month synthesis =="

# --- Headline 1: total incidents = codex quota + merge failure + false-stall = 3
expect "headline-1 total incidents = 3" "total incidents: 3" "$OUT"
expect "headline-1 codex quota incident" "agent-unavailable:quota 1" "$NORM"
expect "headline-1 infra incident"       "infra 1" "$NORM"
expect "headline-1 false-stall incident" "false-stall 1" "$NORM"

# --- Headline 2: cost-per-merged-PR.
# Merged PRs: 4 (Mar) + 3 (Apr) + 1 (May) = 8, all with tokens.
# tokens: 1000,1500,2000,2500,3000,3500,4000,5000 (sorted)
# avg = 22500/8 = 2812.5 → rounds to 2813; p50 nearest-rank(rank=ceil(.5*8)=4) = 2500;
# p90 nearest-rank(rank=ceil(.9*8)=8) = 5000.
expect "headline-2 8 merged, 8 costed" "merged PRs: 8; with token data: 8" "$OUT"
expect "headline-2 avg/p50/p90"        "avg=2813 tokens p50=2500 p90=5000" "$NORM"

# --- Headline 3: per-CLI quota rate.
# claude: 4 review runs, 0 quota → 0%. codex: 3 review runs, 1 quota → 33%.
expect "headline-3 claude 0%"  "claude quota=0 runs=4 → 0%" "$NORM"
expect "headline-3 codex 33%"  "codex quota=1 runs=3 → 33%" "$NORM"

# --- Headline 4: TTHW.
# labeled→first-PR: issues 1-4 = 1h each, 5-7 = 2h each, 8 = 4h, 9 = 1h.
#   deltas(s): 3600 x5 (1,2,3,4,9), 7200 x3 (5,6,7), 14400 x1 (8) → n=9
#   sorted: 3600,3600,3600,3600,3600,7200,7200,7200,14400
#   avg = (5*3600 + 3*7200 + 14400)/9 = (18000+21600+14400)/9 = 54000/9 = 6000 → 1h40m
#   p50 rank=ceil(.5*9)=5 → 3600 = 1h0m;  p90 rank=ceil(.9*9)=9 → 14400 = 4h0m
expect "headline-4 first-PR n=9 avg/p50/p90" "labeled→first-PR: n=9 avg=1h40m p50=1h0m p90=4h0m" "$NORM"
# labeled→merged: issues 1-4 = 2h, 5-7 = 3h, 9 = 2h; issue 8 excluded (never merged) → n=8
#   deltas(s): 7200 x5 (1,2,3,4,9), 10800 x3 (5,6,7)
#   avg = (5*7200 + 3*10800)/8 = (36000+32400)/8 = 68400/8 = 8550 → 2h22m
#   p50 rank=ceil(.5*8)=4 → 7200 = 2h0m;  p90 rank=ceil(.9*8)=8 → 10800 = 3h0m
expect "headline-4 merged n=8 (issue8 excluded) avg/p50/p90" "labeled→merged: n=8 avg=2h22m p50=2h0m p90=3h0m" "$NORM"

echo ""
echo "TC-METRICS-080 Results: ${PASS} passed, ${FAIL} failed"
if [[ $FAIL -ne 0 ]]; then
  echo "---- report output ----"
  printf '%s\n' "$OUT"
  exit 1
fi
echo "METRICS-E2E-SUMMARY pass=${PASS} fail=0"
