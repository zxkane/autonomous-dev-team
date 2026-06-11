#!/bin/bash
# test-lib-agent-per-side-cmd.sh — Unit tests for AGENT_DEV_CMD /
# AGENT_REVIEW_CMD per-side overrides (INV-37).
#
# Verifies:
#   - Defaults: both per-side vars resolve to ${AGENT_CMD:-claude}
#   - Single-side override: only the overridden side changes
#   - Both-side override: each side runs its declared CLI
#   - Empty-string handling: :- treats explicit empty as unset
#   - AGENT_LAUNCHER guard: requires BOTH sides to be claude when set
#   - Wrapper structural placement: AGENT_CMD override lands immediately
#     after source lib-agent.sh in both autonomous-{dev,review}.sh
#
# Run: bash tests/unit/test-lib-agent-per-side-cmd.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent.sh"
# DEV_WRAPPER / REVIEW_WRAPPER are used by PSC-S9 / PSC-S10 (structural
# placement greps) which land in plan Tasks 2 and 3. Defined here so
# the test scaffolding stays in one place across all three tasks.
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

# resolve_pair <agent_cmd> <agent_dev_cmd> <agent_review_cmd>
# Sources lib-agent.sh in a sandbox with the given env, prints
# "DEV=<dev_cmd> REVIEW=<review_cmd>" on stdout. Strips ANY [lib-agent]
# warnings/errors so callers can grep cleanly.
resolve_pair() {
  local _ac="$1" _adc="$2" _arc="$3"
  AGENT_CMD="$_ac" \
  AGENT_DEV_CMD="$_adc" \
  AGENT_REVIEW_CMD="$_arc" \
  AGENT_LAUNCHER="" \
  bash -c '
    unset AUTONOMOUS_CONF
    source "'"$LIB"'" 2>/dev/null
    printf "DEV=%s REVIEW=%s\n" "$AGENT_DEV_CMD" "$AGENT_REVIEW_CMD"
  '
}

# launcher_guard <agent_dev_cmd> <agent_review_cmd>
# Sources lib-agent.sh with AGENT_LAUNCHER=cc and the given per-side
# values. Captures stderr; emits exit code on stdout last line.
launcher_guard() {
  local _adc="$1" _arc="$2"
  AGENT_CMD="claude" \
  AGENT_DEV_CMD="$_adc" \
  AGENT_REVIEW_CMD="$_arc" \
  AGENT_LAUNCHER="cc" \
  bash -c '
    unset AUTONOMOUS_CONF
    source "'"$LIB"'"
    echo "RC=$?"
  ' 2>&1
}

echo "=== test-lib-agent-per-side-cmd.sh — AGENT_DEV_CMD / AGENT_REVIEW_CMD (INV-37) ==="

# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S1: default — neither override set → both equal AGENT_CMD ==="
# ---------------------------------------------------------------------------
out=$(resolve_pair "claude" "" "")
assert_eq "default with AGENT_CMD=claude" "DEV=claude REVIEW=claude" "$out"

out=$(resolve_pair "codex" "" "")
assert_eq "default with AGENT_CMD=codex" "DEV=codex REVIEW=codex" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S2: only AGENT_REVIEW_CMD set → dev=AGENT_CMD, review=override ==="
# ---------------------------------------------------------------------------
out=$(resolve_pair "claude" "" "agy")
assert_eq "AGENT_CMD=claude AGENT_REVIEW_CMD=agy" "DEV=claude REVIEW=agy" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S3: only AGENT_DEV_CMD set → dev=override, review=AGENT_CMD ==="
# ---------------------------------------------------------------------------
out=$(resolve_pair "claude" "codex" "")
assert_eq "AGENT_CMD=claude AGENT_DEV_CMD=codex" "DEV=codex REVIEW=claude" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S4: both set → each side runs its declared CLI ==="
# ---------------------------------------------------------------------------
out=$(resolve_pair "claude" "codex" "agy")
assert_eq "AGENT_CMD=claude DEV=codex REVIEW=agy" "DEV=codex REVIEW=agy" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S5: explicit empty string falls back to AGENT_CMD ==="
# ---------------------------------------------------------------------------
out=$(resolve_pair "kiro" "" "")
assert_eq "AGENT_DEV_CMD='' AGENT_REVIEW_CMD='' AGENT_CMD=kiro" "DEV=kiro REVIEW=kiro" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S6: AGENT_LAUNCHER + both sides claude → source succeeds ==="
# ---------------------------------------------------------------------------
out=$(launcher_guard "claude" "claude")
assert_contains "RC=0 (no guard rejection)" "RC=0" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S7: AGENT_LAUNCHER + dev=claude review=agy → guard fails ==="
# ---------------------------------------------------------------------------
out=$(launcher_guard "claude" "agy")
assert_contains "guard error mentions AGENT_REVIEW_CMD=agy" "AGENT_REVIEW_CMD=agy" "$out"
assert_contains "guard error mentions AGENT_REVIEW_LAUNCHER (per-side, INV-38)" "AGENT_REVIEW_LAUNCHER" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S8: AGENT_LAUNCHER + dev=codex review=claude → guard fails ==="
# ---------------------------------------------------------------------------
out=$(launcher_guard "codex" "claude")
assert_contains "guard error mentions AGENT_DEV_CMD=codex" "AGENT_DEV_CMD=codex" "$out"
assert_contains "guard error mentions AGENT_DEV_LAUNCHER (per-side, INV-38)" "AGENT_DEV_LAUNCHER" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S11: AGENT_LAUNCHER + both sides non-claude → guard fails ==="
# ---------------------------------------------------------------------------
out=$(launcher_guard "codex" "agy")
# Post-INV-38: per-side guards fire independently. The dev-side guard
# fires first and aborts source; we only see the dev-side error.
# AGENT_REVIEW_LAUNCHER's guard never gets to run because of `return 1`.
assert_contains "guard error mentions AGENT_DEV_CMD=codex (dev-side fires first)" \
  "AGENT_DEV_CMD=codex" "$out"
assert_contains "guard error names AGENT_DEV_LAUNCHER (per-side, INV-38)" \
  "AGENT_DEV_LAUNCHER" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S9: autonomous-dev.sh — rebind AFTER source lib-auth.sh ==="
# ---------------------------------------------------------------------------
# The rebind MUST come AFTER `source lib-auth.sh`. lib-auth.sh transitively
# sources lib-config.sh::load_autonomous_conf which re-sources
# autonomous.conf, and conf's unconditional `AGENT_CMD="claude"` line
# would otherwise overwrite this rebind. (Bug discovered 2026-05-26 when
# podcast-curation review wrapper kept invoking claude despite
# AGENT_REVIEW_CMD=kiro.)
hit=$(awk '
  /source "\$\{LIB_DIR\}\/lib-auth\.sh"/ {
    found_lib_auth = NR
    next
  }
  found_lib_auth && NR > found_lib_auth {
    if ($0 ~ /^AGENT_CMD="\$AGENT_DEV_CMD"/) {
      print "MATCH"
      exit
    }
  }
' "$DEV_WRAPPER")

assert_eq "autonomous-dev.sh: AGENT_CMD=\$AGENT_DEV_CMD lands AFTER source lib-auth.sh" \
  "MATCH" "$hit"

# Also assert: rebind is NOT before lib-auth source (would be the bug shape).
hit_pre=$(awk '
  /source "\$\{LIB_DIR\}\/lib-auth\.sh"/ {
    print "REACHED_LIB_AUTH"
    exit
  }
  /^AGENT_CMD="\$AGENT_DEV_CMD"/ {
    print "REBIND_BEFORE_LIB_AUTH"
    exit
  }
' "$DEV_WRAPPER")

assert_eq "autonomous-dev.sh: rebind does NOT precede source lib-auth.sh" \
  "REACHED_LIB_AUTH" "$hit_pre"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S10: autonomous-review.sh — rebind AFTER source lib-auth.sh ==="
# ---------------------------------------------------------------------------
hit=$(awk '
  /source "\$\{LIB_DIR\}\/lib-auth\.sh"/ {
    found_lib_auth = NR
    next
  }
  found_lib_auth && NR > found_lib_auth {
    if ($0 ~ /^AGENT_CMD="\$AGENT_REVIEW_CMD"/) {
      print "MATCH"
      exit
    }
  }
' "$REVIEW_WRAPPER")

assert_eq "autonomous-review.sh: AGENT_CMD=\$AGENT_REVIEW_CMD lands AFTER source lib-auth.sh" \
  "MATCH" "$hit"

hit_pre=$(awk '
  /source "\$\{LIB_DIR\}\/lib-auth\.sh"/ {
    print "REACHED_LIB_AUTH"
    exit
  }
  /^AGENT_CMD="\$AGENT_REVIEW_CMD"/ {
    print "REBIND_BEFORE_LIB_AUTH"
    exit
  }
' "$REVIEW_WRAPPER")

assert_eq "autonomous-review.sh: rebind does NOT precede source lib-auth.sh" \
  "REACHED_LIB_AUTH" "$hit_pre"

echo ""
echo "PASS: $PASS    FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
