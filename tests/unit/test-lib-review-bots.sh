#!/bin/bash
# test-lib-review-bots.sh — Unit tests for lib-review-bots.sh (PR-12).
#
# Verifies:
#   - parse_review_bots: happy path, empty input, unknown bot, custom bot
#     via env vars, case normalization
#   - get_bot_trigger / get_bot_login: built-in and custom bots
#   - render_bot_review_section: empty input → no output, non-empty → all
#     configured bots represented, Claude uses @claude not /claude
#
# Run: bash tests/unit/test-lib-review-bots.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-bots.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-bots.sh
source "$LIB"

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
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected_rc=$expected actual_rc=$actual"
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
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
echo "=== TC-RB-01: parse_review_bots happy path ==="
# ---------------------------------------------------------------------------
assert_eq "two built-ins"      "q codex"        "$(parse_review_bots 'q codex')"
assert_eq "all three built-ins" "q codex claude" "$(parse_review_bots 'q codex claude')"
assert_eq "case normalization"  "q claude"       "$(parse_review_bots 'Q Claude')"
assert_eq "extra whitespace"    "q codex"        "$(parse_review_bots '  q   codex  ')"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RB-02: parse_review_bots empty input ==="
# ---------------------------------------------------------------------------
out=$(parse_review_bots '')
assert_eq "empty → empty output" "" "$out"
parse_review_bots '' >/dev/null 2>&1
assert_rc "empty → rc=0 (not an error)" 0 "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RB-03: unknown bot fails fast ==="
# ---------------------------------------------------------------------------
err=$(parse_review_bots 'q bogus' 2>&1 >/dev/null)
parse_review_bots 'q bogus' >/dev/null 2>&1
assert_rc "unknown bot → rc=1" 1 "$?"
assert_contains "stderr names the bad bot" "bogus" "$err"
assert_contains "stderr shows env-var hint" "REVIEW_BOTS_BOGUS_TRIGGER" "$err"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RB-04: custom bot via env vars ==="
# ---------------------------------------------------------------------------
(
  export REVIEW_BOTS_MYCO_TRIGGER='/myco scan'
  export REVIEW_BOTS_MYCO_LOGIN='myco-bot[bot]'
  parse_review_bots 'q myco' >/dev/null 2>&1
)
assert_rc "q + custom bot via env vars → rc=0" 0 "$?"

(
  export REVIEW_BOTS_MYCO_TRIGGER='/myco scan'
  # LOGIN missing on purpose
  parse_review_bots 'myco' >/dev/null 2>&1
)
assert_rc "custom bot missing _LOGIN → rc=1" 1 "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RB-05: get_bot_trigger / get_bot_login (built-ins) ==="
# ---------------------------------------------------------------------------
assert_eq "q trigger"     "/q review"             "$(get_bot_trigger q)"
assert_eq "q login"       "amazon-q-developer[bot]" "$(get_bot_login q)"
assert_eq "codex trigger" "/codex review"         "$(get_bot_trigger codex)"
assert_eq "codex login"   "codex[bot]"            "$(get_bot_login codex)"
# Critical: Claude uses @claude, NOT /claude (per anthropics/claude-code-action docs).
assert_eq "claude trigger uses @ not /"  "@claude review" "$(get_bot_trigger claude)"
assert_eq "claude login"  "claude[bot]"           "$(get_bot_login claude)"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RB-06: get_bot_trigger / get_bot_login (custom via env) ==="
# ---------------------------------------------------------------------------
(
  export REVIEW_BOTS_ACME_TRIGGER='/acme scan'
  export REVIEW_BOTS_ACME_LOGIN='acme-reviewer[bot]'
  result_trigger=$(get_bot_trigger acme)
  result_login=$(get_bot_login acme)
  if [[ "$result_trigger" == "/acme scan" && "$result_login" == "acme-reviewer[bot]" ]]; then
    echo -e "  ${GREEN}PASS${NC}: custom bot resolves both fields"
    exit 0
  else
    echo -e "  ${RED}FAIL${NC}: custom bot lookup wrong (trigger='$result_trigger' login='$result_login')"
    exit 1
  fi
)
case "$?" in
  0) PASS=$((PASS + 1)) ;;
  *) FAIL=$((FAIL + 1)) ;;
esac

# Unknown bot with no env vars → both helpers return 1.
get_bot_trigger nonexistent >/dev/null 2>&1
assert_rc "get_bot_trigger unknown → rc=1" 1 "$?"
get_bot_login nonexistent >/dev/null 2>&1
assert_rc "get_bot_login unknown → rc=1" 1 "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RB-07: render_bot_review_section ==="
# ---------------------------------------------------------------------------
# Empty REVIEW_BOTS → no output, no header.
out=$(render_bot_review_section "" 42 "myorg/myrepo")
assert_eq "empty REVIEW_BOTS → no output" "" "$out"

# Non-empty → header + per-bot subsections + correct trigger/login.
out=$(render_bot_review_section "q codex" 42 "myorg/myrepo")
assert_contains "header present"           "Configured Review Bots — MANDATORY" "$out"
assert_contains "lists configured bots"    "this project: q codex"              "$out"
assert_contains "q section header"         "### Bot: q"                         "$out"
assert_contains "q trigger"                "/q review"                          "$out"
assert_contains "q login"                  "amazon-q-developer[bot]"            "$out"
assert_contains "codex section"            "### Bot: codex"                     "$out"
assert_contains "codex trigger"            "/codex review"                      "$out"
assert_contains "PR number interpolated"   "/pulls/42/reviews"                  "$out"
assert_contains "repo interpolated"        "myorg/myrepo"                       "$out"
assert_contains "fail-on-timeout language" "FAIL the PR"                        "$out"

# Claude uses @claude review (regression guard for the most-likely-typo'd field).
out=$(render_bot_review_section "claude" 99 "x/y")
assert_contains "claude section uses @claude not /claude" "@claude review" "$out"
if [[ "$out" == *"/claude review"* ]]; then
  echo -e "  ${RED}FAIL${NC}: rendered output contains /claude review (should be @claude review)"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: rendered output does not contain /claude review"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
