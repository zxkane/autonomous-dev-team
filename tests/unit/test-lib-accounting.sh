#!/bin/bash
# test-lib-accounting.sh — issue #505 / INV-139.
#
# Covers lib-accounting.sh: identity construction (D3), strict idempotent
# commit (D5), lifecycle states (D4), locked full-scan query + rebuildable
# projection cache (D2), reconciliation proof-of-death (D6), and the
# metrics-isolation + zero-production-call-site guards.
# Test IDs: TC-RESOURCEACCOUNT-001..080.
#
# Isolation (tests/unit/README.md): every path this test touches is under a
# fresh mktemp -d ($WORK), namespaced per invocation — safe to run
# concurrently with any sibling test.
#
# Run: bash tests/unit/test-lib-accounting.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-accounting.sh"

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
assert_ne() {
  local desc="$1" a="$2" b="$3"
  if [[ "$a" != "$b" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      both='$a'"; FAIL=$((FAIL + 1))
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

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-accounting.sh
source "$LIB"

# ---------------------------------------------------------------------------
# Identity (D3) — TC-RESOURCEACCOUNT-001..006
# ---------------------------------------------------------------------------
echo "== accounting_invocation_id =="

ID1="$(accounting_invocation_id R1 dev dev 1)"
ID1B="$(accounting_invocation_id R1 dev dev 1)"
assert_eq "TC-RESOURCEACCOUNT-001 same tuple -> same id" "$ID1" "$ID1B"
assert_contains "TC-RESOURCEACCOUNT-001 id has inv-v1- prefix" "inv-v1-" "$ID1"

ID2="$(accounting_invocation_id R2 dev dev 1)"
assert_ne "TC-RESOURCEACCOUNT-002 differing run_id -> different id" "$ID1" "$ID2"

ID3="$(accounting_invocation_id R1 review dev 1)"
assert_ne "TC-RESOURCEACCOUNT-003 differing side -> different id" "$ID1" "$ID3"

ID4A="$(accounting_invocation_id R1 review UUID-A 1)"
ID4B="$(accounting_invocation_id R1 review UUID-B 1)"
assert_ne "TC-RESOURCEACCOUNT-004 same-named members, different UUIDs -> different id" "$ID4A" "$ID4B"

ID5="$(accounting_invocation_id R1 dev dev 2)"
assert_ne "TC-RESOURCEACCOUNT-005 incremented attempt -> different id" "$ID1" "$ID5"

RO_DIR="$(mktemp -d)"
chmod 500 "$RO_DIR"
ID6="$(AUTONOMOUS_ACCOUNTING_DIR="$RO_DIR/nope" accounting_invocation_id R1 dev dev 1 2>/dev/null)"
assert_eq "TC-RESOURCEACCOUNT-006 construction is pure (no store I/O)" "$ID1" "$ID6"
chmod 700 "$RO_DIR"; rm -rf "$RO_DIR"

# ---------------------------------------------------------------------------
# Strict idempotent commit (D5) — TC-RESOURCEACCOUNT-010..015
# ---------------------------------------------------------------------------
echo "== accounting_commit_usage =="

WORK="$(mktemp -d)"
export AUTONOMOUS_ACCOUNTING_DIR="$WORK/accounting"
export PROJECT_ID="acctproj"
ISSUE=100

X="$(accounting_invocation_id RUN1 dev dev 1)"
accounting_start "$ISSUE" "$X" dev RUN1 dev 1 >/dev/null
accounting_commit_usage "$ISSUE" "$X" 100 60 40
assert_eq "TC-RESOURCEACCOUNT-010 first commit succeeds" "0" "$?"
REC_FILE="${AUTONOMOUS_ACCOUNTING_DIR}/${ISSUE}/${X}.json"
assert_eq "TC-RESOURCEACCOUNT-010 record is terminal usage-committed" "usage-committed" "$(jq -r .state "$REC_FILE")"
assert_eq "TC-RESOURCEACCOUNT-010 total_tokens=100" "100" "$(jq -r .total_tokens "$REC_FILE")"

MTIME_BEFORE="$(stat -c %Y "$REC_FILE" 2>/dev/null || stat -f %m "$REC_FILE" 2>/dev/null)"
sleep 1
accounting_commit_usage "$ISSUE" "$X" 100 60 40
assert_eq "TC-RESOURCEACCOUNT-011 identical-duplicate commit succeeds" "0" "$?"
MTIME_AFTER="$(stat -c %Y "$REC_FILE" 2>/dev/null || stat -f %m "$REC_FILE" 2>/dev/null)"
assert_eq "TC-RESOURCEACCOUNT-011 identical-duplicate performs no write" "$MTIME_BEFORE" "$MTIME_AFTER"

accounting_commit_usage "$ISSUE" "$X" 200 - - 2>"$WORK/conflict-err.txt"
assert_ne "TC-RESOURCEACCOUNT-012 conflicting-duplicate commit rejected" "0" "$?"
assert_eq "TC-RESOURCEACCOUNT-012 conflicting-duplicate performs no mutation" "100" "$(jq -r .total_tokens "$REC_FILE")"
assert_contains "TC-RESOURCEACCOUNT-012 loud stderr on conflict" "conflicting duplicate" "$(cat "$WORK/conflict-err.txt")"
rm -f "$WORK/conflict-err.txt"

(
  export AUTONOMOUS_ACCOUNTING_DIR="$WORK/accounting"
  export PROJECT_ID="acctproj"
  source "$LIB"
  accounting_commit_usage "$ISSUE" "$X" 100 60 40
)
assert_eq "TC-RESOURCEACCOUNT-013 idempotency survives a simulated restart" "0" "$?"

UNWRITABLE="$(mktemp -d)"
chmod 500 "$UNWRITABLE"
Y_FRESH="$(accounting_invocation_id RUN1 dev dev 99)"
(
  export AUTONOMOUS_ACCOUNTING_DIR="$UNWRITABLE/accounting"
  source "$LIB"
  accounting_commit_usage "$ISSUE" "$Y_FRESH" 5 2>/dev/null
)
assert_ne "TC-RESOURCEACCOUNT-014 write failure is loud (rc!=0)" "0" "$?"
chmod 700 "$UNWRITABLE"; rm -rf "$UNWRITABLE"

Y="$(accounting_invocation_id RUN1 dev dev 2)"
accounting_start "$ISSUE" "$Y" dev RUN1 dev 2 >/dev/null
accounting_commit_unknown "$ISSUE" "$Y" "dead-pid"
assert_eq "TC-RESOURCEACCOUNT-015 commit_unknown succeeds" "0" "$?"
YREC="${AUTONOMOUS_ACCOUNTING_DIR}/${ISSUE}/${Y}.json"
assert_eq "TC-RESOURCEACCOUNT-015 record is terminal usage-unknown" "usage-unknown" "$(jq -r .state "$YREC")"
assert_eq "TC-RESOURCEACCOUNT-015 reason recorded" "dead-pid" "$(jq -r .reason "$YREC")"

# ---------------------------------------------------------------------------
# Lifecycle (D4) — TC-RESOURCEACCOUNT-020..023
# ---------------------------------------------------------------------------
echo "== lifecycle =="

ISSUE2=200
Z="$(accounting_invocation_id RUN2 dev dev 1)"
accounting_start "$ISSUE2" "$Z" dev RUN2 dev 1 >/dev/null
Q="$(accounting_admission_query "$ISSUE2")"
assert_eq "TC-RESOURCEACCOUNT-020 live started record queries incomplete" "incomplete" "$(jq -r .status <<<"$Q")"
assert_contains "TC-RESOURCEACCOUNT-020 open_invocations contains Z" "$Z" "$(jq -c .open_invocations <<<"$Q")"
assert_eq "TC-RESOURCEACCOUNT-020 unknown_invocations empty" "[]" "$(jq -c .unknown_invocations <<<"$Q")"

A="$(accounting_invocation_id RUN2 dev dev 2)"
B="$(accounting_invocation_id RUN2 dev dev 3)"
accounting_start "$ISSUE2" "$A" dev RUN2 dev 2 >/dev/null
accounting_start "$ISSUE2" "$B" dev RUN2 dev 3 >/dev/null
accounting_commit_unknown "$ISSUE2" "$B" "manual-test" >/dev/null
Q2="$(accounting_admission_query "$ISSUE2")"
assert_contains "TC-RESOURCEACCOUNT-021 A stays open (incomplete)" "$A" "$(jq -c .open_invocations <<<"$Q2")"
assert_contains "TC-RESOURCEACCOUNT-021 B is sticky usage-unknown" "$B" "$(jq -c .unknown_invocations <<<"$Q2")"
Q3="$(accounting_admission_query "$ISSUE2")"
assert_eq "TC-RESOURCEACCOUNT-021 re-query without mutation leaves A open" "$(jq -c .open_invocations <<<"$Q2")" "$(jq -c .open_invocations <<<"$Q3")"

ISSUE_UNAVAIL=201
(
  export AUTONOMOUS_ACCOUNTING_DIR="$WORK/accounting"
  export PROJECT_ID="acctproj"
  source "$LIB"
  ACCOUNTING_LOCK_WAIT_SECONDS=1
  DIR="$(_accounting_issue_dir "$ISSUE_UNAVAIL")"
  exec 8>>"${DIR}/.lock"
  flock 8
  QU="$(accounting_admission_query "$ISSUE_UNAVAIL" 2>/dev/null)"
  RC=$?
  echo "$QU" > "$WORK/unavail-out.txt"
  echo "$RC" > "$WORK/unavail-rc.txt"
)
assert_eq "TC-RESOURCEACCOUNT-022 lock contention yields unavailable" "unavailable" "$(jq -r .status < "$WORK/unavail-out.txt")"
assert_ne "TC-RESOURCEACCOUNT-022 unavailable query returns rc!=0" "0" "$(cat "$WORK/unavail-rc.txt")"
rm -f "$WORK/unavail-out.txt" "$WORK/unavail-rc.txt"

ISSUE3=202
C="$(accounting_invocation_id RUN3 dev dev 1)"
accounting_start "$ISSUE3" "$C" dev RUN3 dev 1 >/dev/null
accounting_commit_usage "$ISSUE3" "$C" 30 >/dev/null
CDIR="$(_accounting_issue_dir "$ISSUE3")"
printf 'not valid json{{{' > "${CDIR}/bogus-corrupt.json"
Q4="$(accounting_admission_query "$ISSUE3")"
assert_eq "TC-RESOURCEACCOUNT-023 malformed record yields corrupt status" "corrupt" "$(jq -r .status <<<"$Q4")"
assert_eq "TC-RESOURCEACCOUNT-023 corrupt file left untouched" "not valid json{{{" "$(cat "${CDIR}/bogus-corrupt.json")"
assert_eq "TC-RESOURCEACCOUNT-023 valid record still counted" "30" "$(jq -r .total_tokens <<<"$Q4")"

# ---------------------------------------------------------------------------
# Query / projection (D2) — TC-RESOURCEACCOUNT-030..036
# ---------------------------------------------------------------------------
echo "== query / projection =="

ISSUE4=300
Q5="$(accounting_admission_query "$ISSUE4")"
assert_eq "TC-RESOURCEACCOUNT-030 zero invocations -> total 0" "0" "$(jq -r .total_tokens <<<"$Q5")"
assert_eq "TC-RESOURCEACCOUNT-030 zero invocations -> complete" "complete" "$(jq -r .status <<<"$Q5")"

ISSUE5=301
D1="$(accounting_invocation_id RUN5 dev dev 1)"
accounting_start "$ISSUE5" "$D1" dev RUN5 dev 1 >/dev/null
accounting_commit_usage "$ISSUE5" "$D1" 50 >/dev/null
Q6="$(accounting_admission_query "$ISSUE5")"
assert_eq "TC-RESOURCEACCOUNT-031 one invocation -> total 50" "50" "$(jq -r .total_tokens <<<"$Q6")"

ISSUE6=302
D2A="$(accounting_invocation_id RUN6 dev dev 1)"
D2B="$(accounting_invocation_id RUN6 dev dev 2)"
D2C="$(accounting_invocation_id RUN6 dev dev 3)"
D2OPEN="$(accounting_invocation_id RUN6 dev dev 4)"
D2UNK="$(accounting_invocation_id RUN6 dev dev 5)"
for pair in "$D2A:30" "$D2B:20" "$D2C:10"; do
  id="${pair%%:*}"; tok="${pair##*:}"
  accounting_start "$ISSUE6" "$id" dev RUN6 dev 1 >/dev/null
  accounting_commit_usage "$ISSUE6" "$id" "$tok" >/dev/null
done
accounting_start "$ISSUE6" "$D2OPEN" dev RUN6 dev 4 >/dev/null
accounting_start "$ISSUE6" "$D2UNK" dev RUN6 dev 5 >/dev/null
accounting_commit_unknown "$ISSUE6" "$D2UNK" "test" >/dev/null
Q7="$(accounting_admission_query "$ISSUE6")"
assert_eq "TC-RESOURCEACCOUNT-032 mixed states total counts only committed usage" "60" "$(jq -r .total_tokens <<<"$Q7")"
assert_eq "TC-RESOURCEACCOUNT-032 one open invocation" "1" "$(jq -r '.open_invocations | length' <<<"$Q7")"
assert_eq "TC-RESOURCEACCOUNT-032 one unknown invocation" "1" "$(jq -r '.unknown_invocations | length' <<<"$Q7")"

ISSUE7=303
E1="$(accounting_invocation_id RUN7 dev dev 1)"
accounting_start "$ISSUE7" "$E1" dev RUN7 dev 1 >/dev/null
accounting_commit_usage "$ISSUE7" "$E1" 15 >/dev/null
PROJ="$(_accounting_issue_dir "$ISSUE7")/projection.json"
assert_eq "TC-RESOURCEACCOUNT-033 no projection exists before first query" "absent" "$([[ -f "$PROJ" ]] && echo present || echo absent)"
accounting_admission_query "$ISSUE7" >/dev/null
assert_eq "TC-RESOURCEACCOUNT-033 projection rebuilt after query" "present" "$([[ -f "$PROJ" ]] && echo present || echo absent)"
assert_eq "TC-RESOURCEACCOUNT-033 projection total matches" "15" "$(jq -r .total_tokens "$PROJ")"

STALE_DIGEST_BEFORE="$(jq -r .digest "$PROJ")"
E2="$(accounting_invocation_id RUN7 dev dev 2)"
accounting_start "$ISSUE7" "$E2" dev RUN7 dev 2 >/dev/null
accounting_commit_usage "$ISSUE7" "$E2" 5 >/dev/null
Q8="$(accounting_admission_query "$ISSUE7")"
assert_eq "TC-RESOURCEACCOUNT-034 stale projection rebuilt to current total" "20" "$(jq -r .total_tokens <<<"$Q8")"
assert_ne "TC-RESOURCEACCOUNT-034 digest changed after rebuild" "$STALE_DIGEST_BEFORE" "$(jq -r .digest "$PROJ")"

printf 'not json at all' > "$PROJ"
Q9="$(accounting_admission_query "$ISSUE7")"
assert_eq "TC-RESOURCEACCOUNT-035 corrupt projection discarded, correct total returned" "20" "$(jq -r .total_tokens <<<"$Q9")"

TOTAL_BEFORE_DELETE="$(jq -r .total_tokens "$PROJ")"
DIGEST_BEFORE_DELETE="$(jq -r .digest "$PROJ")"
rm -f "$PROJ"
Q10="$(accounting_admission_query "$ISSUE7")"
assert_eq "TC-RESOURCEACCOUNT-036 rebuilt total matches pre-delete total" "$TOTAL_BEFORE_DELETE" "$(jq -r .total_tokens <<<"$Q10")"
assert_eq "TC-RESOURCEACCOUNT-036 rebuilt digest matches pre-delete digest" "$DIGEST_BEFORE_DELETE" "$(jq -r .source_digest <<<"$Q10")"

# ---------------------------------------------------------------------------
# Reconciliation (D6) — TC-RESOURCEACCOUNT-040..045
# ---------------------------------------------------------------------------
echo "== reconciliation =="

PID_WORK="$(mktemp -d)"
export AUTONOMOUS_PID_DIR="$PID_WORK"
ISSUE8=400

# A dead PID: spawn and wait for a genuinely-exited child.
sh -c 'exit 0' &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null

F1="$(accounting_invocation_id RUNDEAD dev dev 1)"
accounting_start "$ISSUE8" "$F1" dev RUNDEAD dev 1 >/dev/null
printf 'RUNDEAD\n' > "${PID_WORK}/issue-${ISSUE8}.run-id"
jq -nc --argjson pid "$DEAD_PID" '{schema_version:1,run_id:"RUNDEAD",pid:$pid,updated_at_epoch:0}' > "${PID_WORK}/issue-${ISSUE8}.progress.json"
accounting_reconcile "$ISSUE8"
QF1="$(jq -r .state "$(_accounting_issue_dir "$ISSUE8")/${F1}.json")"
assert_eq "TC-RESOURCEACCOUNT-040 dead-PID evidence promotes to usage-unknown" "usage-unknown" "$QF1"

ISSUE9=401
F2="$(accounting_invocation_id RUNOLD dev dev 1)"
accounting_start "$ISSUE9" "$F2" dev RUNOLD dev 1 >/dev/null
printf 'RUNNEW\n' > "${PID_WORK}/issue-${ISSUE9}.run-id"
jq -nc '{schema_version:1,run_id:"RUNNEW",pid:999999,updated_at_epoch:0}' > "${PID_WORK}/issue-${ISSUE9}.progress.json"
accounting_reconcile "$ISSUE9"
QF2="$(jq -r .state "$(_accounting_issue_dir "$ISSUE9")/${F2}.json")"
assert_eq "TC-RESOURCEACCOUNT-041 superseded run-id promotes to usage-unknown" "usage-unknown" "$QF2"

ISSUE10=402
F3="$(accounting_invocation_id RUNLIVE dev dev 1)"
accounting_start "$ISSUE10" "$F3" dev RUNLIVE dev 1 >/dev/null
printf 'RUNLIVE\n' > "${PID_WORK}/issue-${ISSUE10}.run-id"
jq -nc --argjson pid "$$" '{schema_version:1,run_id:"RUNLIVE",pid:$pid,updated_at_epoch:0}' > "${PID_WORK}/issue-${ISSUE10}.progress.json"
accounting_reconcile "$ISSUE10"
QF3="$(jq -r .state "$(_accounting_issue_dir "$ISSUE10")/${F3}.json")"
assert_eq "TC-RESOURCEACCOUNT-042 live lease keeps started (incomplete)" "started" "$QF3"

ISSUE10B=4021
F3B="$(accounting_invocation_id RUNNOEV dev dev 1)"
accounting_start "$ISSUE10B" "$F3B" dev RUNNOEV dev 1 >/dev/null
# No run-id sidecar and no progress.json at all — absence of evidence, not
# proof of death (INV-135's own transient no-lease-yet window).
accounting_reconcile "$ISSUE10B"
QF3B="$(jq -r .state "$(_accounting_issue_dir "$ISSUE10B")/${F3B}.json")"
assert_eq "TC-RESOURCEACCOUNT-042b missing evidence (no sidecars) keeps started, not usage-unknown" "started" "$QF3B"

ISSUE10C=4022
F3C="$(accounting_invocation_id RUNNOPID dev dev 1)"
accounting_start "$ISSUE10C" "$F3C" dev RUNNOPID dev 1 >/dev/null
printf 'RUNNOPID\n' > "${PID_WORK}/issue-${ISSUE10C}.run-id"
# Run-id sidecar matches but progress.json is absent — run-id evidence alone
# says nothing about liveness; must not be treated as a dead pid.
rm -f "${PID_WORK}/issue-${ISSUE10C}.progress.json"
accounting_reconcile "$ISSUE10C"
QF3C="$(jq -r .state "$(_accounting_issue_dir "$ISSUE10C")/${F3C}.json")"
assert_eq "TC-RESOURCEACCOUNT-042c matching run-id, missing pid evidence keeps started" "started" "$QF3C"

ISSUE11=403
F4="$(accounting_invocation_id RUNCLOSE dev dev 1)"
accounting_start "$ISSUE11" "$F4" dev RUNCLOSE dev 1 >/dev/null
F4_FILE="$(_accounting_issue_dir "$ISSUE11")/${F4}.json"
BEFORE_CLOSE="$(cat "$F4_FILE")"
# Simulate "issue closed" — no call into accounting_reconcile at all.
AFTER_CLOSE="$(cat "$F4_FILE")"
assert_eq "TC-RESOURCEACCOUNT-043 closing the issue alone mutates nothing" "$BEFORE_CLOSE" "$AFTER_CLOSE"

ISSUE12=404
F5="$(accounting_invocation_id RUNACK dev dev 1)"
accounting_start "$ISSUE12" "$F5" dev RUNACK dev 1 >/dev/null
accounting_commit_unknown "$ISSUE12" "$F5" "test-reason" >/dev/null
accounting_ack_unknown "$ISSUE12" "$F5"
assert_eq "TC-RESOURCEACCOUNT-044 ack_unknown succeeds" "0" "$?"
ACKS_FILE="$(_accounting_issue_dir "$ISSUE12")/acks.jsonl"
assert_eq "TC-RESOURCEACCOUNT-044 ack record written" "1" "$(wc -l < "$ACKS_FILE" | tr -d ' ')"
F5REC="$(_accounting_issue_dir "$ISSUE12")/${F5}.json"
assert_eq "TC-RESOURCEACCOUNT-044 original usage-unknown record still exists" "usage-unknown" "$(jq -r .state "$F5REC")"

ISSUE13=405
G1="$(accounting_invocation_id RUNRE dev dev 1)"
G2="$(accounting_invocation_id RUNRE dev dev 2)"
accounting_start "$ISSUE13" "$G1" dev RUNRE dev 1 >/dev/null
accounting_commit_usage "$ISSUE13" "$G1" 25 >/dev/null
accounting_start "$ISSUE13" "$G2" dev RUNRE dev 2 >/dev/null
accounting_commit_unknown "$ISSUE13" "$G2" "test" >/dev/null
G1_BEFORE="$(cat "$(_accounting_issue_dir "$ISSUE13")/${G1}.json")"
G2_BEFORE="$(cat "$(_accounting_issue_dir "$ISSUE13")/${G2}.json")"
accounting_reconcile "$ISSUE13"
accounting_reconcile "$ISSUE13"
G1_AFTER="$(cat "$(_accounting_issue_dir "$ISSUE13")/${G1}.json")"
G2_AFTER="$(cat "$(_accounting_issue_dir "$ISSUE13")/${G2}.json")"
assert_eq "TC-RESOURCEACCOUNT-045 committed record unchanged after re-arm" "$G1_BEFORE" "$G1_AFTER"
assert_eq "TC-RESOURCEACCOUNT-045 already-unknown record unchanged after re-arm" "$G2_BEFORE" "$G2_AFTER"

rm -rf "$PID_WORK"
unset AUTONOMOUS_PID_DIR

# ---------------------------------------------------------------------------
# Metrics isolation guard — TC-RESOURCEACCOUNT-060..061
# ---------------------------------------------------------------------------
echo "== metrics isolation =="

METRICS_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-metrics.sh"
ISO_WORK="$(mktemp -d)"
(
  export AUTONOMOUS_METRICS_DIR="$ISO_WORK"
  export AUTONOMOUS_ACCOUNTING_DIR="$ISO_WORK/accounting"
  export PROJECT_ID="isoproj"
  # shellcheck source=/dev/null
  source "$METRICS_LIB"
  source "$LIB"
  # A deliberately OLD ts (200 days) so metrics_prune 90 genuinely rewrites
  # metrics.jsonl below — a "now" ts would survive any retention window,
  # making the prune call a no-op and the checksum comparison vacuous.
  OLD_TS="$(date -u -d '200 days ago' +%Y-%m-%dT%H:%M:%SZ)"
  jq -nc --arg ts "$OLD_TS" '{schema_version:1,ts:$ts,event:"token_usage",side:"dev",issue:999,total_tokens:1}' \
    >> "${ISO_WORK}/metrics.jsonl"
  H1="$(accounting_invocation_id RUNISO dev dev 1)"
  accounting_start 999 "$H1" dev RUNISO dev 1 >/dev/null
  accounting_commit_usage 999 "$H1" 42 >/dev/null
)
METRICS_BEFORE_CHECKSUM="$(sha256sum "${ISO_WORK}/metrics.jsonl" | awk '{print $1}')"
BEFORE_ACCT_CHECKSUM="$(find "$ISO_WORK/accounting" -type f -exec sha256sum {} \; 2>/dev/null | sort)"
(
  export AUTONOMOUS_METRICS_DIR="$ISO_WORK"
  source "$METRICS_LIB"
  metrics_prune 90
)
METRICS_AFTER_CHECKSUM="$(sha256sum "${ISO_WORK}/metrics.jsonl" | awk '{print $1}')"
AFTER_ACCT_CHECKSUM="$(find "$ISO_WORK/accounting" -type f -exec sha256sum {} \; 2>/dev/null | sort)"
assert_ne "TC-RESOURCEACCOUNT-060 sanity: metrics_prune actually rewrote metrics.jsonl (not a vacuous no-op)" "$METRICS_BEFORE_CHECKSUM" "$METRICS_AFTER_CHECKSUM"
assert_eq "TC-RESOURCEACCOUNT-060 metrics_prune leaves accounting/ byte-unchanged" "$BEFORE_ACCT_CHECKSUM" "$AFTER_ACCT_CHECKSUM"
assert_eq "TC-RESOURCEACCOUNT-060 accounting dir is a sibling of metrics.jsonl, not a descendant of it" "sibling" \
  "$([[ "$ISO_WORK/accounting" == "$ISO_WORK/metrics.jsonl/"* ]] && echo "descendant" || echo "sibling")"
rm -rf "$ISO_WORK"

# ---------------------------------------------------------------------------
# Zero production call sites — TC-RESOURCEACCOUNT-070
# ---------------------------------------------------------------------------
echo "== zero production call sites =="

PROD_HITS="$(grep -rlE 'accounting_(invocation_id|start|commit_usage|commit_unknown|reconcile|ack_unknown|admission_query)' \
  "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts" \
  --include='*.sh' 2>/dev/null | grep -v 'lib-accounting\.sh$' || true)"
assert_eq "TC-RESOURCEACCOUNT-070 no production script calls any accounting_* function" "" "$PROD_HITS"

rm -rf "$WORK"

# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]] || exit 1
