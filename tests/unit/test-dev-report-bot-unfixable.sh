#!/bin/bash
# test-dev-report-bot-unfixable.sh — #274 / INV-85, review [P1] finding 1.
#
# Unit tests for lib-dispatch.sh::dev_report_bot_unfixable — the HEAD-window-
# scoped detector for the bot-permission 403 signature. Exercises the REAL
# function (not a mock) against a scripted `gh issue view` that returns a
# fixed comments JSON, so the internal `since_iso` window + RE2-safe jq
# filters are verified.
#
# Run: bash tests/unit/test-dev-report-bot-unfixable.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID="test-botunfix-$$"
export MAX_RETRIES=3
export MAX_CONCURRENT=5

log() { :; }

# Scripted comments JSON, set per test. The gh mock runs the requested jq `-q`
# program against it, faithfully reproducing what the real gh would return
# (so the function's own jq filters are under test, not stubbed away).
_MOCK_COMMENTS_JSON='{"comments":[]}'

gh() {
  # Only `gh issue view ... --json comments -q <prog>` is exercised here.
  local prog=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-q" || "$1" == "--jq" ]]; then prog="$2"; shift 2; continue; fi
    shift
  done
  [[ -n "$prog" ]] || { printf '%s' ""; return 0; }
  jq -r "$prog" <<<"$_MOCK_COMMENTS_JSON"
}

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
# lib-dispatch.sh runs `set -euo pipefail` at source time; re-disable -e so
# assert_rc can capture a non-zero return code without aborting the suite. The
# `log`/`gh` mocks defined above survive the source (the lib defines neither).
set +e

assert_rc() {
  local desc="$1" expected="$2"; shift 2
  "$@"; local rc=$?
  if [[ "$rc" -eq "$expected" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (rc=$rc expected=$expected)"; FAIL=$((FAIL + 1))
  fi
}

echo "=== dev_report_bot_unfixable HEAD-window scoping (#274 INV-85) ==="

# BU-001: a 403-on-PR-edit comment within the current HEAD's window → unfixable (rc 0).
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:00:00Z","body":"Reviewed HEAD: `oldsha` (issue #1)"},
  {"createdAt":"2026-06-26T11:00:00Z","body":"I hit 403 Resource not accessible by integration running gh pr edit on the PR body"}
]}'
assert_rc "BU-001 in-window 403 on pr edit → unfixable" 0 dev_report_bot_unfixable 100 "newsha"

# BU-002: the ONLY 403 is OLDER than the last different-HEAD trailer → stale, out
# of window → NOT unfixable (rc 1). This is the [P1] finding-1 regression: an old
# 403 must self-expire once a newer review cycle's trailer lands.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T09:00:00Z","body":"older 403 Resource not accessible by integration on gh pr edit"},
  {"createdAt":"2026-06-26T10:00:00Z","body":"Reviewed HEAD: `oldsha` (issue #1)"}
]}'
assert_rc "BU-002 stale 403 before window → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha"

# BU-003: a 403 but NO PR-metadata context → not the signature → NOT unfixable.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T11:00:00Z","body":"build failed with Resource not accessible by integration on the issues API"}
]}'
assert_rc "BU-003 403 without PR-edit context → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha"

# BU-004: no 403 anywhere → NOT unfixable.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T11:00:00Z","body":"normal progress comment, all good"}
]}'
assert_rc "BU-004 no 403 → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha"

# BU-005: null comment body does not abort the filter (#148 guard) and a sibling
# in-window 403 still matches → unfixable.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T11:00:00Z","body":null},
  {"createdAt":"2026-06-26T11:30:00Z","body":"403 Resource not accessible by integration — PATCH /repos/o/r/pulls/5 (PR body edit)"}
]}'
assert_rc "BU-005 null body tolerated, sibling 403 → unfixable" 0 dev_report_bot_unfixable 100 "newsha"

# BU-006: first review cycle (no prior different-HEAD trailer, since_iso empty) —
# an in-history 403 with PR context still counts (conservative-toward-escalate on
# the genuinely-first cycle; the caller additionally gates on same-HEAD).
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T11:00:00Z","body":"403 Resource not accessible by integration on gh pr edit (PR body)"}
]}'
assert_rc "BU-006 first cycle (no prior trailer) → unfixable" 0 dev_report_bot_unfixable 100 "newsha"

# BU-007: trailer for the SAME current head does NOT close the window (the
# capture must ignore a `Reviewed HEAD: \`newsha\`` trailer) — an in-window 403
# after a DIFFERENT-head trailer but also after the same-head trailer still counts.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:00:00Z","body":"Reviewed HEAD: `oldsha` (issue)"},
  {"createdAt":"2026-06-26T10:30:00Z","body":"Reviewed HEAD: `newsha` (issue)"},
  {"createdAt":"2026-06-26T11:00:00Z","body":"403 Resource not accessible by integration on gh pr edit PR body"}
]}'
assert_rc "BU-007 same-head trailer ignored for window → unfixable" 0 dev_report_bot_unfixable 100 "newsha"

# --- #274 review [P1] round-3: active-attempt scoping (3rd arg = session_id) ---

# BU-008: a 403 reported BEFORE the current session's `Dev Session ID:` comment
# is from a PRIOR attempt → NOT counted (active-attempt lower bound). This is the
# round-3 finding-1 regression: only the CURRENT dev attempt's 403 should stall.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T09:00:00Z","body":"prior attempt 403 Resource not accessible by integration on gh pr edit (PR body)"},
  {"createdAt":"2026-06-26T10:00:00Z","body":"**Agent Session Report (Dev)**\n- Dev Session ID: `sess-CURRENT`"}
]}'
assert_rc "BU-008 403 before current session start → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha" "sess-CURRENT"

# BU-009: a 403 reported AFTER the current session's `Dev Session ID:` comment IS
# the active attempt → unfixable.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:00:00Z","body":"**Agent Session Report (Dev)**\n- Dev Session ID: `sess-CURRENT`"},
  {"createdAt":"2026-06-26T10:30:00Z","body":"I hit 403 Resource not accessible by integration on gh pr edit (PR body)"}
]}'
assert_rc "BU-009 403 after current session start → unfixable" 0 dev_report_bot_unfixable 100 "newsha" "sess-CURRENT"

# BU-010: a REVIEW-AGENT comment that QUOTES the 403 while describing the bug is
# excluded → NOT unfixable. This is the round-3 finding-1 core case: a reviewer
# (or human) merely mentioning the signature must not stall the active attempt.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:00:00Z","body":"**Agent Session Report (Dev)**\n- Dev Session ID: `sess-CURRENT`"},
  {"createdAt":"2026-06-26T10:30:00Z","body":"Review findings:\n1. [P1] The dev hit 403 Resource not accessible by integration on gh pr edit (PR body) — handle it.\nReview Agent: codex"}
]}'
assert_rc "BU-010 review comment quoting 403 excluded → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha" "sess-CURRENT"

# BU-011: review comment quoting the 403 AND a genuine dev 403 in the same
# window → the dev one still counts (exclusion drops only the review comment).
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:00:00Z","body":"**Agent Session Report (Dev)**\n- Dev Session ID: `sess-CURRENT`"},
  {"createdAt":"2026-06-26T10:20:00Z","body":"Review findings:\n1. quotes 403 Resource not accessible by integration on gh pr edit.\nReview Session: `r1`"},
  {"createdAt":"2026-06-26T10:40:00Z","body":"dev here: I genuinely hit 403 Resource not accessible by integration editing the PR body via gh pr edit"}
]}'
assert_rc "BU-011 dev 403 counts despite a sibling review quote" 0 dev_report_bot_unfixable 100 "newsha" "sess-CURRENT"

echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
