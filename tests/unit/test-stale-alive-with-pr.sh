#!/bin/bash
# test-stale-alive-with-pr.sh — Regression tests for issue #54.
#
# Verifies that the dispatcher's Step 5 has an ALIVE+PR-ready branch that
# kills the lingering wrapper process and transitions to pending-review when:
#   - PID is alive
#   - PR exists for the issue
#   - All CI checks pass (and are non-empty)
#   - PR has been idle (no updates) for >300s
#
# See docs/designs/dispatcher-stale-alive-with-pr.md
# Run: bash tests/unit/test-stale-alive-with-pr.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected to contain '$needle')"
    FAIL=$((FAIL+1))
  fi
}

# NOTE: avoid `grep -q` here — it exits early on first match, which combined
# with `set -o pipefail` and a large haystack (full SKILL.md) makes `echo` exit
# with SIGPIPE (rc=141). That gets propagated through the pipeline and the
# match is reported as a miss. Use full-output grep + stdout-emptiness instead.
assert_match() {
  local desc="$1" pattern="$2" haystack="$3"
  if [[ -n "$(grep -E "$pattern" <<<"$haystack")" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected to match '$pattern')"
    FAIL=$((FAIL+1))
  fi
}

assert_no_match() {
  local desc="$1" pattern="$2" haystack="$3"
  if [[ -z "$(grep -E "$pattern" <<<"$haystack")" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (should NOT match '$pattern')"
    FAIL=$((FAIL+1))
  fi
}

SKILL_FILE="$PROJECT_ROOT/skills/autonomous-dispatcher/SKILL.md"
[[ -f "$SKILL_FILE" ]] || { echo -e "${RED}FATAL${NC}: $SKILL_FILE not found"; exit 1; }
SKILL_CONTENT=$(cat "$SKILL_FILE")

# ============================================================================
# TC-DSAP-001: SKILL.md describes the new ALIVE-with-PR branch
# ============================================================================
echo
echo "=== TC-DSAP-001: SKILL.md ALIVE+PR branch ==="
echo

assert_contains "gh pr checks invocation"          "gh pr checks"  "$SKILL_CONTENT"
assert_contains "PR.updatedAt referenced"          "updatedAt"     "$SKILL_CONTENT"
assert_match    "SIGTERM mentioned (not -9/-KILL)" 'kill[^-9]'     "$SKILL_CONTENT"
assert_no_match "No SIGKILL on this path"          'kill -9|kill -KILL' "$SKILL_CONTENT"
assert_contains "5-minute idle threshold (300s)"   "300"           "$SKILL_CONTENT"
assert_contains "Transitions to pending-review"    "pending-review" "$SKILL_CONTENT"

# ============================================================================
# TC-DSAP-002: New wording is excluded from retry-counter regex
# ============================================================================
echo
echo "=== TC-DSAP-002: New wording is excluded from retry counter ==="
echo

NEW_WORDING="Dev process still alive but PR #117 is ready (all CI checks passed, idle 312s). Sent SIGTERM to PID 12345. Moving to pending-review."
RETRY_REGEX='Task appears to have crashed \(no PR found\)|process not found'

if echo "$NEW_WORDING" | grep -Eq "$RETRY_REGEX"; then
  echo -e "  ${RED}FAIL${NC}: new wording incorrectly matches retry regex"
  FAIL=$((FAIL+1))
else
  echo -e "  ${GREEN}PASS${NC}: new wording does not match retry regex"
  PASS=$((PASS+1))
fi

# ============================================================================
# TC-DSAP-003: Wording is distinct from other handoff phrases
# ============================================================================
echo
echo "=== TC-DSAP-003: Wording is distinct from prior handoffs ==="
echo

# The new comment must contain a phrase unique to this transition path
# ("still alive" or similar) so that historical comments can be classified.
assert_match "New comment carries 'still alive' marker phrase" \
  'still alive' "$NEW_WORDING"

# And the full distinguishing phrase ("still alive but PR") must appear in
# SKILL.md so the dispatcher implements it. (Plain "still alive" is too weak —
# it occurs in unrelated prose elsewhere.)
assert_contains "SKILL.md uses 'still alive but PR' marker" \
  "still alive but PR" "$SKILL_CONTENT"

# Negative checks — confirm the new wording is NOT a substring match of either
# of the other transition comments (would confuse downstream parsers).
OLD_DEAD_PR_FOUND="Dev process exited (PR found). Moving to pending-review for assessment."
OLD_NO_NEW_COMMITS='Dev process exited (no new commits since last review at `abc1234`). Moving to pending-dev for retry.'
if [[ "$NEW_WORDING" == *"Dev process exited"* ]]; then
  echo -e "  ${RED}FAIL${NC}: new wording overlaps with 'Dev process exited' phrase"
  FAIL=$((FAIL+1))
else
  echo -e "  ${GREEN}PASS${NC}: new wording does not collide with 'exited' transitions"
  PASS=$((PASS+1))
fi

# ============================================================================
# TC-DSAP-004: jq CI-green predicate works as documented
# ============================================================================
echo
echo "=== TC-DSAP-004: jq CI-green predicate ==="
echo

if ! command -v jq >/dev/null 2>&1; then
  echo -e "  ${RED}SKIP${NC}: jq not installed"
else
  predicate='length > 0 and all(. == "SUCCESS")'
  declare -A FIXTURES=(
    ["[]"]="false"
    ['["SUCCESS"]']="true"
    ['["SUCCESS","SUCCESS","SUCCESS"]']="true"
    ['["SUCCESS","PENDING"]']="false"
    ['["SUCCESS","FAILURE"]']="false"
    ['["SKIPPED","SUCCESS"]']="false"
  )
  for input in "${!FIXTURES[@]}"; do
    expected="${FIXTURES[$input]}"
    got=$(jq "$predicate" <<<"$input")
    if [[ "$got" == "$expected" ]]; then
      echo -e "  ${GREEN}PASS${NC}: predicate($input) = $expected"
      PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC}: predicate($input) expected $expected, got $got"
      FAIL=$((FAIL+1))
    fi
  done
fi

# ============================================================================
# TC-DSAP-005: Idle-time math is correct
# ============================================================================
echo
echo "=== TC-DSAP-005: Idle-time math ==="
echo

# Reference computation that SKILL.md should match: epoch-second delta.
PAST="2026-05-08T00:00:00Z"
NOW="2026-05-08T00:06:00Z"
PAST_EPOCH=$(date -u -d "$PAST" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$PAST" +%s 2>/dev/null)
NOW_EPOCH=$(date -u -d "$NOW" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$NOW" +%s 2>/dev/null)
IDLE=$(( NOW_EPOCH - PAST_EPOCH ))
if [[ "$IDLE" -ge 300 ]]; then
  echo -e "  ${GREEN}PASS${NC}: idle math (6 min) yields $IDLE seconds (>= 300)"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: idle math broken — got $IDLE seconds, expected >= 300"
  FAIL=$((FAIL+1))
fi

# Also assert SKILL.md uses the +%s / `date -d` pattern (or jq fromdateiso8601).
if [[ -n "$(grep -E 'date -[uU]? *-d|fromdateiso8601|date \+%s' <<<"$SKILL_CONTENT")" ]]; then
  echo -e "  ${GREEN}PASS${NC}: SKILL.md computes idle via known timestamp method"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: SKILL.md doesn't use date -d / fromdateiso8601 / date +%s"
  FAIL=$((FAIL+1))
fi

# ============================================================================
# TC-DSAP-006/7/8/9: Documentation assertions on the guard rails
# ============================================================================
echo
echo "=== TC-DSAP-006: Empty PR_INFO does NOT transition ==="
echo
assert_contains "Skip when no PR" "no PR yet" "$SKILL_CONTENT"

echo
echo "=== TC-DSAP-007: Non-green CI does NOT transition ==="
echo
assert_contains "Skip when CI not green" "CI not green" "$SKILL_CONTENT"

echo
echo "=== TC-DSAP-008: Recent activity (idle ≤ 300s) does NOT transition ==="
echo
assert_match "Idle gate documented" 'idle (>|>=|greater than) *300|> *300' "$SKILL_CONTENT"

echo
echo "=== TC-DSAP-009: SIGTERM not SIGKILL ==="
echo
# Already covered in TC-DSAP-001 (no -9/-KILL) — assert positively too.
if [[ -n "$(grep -E 'SIGTERM|kill -TERM|kill "?\$\{?[A-Z_]*PID' <<<"$SKILL_CONTENT")" ]]; then
  echo -e "  ${GREEN}PASS${NC}: SKILL.md uses SIGTERM (default kill signal)"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: SKILL.md does not use plain kill / SIGTERM"
  FAIL=$((FAIL+1))
fi

# ============================================================================
# TC-DSAP-010: Date-parse failure must NOT fall back to epoch 0
# ============================================================================
echo
echo "=== TC-DSAP-010: Date-parse fail-CLOSED ==="
echo
# Regression guard for the fail-OPEN bug surfaced in PR review:
# `PR_UPDATED_EPOCH=$(date -u -d ... || echo 0)` would make IDLE_SECONDS huge
# and unconditionally fire SIGTERM. The fix must NOT use `|| echo 0` *as the
# fallback specifically for PR_UPDATED_EPOCH*; it must either fail-closed
# (skip the issue this cycle) or use `$NOW_EPOCH` as the safe default.
#
# (Note: an unrelated `|| echo 0` is fine for CI_GREEN, where 0 means
#  "not green" — that is the safe direction.)
PR_EPOCH_BLOCK=$(awk '/PR_UPDATED_EPOCH=/{found=1} found{print; if (/\)$|fi$/) found=0}' \
  <<<"$SKILL_CONTENT")
if [[ -n "$(grep -E '\|\| *echo *0\b' <<<"$PR_EPOCH_BLOCK")" ]]; then
  echo -e "  ${RED}FAIL${NC}: SKILL.md still uses '|| echo 0' for PR_UPDATED_EPOCH (fail-OPEN regression)"
  FAIL=$((FAIL+1))
else
  echo -e "  ${GREEN}PASS${NC}: PR_UPDATED_EPOCH does not fall back to 0 (fail-CLOSED)"
  PASS=$((PASS+1))
fi
# Also assert that the parse-failure path is documented as leaving the issue
# alone (fail-CLOSED).
assert_contains "Date-parse failure documented as leave-alone" \
  "cannot parse PR.updatedAt" "$SKILL_CONTENT"

# ============================================================================
# TC-DSAP-011: BSD/macOS date fallback present
# ============================================================================
echo
echo "=== TC-DSAP-011: BSD/macOS date fallback ==="
echo
# `date -d` is GNU-only. Without a BSD fallback the dispatcher would
# misbehave on macOS even after the fail-CLOSED fix.
assert_match "macOS date -j -f fallback present" \
  'date -[uU]? *-j -f' "$SKILL_CONTENT"

# ============================================================================
# TC-DSAP-012: Null-guard on jq-extracted PR_NUM
# ============================================================================
echo
echo "=== TC-DSAP-012: PR_NUM null-guard ==="
echo
# Without a guard, malformed PR_INFO → PR_NUM='null' → `gh pr checks "null"`
# 404 forever.
assert_match "PR_NUM validated as positive integer" \
  'PR_NUM.*=~.*\^\[0-9\]\+\$|\[\[.*PR_NUM.*\[0-9\]' "$SKILL_CONTENT"

# ============================================================================
# TC-DSAP-013: PID re-verified before SIGTERM
# ============================================================================
echo
echo "=== TC-DSAP-013: PID re-verified before SIGTERM ==="
echo
# Mitigates PID-reuse hazard between the earlier kill -0 check and the actual
# kill. SKILL.md must show a recheck (kill -0) inside the new branch, not just
# at the top.
RECHECK_COUNT=$(grep -c 'kill -0 "\$PID"' <<<"$SKILL_CONTENT" || true)
if [[ "$RECHECK_COUNT" -ge 2 ]]; then
  echo -e "  ${GREEN}PASS${NC}: PID is rechecked with kill -0 inside Step 5a (count=${RECHECK_COUNT})"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: only ${RECHECK_COUNT} 'kill -0 \"\$PID\"' calls found (expected at least 2: liveness + pre-SIGTERM recheck)"
  FAIL=$((FAIL+1))
fi

# ============================================================================
# TC-DSAP-014: gh pr checks failure produces a diagnostic
# ============================================================================
echo
echo "=== TC-DSAP-014: gh pr checks failure is observable ==="
echo
# The original `2>/dev/null || echo '[]'` discarded stderr. The fix must
# capture it and surface it (via WARN log or stderr) so a chronic gh failure
# is diagnosable instead of silently skipping issues forever.
assert_contains "gh pr checks failure logged" \
  "gh pr checks failed" "$SKILL_CONTENT"

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo -e "Total: $TOTAL  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}"
echo

[[ $FAIL -gt 0 ]] && exit 1
exit 0
