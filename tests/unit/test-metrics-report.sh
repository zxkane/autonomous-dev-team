#!/bin/bash
# test-metrics-report.sh — issue #228 / INV-70.
#
# Covers metrics-report.sh aggregation math on deterministic fixtures.
# Test IDs: TC-METRICS-040..051.
#
# Strategy: build a fixture metrics.jsonl with known event counts/timestamps,
# run metrics-report.sh --file <fixture>, and assert the four headline blocks
# match hand-computed values.
#
# Run: bash tests/unit/test-metrics-report.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPORT="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/metrics-report.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      want='$want'"; echo "      got ='$got'"; FAIL=$((FAIL + 1))
  fi
}
assert_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      needle='$needle'"; echo "      hay   ='$hay'"; FAIL=$((FAIL + 1))
  fi
}

# emit <file> <ts> <k=v...> — append one JSON line (numbers coerced for known keys).
emit() {
  local f="$1" ts="$2"; shift 2
  local out; out=$(printf '{"schema_version":1,"ts":"%s","project":"p"' "$ts")
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    if [[ "$v" =~ ^-?[0-9]+$ && "$k" =~ ^(issue|pr|input_tokens|output_tokens|total_tokens|rc|duration_s|retry_count)$ ]]; then
      out+=$(printf ',"%s":%s' "$k" "$v")
    else
      out+=$(printf ',"%s":"%s"' "$k" "$v")
    fi
  done
  out+='}'
  printf '%s\n' "$out" >> "$f"
}

# ---------------------------------------------------------------------------
# Build the main fixture
# ---------------------------------------------------------------------------
FIX="$(mktemp -d)/metrics.jsonl"; mkdir -p "$(dirname "$FIX")"; : > "$FIX"

# Incidents: 2 in March, 3 in April (one spans month boundary into April).
emit "$FIX" "2026-03-05T00:00:00Z" event=agent_drop agent_name=codex reason=agent-unavailable:quota pr=201
emit "$FIX" "2026-03-31T23:00:00Z" event=agent_drop agent_name=agy   reason=agent-unavailable:auth  pr=202
emit "$FIX" "2026-04-01T01:00:00Z" event=merge result=failure failure_class=infra pr=203
emit "$FIX" "2026-04-02T00:00:00Z" event=dispatch_stale kind=in-progress failure_class=false-stall
emit "$FIX" "2026-04-03T00:00:00Z" event=verdict verdict=all-unavailable pr=204

# Cost-per-merged-PR: 3 merged PRs with tokens 1000/2000/3000, 1 merged PR no tokens.
# Production shape: the dev wrapper emits token_usage keyed by ISSUE (it does not
# know the PR number); the review wrapper's merge event carries both issue + pr.
# The aggregator joins on `issue` — fixtures must NOT fabricate a `pr` on
# token_usage (that would mask the real join-key contract; #228 review finding).
emit "$FIX" "2026-03-01T02:00:00Z" event=merge result=success pr=101 issue=1
emit "$FIX" "2026-03-01T02:00:00Z" event=token_usage issue=1 total_tokens=1000
emit "$FIX" "2026-04-15T04:00:00Z" event=merge result=success pr=102 issue=2
emit "$FIX" "2026-04-15T04:00:00Z" event=token_usage issue=2 total_tokens=2000
emit "$FIX" "2026-05-10T06:00:00Z" event=merge result=success pr=103 issue=3
emit "$FIX" "2026-05-10T06:00:00Z" event=token_usage issue=3 total_tokens=3000
emit "$FIX" "2026-05-12T06:00:00Z" event=merge result=success pr=105 issue=5   # no token_usage

# Per-CLI quota: claude 2 quota drops over 10 review runs (20%); agy 0 runs.
for i in 0 1 2 3 4 5 6 7 8 9; do
  emit "$FIX" "2026-03-01T1${i}:00:00Z" event=wrapper_end side=review agent=claude rc=0
done
emit "$FIX" "2026-03-01T20:00:00Z" event=agent_drop agent_name=claude reason=agent-unavailable:quota pr=205
emit "$FIX" "2026-03-02T20:00:00Z" event=agent_drop agent_name=claude reason=agent-unavailable:quota pr=206

# TTHW: issue 1 labeled@day0 → PR +1h → merged +2h; issue 2 +2h/+4h; issue 3 +3h/+6h;
# issue 4 labeled + PR(+5h) but NEVER merged (missing merged endpoint).
emit "$FIX" "2026-03-01T00:00:00Z" event=issue_labeled issue=1
emit "$FIX" "2026-03-01T01:00:00Z" event=pr_opened issue=1
emit "$FIX" "2026-04-15T00:00:00Z" event=issue_labeled issue=2
emit "$FIX" "2026-04-15T02:00:00Z" event=pr_opened issue=2
emit "$FIX" "2026-05-10T00:00:00Z" event=issue_labeled issue=3
emit "$FIX" "2026-05-10T03:00:00Z" event=pr_opened issue=3
emit "$FIX" "2026-05-20T00:00:00Z" event=issue_labeled issue=4
emit "$FIX" "2026-05-20T05:00:00Z" event=pr_opened issue=4

OUT="$(bash "$REPORT" --file "$FIX" 2>&1)"

# ---------------------------------------------------------------------------
# 1. Incidents per month
# ---------------------------------------------------------------------------
echo "== incidents =="
# TC-METRICS-040: per-class counts. NOTE every agent_drop is an incident,
# including the 2 claude quota drops emitted for the per-CLI section below — so
# March quota = codex(201) + claude(205,206) = 3.
assert_contains "TC-METRICS-040 Mar quota=3"  "2026-03  agent-unavailable:quota          3" "$OUT"
assert_contains "TC-METRICS-040 Mar auth=1"   "2026-03  agent-unavailable:auth           1" "$OUT"
assert_contains "TC-METRICS-040 Apr infra=1"  "2026-04  infra                            1" "$OUT"
assert_contains "TC-METRICS-040 Apr stale=1"  "2026-04  false-stall                      1" "$OUT"
assert_contains "TC-METRICS-040 Apr vabsent=1" "2026-04  verdict-absent                   1" "$OUT"
# Total = 3 quota + 1 auth + 1 infra + 1 false-stall + 1 verdict-absent = 7.
assert_contains "TC-METRICS-040 total=7"      "total incidents: 7" "$OUT"
# TC-METRICS-041: month-boundary split — the 03-31 auth and 04-01 infra are in
# different month buckets (asserted by the distinct 2026-03 / 2026-04 rows above).
assert_contains "TC-METRICS-041 boundary: Mar bucket present" "2026-03  agent-unavailable:auth" "$OUT"
assert_contains "TC-METRICS-041 boundary: Apr bucket present" "2026-04  infra" "$OUT"

# ---------------------------------------------------------------------------
# 2. Cost-per-merged-PR
# ---------------------------------------------------------------------------
echo "== cost =="
# TC-METRICS-042: 1000/2000/3000 → avg=2000 p50=2000 p90=3000.
assert_contains "TC-METRICS-042 avg/p50/p90" "avg=2000 tokens  p50=2000  p90=3000" "$OUT"
# TC-METRICS-043: 4 merged PRs but only 3 have token data (PR105/issue5 excluded).
assert_contains "TC-METRICS-043 4 merged, 3 costed" "merged PRs: 4; with token data: 3" "$OUT"

# TC-METRICS-052: production join-key regression (#228 review). token_usage is
# keyed by ISSUE (no pr field — the dev wrapper doesn't know the PR number); the
# aggregator MUST join cost to merge on `issue`. A separate fixture in exactly
# the production shape (token_usage has issue, NO pr) must still be costed.
PFIX="$(mktemp -d)/metrics.jsonl"; mkdir -p "$(dirname "$PFIX")"; : > "$PFIX"
emit "$PFIX" "2026-06-01T02:00:00Z" event=merge result=success pr=301 issue=11
emit "$PFIX" "2026-06-01T02:00:00Z" event=token_usage side=dev issue=11 agent=claude input_tokens=400 output_tokens=600 total_tokens=1000
emit "$PFIX" "2026-06-02T02:00:00Z" event=merge result=success pr=302 issue=12
emit "$PFIX" "2026-06-02T02:00:00Z" event=token_usage side=dev issue=12 agent=claude total_tokens=3000
# issue 13 merged but its token_usage carries NO total_tokens → excluded, not 0.
emit "$PFIX" "2026-06-03T02:00:00Z" event=merge result=success pr=303 issue=13
emit "$PFIX" "2026-06-03T02:00:00Z" event=token_usage side=dev issue=13 agent=claude
OUT_PROD="$(bash "$REPORT" --file "$PFIX" 2>&1)"
assert_contains "TC-METRICS-052 issue-keyed token_usage (no pr) IS costed" "merged PRs: 3; with token data: 2" "$OUT_PROD"
# 2 costed issues [1000,3000]: avg=2000; nearest-rank p50(rank=1)=1000, p90(rank=2)=3000.
assert_contains "TC-METRICS-052 cost avg over the 2 costed (1000,3000)" "avg=2000 tokens  p50=1000  p90=3000" "$OUT_PROD"

# TC-METRICS-056 (#228 round-8 finding 2): review-side token_usage is summed into
# cost-per-merged-PR alongside dev-side, so fleet cost isn't undercounted. One
# merged issue with a dev token_usage (1000) AND a review token_usage (250) must
# cost 1250 total (both join on `issue`). A second merged issue with ONLY a
# review token_usage (500) must still be costed (review-only is valid).
RVFIX="$(mktemp -d)/metrics.jsonl"; mkdir -p "$(dirname "$RVFIX")"; : > "$RVFIX"
emit "$RVFIX" "2026-07-01T02:00:00Z" event=merge result=success pr=401 issue=21
emit "$RVFIX" "2026-07-01T02:00:00Z" event=token_usage side=dev    issue=21 agent=claude total_tokens=1000
emit "$RVFIX" "2026-07-01T02:00:00Z" event=token_usage side=review issue=21 agent=codex  total_tokens=250
emit "$RVFIX" "2026-07-02T02:00:00Z" event=merge result=success pr=402 issue=22
emit "$RVFIX" "2026-07-02T02:00:00Z" event=token_usage side=review issue=22 agent=claude total_tokens=500
OUT_RV="$(bash "$REPORT" --file "$RVFIX" 2>&1)"
assert_contains "TC-METRICS-056 review-side token_usage costed (2 issues)" "merged PRs: 2; with token data: 2" "$OUT_RV"
# costs: issue21=1000+250=1250, issue22=500 → sorted [500,1250]: avg=875, p50(rank=1)=500, p90(rank=2)=1250.
assert_contains "TC-METRICS-056 dev+review summed per issue (1250) + review-only (500)" "avg=875 tokens  p50=500  p90=1250" "$OUT_RV"

# ---------------------------------------------------------------------------
# 3. Quota-failure rate per CLI
# ---------------------------------------------------------------------------
echo "== quota rate =="
# TC-METRICS-044: claude 2/10 = 20%.
assert_contains "TC-METRICS-044 claude 20%" "claude     quota=2 runs=10 → 20%" "$OUT"
# TC-METRICS-045: codex appears via drops but has 0 review runs → n/a (no div0).
assert_contains "TC-METRICS-045 codex 0 runs n/a" "codex      quota=1 runs=0 → n/a" "$OUT"
assert_contains "TC-METRICS-045 agy 0 runs n/a"   "agy        quota=0 runs=0 → n/a" "$OUT"

# ---------------------------------------------------------------------------
# 4. TTHW
# ---------------------------------------------------------------------------
echo "== TTHW =="
# Match label and stats separately to stay tolerant of byte-vs-glyph padding
# around the multibyte `→`. Reduce runs of spaces to single spaces for the assert.
OUT_TTHW="$(printf '%s\n' "$OUT" | sed -E 's/[[:space:]]+/ /g')"
# labeled→first-PR: 1h,2h,3h,5h → avg=2.75h≈2h45m, p50(nearest-rank @4: rank=2)=2h, p90(rank=4)=5h
assert_contains "TC-METRICS-046 first-PR n=4 avg/p50/p90" "labeled→first-PR: n=4 avg=2h45m p50=2h0m p90=5h0m" "$OUT_TTHW"
# labeled→merged: issues 1,2,3 merged (2h,4h,6h) → avg=4h p50=4h p90=6h; issue 4 excluded.
assert_contains "TC-METRICS-047/048 merged n=3 (issue4 excluded)" "labeled→merged: n=3 avg=4h0m p50=4h0m p90=6h0m" "$OUT_TTHW"

# ---------------------------------------------------------------------------
# Filters & edge cases
# ---------------------------------------------------------------------------
echo "== filters & edges =="
# TC-METRICS-049: --since 2026-05-01 drops Mar/Apr incidents; only PR103/105 cost.
OUT_SINCE="$(bash "$REPORT" --file "$FIX" --since 2026-05-01 2>&1)"
assert_contains "TC-METRICS-049 since drops earlier incidents" "(no incidents)" "$OUT_SINCE"
assert_contains "TC-METRICS-049 since: only May merge costed" "with token data: 1" "$OUT_SINCE"

# TC-METRICS-050: --project filter — second project's events ignored.
FIX2="$(mktemp -d)/metrics.jsonl"; mkdir -p "$(dirname "$FIX2")"; : > "$FIX2"
printf '{"schema_version":1,"ts":"2026-03-01T00:00:00Z","project":"p","event":"agent_drop","reason":"agent-unavailable:quota","agent_name":"codex"}\n' >> "$FIX2"
printf '{"schema_version":1,"ts":"2026-03-01T00:00:00Z","project":"other","event":"agent_drop","reason":"agent-unavailable:quota","agent_name":"codex"}\n' >> "$FIX2"
OUT_PROJ="$(bash "$REPORT" --file "$FIX2" --project p 2>&1)"
assert_contains "TC-METRICS-050 project filter total=1" "total incidents: 1" "$OUT_PROJ"

# TC-METRICS-051: empty file → all four blocks n/a, exit 0.
EMPTY="$(mktemp)"
OUT_EMPTY="$(bash "$REPORT" --file "$EMPTY" 2>&1)"; rc_empty=$?
assert_eq "TC-METRICS-051 empty exits 0" "0" "$rc_empty"
assert_contains "TC-METRICS-051 empty → n/a" "n/a" "$OUT_EMPTY"

# TC-METRICS-053: per-CLI denominator from review_agent_run, not wrapper_end
# (#228 finding 3). Multi-agent fan-out where the wrapper's default AGENT_CMD is
# claude: each review emits review_agent_run for BOTH codex and claude, but
# wrapper_end side=review carries only claude. codex must get a real denominator.
MFIX="$(mktemp -d)/metrics.jsonl"; mkdir -p "$(dirname "$MFIX")"; : > "$MFIX"
for r in 1 2 3 4; do
  emit "$MFIX" "2026-06-0${r}T10:00:00Z" event=wrapper_end side=review agent=claude rc=0
  emit "$MFIX" "2026-06-0${r}T10:00:00Z" event=review_agent_run agent_name=claude state=pass
  emit "$MFIX" "2026-06-0${r}T10:00:00Z" event=review_agent_run agent_name=codex state=pass
done
# codex hit quota once (1 quota / 4 runs = 25%); claude 0/4 = 0%.
emit "$MFIX" "2026-06-05T10:00:00Z" event=review_agent_run agent_name=codex state=unavailable
emit "$MFIX" "2026-06-05T10:00:00Z" event=agent_drop agent_name=codex reason=agent-unavailable:quota
OUT_MULTI="$(bash "$REPORT" --file "$MFIX" 2>&1 | sed -E 's/[[:space:]]+/ /g')"
assert_contains "TC-METRICS-053 codex denominator from review_agent_run (5 runs)" "codex quota=1 runs=5 → 20%" "$OUT_MULTI"
assert_contains "TC-METRICS-053 claude 0% over its 4 runs" "claude quota=0 runs=4 → 0%" "$OUT_MULTI"

# TC-METRICS-054: TTHW prefers labeled_at over ts (#228 finding 4). The
# issue_labeled event's `ts` is the dispatch instant (here 3h after the real
# label); `labeled_at` is the true autonomous-label time. labeled→first-PR must
# be measured from labeled_at (4h), not from ts (1h).
LFIX="$(mktemp -d)/metrics.jsonl"; mkdir -p "$(dirname "$LFIX")"; : > "$LFIX"
# real label at 00:00, dispatched (ts) at 03:00, PR at 04:00.
emit "$LFIX" "2026-06-01T03:00:00Z" event=issue_labeled issue=1 labeled_at=2026-06-01T00:00:00Z
emit "$LFIX" "2026-06-01T04:00:00Z" event=pr_opened issue=1
OUT_LBL="$(bash "$REPORT" --file "$LFIX" 2>&1 | sed -E 's/[[:space:]]+/ /g')"
assert_contains "TC-METRICS-054 TTHW uses labeled_at (4h) not ts (1h)" "labeled→first-PR: n=1 avg=4h0m p50=4h0m p90=4h0m" "$OUT_LBL"
# Without labeled_at, falls back to ts (1h).
LFIX2="$(mktemp -d)/metrics.jsonl"; mkdir -p "$(dirname "$LFIX2")"; : > "$LFIX2"
emit "$LFIX2" "2026-06-01T03:00:00Z" event=issue_labeled issue=2
emit "$LFIX2" "2026-06-01T04:00:00Z" event=pr_opened issue=2
OUT_LBL2="$(bash "$REPORT" --file "$LFIX2" 2>&1 | sed -E 's/[[:space:]]+/ /g')"
assert_contains "TC-METRICS-054 falls back to ts when no labeled_at (1h)" "labeled→first-PR: n=1 avg=1h0m p50=1h0m p90=1h0m" "$OUT_LBL2"

# TC-METRICS-055: TTHW prefers pr_opened_at over ts (#228 round-7 finding 2). The
# pr_opened event's `ts` is the wrapper-cleanup instant (here 3h after label);
# `pr_opened_at` is the REAL PR createdAt (1h after label, e.g. PR opened before
# tests finished). labeled→first-PR must be measured from pr_opened_at (1h), not
# the cleanup ts (3h).
PFIX="$(mktemp -d)/metrics.jsonl"; mkdir -p "$(dirname "$PFIX")"; : > "$PFIX"
emit "$PFIX" "2026-06-01T00:00:00Z" event=issue_labeled issue=1 labeled_at=2026-06-01T00:00:00Z
emit "$PFIX" "2026-06-01T03:00:00Z" event=pr_opened issue=1 pr_opened_at=2026-06-01T01:00:00Z
OUT_PRA="$(bash "$REPORT" --file "$PFIX" 2>&1 | sed -E 's/[[:space:]]+/ /g')"
assert_contains "TC-METRICS-055 TTHW uses pr_opened_at (1h) not cleanup ts (3h)" "labeled→first-PR: n=1 avg=1h0m p50=1h0m p90=1h0m" "$OUT_PRA"
# Without pr_opened_at, falls back to the cleanup ts (3h).
PFIX2="$(mktemp -d)/metrics.jsonl"; mkdir -p "$(dirname "$PFIX2")"; : > "$PFIX2"
emit "$PFIX2" "2026-06-01T00:00:00Z" event=issue_labeled issue=2 labeled_at=2026-06-01T00:00:00Z
emit "$PFIX2" "2026-06-01T03:00:00Z" event=pr_opened issue=2
OUT_PRA2="$(bash "$REPORT" --file "$PFIX2" 2>&1 | sed -E 's/[[:space:]]+/ /g')"
assert_contains "TC-METRICS-055 falls back to ts when no pr_opened_at (3h)" "labeled→first-PR: n=1 avg=3h0m p50=3h0m p90=3h0m" "$OUT_PRA2"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]] || { echo "---- report output for debugging ----"; echo "$OUT"; exit 1; }
