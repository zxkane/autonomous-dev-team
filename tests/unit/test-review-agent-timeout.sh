#!/bin/bash
# test-review-agent-timeout.sh — issue #185 / INV-48 (+ INV-40 amendment).
#
# Per-side review wall-clock timeout (AGENT_REVIEW_TIMEOUT, 1h default) with a
# browser-mode E2E exclusion (E2E_BROWSER_TIMEOUT_SECONDS, default = the original
# 4h AGENT_TIMEOUT) and a timeout-veto: a review fan-out agent killed BY the
# timeout (rc 124/137) with no posted verdict is a deciding FAIL, not a silent
# `unavailable` drop.
#
# Four-pronged (the wrapper is too heavy to run end-to-end):
#   1. pure validator harness — lib-agent.sh::_is_positive_timeout_value;
#   2. pure no-verdict classifier + aggregation — lib-review-aggregate.sh
#      (_classify_noverdict_agent, _aggregate_review_verdicts with `timed-out`);
#   3. rebind-order simulation — extract the wrapper's source/rebind block and
#      assert the resolved AGENT_TIMEOUT / E2E_BROWSER_TIMEOUT_SECONDS (mirrors
#      test-wrapper-rebind-order.sh);
#   4. source-of-truth greps + conf/doc presence.
#
# Run: bash tests/unit/test-review-agent-timeout.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS_DIR="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
WRAPPER="$SCRIPTS_DIR/autonomous-review.sh"
DEV_WRAPPER="$SCRIPTS_DIR/autonomous-dev.sh"
AGENT_LIB="$SCRIPTS_DIR/lib-agent.sh"
AGG_LIB="$SCRIPTS_DIR/lib-review-aggregate.sh"
CONF_EXAMPLE="$SCRIPTS_DIR/autonomous.conf.example"
INVARIANTS="$PROJECT_ROOT/docs/pipeline/invariants.md"
FLOW="$PROJECT_ROOT/docs/pipeline/review-agent-flow.md"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected=[$expected]"; echo "      actual=  [$actual]"; FAIL=$((FAIL + 1))
  fi
}

assert_rc() {
  local desc="$1" expected_rc="$2" actual_rc="$3"
  if [[ "$expected_rc" == "$actual_rc" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected_rc=$expected_rc actual_rc=$actual_rc)"; FAIL=$((FAIL + 1))
  fi
}

assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"; FAIL=$((FAIL + 1))
  fi
}

assert_not_grep() {
  local desc="$1" pattern="$2" file="$3"
  if ! grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (matched: $pattern)"; FAIL=$((FAIL + 1))
  fi
}

# =========================================================================
echo "=== TC-RTO-VAL: _is_positive_timeout_value (lib-agent.sh) ==="
# =========================================================================
# Pure predicate: rc 0 for a positive coreutils-timeout value (n optionally
# suffixed s/m/h/d), rc != 0 otherwise. Rejects 0 (GNU `timeout 0` disables the
# cap), empty, non-numeric, fractional, negative.
#
# Source lib-agent.sh in a sandbox with the required conf vars exported so
# lib-config.sh does not block. env -u PROJECT_DIR avoids loading the live conf.
(
  export REPO=zxkane/autonomous-dev-team REPO_OWNER=zxkane REPO_NAME=autonomous-dev-team
  export PROJECT_ID=test-rto GH_AUTH_MODE=token
  export PROJECT_DIR="$PROJECT_ROOT"
  # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-agent.sh
  source "$AGENT_LIB"
  set +e

  v() { _is_positive_timeout_value "$1"; echo $?; }

  assert_rc "TC-RTO-VAL-01 '0' rejected"      1 "$(v 0)"
  assert_rc "TC-RTO-VAL-02 '0h' rejected"     1 "$(v 0h)"
  assert_rc "TC-RTO-VAL-03 '' rejected"       1 "$(v '')"
  assert_rc "TC-RTO-VAL-04 'abc' rejected"    1 "$(v abc)"
  assert_rc "TC-RTO-VAL-05 '1.5h' rejected"   1 "$(v 1.5h)"
  assert_rc "TC-RTO-VAL-06 '-5' rejected"     1 "$(v -- -5)"
  assert_rc "TC-RTO-VAL-06b '10x' rejected"   1 "$(v 10x)"
  assert_rc "TC-RTO-VAL-07 '90m' accepted"    0 "$(v 90m)"
  assert_rc "TC-RTO-VAL-08 '2h' accepted"     0 "$(v 2h)"
  assert_rc "TC-RTO-VAL-09 '3600' accepted"   0 "$(v 3600)"
  assert_rc "TC-RTO-VAL-10 '1d' accepted"     0 "$(v 1d)"
  assert_rc "TC-RTO-VAL-10b '30s' accepted"   0 "$(v 30s)"

  echo "$PASS $FAIL" > "${TMPDIR:-/tmp}/.rto-val-counts.$$"
)
# Merge the subshell's counts (the subshell cannot mutate parent PASS/FAIL).
if [[ -f "${TMPDIR:-/tmp}/.rto-val-counts.$$" ]]; then
  read -r _sp _sf < "${TMPDIR:-/tmp}/.rto-val-counts.$$"
  PASS=$((PASS + _sp)); FAIL=$((FAIL + _sf))
  rm -f "${TMPDIR:-/tmp}/.rto-val-counts.$$"
fi

# =========================================================================
echo ""
echo "=== TC-RTO-VETO: _classify_noverdict_agent + aggregation (INV-40 amendment) ==="
# =========================================================================
[[ -f "$AGG_LIB" ]] || { echo -e "  ${RED}FAIL${NC}: $AGG_LIB not found"; FAIL=$((FAIL + 1)); }
if [[ -f "$AGG_LIB" ]]; then
  # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-aggregate.sh
  source "$AGG_LIB"

  # rc → no-verdict terminal state.
  assert_eq "TC-RTO-VETO-01 rc 124 → timed-out"     "timed-out"    "$(_classify_noverdict_agent 124)"
  assert_eq "TC-RTO-VETO-02 rc 137 → timed-out"     "timed-out"    "$(_classify_noverdict_agent 137)"
  assert_eq "TC-RTO-VETO-03 rc 1 → unavailable"     "unavailable"  "$(_classify_noverdict_agent 1)"
  assert_eq "TC-RTO-VETO-04 rc 0 → unavailable"     "unavailable"  "$(_classify_noverdict_agent 0)"
  assert_eq "TC-RTO-VETO-04b rc 2 → unavailable"    "unavailable"  "$(_classify_noverdict_agent 2)"

  # Aggregation: timed-out is a deciding FAIL (veto).
  assert_eq "TC-RTO-VETO-05 pass+timed-out → fail (veto)"      "fail" "$(_aggregate_review_verdicts pass timed-out)"
  assert_eq "TC-RTO-VETO-06 single timed-out → fail (veto)"    "fail" "$(_aggregate_review_verdicts timed-out)"
  assert_eq "TC-RTO-VETO-09 timed-out+unavailable → fail"      "fail" "$(_aggregate_review_verdicts timed-out unavailable)"
  assert_eq "TC-RTO-VETO-09b timed-out+timed-out → fail"       "fail" "$(_aggregate_review_verdicts timed-out timed-out)"

  # INV-40 EXISTING truth table — must stay green (unavailable still dropped).
  assert_eq "TC-RTO-VETO-07 pass+unavailable → pass (unavailable dropped)" "pass"            "$(_aggregate_review_verdicts pass unavailable)"
  assert_eq "TC-RTO-VETO-08 unavailable+unavailable → all-unavailable"     "all-unavailable" "$(_aggregate_review_verdicts unavailable unavailable)"
  assert_eq "TC-RTO-VETO-10a both PASS → pass"                            "pass"            "$(_aggregate_review_verdicts pass pass)"
  assert_eq "TC-RTO-VETO-10b pass+fail → fail"                            "fail"            "$(_aggregate_review_verdicts pass fail)"
  assert_eq "TC-RTO-VETO-10c unavailable+fail → fail"                     "fail"            "$(_aggregate_review_verdicts unavailable fail)"
fi

# =========================================================================
echo ""
echo "=== TC-RTO-RES / TC-RTO-E2E: rebind-order simulation ==="
# =========================================================================
# Extract the wrapper's source/rebind block (same technique as
# test-wrapper-rebind-order.sh) and print the resolved review cap + browser cap.
simulate_review_timeout() {
  local conf_dir="$1"
  local tmp_script
  tmp_script=$(mktemp)
  {
    echo 'set -uo pipefail'
    echo "SCRIPT_DIR='$conf_dir'"
    echo "AUTONOMOUS_CONF='$conf_dir/autonomous.conf'"
    awk '
      /^SCRIPT_DIR=/ { capture = 1; next }
      /^: "\$\{[A-Z_]+:\?/ { capture = 0 }
      capture { print }
    ' "$WRAPPER"
    echo 'echo "RESOLVED_AGENT_TIMEOUT=$AGENT_TIMEOUT"'
    echo 'echo "RESOLVED_E2E_BROWSER=$E2E_BROWSER_TIMEOUT_SECONDS"'
    echo 'echo "ORIG_AGENT_TIMEOUT=${_ORIG_AGENT_TIMEOUT:-UNSET}"'
  } >"$tmp_script"
  bash "$tmp_script" 2>&1
  rm -f "$tmp_script"
}

build_review_sandbox() {
  local sandbox="$1"; shift
  mkdir -p "$sandbox"
  for f in lib-agent.sh lib-auth.sh lib-config.sh lib-review-bots.sh \
           lib-review-verdict.sh lib-review-aggregate.sh lib-review-resolve.sh \
           lib-review-poll.sh lib-review-mergeable.sh lib-review-e2e.sh \
           gh-app-token.sh gh-with-token-refresh.sh; do
    ln -sf "$SCRIPTS_DIR/$f" "$sandbox/$f"
  done
  cat >"$sandbox/autonomous.conf" <<CONF
PROJECT_ID="test-sandbox"
REPO="example/test"
REPO_OWNER="example"
REPO_NAME="test"
PROJECT_DIR="/tmp/sandbox"
AGENT_CMD="claude"
AGENT_REVIEW_CMD="claude"
AGENT_REVIEW_MODEL="sonnet"
AGENT_PERMISSION_MODE="bypassPermissions"
AGENT_TIMEOUT="4h"
GH_AUTH_MODE="token"
$*
CONF
}

# TC-RTO-RES-01: AGENT_REVIEW_TIMEOUT=2h → review cap 2h
SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
build_review_sandbox "$SB" 'AGENT_REVIEW_TIMEOUT="2h"'
out=$(simulate_review_timeout "$SB")
got=$(echo "$out" | grep '^RESOLVED_AGENT_TIMEOUT=' | cut -d= -f2)
assert_eq "TC-RTO-RES-01 AGENT_REVIEW_TIMEOUT=2h → review cap 2h" "2h" "$got"

# TC-RTO-RES-02: unset → 1h default
SB2=$(mktemp -d)
build_review_sandbox "$SB2"
out=$(simulate_review_timeout "$SB2")
got=$(echo "$out" | grep '^RESOLVED_AGENT_TIMEOUT=' | cut -d= -f2)
assert_eq "TC-RTO-RES-02 AGENT_REVIEW_TIMEOUT unset → 1h default" "1h" "$got"

# TC-RTO-RES-03: empty → 1h default
SB3=$(mktemp -d)
build_review_sandbox "$SB3" 'AGENT_REVIEW_TIMEOUT=""'
out=$(simulate_review_timeout "$SB3")
got=$(echo "$out" | grep '^RESOLVED_AGENT_TIMEOUT=' | cut -d= -f2)
assert_eq "TC-RTO-RES-03 AGENT_REVIEW_TIMEOUT=\"\" → 1h default" "1h" "$got"

# TC-RTO-E2E-01: E2E_BROWSER_TIMEOUT_SECONDS unset → original AGENT_TIMEOUT (4h),
# NOT the 1h review cap.
out=$(simulate_review_timeout "$SB2")
got=$(echo "$out" | grep '^RESOLVED_E2E_BROWSER=' | cut -d= -f2)
assert_eq "TC-RTO-E2E-01 browser cap defaults to ORIGINAL 4h (not 1h review cap)" "4h" "$got"
orig=$(echo "$out" | grep '^ORIG_AGENT_TIMEOUT=' | cut -d= -f2)
assert_eq "TC-RTO-E2E-01b _ORIG_AGENT_TIMEOUT captured the conf 4h" "4h" "$orig"

# TC-RTO-E2E-02: explicit browser cap honored
SB4=$(mktemp -d)
build_review_sandbox "$SB4" 'E2E_BROWSER_TIMEOUT_SECONDS="7200"'
out=$(simulate_review_timeout "$SB4")
got=$(echo "$out" | grep '^RESOLVED_E2E_BROWSER=' | cut -d= -f2)
assert_eq "TC-RTO-E2E-02 E2E_BROWSER_TIMEOUT_SECONDS=7200 honored" "7200" "$got"
# And the review cap is still 1h (browser cap is independent).
got=$(echo "$out" | grep '^RESOLVED_AGENT_TIMEOUT=' | cut -d= -f2)
assert_eq "TC-RTO-E2E-02b review cap still 1h with explicit browser cap" "1h" "$got"

rm -rf "$SB2" "$SB3" "$SB4"

# =========================================================================
echo ""
echo "=== TC-RTO-VAL-startup: validate_review_timeout_config via --validate-config-only ==="
# =========================================================================
# Exercise the REAL wrapper through its hidden --validate-config-only flag (same
# technique as test-e2e-mode-command.sh) so the actual startup validation runs.
# Env-var overrides are exported; PROJECT_DIR points at the repo (no
# autonomous.conf there, so load_autonomous_conf leaves the exported vars in
# place — verified by the e2e-mode-command suite using this same harness).
_RUN_REVIEW_VALIDATE() {
  unset AGENT_REVIEW_TIMEOUT E2E_BROWSER_TIMEOUT_SECONDS \
    E2E_ENABLED E2E_MODE E2E_COMMAND E2E_COMMAND_TIMEOUT_SECONDS \
    E2E_COMMAND_PRE_HOOKS E2E_COMMAND_EVIDENCE_PARSER \
    E2E_PREVIEW_URL_PATTERN E2E_TEST_USER_EMAIL E2E_TEST_USER_PASSWORD
  export ISSUE_NUMBER=1 REPO=zxkane/test PROJECT_ID=test \
    REPO_OWNER=zxkane REPO_NAME=test PROJECT_DIR="$PROJECT_ROOT" \
    AGENT_CMD=claude AGENT_PERMISSION_MODE=bypassPermissions GH_AUTH_MODE=token
  while [[ $# -gt 0 ]]; do
    local kv="$1"; export "${kv%%=*}=${kv#*=}"; shift
  done
  bash "$WRAPPER" --validate-config-only 2>&1
}
_assert_review_validate_fails() {
  local desc="$1" pat="$2"; shift 2
  local out rc; out=$(_RUN_REVIEW_VALIDATE "$@"); rc=$?
  if [[ $rc -ne 0 ]] && echo "$out" | grep -qE "$pat"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (rc=$rc, no match: $pat)"
    echo "    out: $(echo "$out" | grep -i error | head -2)"; FAIL=$((FAIL + 1))
  fi
}
_assert_review_validate_succeeds() {
  local desc="$1"; shift
  local out rc; out=$(_RUN_REVIEW_VALIDATE "$@"); rc=$?
  if [[ $rc -eq 0 ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (rc=$rc)"
    echo "    out: $(echo "$out" | grep -i error | head -2)"; FAIL=$((FAIL + 1))
  fi
}

# TC-RTO-VAL-11: AGENT_REVIEW_TIMEOUT=0 fails loud at startup.
_assert_review_validate_fails "TC-RTO-VAL-11 AGENT_REVIEW_TIMEOUT=0 fails loud" \
  "AGENT_REVIEW_TIMEOUT.*not a positive" AGENT_REVIEW_TIMEOUT=0
# Non-timeout value fails.
_assert_review_validate_fails "TC-RTO-VAL-11b AGENT_REVIEW_TIMEOUT=abc fails loud" \
  "AGENT_REVIEW_TIMEOUT.*not a positive" AGENT_REVIEW_TIMEOUT=abc
# Operator-set browser cap of 0 fails.
_assert_review_validate_fails "TC-RTO-VAL-11c E2E_BROWSER_TIMEOUT_SECONDS=0 fails loud" \
  "E2E_BROWSER_TIMEOUT_SECONDS.*not a positive" E2E_BROWSER_TIMEOUT_SECONDS=0
# Valid values pass.
_assert_review_validate_succeeds "TC-RTO-VAL-11d AGENT_REVIEW_TIMEOUT=90m passes" \
  AGENT_REVIEW_TIMEOUT=90m
# REGRESSION (codex review High): a conf whose AGENT_TIMEOUT is a `timeout`-valid
# but predicate-rejected value (fractional) and NO operator-set browser cap must
# NOT crash review startup — the dev side accepts AGENT_TIMEOUT unvalidated, and
# the resolved browser DEFAULT (= AGENT_TIMEOUT) must not be re-validated. Only
# the operator-supplied raw value is validated.
_assert_review_validate_succeeds "TC-RTO-VAL-11e AGENT_TIMEOUT=1.5h (no browser-cap set) does NOT crash review startup" \
  AGENT_TIMEOUT=1.5h
_assert_review_validate_succeeds "TC-RTO-VAL-11f AGENT_TIMEOUT=infinity (no browser-cap set) does NOT crash review startup" \
  AGENT_TIMEOUT=infinity
# But if the operator EXPLICITLY sets an invalid browser cap, it still fails loud
# even when AGENT_TIMEOUT itself is fine.
_assert_review_validate_fails "TC-RTO-VAL-11g explicit E2E_BROWSER_TIMEOUT_SECONDS=1.5h fails loud" \
  "E2E_BROWSER_TIMEOUT_SECONDS.*not a positive" E2E_BROWSER_TIMEOUT_SECONDS=1.5h

# =========================================================================
echo ""
echo "=== TC-RTO-SRC: source-of-truth greps ==="
# =========================================================================
assert_grep "TC-RTO-SRC-01a captures _ORIG_AGENT_TIMEOUT before rebind" \
  '_ORIG_AGENT_TIMEOUT="\$AGENT_TIMEOUT"' "$WRAPPER"
assert_grep "TC-RTO-SRC-01b rebinds AGENT_TIMEOUT to AGENT_REVIEW_TIMEOUT with 1h default" \
  'AGENT_TIMEOUT="\$\{AGENT_REVIEW_TIMEOUT:-1h\}"' "$WRAPPER"
assert_grep "TC-RTO-SRC-02 browser cap defaults to _ORIG_AGENT_TIMEOUT" \
  'E2E_BROWSER_TIMEOUT_SECONDS:-\$_ORIG_AGENT_TIMEOUT' "$WRAPPER"
# The raw operator-supplied browser cap is captured BEFORE the default fold-in,
# and validation reads the RAW value (not the resolved default) — so a conf whose
# AGENT_TIMEOUT only flows through to the browser DEFAULT is never re-validated
# (codex review High fix).
assert_grep "TC-RTO-SRC-02b raw browser cap captured before default fold-in" \
  '_E2E_BROWSER_TIMEOUT_RAW="\$\{E2E_BROWSER_TIMEOUT_SECONDS:-\}"' "$WRAPPER"
assert_grep "TC-RTO-SRC-02c validation reads the RAW browser cap, not the resolved default" \
  '_is_positive_timeout_value "\$_E2E_BROWSER_TIMEOUT_RAW"' "$WRAPPER"
# Dev wrapper must NOT leak AGENT_REVIEW_TIMEOUT.
assert_not_grep "TC-RTO-SRC-03 dev wrapper does NOT read AGENT_REVIEW_TIMEOUT" \
  'AGENT_REVIEW_TIMEOUT' "$DEV_WRAPPER"
# Browser lane rebinds AGENT_TIMEOUT to the browser cap.
assert_grep "TC-RTO-SRC-03b browser lane rebinds AGENT_TIMEOUT to the browser cap" \
  'AGENT_TIMEOUT="\$E2E_BROWSER_TIMEOUT_SECONDS"' "$WRAPPER"
# Startup validation function defined + called.
assert_grep "TC-RTO-VAL-12a validate_review_timeout_config defined" \
  'validate_review_timeout_config\(\)' "$WRAPPER"
assert_grep "TC-RTO-VAL-12b validate_review_timeout_config called at startup" \
  'validate_review_timeout_config \|\| exit 1' "$WRAPPER"
assert_grep "TC-RTO-VAL-12c startup log line shows resolved review cap" \
  '[Rr]eview (CLI )?(wall-clock )?(timeout|cap)' "$WRAPPER"
# emit_verdict_trailer count: the timeout-veto adds NO new trailer site (its veto
# routes through the existing FAIL branch's trailer). The total is 11 = the 10
# pre-INV-64 sites (6 legacy + 2 INV-44 mergeable gate + 2 INV-46 E2E gate) PLUS
# the 1 INV-64 Phase-A.5 smoke-FAIL abort site (#224) — the veto itself still
# contributes none.
EMIT_COUNT=$(grep -cE '^\s*emit_verdict_trailer ' "$WRAPPER")
assert_eq "TC-RTO-SRC-06 emit_verdict_trailer count is 11 (veto adds none; INV-64 smoke abort is the only new site)" "11" "$EMIT_COUNT"
# Post-window sweep classifies a no-verdict agent via _classify_noverdict_agent.
assert_grep "TC-RTO-VETO-11 post-window sweep uses _classify_noverdict_agent on launch rc" \
  '_classify_noverdict_agent' "$WRAPPER"

# bash -n
if bash -n "$WRAPPER" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-RTO-SRC-05 wrapper passes bash -n"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-RTO-SRC-05 wrapper has syntax errors"; FAIL=$((FAIL + 1))
fi
if bash -n "$AGG_LIB" 2>/dev/null && bash -n "$AGENT_LIB" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-RTO-SRC-05b libs pass bash -n"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-RTO-SRC-05b libs have syntax errors"; FAIL=$((FAIL + 1))
fi

# =========================================================================
echo ""
echo "=== TC-RTO-SRC-04 / TC-RTO-DOC: conf example + docs ==="
# =========================================================================
assert_grep "TC-RTO-SRC-04a conf example documents AGENT_REVIEW_TIMEOUT" \
  'AGENT_REVIEW_TIMEOUT' "$CONF_EXAMPLE"
assert_grep "TC-RTO-SRC-04b conf example documents E2E_BROWSER_TIMEOUT_SECONDS" \
  'E2E_BROWSER_TIMEOUT_SECONDS' "$CONF_EXAMPLE"
assert_grep "TC-RTO-DOC-01 invariants.md has INV-48 entry" \
  '## INV-48' "$INVARIANTS"
assert_grep "TC-RTO-DOC-02 INV-40 (or INV-48) mentions timed-out deciding FAIL" \
  'timed-out' "$INVARIANTS"
assert_grep "TC-RTO-DOC-03 review-agent-flow.md references the review timeout" \
  'AGENT_REVIEW_TIMEOUT' "$FLOW"

# =========================================================================
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
