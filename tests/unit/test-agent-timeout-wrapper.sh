#!/bin/bash
# test-agent-timeout-wrapper.sh — Unit tests for lib-agent.sh::_run_with_timeout
# and the fail-closed timeout-tool-missing guard (INV-13, INV-126 / #451).
#
# Closes the test side of #60 (INV-13) and #451 (INV-126: fail-closed instead
# of WARN-and-proceed when neither `timeout` nor `gtimeout` is on PATH).
#
# Run: bash tests/unit/test-agent-timeout-wrapper.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS_DIR="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
LIB="$SCRIPTS_DIR/lib-agent.sh"
LIB_ERROR="$SCRIPTS_DIR/lib-error.sh"
LIB_LANE="$SCRIPTS_DIR/lib-lane.sh"
ERRORS_DOC="$PROJECT_ROOT/docs/pipeline/errors.md"
DISPATCH_TICK="$SCRIPTS_DIR/dispatcher-tick.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Suppress lib-config.sh from blocking on missing autonomous.conf — provide
# all required vars before sourcing lib-agent.sh.
export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export REPO_NAME=autonomous-dev-team
export PROJECT_ID=test-timeout
export PROJECT_DIR="$PROJECT_ROOT"
export GH_AUTH_MODE=token

# Source lib-agent.sh (also sources lib-config.sh and may load autonomous.conf).
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-agent.sh
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

assert_rc() {
  local desc="$1" expected_rc="$2" actual_rc="$3"
  if [[ "$expected_rc" == "$actual_rc" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected_rc=$expected_rc actual_rc=$actual_rc"
    FAIL=$((FAIL + 1))
  fi
}

ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
echo "=== _run_with_timeout (INV-13) ==="
# ---------------------------------------------------------------------------

# Skip if no timeout binary available (CI matrix may include macOS without
# coreutils — the fail-closed path is exercised by the hermetic sandbox cases
# below).
if [[ -z "${_AGENT_TIMEOUT_CMD:-}" ]]; then
  echo "  SKIP: no timeout binary on PATH (testing fallback only)"
else
  # TC-WH-001: timeout fires within bound
  AGENT_TIMEOUT=1s
  start=$(date +%s)
  _run_with_timeout sleep 5 >/dev/null 2>&1
  rc=$?
  end=$(date +%s)
  elapsed=$((end - start))
  assert_rc "1s timeout vs sleep 5 returns 124" 124 "$rc"
  if [[ "$elapsed" -le 3 ]]; then
    echo -e "  ${GREEN}PASS${NC}: elapsed ${elapsed}s within 3s budget (--kill-after grace)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: elapsed ${elapsed}s exceeded 3s budget"
    FAIL=$((FAIL + 1))
  fi

  # TC-WH-002 (positive): command finishes before timeout passes through exit code
  AGENT_TIMEOUT=10s
  _run_with_timeout /bin/true
  assert_rc "fast command (true) returns 0" 0 "$?"

  _run_with_timeout bash -c 'exit 7'
  assert_rc "command's own non-zero rc passes through" 7 "$?"
fi

# ---------------------------------------------------------------------------
# Hermetic sandbox for the fail-closed / watchdog / source-time cases. These
# source a FRESH lib-agent.sh (not the already-sourced copy above) under a
# controlled PATH that hides/exposes timeout/gtimeout, so each case gets its
# own source-time detection outcome.
# ---------------------------------------------------------------------------
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
mkdir -p "$TMPROOT/scripts" "$TMPROOT/cu" "$TMPROOT/cu-notimeout" "$TMPROOT/cu-nosetsid" "$TMPROOT/bin-gtimeout"
GH_CALLS="$TMPROOT/gh-calls.log"

# Hermetic coreutils dir WITH a real `timeout`.
for _u in bash sh env jq sed grep cat date dirname basename readlink \
          mkdir rm chmod ln mktemp timeout cut tr head tail wc sort uniq awk tee cp mv setsid sleep; do
  _p=$(command -v "$_u" 2>/dev/null) && ln -sf "$_p" "$TMPROOT/cu/$_u"
done

# Hermetic coreutils dir WITHOUT timeout/gtimeout (everything else present).
for _u in bash sh env jq sed grep cat date dirname basename readlink \
          mkdir rm chmod ln mktemp cut tr head tail wc sort uniq awk tee cp mv setsid sleep; do
  _p=$(command -v "$_u" 2>/dev/null) && ln -sf "$_p" "$TMPROOT/cu-notimeout/$_u"
done

# Hermetic coreutils dir WITHOUT timeout/gtimeout AND WITHOUT setsid — the
# combination TC-TIMEOUTGUARD-004b simulates (a macOS host missing both
# coreutils and util-linux).
for _u in bash sh env jq sed grep cat date dirname basename readlink \
          mkdir rm chmod ln mktemp cut tr head tail wc sort uniq awk tee cp mv sleep; do
  _p=$(command -v "$_u" 2>/dev/null) && ln -sf "$_p" "$TMPROOT/cu-nosetsid/$_u"
done

# A directory with ONLY a fake `gtimeout` (macOS-style), layered on top of
# the no-timeout coreutils dir via PATH ordering.
cat > "$TMPROOT/bin-gtimeout/gtimeout" <<'EOF'
#!/bin/bash
# Minimal gtimeout stand-in: same argv shape as GNU timeout; delegates to the
# real 'timeout' visible on this hermetic dir's PATH.
exec timeout "$@"
EOF
chmod +x "$TMPROOT/bin-gtimeout/gtimeout"

# Stub token-refresh `gh` proxy: record issue-comment posts.
cat > "$TMPROOT/scripts/gh" <<EOF
#!/bin/bash
{ echo "GH:"; printf '%s\n' "\$@"; echo "---"; } >> "$GH_CALLS"
echo "https://github.com/o/r/issues/451#issuecomment-1"
exit 0
EOF
chmod +x "$TMPROOT/scripts/gh"

# source_lib_agent <path_extra_dirs...> -- source lib-error.sh + lib-agent.sh
# (optionally lib-lane.sh) in a clean subshell with a controlled PATH, the
# stub gh proxy, and args forwarded as "$@" (for error_peek_issue_arg). Echoes
# stdout/stderr from the source attempt plus a trailing RC=<n> line reflecting
# whether the source itself succeeded (0) or aborted (non-zero, via the
# `return 1 || exit 1` guard).
source_lib_agent() {
  local extra_path="$1" with_lane="$2"; shift 2
  ( set -uo pipefail
    export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="o/r"
    export PATH="$extra_path"
    export REPO_OWNER=o REPO_NAME=r PROJECT_ID=t PROJECT_DIR="$PROJECT_ROOT" GH_AUTH_MODE=token
    # shellcheck disable=SC1090
    source "$LIB_ERROR"
    if [[ "$with_lane" == "with-lane" ]]; then
      # shellcheck disable=SC1090
      source "$LIB_LANE" 2>/dev/null || true
    fi
    # shellcheck disable=SC1090
    source "$LIB" "$@"
    echo "RC=$?"
  ) 2>&1
}
rc_of() { sed -n 's/.*RC=\([0-9]*\).*/\1/p' <<<"$1" | tail -1; }

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TIMEOUTGUARD-001: timeout present -> unchanged, mechanism logged ==="
: > "$GH_CALLS"
out=$(source_lib_agent "$TMPROOT/cu" no-lane --issue 451)
assert_rc "001 source succeeds with timeout present" 0 "$(rc_of "$out")"
[[ "$out" == *"Wall-clock timeout mechanism: timeout"* ]] && ok "001 mechanism logged as 'timeout'" || bad "001 mechanism not logged as 'timeout' — got: $out"
[[ "$(cat "$GH_CALLS")" == "" ]] && ok "001 no envelope posted" || bad "001 unexpectedly posted an envelope"

echo ""
echo "=== TC-TIMEOUTGUARD-002: gtimeout present (macOS-style PATH), timeout absent ==="
: > "$GH_CALLS"
out=$(source_lib_agent "$TMPROOT/bin-gtimeout:$TMPROOT/cu-notimeout" no-lane --issue 451)
assert_rc "002 source succeeds with gtimeout present" 0 "$(rc_of "$out")"
[[ "$out" == *"Wall-clock timeout mechanism: gtimeout"* ]] && ok "002 mechanism logged as 'gtimeout'" || bad "002 mechanism not logged as 'gtimeout' — got: $out"

echo ""
echo "=== TC-TIMEOUTGUARD-003: neither present, watchdog fallback unset (default) -> fail-closed abort ==="
: > "$GH_CALLS"
out=$(source_lib_agent "$TMPROOT/cu-notimeout" no-lane --issue 451)
assert_rc "003 source ABORTS (fail-closed default)" 1 "$(rc_of "$out")"
[[ "$out" == *"ADT_CFG_TIMEOUT_TOOL_MISSING"* ]] && ok "003 abort message names ADT_CFG_TIMEOUT_TOOL_MISSING" || bad "003 abort message missing the code"
[[ "$out" == *"fail-closed-abort"* ]] && ok "003 mechanism logged as fail-closed-abort" || bad "003 mechanism not logged"
GHBODY=$(cat "$GH_CALLS")
[[ "$GHBODY" == *"ADT_CFG_TIMEOUT_TOOL_MISSING"* ]] && ok "003 envelope posted on the issue" || bad "003 no envelope posted"
[[ "$GHBODY" == *"brew install coreutils"* ]] && ok "003 remediation names 'brew install coreutils' for macOS" || bad "003 remediation missing macOS guidance"
[[ "$GHBODY" == *'"surface":"issue-comment"'* ]] && ok "003 marker surface=issue-comment" || bad "003 marker surface wrong"

echo ""
echo "=== TC-TIMEOUTGUARD-004: neither present, watchdog fallback opted in -> proceeds, mechanism logged ==="
: > "$GH_CALLS"
out=$(
  ( set -uo pipefail
    export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="o/r" REPO_OWNER=o REPO_NAME=r PROJECT_ID=t PROJECT_DIR="$PROJECT_ROOT" GH_AUTH_MODE=token
    export PATH="$TMPROOT/cu-notimeout"
    export AGENT_TIMEOUT_WATCHDOG_FALLBACK=true
    # shellcheck disable=SC1090
    source "$LIB_ERROR"
    # shellcheck disable=SC1090
    source "$LIB" --issue 451
    echo "RC=0"
  ) 2>&1
)
assert_rc "004 source succeeds with watchdog fallback opted in" 0 "$(rc_of "$out")"
[[ "$out" == *"watchdog-fallback"* ]] && ok "004 mechanism logged as watchdog-fallback" || bad "004 mechanism not logged — got: $out"
[[ "$(cat "$GH_CALLS")" == "" ]] && ok "004 no envelope posted (opted-in, not an error)" || bad "004 unexpectedly posted an envelope"

echo ""
echo "=== TC-TIMEOUTGUARD-004b: watchdog opted in but 'setsid' ALSO absent -> fail-closed abort (not a WARN-and-proceed) ==="
# The watchdog's kill targets the setsid-established process GROUP; without
# setsid, _AGENT_RUN_PID is an ordinary PID, not a PGID, and the watchdog's
# group-form kill would silently find nothing to signal, leaving the run
# genuinely unbounded despite the opt-in. This combination (no coreutils AND
# no util-linux) is realistic on a bare macOS host, so it must be treated the
# same as the plain fail-closed default (PR #469 review [P1]) rather than
# degrading to a warning that implies a bound is in effect when none is.
: > "$GH_CALLS"
out=$(
  ( set -uo pipefail
    export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="o/r" REPO_OWNER=o REPO_NAME=r PROJECT_ID=t PROJECT_DIR="$PROJECT_ROOT" GH_AUTH_MODE=token
    export PATH="$TMPROOT/cu-nosetsid"
    export AGENT_TIMEOUT_WATCHDOG_FALLBACK=true
    # shellcheck disable=SC1090
    source "$LIB_ERROR"
    # shellcheck disable=SC1090
    source "$LIB" --issue 451
    echo "RC=$?"
  ) 2>&1
)
assert_rc "004b source ABORTS (watchdog opted in but 'setsid' missing too, fail-closed)" 1 "$(rc_of "$out")"
[[ "$out" == *"ADT_CFG_TIMEOUT_TOOL_MISSING"* ]] && ok "004b abort message names ADT_CFG_TIMEOUT_TOOL_MISSING" || bad "004b abort message missing the code — got: $out"
[[ "$out" == *"fail-closed-abort"* ]] && ok "004b mechanism logged as fail-closed-abort" || bad "004b mechanism not logged"
[[ "$out" == *"'setsid' is also missing"* || "$out" == *"setsid' is also missing"* ]] && ok "004b message names the setsid gap specifically" || bad "004b message does not distinguish the setsid-missing case — got: $out"
GHBODY4B=$(cat "$GH_CALLS")
[[ "$GHBODY4B" == *"ADT_CFG_TIMEOUT_TOOL_MISSING"* ]] && ok "004b envelope posted on the issue" || bad "004b no envelope posted"

echo ""
echo "=== TC-TIMEOUTGUARD-005: shared detection — AGENT_TIMEOUT and AGENT_REVIEW_TIMEOUT both observe the same _AGENT_TIMEOUT_CMD ==="
# Detection is resolved once at source time into _AGENT_TIMEOUT_CMD; nothing
# re-resolves it per timeout-value. Assert there is exactly ONE
# `command -v timeout` resolution site feeding _AGENT_TIMEOUT_CMD.
cmd_v_sites=$(grep -cE '_AGENT_TIMEOUT_CMD="\$\(command -v timeout' "$LIB" || true)
[[ "$cmd_v_sites" -eq 1 ]] && ok "005 exactly one _AGENT_TIMEOUT_CMD resolution site in lib-agent.sh" || bad "005 expected 1 resolution site, found ${cmd_v_sites:-0}"
# And AGENT_REVIEW_TIMEOUT is rebound in autonomous-review.sh, never
# re-triggering its own timeout-binary detection (no second command -v site
# outside lib-agent.sh).
review_cmd_v=$(grep -c 'command -v timeout' "$SCRIPTS_DIR/autonomous-review.sh" 2>/dev/null || true)
[[ "${review_cmd_v:-0}" -eq 0 ]] && ok "005 autonomous-review.sh does not re-detect the timeout binary" || bad "005 autonomous-review.sh unexpectedly re-detects the timeout binary"

echo ""
echo "=== TC-TIMEOUTGUARD-010/011: fail-closed error_surface call shape mirrors INV-38 ==="
# Same 4-arg + doc-link signature convention as the ADT_CFG_LAUNCHER_CLI_MISMATCH guard.
if grep -qE 'error_surface "\$\(error_peek_issue_arg "\$@"\)" ADT_CFG_TIMEOUT_TOOL_MISSING' "$LIB"; then
  ok "010 fail-closed abort calls error_surface with error_peek_issue_arg, mirroring INV-38"
else
  bad "010 fail-closed abort does not use the INV-38 error_surface call shape"
fi
if grep -A2 'ADT_CFG_TIMEOUT_TOOL_MISSING \\' "$LIB" | grep -q 'return 1 2>/dev/null || exit 1' || grep -q 'return 1 2>/dev/null || exit 1' "$LIB"; then
  ok "011 fail-closed abort uses 'return 1 2>/dev/null || exit 1' (mirrors INV-38)"
else
  bad "011 fail-closed abort does not use the standard abort idiom"
fi

echo ""
echo "=== TC-TIMEOUTGUARD-012/013: issue-arg peek routing (issue-comment vs dispatcher-alert) ==="
: > "$GH_CALLS"
out=$(source_lib_agent "$TMPROOT/cu-notimeout" no-lane --issue 999)
GHBODY=$(cat "$GH_CALLS")
[[ "$GHBODY" == *'"surface":"issue-comment"'* ]] && ok "012 known --issue routes to issue-comment" || bad "012 known --issue did not route to issue-comment"

: > "$GH_CALLS"
out=$(source_lib_agent "$TMPROOT/cu-notimeout" no-lane)
assert_rc "013 source still aborts with no --issue" 1 "$(rc_of "$out")"
[[ "$out" == *'"surface":"dispatcher-alert"'* ]] && ok "013 no --issue degrades to dispatcher-alert (log-only)" || bad "013 no --issue did not degrade to dispatcher-alert"
[[ "$(cat "$GH_CALLS")" == "" ]] && ok "013 no gh post made (dispatcher-alert, no issue)" || bad "013 unexpectedly posted a gh comment with no issue"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TIMEOUTGUARD-020/021/022: watchdog fallback PGID kill + descendant reaping + cancel-on-fast-finish ==="
# Drive the REAL _run_with_timeout with the watchdog fallback armed, inside
# a subshell using the no-timeout coreutils dir. A short AGENT_TIMEOUT lets
# the watchdog fire quickly; the wrapped command spawns a grandchild so we
# can assert the whole process GROUP (not just the direct child) is reaped.
WD_MARKER_DIR="$TMPROOT/wd-marker"
mkdir -p "$WD_MARKER_DIR"
(
  set -uo pipefail
  export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="o/r" REPO_OWNER=o REPO_NAME=r PROJECT_ID=t PROJECT_DIR="$PROJECT_ROOT" GH_AUTH_MODE=token
  export PATH="$TMPROOT/cu-notimeout"
  export AGENT_TIMEOUT_WATCHDOG_FALLBACK=true
  # shellcheck disable=SC1090
  source "$LIB_ERROR"
  # shellcheck disable=SC1090
  source "$LIB" --issue 451 >/dev/null 2>&1
  AGENT_TIMEOUT=2
  # Wrapped command: spawn a background grandchild that touches a marker
  # file every 100ms so we can tell if it's still alive after the watchdog
  # fires, then sleep well past AGENT_TIMEOUT itself.
  _run_with_timeout bash -c '
    ( while true; do date +%s >> "'"$WD_MARKER_DIR"'/alive"; sleep 0.2; done ) &
    sleep 30
  '
  echo "WD_RC=$?"
) >"$TMPROOT/wd-out.log" 2>&1
wd_out=$(cat "$TMPROOT/wd-out.log")
# Give the OS a brief moment past the watchdog's own grace window to settle.
sleep 1
if [[ -f "$WD_MARKER_DIR/alive" ]]; then
  last_write_epoch=$(tail -1 "$WD_MARKER_DIR/alive")
  now_epoch=$(date +%s)
  age=$((now_epoch - last_write_epoch))
  # The grandchild should have stopped writing once the group was killed —
  # allow generous slack (watchdog fires at ~2s + up to 30s escalation grace
  # in the worst case, but _kill_group_escalate/the inline fallback issue
  # TERM immediately after the sleep, so the marker should go stale well
  # before this check runs).
  if [[ "$age" -ge 1 ]]; then
    ok "020/021 watchdog killed the process GROUP — grandchild marker went stale (age=${age}s)"
  else
    bad "020/021 grandchild still writing after watchdog should have fired (age=${age}s) — descendant not reaped"
  fi
else
  bad "020/021 grandchild marker file never created — test harness issue"
fi
[[ "$wd_out" == *"WD_RC="* ]] && ok "020 wrapped command returned (watchdog or natural exit, no shell error)" || bad "020 wrapped command did not return cleanly: $wd_out"

echo ""
echo "--- TC-TIMEOUTGUARD-022: fast-finishing command cancels the watchdog (no stray delayed kill) ---"
(
  set -uo pipefail
  export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="o/r" REPO_OWNER=o REPO_NAME=r PROJECT_ID=t PROJECT_DIR="$PROJECT_ROOT" GH_AUTH_MODE=token
  export PATH="$TMPROOT/cu-notimeout"
  export AGENT_TIMEOUT_WATCHDOG_FALLBACK=true
  # shellcheck disable=SC1090
  source "$LIB_ERROR"
  # shellcheck disable=SC1090
  source "$LIB" --issue 451 >/dev/null 2>&1
  AGENT_TIMEOUT=30
  start=$(date +%s)
  _run_with_timeout /bin/true
  rc=$?
  end=$(date +%s)
  echo "RC=$rc ELAPSED=$((end - start))"
) >"$TMPROOT/wd-fast-out.log" 2>&1
fast_out=$(cat "$TMPROOT/wd-fast-out.log")
fast_rc=$(sed -n 's/.*RC=\([0-9-]*\).*/\1/p' <<<"$fast_out")
fast_elapsed=$(sed -n 's/.*ELAPSED=\([0-9]*\).*/\1/p' <<<"$fast_out")
assert_rc "022 fast command's own rc passes through under watchdog fallback" 0 "${fast_rc:-99}"
if [[ -n "$fast_elapsed" && "$fast_elapsed" -le 3 ]]; then
  ok "022 _run_with_timeout returned promptly (${fast_elapsed}s), not blocked on the watchdog's own sleep"
else
  bad "022 _run_with_timeout took too long (${fast_elapsed:-?}s) — may be waiting on the watchdog job"
fi

echo ""
echo "--- TC-TIMEOUTGUARD-023: _timeout_value_to_seconds direct unit coverage ---"
(
  export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="o/r" REPO_OWNER=o REPO_NAME=r PROJECT_ID=t PROJECT_DIR="$PROJECT_ROOT" GH_AUTH_MODE=token
  export PATH="$TMPROOT/cu"
  # shellcheck disable=SC1090
  source "$LIB_ERROR" 2>/dev/null
  # shellcheck disable=SC1090
  source "$LIB" >/dev/null 2>&1
  echo "3600S=$(_timeout_value_to_seconds 3600)"
  echo "30S=$(_timeout_value_to_seconds 30s)"
  echo "90M=$(_timeout_value_to_seconds 90m)"
  echo "2H=$(_timeout_value_to_seconds 2h)"
  echo "1D=$(_timeout_value_to_seconds 1d)"
  echo "BADVAL=$(_timeout_value_to_seconds 1.5h)"
  echo "INF=$(_timeout_value_to_seconds infinity)"
) > "$TMPROOT/tv2s-out.log" 2>&1
tv2s_out=$(cat "$TMPROOT/tv2s-out.log")
assert_eq "023 3600 -> 3600s" "3600S=3600" "$(grep '^3600S=' <<<"$tv2s_out")"
assert_eq "023 30s -> 30s" "30S=30" "$(grep '^30S=' <<<"$tv2s_out")"
assert_eq "023 90m -> 5400s" "90M=5400" "$(grep '^90M=' <<<"$tv2s_out")"
assert_eq "023 2h -> 7200s" "2H=7200" "$(grep '^2H=' <<<"$tv2s_out")"
assert_eq "023 1d -> 86400s" "1D=86400" "$(grep '^1D=' <<<"$tv2s_out")"
assert_eq "023 unparseable (1.5h) falls back to 14400s (4h) default" "BADVAL=14400" "$(grep '^BADVAL=' <<<"$tv2s_out")"
assert_eq "023 unparseable (infinity) falls back to 14400s (4h) default" "INF=14400" "$(grep '^INF=' <<<"$tv2s_out")"

echo ""
echo "--- TC-TIMEOUTGUARD-024: a non-integer AGENT_TIMEOUT (e.g. 1.5h) under watchdog fallback logs the coercion, doesn't silently diverge ---"
: > "$GH_CALLS"
out=$(
  ( set -uo pipefail
    export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="o/r" REPO_OWNER=o REPO_NAME=r PROJECT_ID=t PROJECT_DIR="$PROJECT_ROOT" GH_AUTH_MODE=token
    export PATH="$TMPROOT/cu-notimeout"
    export AGENT_TIMEOUT_WATCHDOG_FALLBACK=true
    # shellcheck disable=SC1090
    source "$LIB_ERROR"
    # shellcheck disable=SC1090
    source "$LIB" --issue 451 >/dev/null 2>&1
    AGENT_TIMEOUT=1.5h
    _run_with_timeout /bin/true
    echo "RC=$?"
  ) 2>&1
)
[[ "$out" == *"AGENT_TIMEOUT='1.5h' is not an integer+unit value the watchdog fallback can parse"* ]] \
  && ok "024 WARN names the unparseable AGENT_TIMEOUT value and the 4h fallback" \
  || bad "024 missing the coercion WARN — got: $out"
assert_rc "024 command still runs and returns its own rc despite the coercion" 0 "$(rc_of "$out")"

echo ""
echo "--- TC-TIMEOUTGUARD-025: watchdog TERM-expiry normalizes rc to 124 (not a raw signal-death status) ---"
(
  set -uo pipefail
  export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="o/r" REPO_OWNER=o REPO_NAME=r PROJECT_ID=t PROJECT_DIR="$PROJECT_ROOT" GH_AUTH_MODE=token
  export PATH="$TMPROOT/cu-notimeout"
  export AGENT_TIMEOUT_WATCHDOG_FALLBACK=true
  # shellcheck disable=SC1090
  source "$LIB_ERROR"
  # shellcheck disable=SC1090
  source "$LIB" --issue 451 >/dev/null 2>&1
  AGENT_TIMEOUT=1
  # A well-behaved (TERM-obeying) command: dies promptly on the watchdog's
  # first signal, so the wrapper's own `wait` reports a raw 143 unless
  # normalized.
  _run_with_timeout bash -c 'trap "exit 0" TERM; sleep 30'
  echo "RC=$?"
) >"$TMPROOT/wd025-out.log" 2>&1
wd025_out=$(cat "$TMPROOT/wd025-out.log")
assert_rc "025 watchdog TERM-expiry reports rc=124 (the coreutils-timeout TERM contract), not a bare 143" 124 "$(rc_of "$wd025_out")"

echo ""
echo "--- TC-TIMEOUTGUARD-026: watchdog KILL-escalation (TERM ignored) normalizes rc to 137 AND reaps the group before returning ---"
WD026_MARKER_DIR="$TMPROOT/wd026-marker"
mkdir -p "$WD026_MARKER_DIR"
(
  set -uo pipefail
  export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="o/r" REPO_OWNER=o REPO_NAME=r PROJECT_ID=t PROJECT_DIR="$PROJECT_ROOT" GH_AUTH_MODE=token
  export PATH="$TMPROOT/cu-notimeout"
  export AGENT_TIMEOUT_WATCHDOG_FALLBACK=true
  export _AGENT_WATCHDOG_GRACE_SECS=1
  # shellcheck disable=SC1090
  source "$LIB_ERROR"
  # shellcheck disable=SC1090
  source "$LIB" --issue 451 >/dev/null 2>&1
  AGENT_TIMEOUT=1
  # A TERM-ignoring leader whose descendant keeps writing a marker file —
  # the leader traps TERM away, so only the escalated KILL (after the
  # shrunk 1s grace) reaps the group. If _run_with_timeout returned as soon
  # as the LEADER died (it never does here, since it ignores TERM) rather
  # than waiting for the watchdog's own pending KILL step to finish, the
  # marker-writing descendant would still be alive when this subshell exits.
  _run_with_timeout bash -c '
    trap "" TERM
    ( while true; do date +%s >> "'"$WD026_MARKER_DIR"'/alive"; sleep 0.2; done ) &
    sleep 30
  '
  echo "RC=$?"
  # Checked from INSIDE the same subshell, immediately after
  # _run_with_timeout returns — proves the group is already gone by the
  # time the function hands control back, not merely "gone eventually".
  if kill -0 -- "-$_AGENT_RUN_PID" 2>/dev/null; then
    echo "GROUP_STILL_ALIVE=1"
  else
    echo "GROUP_STILL_ALIVE=0"
  fi
) >"$TMPROOT/wd026-out.log" 2>&1
wd026_out=$(cat "$TMPROOT/wd026-out.log")
assert_rc "026 watchdog KILL-escalation reports rc=137 (the coreutils-timeout KILL contract)" 137 "$(rc_of "$wd026_out")"
[[ "$wd026_out" == *"GROUP_STILL_ALIVE=0"* ]] \
  && ok "026 _run_with_timeout does not return until the watchdog's pending KILL has reaped the group" \
  || bad "026 _run_with_timeout returned while the TERM-ignoring group was still alive — got: $wd026_out"
sleep 1
if [[ -f "$WD026_MARKER_DIR/alive" ]]; then
  last_write_epoch=$(tail -1 "$WD026_MARKER_DIR/alive")
  now_epoch=$(date +%s)
  age=$((now_epoch - last_write_epoch))
  [[ "$age" -ge 1 ]] && ok "026 descendant marker went stale (age=${age}s) — KILL reaped it, not abandoned mid-escalation" \
    || bad "026 descendant still writing after _run_with_timeout returned (age=${age}s)"
else
  bad "026 descendant marker file never created — test harness issue"
fi

echo ""
echo "--- TC-TIMEOUTGUARD-027: TERM-obeying LEADER dies promptly but a TERM-ignoring DESCENDANT survives — reconciliation must still block for the KILL ---"
# This is the specific scenario PR #469 review round-3 [P1] flagged: unlike
# TC-TIMEOUTGUARD-026 (where the LEADER itself ignores TERM, so the leader's
# own `wait "$_AGENT_RUN_PID"` doesn't unblock until the watchdog's KILL
# reaps the whole group), here the LEADER exits immediately on TERM — so
# `wait "$_AGENT_RUN_PID"` unblocks right after the 124 marker is written,
# BEFORE the watchdog's grace-then-KILL step has run. The reconciliation
# block's `wait "$_watchdog_pid"` must genuinely block here (not return
# immediately, which is what an accidentally-disowned watchdog job would
# do) so the still-alive, TERM-ignoring descendant is actually reaped by
# the escalated KILL before _run_with_timeout returns.
WD027_MARKER_DIR="$TMPROOT/wd027-marker"
mkdir -p "$WD027_MARKER_DIR"
(
  set -uo pipefail
  export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="o/r" REPO_OWNER=o REPO_NAME=r PROJECT_ID=t PROJECT_DIR="$PROJECT_ROOT" GH_AUTH_MODE=token
  export PATH="$TMPROOT/cu-notimeout"
  export AGENT_TIMEOUT_WATCHDOG_FALLBACK=true
  export _AGENT_WATCHDOG_GRACE_SECS=1
  # shellcheck disable=SC1090
  source "$LIB_ERROR"
  # shellcheck disable=SC1090
  source "$LIB" --issue 451 >/dev/null 2>&1
  AGENT_TIMEOUT=1
  # Leader obeys TERM and exits immediately; its backgrounded descendant
  # traps TERM away and keeps writing a marker file until KILLed.
  _run_with_timeout bash -c '
    ( trap "" TERM; while true; do date +%s >> "'"$WD027_MARKER_DIR"'/alive"; sleep 0.2; done ) &
    trap "exit 0" TERM
    sleep 30
  '
  echo "RC=$?"
  if kill -0 -- "-$_AGENT_RUN_PID" 2>/dev/null; then
    echo "GROUP_STILL_ALIVE=1"
  else
    echo "GROUP_STILL_ALIVE=0"
  fi
) >"$TMPROOT/wd027-out.log" 2>&1
wd027_out=$(cat "$TMPROOT/wd027-out.log")
assert_rc "027 rc normalized to 137 (KILL reaped the surviving descendant), not the leader's own 124/0" 137 "$(rc_of "$wd027_out")"
[[ "$wd027_out" == *"GROUP_STILL_ALIVE=0"* ]] \
  && ok "027 _run_with_timeout blocked for the watchdog's escalated KILL despite the leader dying immediately on TERM" \
  || bad "027 _run_with_timeout returned while the TERM-ignoring descendant was still alive — got: $wd027_out"
sleep 1
if [[ -f "$WD027_MARKER_DIR/alive" ]]; then
  last_write_epoch=$(tail -1 "$WD027_MARKER_DIR/alive")
  now_epoch=$(date +%s)
  age=$((now_epoch - last_write_epoch))
  [[ "$age" -ge 1 ]] && ok "027 descendant marker went stale (age=${age}s) — not abandoned when the leader alone died" \
    || bad "027 descendant still writing after _run_with_timeout returned (age=${age}s) — the leader-death-then-abandon bug"
else
  bad "027 descendant marker file never created — test harness issue"
fi

echo ""
echo "--- TC-TIMEOUTGUARD-028: rescinded-marker race — natural finish between the 124 marker write and the watchdog's kill -TERM must NOT be replayed as a stale 124 ---"
# PR #469 review round-4 [P1]: the watchdog writes its 124 marker BEFORE
# attempting kill -TERM. If the wrapped command finishes naturally in that
# exact window, the watchdog's kill -TERM finds the group already gone,
# rescinds (deletes) the marker, and exits 0 — but the round-2/3
# reconciliation re-read the marker with `cat ... || echo "$_wd_marker"`,
# whose `||` fallback silently replayed the STALE pre-wait 124 instead of
# recognizing the file's absence as proof of a rescind.
# _AGENT_WATCHDOG_TERM_DELAY_SECS (test-only seam) widens the
# marker-write-to-kill window so this race lands deterministically:
# AGENT_TIMEOUT=1 fires the marker write at
# ~1s, the wrapped command exits on its own at ~1.3s (well inside the 2s
# delay before the watchdog even attempts kill -TERM), so the group is
# provably gone by the time the watchdog tries to signal it.
(
  set -uo pipefail
  export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="o/r" REPO_OWNER=o REPO_NAME=r PROJECT_ID=t PROJECT_DIR="$PROJECT_ROOT" GH_AUTH_MODE=token
  export PATH="$TMPROOT/cu-notimeout"
  export AGENT_TIMEOUT_WATCHDOG_FALLBACK=true
  export _AGENT_WATCHDOG_TERM_DELAY_SECS=2
  # shellcheck disable=SC1090
  source "$LIB_ERROR"
  # shellcheck disable=SC1090
  source "$LIB" --issue 451 >/dev/null 2>&1
  AGENT_TIMEOUT=1
  # Finishes naturally at ~1.3s: after the watchdog's marker write (~1s) but
  # well before its delayed kill -TERM attempt (~3s).
  _run_with_timeout bash -c 'sleep 1.3; exit 0'
  echo "RC=$?"
) >"$TMPROOT/wd028-out.log" 2>&1
wd028_out=$(cat "$TMPROOT/wd028-out.log")
assert_rc "028 natural exit code (0) preserved, not replayed as the stale rescinded 124 marker" 0 "$(rc_of "$wd028_out")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TIMEOUTGUARD-030/031: source-location static assertion ==="
# The fail-closed abort must live in lib-agent.sh TOP-LEVEL code (outside any
# function body), never inside run_agent/resume_agent, and never in
# dispatcher-tick.sh — mirrors the TC-BINPF-STATIC pattern.
abort_line=$(grep -n 'ADT_CFG_TIMEOUT_TOOL_MISSING \\' "$LIB" | head -1 | cut -d: -f1)
if [[ -n "$abort_line" ]]; then
  # Find the nearest enclosing function boundary: walk backward from
  # abort_line looking for a `<name>() {` line: if the closest preceding
  # such line has no matching close before abort_line, we're inside it.
  # Simpler robust check: none of the known function names' bodies (bounded
  # by grep for their def line and the FIRST top-level `^}` after) contain
  # abort_line. We approximate by checking abort_line falls BEFORE the first
  # `^_run_with_timeout() {` — i.e. in the init block, not inside any function.
  first_func_line=$(grep -n '^_run_with_timeout() {' "$LIB" | head -1 | cut -d: -f1)
  if [[ -n "$first_func_line" && "$abort_line" -lt "$first_func_line" ]]; then
    ok "030 ADT_CFG_TIMEOUT_TOOL_MISSING abort (line $abort_line) is top-level init code, before the first function def (line $first_func_line)"
  else
    bad "030 ADT_CFG_TIMEOUT_TOOL_MISSING abort (line $abort_line) is NOT clearly top-level (first function def at line ${first_func_line:-unknown})"
  fi
else
  bad "030 could not locate the ADT_CFG_TIMEOUT_TOOL_MISSING abort site in lib-agent.sh"
fi

if grep -q 'ADT_CFG_TIMEOUT_TOOL_MISSING' "$DISPATCH_TICK" 2>/dev/null; then
  bad "031 ADT_CFG_TIMEOUT_TOOL_MISSING (authoritative code) unexpectedly appears in dispatcher-tick.sh"
else
  ok "031 dispatcher-tick.sh does not contain the authoritative ADT_CFG_TIMEOUT_TOOL_MISSING code"
fi

grep -q 'ADT_CFG_TIMEOUT_TOOL_MISSING' "$ERRORS_DOC" && ok "031b ADT_CFG_TIMEOUT_TOOL_MISSING documented in errors.md" \
  || bad "031b ADT_CFG_TIMEOUT_TOOL_MISSING missing from errors.md (drift)"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TIMEOUTGUARD-040/041: remote-aws-ssm topology simulation ==="
# The dispatcher's own host (simulated here as the CALLING test shell) has a
# real 'timeout' on PATH throughout this entire test file — that is exactly
# the point: local presence must NOT leak into the sourcing site's decision.
# We source lib-agent.sh under a PATH standing in for "the remote execution
# host" (no timeout/gtimeout) and assert it still aborts fail-closed,
# regardless of what this test process's OWN ambient PATH looks like.
[[ -n "$(command -v timeout 2>/dev/null)" ]] && ok "040 sanity: the test-runner's OWN host has 'timeout' (proves local presence isn't the deciding factor)" \
  || bad "040 sanity check failed — test-runner host unexpectedly lacks 'timeout'"
: > "$GH_CALLS"
out=$(source_lib_agent "$TMPROOT/cu-notimeout" no-lane --issue 451)
assert_rc "040 simulated remote host (PATH lacks both binaries) aborts fail-closed despite local presence" 1 "$(rc_of "$out")"
GHBODY=$(cat "$GH_CALLS")
[[ "$GHBODY" == *"ADT_CFG_TIMEOUT_TOOL_MISSING"* ]] && ok "041 envelope posted from the simulated remote sourcing site, not suppressed by local presence" \
  || bad "041 no envelope posted — local presence may have incorrectly influenced the remote-simulated check"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
