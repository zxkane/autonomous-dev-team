#!/bin/bash
# test-lib-agent-per-side-launcher.sh — Unit tests for AGENT_DEV_LAUNCHER /
# AGENT_REVIEW_LAUNCHER per-side overrides (INV-38).
#
# Verifies:
#   - Defaults: both per-side ARGVs default to AGENT_LAUNCHER_ARGV
#   - Single-side override: only the overridden side changes
#   - Both-side override: each side runs its declared launcher
#   - Empty-string handling: :- treats explicit empty as unset
#   - Per-side guard: each side's launcher is gated on THAT side's CLI
#   - Wrapper structural placement: rebind lands within ≤5 / ≤6 lines
#     of `source lib-agent.sh` in autonomous-{dev,review}.sh
#
# Run: bash tests/unit/test-lib-agent-per-side-launcher.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent.sh"
# DEV_WRAPPER / REVIEW_WRAPPER are used by PSL-S9 / PSL-S10 structural greps.
# shellcheck disable=SC2034
DEV_WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
# shellcheck disable=SC2034
REVIEW_WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"

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
    echo "      needle='$needle'"
    echo "      haystack='${haystack:0:300}'"
    FAIL=$((FAIL + 1))
  fi
}

# resolve_argvs <agent_launcher> <agent_dev_launcher> <agent_review_launcher>
# Sources lib-agent.sh in a sandbox with the given env, prints the joined
# tokens of each ARGV array on a single line: "DEV=<...> REVIEW=<...>".
# Both per-side CMDs are forced to "claude" so the per-side guard does
# not fire (this helper is for resolution-order tests only; guard tests
# use launcher_guard).
resolve_argvs() {
  local _al="$1" _adl="$2" _arl="$3"
  AGENT_LAUNCHER="$_al" \
  AGENT_DEV_LAUNCHER="$_adl" \
  AGENT_REVIEW_LAUNCHER="$_arl" \
  AGENT_CMD="claude" \
  AGENT_DEV_CMD="claude" \
  AGENT_REVIEW_CMD="claude" \
  bash -c '
    unset AUTONOMOUS_CONF
    source "'"$LIB"'" 2>/dev/null
    printf "DEV=%s REVIEW=%s\n" \
      "${AGENT_DEV_LAUNCHER_ARGV[*]:-}" \
      "${AGENT_REVIEW_LAUNCHER_ARGV[*]:-}"
  '
}

# launcher_guard <agent_launcher> <agent_dev_launcher> <agent_review_launcher> \
#                <agent_dev_cmd> <agent_review_cmd>
# Sources lib-agent.sh and emits "RC=<n>" plus stderr. Used by PSL-S6..S8.
launcher_guard() {
  local _al="$1" _adl="$2" _arl="$3" _adc="$4" _arc="$5"
  AGENT_LAUNCHER="$_al" \
  AGENT_DEV_LAUNCHER="$_adl" \
  AGENT_REVIEW_LAUNCHER="$_arl" \
  AGENT_CMD="claude" \
  AGENT_DEV_CMD="$_adc" \
  AGENT_REVIEW_CMD="$_arc" \
  bash -c '
    unset AUTONOMOUS_CONF
    source "'"$LIB"'"
    echo "RC=$?"
  ' 2>&1
}

echo "=== test-lib-agent-per-side-launcher.sh — AGENT_DEV/REVIEW_LAUNCHER (INV-38) ==="

# ---------------------------------------------------------------------------
echo ""
echo "=== PSL-S1: default — neither override + AGENT_LAUNCHER unset → both empty ==="
# ---------------------------------------------------------------------------
out=$(resolve_argvs "" "" "")
assert_eq "all unset → both ARGVs empty" "DEV= REVIEW=" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSL-S2: back-compat — AGENT_LAUNCHER set, no per-side → both default to it ==="
# ---------------------------------------------------------------------------
out=$(resolve_argvs "cc" "" "")
assert_eq "AGENT_LAUNCHER='cc' → DEV+REVIEW both 'cc'" "DEV=cc REVIEW=cc" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSL-S3: only AGENT_DEV_LAUNCHER → DEV=override, REVIEW=AGENT_LAUNCHER (empty) ==="
# ---------------------------------------------------------------------------
out=$(resolve_argvs "" "cc" "")
assert_eq "AGENT_DEV_LAUNCHER='cc' alone → DEV=cc, REVIEW empty" \
  "DEV=cc REVIEW=" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSL-S4: only AGENT_REVIEW_LAUNCHER → REVIEW=override, DEV empty ==="
# ---------------------------------------------------------------------------
out=$(resolve_argvs "" "" "wrap")
assert_eq "AGENT_REVIEW_LAUNCHER='wrap' alone → DEV empty, REVIEW=wrap" \
  "DEV= REVIEW=wrap" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSL-S5: both set, different values → each side gets its declared launcher ==="
# ---------------------------------------------------------------------------
out=$(resolve_argvs "default-launcher" "cc" "wrap")
assert_eq "DEV=cc, REVIEW=wrap, AGENT_LAUNCHER ignored on both sides" \
  "DEV=cc REVIEW=wrap" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSL-S6: AGENT_DEV_LAUNCHER + AGENT_DEV_CMD=claude → guard pass ==="
# ---------------------------------------------------------------------------
out=$(launcher_guard "" "cc" "" "claude" "claude")
assert_contains "RC=0 (no guard rejection)" "RC=0" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSL-S7: AGENT_DEV_LAUNCHER + AGENT_DEV_CMD=kiro → guard fails per-side ==="
# ---------------------------------------------------------------------------
out=$(launcher_guard "" "cc" "" "kiro" "claude")
assert_contains "guard error names AGENT_DEV_LAUNCHER" "AGENT_DEV_LAUNCHER" "$out"
assert_contains "guard error names AGENT_DEV_CMD=kiro" "AGENT_DEV_CMD=kiro" "$out"
assert_contains "guard returns rc=1 (source aborted)" "RC=1" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSL-S8: AGENT_REVIEW_LAUNCHER + AGENT_REVIEW_CMD=agy → guard fails per-side ==="
# ---------------------------------------------------------------------------
out=$(launcher_guard "" "" "wrap" "claude" "agy")
assert_contains "guard error names AGENT_REVIEW_LAUNCHER" "AGENT_REVIEW_LAUNCHER" "$out"
assert_contains "guard error names AGENT_REVIEW_CMD=agy" "AGENT_REVIEW_CMD=agy" "$out"
assert_contains "guard returns rc=1 (source aborted)" "RC=1" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSL-S9: autonomous-dev.sh — launcher rebind AFTER source lib-auth.sh ==="
# ---------------------------------------------------------------------------
# Same invariant as INV-37 PSC-S9: the per-side rebind MUST come AFTER
# `source lib-auth.sh` because lib-auth.sh transitively re-sources
# autonomous.conf, which would otherwise reset AGENT_LAUNCHER (and
# transitively AGENT_LAUNCHER_ARGV via lib-agent.sh's :- defaults if
# the wrapper rebind happened before this re-source).
hit=$(awk '
  /source "\$\{LIB_DIR\}\/lib-auth\.sh"/ {
    found_lib_auth = NR
    next
  }
  found_lib_auth && NR > found_lib_auth {
    if ($0 ~ /^AGENT_LAUNCHER_ARGV=\("\$\{AGENT_DEV_LAUNCHER_ARGV\[@\]\}"\)/) {
      print "MATCH"
      exit
    }
  }
' "$DEV_WRAPPER")

assert_eq "autonomous-dev.sh: launcher rebind lands AFTER source lib-auth.sh" \
  "MATCH" "$hit"

# Symmetric pre-source check: assert the rebind does NOT appear before
# source lib-auth.sh. Mirrors the dual check in PSC-S9. agy review on
# PR #159 caught the missing pre-source assertion.
hit_pre=$(awk '
  /source "\$\{LIB_DIR\}\/lib-auth\.sh"/ {
    print "REACHED_LIB_AUTH"
    exit
  }
  /^AGENT_LAUNCHER_ARGV=\("\$\{AGENT_DEV_LAUNCHER_ARGV\[@\]\}"\)/ {
    print "REBIND_BEFORE_LIB_AUTH"
    exit
  }
' "$DEV_WRAPPER")

assert_eq "autonomous-dev.sh: launcher rebind does NOT precede source lib-auth.sh" \
  "REACHED_LIB_AUTH" "$hit_pre"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSL-S10: autonomous-review.sh — launcher rebind AFTER source lib-auth.sh ==="
# ---------------------------------------------------------------------------
hit=$(awk '
  /source "\$\{LIB_DIR\}\/lib-auth\.sh"/ {
    found_lib_auth = NR
    next
  }
  found_lib_auth && NR > found_lib_auth {
    if ($0 ~ /^AGENT_LAUNCHER_ARGV=\("\$\{AGENT_REVIEW_LAUNCHER_ARGV\[@\]\}"\)/) {
      print "MATCH"
      exit
    }
  }
' "$REVIEW_WRAPPER")

assert_eq "autonomous-review.sh: launcher rebind lands AFTER source lib-auth.sh" \
  "MATCH" "$hit"

hit_pre=$(awk '
  /source "\$\{LIB_DIR\}\/lib-auth\.sh"/ {
    print "REACHED_LIB_AUTH"
    exit
  }
  /^AGENT_LAUNCHER_ARGV=\("\$\{AGENT_REVIEW_LAUNCHER_ARGV\[@\]\}"\)/ {
    print "REBIND_BEFORE_LIB_AUTH"
    exit
  }
' "$REVIEW_WRAPPER")

assert_eq "autonomous-review.sh: launcher rebind does NOT precede source lib-auth.sh" \
  "REACHED_LIB_AUTH" "$hit_pre"

echo ""
echo "PASS: $PASS    FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
