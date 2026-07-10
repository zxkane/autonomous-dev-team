#!/bin/bash
# test-dispatcher-tick-issue-filter.sh — Unit tests for the ISSUE_FILTER /
# ISSUE_SCAN_LIMIT fail-closed precheck added to dispatcher-tick.sh (#436,
# docs/designs/issue-filter.md §4.3).
#
# Same strategy as test-dispatcher-tick-review-bots.sh: a poisoned filter
# (or scan-limit) must abort the WHOLE tick, before any gh call / token
# mint / label edit — not just fail a later selector call. Build a sandbox
# autonomous.conf, run dispatcher-tick.sh, assert rc!=0 + the right
# envelope code + zero gh invocations.
#
# Run: bash tests/unit/test-dispatcher-tick-issue-filter.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TICK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle='$needle'"
    echo "      haystack='${haystack:0:800}'"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      should not contain: '$needle'"
    FAIL=$((FAIL + 1))
  fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

PROJECT_DIR_FAKE="$TMPROOT/proj"
mkdir -p "$PROJECT_DIR_FAKE/scripts"

BIN="$TMPROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<EOF
#!/bin/bash
if [[ "\$1" == "--version" ]]; then
  echo "gh version 2.96.0 (2026-01-01)"
  exit 0
fi
echo "GH_CALLED \$*" >> "$TMPROOT/gh-calls"
exit 0
EOF
chmod +x "$BIN/gh"

write_conf() {
  local issue_filter_value="$1" scan_limit_value="${2:-}"
  cat > "$TMPROOT/autonomous.conf" <<EOF
PROJECT_ID="testproj"
REPO="owner/repo"
REPO_OWNER="owner"
REPO_NAME="repo"
PROJECT_DIR="$PROJECT_DIR_FAKE"
MAX_CONCURRENT=5
MAX_RETRIES=3
REVIEW_BOTS=""
ISSUE_FILTER="$issue_filter_value"
EOF
  if [[ -n "$scan_limit_value" ]]; then
    echo "ISSUE_SCAN_LIMIT=\"$scan_limit_value\"" >> "$TMPROOT/autonomous.conf"
  fi
}

run_tick() {
  : > "$TMPROOT/gh-calls"
  PATH="$BIN:$PATH" \
  AUTONOMOUS_CONF="$TMPROOT/autonomous.conf" \
  bash "$TICK" 2>&1
}

run_tick_rc() {
  PATH="$BIN:$PATH" AUTONOMOUS_CONF="$TMPROOT/autonomous.conf" \
    bash "$TICK" >/dev/null 2>&1
  echo $?
}

assert_gh_not_called() {
  local desc="$1"
  if [[ -s "$TMPROOT/gh-calls" ]]; then
    echo -e "  ${RED}FAIL${NC}: $desc"
    sed 's/^/      /' "$TMPROOT/gh-calls"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  fi
}

# ---------------------------------------------------------------------------
echo "=== TC-IFILT-080: malformed ISSUE_FILTER aborts the tick rc!=0 ==="
# ---------------------------------------------------------------------------
write_conf "bogus:foo"
output=$(run_tick)
rc=$(run_tick_rc)
if [[ "$rc" -ne 0 ]]; then
  echo -e "  ${GREEN}PASS${NC}: tick exits non-zero on malformed ISSUE_FILTER (rc=$rc)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: tick should exit non-zero on malformed ISSUE_FILTER (got rc=0)"
  FAIL=$((FAIL + 1))
fi
assert_contains "stderr mentions ISSUE_FILTER" "ISSUE_FILTER" "$output"
assert_contains "envelope code present" "ADT_CFG_ISSUE_FILTER_INVALID" "$output"
assert_gh_not_called "gh not called — malformed filter aborts before any side-effect"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IFILT-081: reserved-label filter aborts the tick rc!=0 ==="
# ---------------------------------------------------------------------------
write_conf "label:in-progress"
output=$(run_tick)
rc=$(run_tick_rc)
if [[ "$rc" -ne 0 ]]; then
  echo -e "  ${GREEN}PASS${NC}: tick exits non-zero on reserved-label filter (rc=$rc)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: tick should exit non-zero on reserved-label filter (got rc=0)"
  FAIL=$((FAIL + 1))
fi
assert_contains "stderr names the reserved label" "in-progress" "$output"
assert_contains "envelope code present" "ADT_CFG_ISSUE_FILTER_INVALID" "$output"
assert_gh_not_called "gh not called — reserved-label filter aborts before any side-effect"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IFILT-083/084: invalid ISSUE_SCAN_LIMIT aborts the tick rc!=0 ==="
# ---------------------------------------------------------------------------
write_conf "" "abc"
output=$(run_tick)
rc=$(run_tick_rc)
if [[ "$rc" -ne 0 ]]; then
  echo -e "  ${GREEN}PASS${NC}: tick exits non-zero on non-numeric ISSUE_SCAN_LIMIT (rc=$rc)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: tick should exit non-zero on non-numeric ISSUE_SCAN_LIMIT (got rc=0)"
  FAIL=$((FAIL + 1))
fi
assert_contains "stderr mentions ISSUE_SCAN_LIMIT" "ISSUE_SCAN_LIMIT" "$output"
assert_contains "envelope code present" "ADT_CFG_ISSUE_SCAN_LIMIT_INVALID" "$output"
assert_gh_not_called "gh not called — invalid scan limit aborts before any side-effect"

write_conf "" "0"
rc=$(run_tick_rc)
if [[ "$rc" -ne 0 ]]; then
  echo -e "  ${GREEN}PASS${NC}: tick exits non-zero on ISSUE_SCAN_LIMIT=0 (rc=$rc)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: tick should exit non-zero on ISSUE_SCAN_LIMIT=0 (got rc=0)"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IFILT-086: valid empty ISSUE_FILTER does NOT trip the precheck ==="
# ---------------------------------------------------------------------------
write_conf ""
output=$(run_tick)
assert_not_contains "no ISSUE_FILTER validation error for empty value" \
  "ISSUE_FILTER validation failed" "$output"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IFILT-085: precheck positioned before token mint / dispatch ==="
# ---------------------------------------------------------------------------
if grep -q 'issue_filter_validate "${ISSUE_FILTER:-}"' "$TICK"; then
  echo -e "  ${GREEN}PASS${NC}: tick calls issue_filter_validate"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: tick missing issue_filter_validate precheck"
  FAIL=$((FAIL + 1))
fi

PRECHECK_LINE=$(grep -n 'issue_filter_validate "${ISSUE_FILTER:-}"' "$TICK" | head -1 | cut -d: -f1)
TOKEN_MINT_LINE=$(grep -n 'get_gh_app_token' "$TICK" | head -1 | cut -d: -f1)
FIRST_DISPATCH_LINE=$(grep -n '^[[:space:]]*dispatch ' "$TICK" | head -1 | cut -d: -f1)
if [[ -n "$PRECHECK_LINE" && -n "$TOKEN_MINT_LINE" && "$PRECHECK_LINE" -lt "$TOKEN_MINT_LINE" ]]; then
  echo -e "  ${GREEN}PASS${NC}: precheck (line $PRECHECK_LINE) runs before token mint (line $TOKEN_MINT_LINE)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: precheck not positioned before token mint (precheck=$PRECHECK_LINE, mint=$TOKEN_MINT_LINE)"
  FAIL=$((FAIL + 1))
fi
if [[ -n "$PRECHECK_LINE" && -n "$FIRST_DISPATCH_LINE" && "$PRECHECK_LINE" -lt "$FIRST_DISPATCH_LINE" ]]; then
  echo -e "  ${GREEN}PASS${NC}: precheck (line $PRECHECK_LINE) runs before any dispatch (line $FIRST_DISPATCH_LINE)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: precheck not positioned before dispatch (precheck=$PRECHECK_LINE, first dispatch=$FIRST_DISPATCH_LINE)"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
