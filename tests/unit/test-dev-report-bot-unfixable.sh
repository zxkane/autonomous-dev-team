#!/bin/bash
# test-dev-report-bot-unfixable.sh — #274 / INV-85, review [P1] finding 1.
#
# Unit tests for lib-dispatch.sh::dev_report_bot_unfixable — the dev-author +
# HEAD-cycle scoped detector for the bot-permission 403 signature
# (`(issue, current_head)`). Exercises the REAL function (not a mock) against a
# scripted `gh issue view` that returns a fixed comments JSON (with
# `.author.login` per comment), so the dev-author allow-list (resolved from the
# `Agent Session Report (Dev)` comment), the `since_iso` HEAD-cycle window, the
# review-comment exclusion, and the RE2-safe jq filters are all verified.
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
  # `gh issue view ... --json comments [-q <prog>]`. With `-q`/`--jq` (the
  # dev-login + since_iso lookups), run the program against the fixture. Without
  # it (the bare `--json comments` the hits-scan pipes to a standalone jq), emit
  # the raw fixture JSON so the downstream `| jq --arg ...` sees real data.
  local prog=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-q" || "$1" == "--jq" ]]; then prog="$2"; shift 2; continue; fi
    shift
  done
  [[ -n "$prog" ]] || { printf '%s' "$_MOCK_COMMENTS_JSON"; return 0; }
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

echo "=== dev_report_bot_unfixable dev-author + HEAD-cycle scoping (#274 INV-85) ==="
# All fixtures carry `.author.login`. The dev agent authors `dev-bot[bot]` and
# its `Agent Session Report (Dev)` comment (the dev-login anchor); reviewers and
# maintainers author distinct logins so the author allow-list can be exercised.

# BU-001: a dev-authored, in-window 403 on a PR edit → unfixable (rc 0).
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:00:00Z","author":{"login":"kane-review-agent"},"body":"Reviewed HEAD: `oldsha` (issue #1)"},
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"dev-bot[bot]"},"body":"I hit 403 Resource not accessible by integration running gh pr edit on the PR body"},
  {"createdAt":"2026-06-26T11:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s1`"}
]}'
assert_rc "BU-001 in-window dev 403 on pr edit → unfixable" 0 dev_report_bot_unfixable 100 "newsha"

# BU-002: the only 403 is OLDER than the last different-HEAD trailer → out of
# window → NOT unfixable (an old 403 self-expires once a newer trailer lands).
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T09:00:00Z","author":{"login":"dev-bot[bot]"},"body":"older 403 Resource not accessible by integration on gh pr edit"},
  {"createdAt":"2026-06-26T10:00:00Z","author":{"login":"kane-review-agent"},"body":"Reviewed HEAD: `oldsha` (issue #1)"},
  {"createdAt":"2026-06-26T10:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s2`"}
]}'
assert_rc "BU-002 stale 403 before window → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha"

# BU-003: a dev 403 but NO PR-metadata context → not the signature → NOT unfixable.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"dev-bot[bot]"},"body":"build failed with Resource not accessible by integration on the issues API"},
  {"createdAt":"2026-06-26T11:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s3`"}
]}'
assert_rc "BU-003 403 without PR-edit context → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha"

# BU-004: no 403 anywhere → NOT unfixable.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"dev-bot[bot]"},"body":"normal progress comment, all good"},
  {"createdAt":"2026-06-26T11:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s4`"}
]}'
assert_rc "BU-004 no 403 → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha"

# BU-005: null comment body does not abort the filter (#148 guard); a sibling
# dev 403 still matches → unfixable.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"dev-bot[bot]"},"body":null},
  {"createdAt":"2026-06-26T11:30:00Z","author":{"login":"dev-bot[bot]"},"body":"403 Resource not accessible by integration — PATCH /repos/o/r/pulls/5 (PR body edit)"},
  {"createdAt":"2026-06-26T11:40:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s5`"}
]}'
assert_rc "BU-005 null body tolerated, sibling dev 403 → unfixable" 0 dev_report_bot_unfixable 100 "newsha"

# BU-006: first review cycle (no prior different-HEAD trailer → no lower bound) —
# a dev 403 with PR context still counts (conservative-toward-escalate; caller
# additionally gates on same-HEAD).
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"dev-bot[bot]"},"body":"403 Resource not accessible by integration on gh pr edit (PR body)"},
  {"createdAt":"2026-06-26T11:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s6`"}
]}'
assert_rc "BU-006 first cycle (no prior trailer) → unfixable" 0 dev_report_bot_unfixable 100 "newsha"

# BU-007: a `Reviewed HEAD: \`newsha\`` (SAME current head) trailer does NOT close
# the window — only a DIFFERENT-SHA trailer does. The in-window dev 403 counts.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:00:00Z","author":{"login":"kane-review-agent"},"body":"Reviewed HEAD: `oldsha` (issue)"},
  {"createdAt":"2026-06-26T10:30:00Z","author":{"login":"kane-review-agent"},"body":"Reviewed HEAD: `newsha` (issue)"},
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"dev-bot[bot]"},"body":"403 Resource not accessible by integration on gh pr edit PR body"},
  {"createdAt":"2026-06-26T11:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s7`"}
]}'
assert_rc "BU-007 same-head trailer ignored for window → unfixable" 0 dev_report_bot_unfixable 100 "newsha"

# --- dev-author allow-list + review/maintainer exclusion (#274 review [P1]) ---

# BU-010: a REVIEW-AGENT comment quoting the 403 → different author → NOT counted.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:30:00Z","author":{"login":"kane-review-agent"},"body":"Review findings:\n1. [P1] The dev hit 403 Resource not accessible by integration on gh pr edit (PR body) — handle it.\nReview Agent: codex"},
  {"createdAt":"2026-06-26T10:40:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s10`"}
]}'
assert_rc "BU-010 review comment quoting 403 → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha"

# BU-011: a review quote AND a genuine DEV 403 in the same window → the dev one
# still counts (the review comment is a different author).
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:20:00Z","author":{"login":"kane-review-agent"},"body":"Review findings:\n1. quotes 403 Resource not accessible by integration on gh pr edit.\nReview Session: `r1`"},
  {"createdAt":"2026-06-26T10:40:00Z","author":{"login":"dev-bot[bot]"},"body":"dev here: I genuinely hit 403 Resource not accessible by integration editing the PR body via gh pr edit"},
  {"createdAt":"2026-06-26T10:50:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s11`"}
]}'
assert_rc "BU-011 dev 403 counts despite a sibling review quote" 0 dev_report_bot_unfixable 100 "newsha"

# BU-012 (round-4 finding 2 regression): the agent's completion 403 is posted
# DURING the run, before the cleanup-time `Agent Session Report (Dev)` trailer.
# The cycle-window bound includes it → still counted.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:00:00Z","author":{"login":"kane-review-agent"},"body":"Reviewed HEAD: `oldsha` (issue #1)"},
  {"createdAt":"2026-06-26T10:30:00Z","author":{"login":"dev-bot[bot]"},"body":"I cannot edit the PR body: 403 Resource not accessible by integration on gh pr edit. This is a maintainer action."},
  {"createdAt":"2026-06-26T10:40:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `sess-CURRENT`\n- Exit code: 0"}
]}'
assert_rc "BU-012 agent completion 403 before the session-report trailer → unfixable" 0 dev_report_bot_unfixable 100 "newsha"

# BU-013: a dev 403 from a PRIOR HEAD's cycle (before the most recent
# different-HEAD trailer) → out of window → NOT unfixable.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T09:00:00Z","author":{"login":"dev-bot[bot]"},"body":"prior-cycle 403 Resource not accessible by integration on gh pr edit (PR body)"},
  {"createdAt":"2026-06-26T10:00:00Z","author":{"login":"kane-review-agent"},"body":"Reviewed HEAD: `oldsha` (issue #1)"},
  {"createdAt":"2026-06-26T10:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s13`"}
]}'
assert_rc "BU-013 403 before the prior-HEAD trailer → out of window → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha"

# BU-014 (#274 review [P1] round-5): a MAINTAINER/OWNER comment (not a review
# agent — so the review-marker exclusion would NOT drop it) quoting the 403 with
# PR-edit text must NOT stall the active attempt. Only the author allow-list
# excludes it. The dev attempt itself never hit the 403.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:00:00Z","author":{"login":"kane-review-agent"},"body":"Reviewed HEAD: `oldsha` (issue #1)"},
  {"createdAt":"2026-06-26T10:30:00Z","author":{"login":"zxkane"},"body":"FYI the bot gets 403 Resource not accessible by integration when it tries gh pr edit on the PR body — Ill handle the metadata myself."},
  {"createdAt":"2026-06-26T10:40:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s14`"}
]}'
assert_rc "BU-014 maintainer quoting 403 (non-review) → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha"

# BU-015: no dev session report at all → dev author unresolvable → fail-open
# (NOT unfixable), even though a dev-looking 403 is present.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"dev-bot[bot]"},"body":"403 Resource not accessible by integration on gh pr edit (PR body)"}
]}'
assert_rc "BU-015 no dev session report → unresolvable author → NOT unfixable (fail-open)" 1 dev_report_bot_unfixable 100 "newsha"

echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
