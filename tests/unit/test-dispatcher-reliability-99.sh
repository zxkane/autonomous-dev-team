#!/bin/bash
# test-dispatcher-reliability-99.sh — Unit tests for issue #99 fixes.
#
# Covers:
#   - is_within_grace_period (Bug 1 — cold-start grace period)
#   - latest_dispatch_token_age_seconds (Bug 1 — token age extraction)
#   - post_dispatch_token (Bug 2 — dispatcher-written marker)
#   - count_retries with session-id gate (Bug 5 — false-positive filter)
#
# Run: bash tests/unit/test-dispatcher-reliability-99.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Required env (lib-dispatch.sh enforces these via : "${VAR:?...}")
export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-proj
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# Mocked gh: returns nothing by default. Tests override _MOCK_COMMENTS_JSON
# to control what `gh issue view ... --json comments -q ...` returns.
# _MOCK_LAST_COMMENT_BODY captures the most recent `gh issue comment ... --body ...` body.
_MOCK_COMMENTS_JSON=""
_MOCK_LAST_COMMENT_BODY=""
gh() {
  local cmd="${1:-}"
  local sub="${2:-}"
  if [[ "$cmd" == "issue" && "$sub" == "comment" ]]; then
    # Find --body in args.
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--body" ]]; then
        _MOCK_LAST_COMMENT_BODY="$2"
        return 0
      fi
      shift
    done
    return 0
  fi
  # Find the -q expression in the args, if any.
  local q_expr=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -q) q_expr="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ -n "$q_expr" && -n "$_MOCK_COMMENTS_JSON" ]]; then
    jq -r "$q_expr" <<<"$_MOCK_COMMENTS_JSON"
  fi
}
export -f gh

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected='$expected'"
    echo "      actual=  '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_true() {
  local desc="$1" rc="$2"
  if [[ "$rc" -eq 0 ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (rc=$rc, expected 0)"
    FAIL=$((FAIL + 1))
  fi
}

assert_false() {
  local desc="$1" rc="$2"
  if [[ "$rc" -ne 0 ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (rc=$rc, expected non-zero)"
    FAIL=$((FAIL + 1))
  fi
}

iso_minus_seconds() {
  # Echo an ISO-8601 UTC timestamp $1 seconds in the past.
  local seconds_ago="$1"
  local epoch
  epoch=$(( $(date -u +%s) - seconds_ago ))
  date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null
}

# ---------------------------------------------------------------------------
echo "=== latest_dispatch_token_age_seconds (Bug 1) ==="
# ---------------------------------------------------------------------------

# TC-99-001/004: latest token wins, age extracted correctly.
T_OLD=$(iso_minus_seconds 3000)
T_NEW=$(iso_minus_seconds 60)
_MOCK_COMMENTS_JSON="{\"comments\":[
  {\"body\":\"<!-- dispatcher-token: aaaaaaa at ${T_OLD} mode=dev-new -->\nDispatching autonomous development...\"},
  {\"body\":\"<!-- dispatcher-token: bbbbbbb at ${T_NEW} mode=dev-resume -->\nResuming development...\"}
]}"
age=$(latest_dispatch_token_age_seconds 99)
if [[ "$age" =~ ^[0-9]+$ ]] && (( age >= 50 && age <= 75 )); then
  echo -e "  ${GREEN}PASS${NC}: latest token age ~60s (got $age)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: latest token age expected ~60s, got '$age'"
  FAIL=$((FAIL + 1))
fi

# TC-99-003: no token comments → empty.
_MOCK_COMMENTS_JSON='{"comments":[{"body":"some random comment"}]}'
out=$(latest_dispatch_token_age_seconds 99)
assert_eq "no token comments → empty age" "" "$out"

# Empty comments list → empty.
_MOCK_COMMENTS_JSON='{"comments":[]}'
out=$(latest_dispatch_token_age_seconds 99)
assert_eq "empty comments list → empty age" "" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== is_within_grace_period (Bug 1) ==="
# ---------------------------------------------------------------------------

export DISPATCH_GRACE_PERIOD_SECONDS=1800

# TC-99-001: token 60s old, grace 1800s → true.
T_RECENT=$(iso_minus_seconds 60)
_MOCK_COMMENTS_JSON="{\"comments\":[
  {\"body\":\"<!-- dispatcher-token: aaaaaaa at ${T_RECENT} mode=dev-new -->\"}
]}"
is_within_grace_period 99
assert_true "token 60s old → in grace period" $?

# TC-99-002: token 2000s old, grace 1800s → false.
T_OLD=$(iso_minus_seconds 2000)
_MOCK_COMMENTS_JSON="{\"comments\":[
  {\"body\":\"<!-- dispatcher-token: aaaaaaa at ${T_OLD} mode=dev-new -->\"}
]}"
is_within_grace_period 99
assert_false "token 2000s old → out of grace period" $?

# TC-99-003: no token comments → false (backward compat).
_MOCK_COMMENTS_JSON='{"comments":[]}'
is_within_grace_period 99
assert_false "no dispatch token → grace period not applied" $?

# Boundary: token at exactly grace seconds → false (strict <).
export DISPATCH_GRACE_PERIOD_SECONDS=100
T_BOUNDARY=$(iso_minus_seconds 200)
_MOCK_COMMENTS_JSON="{\"comments\":[
  {\"body\":\"<!-- dispatcher-token: x at ${T_BOUNDARY} mode=dev-new -->\"}
]}"
is_within_grace_period 99
assert_false "age > grace → out of grace" $?

# DISPATCH_GRACE_PERIOD_SECONDS=0 → grace disabled.
export DISPATCH_GRACE_PERIOD_SECONDS=0
T_RECENT=$(iso_minus_seconds 5)
_MOCK_COMMENTS_JSON="{\"comments\":[
  {\"body\":\"<!-- dispatcher-token: x at ${T_RECENT} mode=dev-new -->\"}
]}"
is_within_grace_period 99
assert_false "DISPATCH_GRACE_PERIOD_SECONDS=0 disables grace" $?

unset DISPATCH_GRACE_PERIOD_SECONDS

# ---------------------------------------------------------------------------
echo ""
echo "=== post_dispatch_token (Bug 2) ==="
# ---------------------------------------------------------------------------

# TC-99-005: post_dispatch_token writes a comment containing the marker.
_MOCK_LAST_COMMENT_BODY=""
post_dispatch_token 99 "dev-new"
if [[ "$_MOCK_LAST_COMMENT_BODY" == *"<!-- dispatcher-token: "*"mode=dev-new"*" -->"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: post_dispatch_token writes dispatcher-token marker"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: marker missing from comment body"
  echo "      body='${_MOCK_LAST_COMMENT_BODY}'"
  FAIL=$((FAIL + 1))
fi

# Also check the mode is in the marker for review and dev-resume.
_MOCK_LAST_COMMENT_BODY=""
post_dispatch_token 99 "review"
if [[ "$_MOCK_LAST_COMMENT_BODY" == *"mode=review"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: post_dispatch_token records mode=review"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: mode=review missing"
  FAIL=$((FAIL + 1))
fi

# TC-99-011: roundtrip — write a token, then parse its age. Should be < 5s.
_MOCK_LAST_COMMENT_BODY=""
post_dispatch_token 99 "dev-new"
_MOCK_COMMENTS_JSON=$(jq -n --arg body "$_MOCK_LAST_COMMENT_BODY" \
  '{comments: [{body: $body}]}')
age=$(latest_dispatch_token_age_seconds 99)
if [[ "$age" =~ ^[0-9]+$ ]] && (( age >= 0 && age <= 10 )); then
  echo -e "  ${GREEN}PASS${NC}: token roundtrip age ~0s (got $age)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: token roundtrip age expected ~0s, got '$age'"
  echo "      body='${_MOCK_LAST_COMMENT_BODY}'"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== count_retries session-id gate (Bug 5) ==="
# ---------------------------------------------------------------------------

# TC-99-006: dispatcher crashes alone (no session ID ever) → 0.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-01-01T00:00:00Z","body":"Task appears to have crashed (no PR found). Moving to pending-dev for retry."},
  {"createdAt":"2026-01-02T00:00:00Z","body":"Task appears to have crashed (no PR found). Moving to pending-dev for retry."}
]}'
assert_eq "2 dispatcher crashes, no session ID → 0 (false positives suppressed)" "0" "$(count_retries 99)"

# TC-99-007: dispatcher crashes with session ID present → counts.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-01-01T00:00:00Z","body":"**Agent Session Report (Dev)**\nDev Session ID: `abc-123`\n- Exit code: 0"},
  {"createdAt":"2026-01-02T00:00:00Z","body":"Task appears to have crashed (no PR found). Moving to pending-dev for retry."},
  {"createdAt":"2026-01-03T00:00:00Z","body":"Task appears to have crashed (no PR found). Moving to pending-dev for retry."}
]}'
assert_eq "2 dispatcher crashes WITH session ID → 2 (counted)" "2" "$(count_retries 99)"

# TC-99-008: agent failure always counts even without session ID.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-01-01T00:00:00Z","body":"**Agent Session Report (Dev)**\n- Exit code: 1\n- Mode: startup-failure"}
]}'
assert_eq "agent failure always counts → 1" "1" "$(count_retries 99)"

# TC-99-009: stalled-cutoff still applies.
# Pre-stall: 1 dispatcher crash + 1 session ID. Post-stall: 1 dispatcher crash, NO session ID.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-01-01T00:00:00Z","body":"Dev Session ID: `pre-stall-id`"},
  {"createdAt":"2026-01-02T00:00:00Z","body":"Task appears to have crashed (no PR found)"},
  {"createdAt":"2026-01-03T00:00:00Z","body":"Marking as stalled"},
  {"createdAt":"2026-01-04T00:00:00Z","body":"Task appears to have crashed (no PR found)"}
]}'
assert_eq "post-stall: dispatcher crash without post-stall session ID → 0" "0" "$(count_retries 99)"

# Mixed post-stall: agent failure (counts) + dispatcher crash without session ID (suppressed).
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-01-01T00:00:00Z","body":"Marking as stalled"},
  {"createdAt":"2026-01-02T00:00:00Z","body":"Task appears to have crashed (no PR found)"},
  {"createdAt":"2026-01-03T00:00:00Z","body":"**Agent Session Report (Dev)**\n- Exit code: 1"}
]}'
assert_eq "post-stall: agent failure (1) + dispatcher crash w/o session-id (0) → 1" "1" "$(count_retries 99)"

# Existing TCs from test-lib-dispatch.sh — make sure we don't regress them:
# 2 failures, no stall comment → counter = 2
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-01-01T00:00:00Z","body":"Agent Session Report (Dev)\nExit code: 1"},
  {"createdAt":"2026-01-02T00:00:00Z","body":"Agent Session Report (Dev)\nExit code: 1"}
]}'
assert_eq "regression: 2 agent failures, no stall comment → 2" "2" "$(count_retries 99)"

# Bug 5 edge case (review feedback): startup-failure session report
# (autonomous-dev.sh:144 — Mode: startup-failure) carries a forwarded
# SESSION_ID for dev-resume but the agent never actually ran. It must
# NOT arm dispatcher-crash counting.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-01-01T00:00:00Z","body":"**Agent Session Report (Dev)**\n- Dev Session ID: `forwarded-id`\n- Exit code: 1\n- Mode: startup-failure"},
  {"createdAt":"2026-01-02T00:00:00Z","body":"Task appears to have crashed (no PR found). Moving to pending-dev for retry."}
]}'
# Expected: 1 agent failure (startup-failure exit 1) + 0 dispatcher crashes
# (gate not armed by startup-failure session ID) = 1.
assert_eq "startup-failure session ID does NOT arm dispatcher-crash counting → 1" "1" "$(count_retries 99)"

# But a NORMAL dev-mode session report DOES arm the gate, even if its exit
# was 0 (proving the agent really did run).
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-01-01T00:00:00Z","body":"**Agent Session Report (Dev)**\n- Dev Session ID: `real-id`\n- Exit code: 0\n- Mode: new"},
  {"createdAt":"2026-01-02T00:00:00Z","body":"Task appears to have crashed (no PR found). Moving to pending-dev for retry."}
]}'
assert_eq "Mode: new session report arms dispatcher-crash counting → 1" "1" "$(count_retries 99)"

# ---------------------------------------------------------------------------
echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
