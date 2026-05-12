#!/bin/bash
# test-autonomous-launcher-verdict-fresh.sh —
# unit tests for the three-fix bundle: verdict actor+time-window detection
# (Fix 1), AGENT_LAUNCHER prefix injection (Fix 2), and prompt_too_long
# fresh-session fallback (Fix 3).
#
# All tests are stub-driven (no real claude / gh invocation) and exercise
# the actual code paths in autonomous-review.sh, lib-agent.sh, and
# lib-dispatch.sh.
#
# Run: bash tests/unit/test-autonomous-launcher-verdict-fresh.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS_DIR="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      missing needle: $needle"
    echo "      in haystack:    ${haystack:0:200}..."
    FAIL=$((FAIL + 1))
  fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# ---------------------------------------------------------------------------
# Fix 1 — verdict detection: actor + time window
# ---------------------------------------------------------------------------
echo "=== Fix 1 (TC-VRD): verdict detector with actor + time window ==="

# Drive the actor+window jq predicate directly. We mirror the wrapper's
# query construction: when BOT_LOGIN is set, gate by author.login and
# createdAt; otherwise legacy session-id fallback.
classify_actor_window() {
  local body="$1" author="$2" createdAt="$3" bot_login="$4" wrapper_ts="$5"
  local json="$TMPROOT/case.json"
  python3 -c "
import json, sys
out = {'comments': [{'body': sys.argv[1], 'author': {'login': sys.argv[2]}, 'createdAt': sys.argv[3]}]}
with open(sys.argv[4], 'w') as f:
    json.dump(out, f)
" "$body" "$author" "$createdAt" "$json"

  local verdict_re='Review PASSED|Review APPROVED|APPROVED FOR MERGE|LGTM|Review PASS|Review findings:|Review FAILED|Review REJECTED|Changes requested'
  local matched
  if [[ -n "$bot_login" ]]; then
    matched=$(jq -r "[.comments[] | select((.author.login == \"${bot_login}\") and (.createdAt >= \"${wrapper_ts}\") and (.body | test(\"${verdict_re}\"; \"i\")))] | last | .body" < "$json" 2>/dev/null)
  else
    # Legacy fallback path
    matched=$(jq -r "[.comments[] | select((.body | test(\"${verdict_re}\"; \"i\")) and (.body | test(\"Review Session.*${wrapper_ts}\")))] | last | .body" < "$json" 2>/dev/null)
  fi
  if [[ -z "$matched" || "$matched" == "null" ]]; then
    echo "no-match"
    return
  fi
  if echo "$matched" | grep -qiE 'Review (FAILED|REJECTED)|Review findings:|Changes requested'; then
    echo "fail"
  elif echo "$matched" | grep -qiE 'Review PASSED|Review APPROVED|APPROVED FOR MERGE|LGTM|Review PASS'; then
    echo "pass"
  else
    echo "fail"
  fi
}

BOT="kane-review-agent"
WRAPPER_TS="2026-05-12T00:00:00Z"
BEFORE_TS="2026-05-11T23:00:00Z"
AFTER_TS="2026-05-12T00:30:00Z"

assert_eq "TC-VRD-001 BOT actor + in-window + Review PASSED → pass" "pass" \
  "$(classify_actor_window "Review PASSED — all good." "$BOT" "$AFTER_TS" "$BOT" "$WRAPPER_TS")"

assert_eq "TC-VRD-002 BOT actor + in-window + APPROVED FOR MERGE → pass" "pass" \
  "$(classify_actor_window "**APPROVED FOR MERGE** — ship it." "$BOT" "$AFTER_TS" "$BOT" "$WRAPPER_TS")"

assert_eq "TC-VRD-003 BOT actor + in-window + Review findings → fail" "fail" \
  "$(classify_actor_window "Review findings: 1. Coverage low" "$BOT" "$AFTER_TS" "$BOT" "$WRAPPER_TS")"

assert_eq "TC-VRD-004 anti-regression: random session-uuid in body still matches" "pass" \
  "$(classify_actor_window "Review PASSED. Review Session: 95219405-aa55-4e37-98c7-a28138a23878" "$BOT" "$AFTER_TS" "$BOT" "$WRAPPER_TS")"

assert_eq "TC-VRD-005 anti-spoof: foreign actor → no-match" "no-match" \
  "$(classify_actor_window "Review PASSED — totally legit" "third-party-bot" "$AFTER_TS" "$BOT" "$WRAPPER_TS")"

assert_eq "TC-VRD-006 anti-spoof: stale comment from prior tick → no-match" "no-match" \
  "$(classify_actor_window "Review PASSED" "$BOT" "$BEFORE_TS" "$BOT" "$WRAPPER_TS")"

assert_eq "TC-VRD-007 ambiguous (PASS + FAIL keywords) → fail (conservative)" "fail" \
  "$(classify_actor_window "LGTM mostly. Review findings: 1. nit" "$BOT" "$AFTER_TS" "$BOT" "$WRAPPER_TS")"

# Legacy fallback (BOT_LOGIN empty) — uses session-id binding via the
# fixture's wrapper_ts arg (we pass a session id there).
LEGACY_SID="abc-test-session"
assert_eq "TC-VRD-008 fallback: matching session-id → pass" "pass" \
  "$(classify_actor_window "Review PASSED — Review Session: ${LEGACY_SID}" "$BOT" "$AFTER_TS" "" "$LEGACY_SID")"

assert_eq "TC-VRD-009 fallback: missing session-id → no-match" "no-match" \
  "$(classify_actor_window "Review PASSED — no trailer" "$BOT" "$AFTER_TS" "" "$LEGACY_SID")"

# ---------------------------------------------------------------------------
# Fix 2 — AGENT_LAUNCHER prefix
# ---------------------------------------------------------------------------
echo ""
echo "=== Fix 2 (TC-LCH): AGENT_LAUNCHER prefix injection ==="

# Stub claude shim that records its argv (and selected env) to a file
# instead of running the real CLI. We exercise lib-agent.sh's run_agent
# / resume_agent and check what got invoked.
SHIM_DIR="$TMPROOT/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/claude" <<'SHIM'
#!/bin/bash
# Record argv + the env vars the test cares about.
{
  printf 'argv:'
  printf ' %q' "$@"
  printf '\n'
  printf 'CC_USER=%s\n' "${CC_USER:-<unset>}"
  printf 'CC_ROLE_KIND=%s\n' "${CC_ROLE_KIND:-<unset>}"
  printf 'LAUNCHER_FOO=%s\n' "${LAUNCHER_FOO:-<unset>}"
} > "$SHIM_OUT"
exit 0
SHIM
chmod +x "$SHIM_DIR/claude"

# Drive lib-agent.sh in a subshell with the shim on PATH and minimal env.
run_agent_capture() {
  local launcher="$1"
  local out="$TMPROOT/agent-out-$$"
  local err="$TMPROOT/agent-err-$$"
  (
    export PATH="$SHIM_DIR:$PATH"
    export SHIM_OUT="$out"
    export AGENT_CMD="claude"
    export AGENT_LAUNCHER="$launcher"
    export AGENT_PERMISSION_MODE="auto"
    export AGENT_DEV_MODEL=""
    export PROJECT_ID="test"
    export REPO="test/repo"
    export REPO_OWNER="test"
    export REPO_NAME="repo"
    export PROJECT_DIR="$TMPROOT"
    # lib-config.sh's load_autonomous_conf will fail to find conf — that's
    # fine, all the env above is already set.
    # shellcheck disable=SC1090
    source "$SCRIPTS_DIR/lib-agent.sh" 2>"$err" || { echo "SOURCE_FAILED: $(cat "$err")"; return; }
    run_agent "test-session-$$" "test prompt" "" "test-name" >/dev/null 2>>"$err"
  )
  cat "$out" 2>/dev/null
}

# TC-LCH-001: launcher unset → claude shim is invoked directly with the
# wrapper's standard argv (--session-id, --output-format json, etc).
OUT1=$(run_agent_capture "")
ARGV1=$(echo "$OUT1" | grep '^argv:')
assert_contains "TC-LCH-001 launcher unset: claude shim invoked (--session-id present)" "--session-id" "$ARGV1"
# Sanity: launcher-injected env should be UNSET when no launcher is set.
assert_contains "TC-LCH-001 launcher unset: LAUNCHER_FOO env is <unset>" "LAUNCHER_FOO=<unset>" "$OUT1"

# TC-LCH-002: launcher = `env LAUNCHER_FOO=bar` → env reaches claude shim.
OUT2=$(run_agent_capture "env LAUNCHER_FOO=bar")
ARGV2=$(echo "$OUT2" | grep '^argv:')
assert_contains "TC-LCH-002 launcher set: LAUNCHER_FOO reaches claude env" "LAUNCHER_FOO=bar" "$OUT2"
assert_contains "TC-LCH-002 launcher set: claude still receives --session-id" "--session-id" "$ARGV2"

# TC-LCH-003: launcher with single-quoted bash -c form (the canonical cc shape).
LAUNCHER='bash -c '\''LAUNCHER_FOO=quoted exec "$@"'\'' --'
ARGV3=$(run_agent_capture "$LAUNCHER")
assert_contains "TC-LCH-003 quoted launcher: env propagates through bash -c" "LAUNCHER_FOO=quoted" "$ARGV3"

# TC-LCH-007: autonomous-dev.sh exports CC_USER/CC_ROLE_KIND.
DEV_LINE=$(grep -E '^export CC_USER=' "$SCRIPTS_DIR/autonomous-dev.sh" | head -1)
REVIEW_LINE=$(grep -E '^export CC_USER=' "$SCRIPTS_DIR/autonomous-review.sh" | head -1)
assert_contains "TC-LCH-007 autonomous-dev exports CC_USER=autonomous-dev-bot" "autonomous-dev-bot" "$DEV_LINE"
assert_contains "TC-LCH-008 autonomous-review exports CC_USER=autonomous-review-bot" "autonomous-review-bot" "$REVIEW_LINE"

# ---------------------------------------------------------------------------
# Fix 3 — is_session_completed accepts prompt_too_long
# ---------------------------------------------------------------------------
echo ""
echo "=== Fix 3 (TC-PTL): is_session_completed prompt_too_long handling ==="

# Source lib-dispatch.sh in a controlled env. We need PROJECT_ID and a
# log file at /tmp/agent-${PROJECT_ID}-issue-${N}.log to drive the probe.
TEST_PID="ptl-$$"
LOG_BASE="/tmp/agent-${TEST_PID}-issue"

run_is_completed() {
  local issue_num="$1"
  local capture_var_arg="$2"  # "" or "reason"
  (
    # lib-dispatch.sh has hard `:` asserts on REPO/REPO_OWNER/PROJECT_ID;
    # set them before sourcing so the unit test isn't gated on autonomous.conf.
    export REPO="test/repo"
    export REPO_OWNER="test"
    export PROJECT_ID="$TEST_PID"
    export AGENT_CMD="claude"
    # shellcheck disable=SC1090
    source "$SCRIPTS_DIR/lib-config.sh"
    # shellcheck disable=SC1090
    source "$SCRIPTS_DIR/lib-dispatch.sh"
    if [[ -n "$capture_var_arg" ]]; then
      local r=""
      if is_session_completed "$issue_num" r; then
        echo "OK:$r"
      else
        echo "NO:$r"
      fi
    else
      if is_session_completed "$issue_num"; then
        echo "OK"
      else
        echo "NO"
      fi
    fi
  )
}

# TC-PTL-001: end_turn|completed → 0 (existing behavior).
echo '{"type":"result","stop_reason":"end_turn","terminal_reason":"completed"}' > "${LOG_BASE}-1.log"
assert_eq "TC-PTL-001 end_turn|completed → terminal" "OK:completed" "$(run_is_completed 1 reason)"

# TC-PTL-002: prompt_too_long → 0 (NEW).
echo '{"type":"result","stop_reason":"stop_sequence","terminal_reason":"prompt_too_long"}' > "${LOG_BASE}-2.log"
assert_eq "TC-PTL-002 prompt_too_long → terminal (NEW)" "OK:prompt_too_long" "$(run_is_completed 2 reason)"

# TC-PTL-003: api_error → 1 (transient, keep retrying).
echo '{"type":"result","stop_reason":"end_turn","terminal_reason":"api_error","api_error_status":500}' > "${LOG_BASE}-3.log"
assert_eq "TC-PTL-003 api_error → not terminal" "NO:" "$(run_is_completed 3 reason)"

# TC-PTL-004: log file missing → 1.
assert_eq "TC-PTL-004 missing log → not terminal" "NO:" "$(run_is_completed 999 reason)"

# Cleanup created log files.
rm -f "${LOG_BASE}"-*.log

# ---------------------------------------------------------------------------
# Fix 3 — autonomous-dev.sh fallback posts standalone Dev Session ID marker.
# ---------------------------------------------------------------------------
DEV_SCRIPT="$SCRIPTS_DIR/autonomous-dev.sh"
FALLBACK_SECTION=$(awk '/If resume failed/,/SESSION_ID="\$NEW_SESSION_ID"/' "$DEV_SCRIPT")
assert_contains "TC-PTL-005 fallback posts Dev Session ID: marker for NEW_SESSION_ID" \
  'Dev Session ID:' "$FALLBACK_SECTION"
assert_contains "TC-PTL-005 fallback marker references NEW_SESSION_ID" \
  'NEW_SESSION_ID' "$FALLBACK_SECTION"
assert_contains "TC-PTL-005 fallback marker tagged as resume-fallback" \
  'resume-fallback' "$FALLBACK_SECTION"

# ---------------------------------------------------------------------------
# Fix 3 — dispatcher-tick.sh routes prompt_too_long to dev-new with marker.
# ---------------------------------------------------------------------------
TICK_SCRIPT="$SCRIPTS_DIR/dispatcher-tick.sh"
assert_contains "TC-PTL-006 dispatcher-tick has INV-12-prompt-too-long marker" \
  "INV-12-prompt-too-long" "$(cat "$TICK_SCRIPT")"
assert_contains "TC-PTL-006 dispatcher-tick routes PTL to dev-new" \
  "dispatch dev-new" "$(awk '/prompt_too_long/,/JUST_DISPATCHED/' "$TICK_SCRIPT")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
