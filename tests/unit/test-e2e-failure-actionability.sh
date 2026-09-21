#!/bin/bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/skills/autonomous-dispatcher/scripts/lib-review-e2e.sh"

PASS=0 FAIL=0
check() { local name="$1" expected="$2" actual="$3"; if [[ "$actual" == "$expected" ]]; then echo "PASS: $name"; PASS=$((PASS+1)); else echo "FAIL: $name expected=$expected actual=$actual"; FAIL=$((FAIL+1)); fi; }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
FILE="$TMPD/e2e-failure-classification"

check "TC-E2E-ACT-002 absent is legacy actionable" true "$(_e2e_failure_actionability "$TMPD" "$FILE")"
printf 'dev-actionable=false\n' >"$FILE"
check "TC-E2E-ACT-003 explicit non-actionable" false "$(_e2e_failure_actionability "$TMPD" "$FILE")"
printf 'dev-actionable=true\n' >"$FILE"
check "TC-E2E-ACT-004 explicit actionable" true "$(_e2e_failure_actionability "$TMPD" "$FILE")"

for value in 'false' 'dev-actionable=maybe' 'dev-actionable=false extra'; do
  printf '%s\n' "$value" >"$FILE"
  check "TC-E2E-ACT-005 malformed fails closed: $value" false "$(_e2e_failure_actionability "$TMPD" "$FILE")"
done
printf 'dev-actionable=true\ntrailing-junk' >"$FILE"
check "TC-E2E-ACT-005 unterminated trailing junk fails closed" false "$(_e2e_failure_actionability "$TMPD" "$FILE")"
printf 'dev-actionable=true' >"$FILE"
check "TC-E2E-ACT-005 missing final newline fails closed" false "$(_e2e_failure_actionability "$TMPD" "$FILE")"
rm -f "$FILE"; mkdir "$FILE"
check "TC-E2E-ACT-005 directory fails closed" false "$(_e2e_failure_actionability "$TMPD" "$FILE")"
rm -rf "$FILE"; ln -s /dev/null "$FILE"
check "TC-E2E-ACT-005 symlink fails closed" false "$(_e2e_failure_actionability "$TMPD" "$FILE")"
rm -f "$FILE"; head -c 1025 /dev/zero >"$FILE"
check "TC-E2E-ACT-005 oversized fails closed" false "$(_e2e_failure_actionability "$TMPD" "$FILE")"

WRAPPER="$ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
check "TC-E2E-ACT-001 wrapper exports private path" 1 "$(grep -c 'export E2E_FAILURE_CLASSIFICATION_FILE="${_E2E_LANE_DIR}/e2e-failure-classification"' "$WRAPPER")"

# Exercise command-mode inheritance through the real lane function. Browser
# mode uses the same parent export before its subshell/run_agent launch; pin the
# source ordering as the complementary wiring assertion.
rm -rf "$FILE"
export E2E_FAILURE_CLASSIFICATION_FILE="$FILE"
export PROJECT_ID=test PR_NUMBER=42 PR_HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export E2E_COMMAND_RENDERED='printf "dev-actionable=false\n" >"$E2E_FAILURE_CLASSIFICATION_FILE"; exit 7'
export E2E_COMMAND_PRE_HOOKS_RENDERED="" E2E_COMMAND_EVIDENCE_PARSER_RENDERED=""
_fetch_sha_evidence() { :; }
_run_command_e2e_verify() { bash -c "$E2E_COMMAND_RENDERED"; }
chp_pr_comment() { :; }
log() { :; }
_run_command_e2e_lane "$TMPD/command.rc"
check "TC-E2E-ACT-001 command lane receives private path" false "$(_e2e_failure_actionability "$TMPD" "$FILE")"
export_line=$(grep -n 'export E2E_FAILURE_CLASSIFICATION_FILE=' "$WRAPPER" | cut -d: -f1)
browser_line=$(grep -n 'run_agent "\$_e2e_session_id"' "$WRAPPER" | cut -d: -f1)
if [[ -n "$export_line" && -n "$browser_line" && "$export_line" -lt "$browser_line" ]]; then
  check "TC-E2E-ACT-001 browser lane inherits private path" pass pass
else
  check "TC-E2E-ACT-001 browser lane inherits private path" pass fail
fi
DISPOSITION="$ROOT/skills/autonomous-dispatcher/scripts/lib-review-disposition.sh"
source "$DISPOSITION"
source "$ROOT/skills/autonomous-dispatcher/scripts/lib-review-mergeable.sh"
HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
check "TC-E2E-ACT-003 neutral disposition is accepted" \
  "<!-- review-disposition: issue=115 head=$HEAD_SHA phase=pre-fanout result=e2e-failed -->" \
  "$(_review_disposition_marker 115 "$HEAD_SHA" e2e-failed)"

TRACE=""; FAIL_AT=""
_review_ensure_disposition() { TRACE+="disposition\n"; [[ "$FAIL_AT" != disposition ]]; }
_review_ensure_required_verdict() { TRACE+="verdict:$7\n"; [[ "$FAIL_AT" != verdict ]]; }
itp_transition_state() { TRACE+="transition:$2>$3\n"; [[ "$FAIL_AT" != transition ]]; }
log() { :; }

for FAIL_AT in disposition verdict transition; do
  TRACE=""; rc=0
  _review_route_e2e_failure 115 "$HEAD_SHA" false || rc=$?
  check "TC-E2E-ACT-008 $FAIL_AT failure returns closed" \
    "$( [[ "$FAIL_AT" == transition ]] && echo 21 || echo 20 )" "$rc"
  if [[ "$FAIL_AT" == disposition || "$FAIL_AT" == verdict ]]; then
    check "TC-E2E-ACT-008 $FAIL_AT failure makes zero transitions" 0 "$(grep -c transition <<<"$TRACE")"
  fi
done
FAIL_AT=""; TRACE=""
_review_route_e2e_failure 115 "$HEAD_SHA" false
check "TC-E2E-ACT-003 route carries false only in verdict" 1 "$(grep -c 'verdict:false' <<<"$TRACE")"
check "TC-E2E-ACT-003 route transitions once after writes" 1 "$(grep -c transition <<<"$TRACE")"

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
