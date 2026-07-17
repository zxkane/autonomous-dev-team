#!/bin/bash
# test-dev-report-bot-unfixable.sh — #274 / INV-85, review [P1] finding 1.
#
# Unit tests for lib-dispatch.sh::dev_report_bot_unfixable — the dev-author +
# per-attempt scoped detector for the bot-permission 403 signature. Exercises the
# REAL function (not a mock) against a scripted `gh issue view` that returns a
# fixed comments JSON (with `.author.login` per comment), so the dev-author
# allow-list (resolved from the `Agent Session Report (Dev)` comment), the
# per-attempt `since_iso` lower bound (the current `dispatcher-token ...
# mode=dev-*` comment), the review-comment exclusion, and the RE2-safe jq filters
# are all verified.
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
  # [#393] itp_list_comments reads REST (gh api --paginate --slurp .../comments).
  # Serve the GraphQL-style fixture converted to REST page shape (type=Bot iff
  # login ends [bot]; id=ordinal), so authorKind derivation works unchanged.
  if [[ "${1:-}" == "api" && "${2:-}" == "--paginate" ]]; then
    jq '(if type == "object" then (.comments // []) else . end) | [ [ .[] | {id: 0, user: {login: (.author.login // ""), type: (if ((.author.login // "") | endswith("[bot]")) then "Bot" else "User" end)}, body: (.body // ""), created_at: (.createdAt // null)} ] | to_entries | map(.value + {id: (.key + 1)}) ]' <<<"${_MOCK_COMMENTS_JSON:-[]}"
    return 0
  fi
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

echo "=== dev_report_bot_unfixable dev-author + per-attempt scoping (#274 INV-85) ==="
# All fixtures carry `.author.login`. The dev agent authors `dev-bot[bot]` and
# its `Agent Session Report (Dev)` comment (the dev-login anchor); the dispatcher
# (`my-claw`) posts the `dispatcher-token ... mode=dev-*` comment that anchors the
# current dev attempt's lower bound; reviewers/maintainers author distinct logins.
DTOK='"<!-- dispatcher-token: abc123 at 2026-06-26T10:45:00Z mode=dev-new -->\nResuming autonomous development..."'

# BU-001: a dev-authored 403 (on a PR edit) AFTER the current dev-dispatch token
# → in window → unfixable (rc 0).
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:45:00Z","author":{"login":"my-claw"},"body":'"$DTOK"'},
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"dev-bot[bot]"},"body":"I hit 403 Resource not accessible by integration running gh pr edit on the PR body"},
  {"createdAt":"2026-06-26T11:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s1`"}
]}'
assert_rc "BU-001 in-attempt dev 403 on pr edit → unfixable" 0 dev_report_bot_unfixable 100 "newsha"

# BU-002: the only 403 is OLDER than the current dev-dispatch token → out of
# window → NOT unfixable (a prior attempt's 403 expires at the next dispatch).
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T09:00:00Z","author":{"login":"dev-bot[bot]"},"body":"older 403 Resource not accessible by integration on gh pr edit"},
  {"createdAt":"2026-06-26T10:45:00Z","author":{"login":"my-claw"},"body":'"$DTOK"'},
  {"createdAt":"2026-06-26T10:50:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s2`"}
]}'
assert_rc "BU-002 403 before current dev-dispatch token → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha"

# BU-003: a dev 403 but NO PR-metadata context → not the signature → NOT unfixable.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:45:00Z","author":{"login":"my-claw"},"body":'"$DTOK"'},
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"dev-bot[bot]"},"body":"build failed with Resource not accessible by integration on the issues API"},
  {"createdAt":"2026-06-26T11:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s3`"}
]}'
assert_rc "BU-003 403 without PR-edit context → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha"

# BU-004: no 403 anywhere → NOT unfixable.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:45:00Z","author":{"login":"my-claw"},"body":'"$DTOK"'},
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"dev-bot[bot]"},"body":"normal progress comment, all good"},
  {"createdAt":"2026-06-26T11:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s4`"}
]}'
assert_rc "BU-004 no 403 → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha"

# BU-005: null comment body does not abort the filter (#148 guard); a sibling
# in-attempt dev 403 still matches → unfixable.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:45:00Z","author":{"login":"my-claw"},"body":'"$DTOK"'},
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"dev-bot[bot]"},"body":null},
  {"createdAt":"2026-06-26T11:30:00Z","author":{"login":"dev-bot[bot]"},"body":"403 Resource not accessible by integration — PATCH /repos/o/r/pulls/5 (PR body edit)"},
  {"createdAt":"2026-06-26T11:40:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s5`"}
]}'
assert_rc "BU-005 null body tolerated, sibling dev 403 → unfixable" 0 dev_report_bot_unfixable 100 "newsha"

# BU-006: no dev-dispatch token at all (no lower bound) — a dev 403 with PR
# context still counts (conservative-toward-escalate; caller gates on same-HEAD).
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"dev-bot[bot]"},"body":"403 Resource not accessible by integration on gh pr edit (PR body)"},
  {"createdAt":"2026-06-26T11:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s6`"}
]}'
assert_rc "BU-006 no dev-dispatch token (no bound) → unfixable" 0 dev_report_bot_unfixable 100 "newsha"

# BU-007: a `mode=review` dispatch token does NOT move the bound — only a
# `mode=dev-*` token does. The dev 403 after the dev token (but with a later
# review token) still counts.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:45:00Z","author":{"login":"my-claw"},"body":'"$DTOK"'},
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"dev-bot[bot]"},"body":"403 Resource not accessible by integration on gh pr edit PR body"},
  {"createdAt":"2026-06-26T11:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s7`"},
  {"createdAt":"2026-06-26T11:20:00Z","author":{"login":"my-claw"},"body":"<!-- dispatcher-token: rev999 at 2026-06-26T11:20:00Z mode=review -->\nDispatching autonomous review..."}
]}'
assert_rc "BU-007 mode=review token does not move the bound → unfixable" 0 dev_report_bot_unfixable 100 "newsha"

# --- dev-author allow-list + review/maintainer exclusion (#274 review [P1]) ---

# BU-010: a REVIEW-AGENT comment quoting the 403 → different author → NOT counted.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:45:00Z","author":{"login":"my-claw"},"body":'"$DTOK"'},
  {"createdAt":"2026-06-26T10:50:00Z","author":{"login":"kane-review-agent"},"body":"Review findings:\n1. [P1] The dev hit 403 Resource not accessible by integration on gh pr edit (PR body) — handle it.\nReview Agent: codex"},
  {"createdAt":"2026-06-26T10:55:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s10`"}
]}'
assert_rc "BU-010 review comment quoting 403 → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha"

# BU-011: a review quote AND a genuine DEV 403 in the same window → the dev one
# still counts (the review comment is a different author).
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:45:00Z","author":{"login":"my-claw"},"body":'"$DTOK"'},
  {"createdAt":"2026-06-26T10:50:00Z","author":{"login":"kane-review-agent"},"body":"Review findings:\n1. quotes 403 Resource not accessible by integration on gh pr edit.\nReview Session: `r1`"},
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"dev-bot[bot]"},"body":"dev here: I genuinely hit 403 Resource not accessible by integration editing the PR body via gh pr edit"},
  {"createdAt":"2026-06-26T11:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s11`"}
]}'
assert_rc "BU-011 dev 403 counts despite a sibling review quote" 0 dev_report_bot_unfixable 100 "newsha"

# BU-012 (round-4 finding 2 regression): the agent's completion 403 is posted
# DURING the run — AFTER the dev-dispatch token, BEFORE the cleanup-time
# `Agent Session Report (Dev)` trailer. The per-attempt window includes it.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:45:00Z","author":{"login":"my-claw"},"body":'"$DTOK"'},
  {"createdAt":"2026-06-26T10:50:00Z","author":{"login":"dev-bot[bot]"},"body":"I cannot edit the PR body: 403 Resource not accessible by integration on gh pr edit. This is a maintainer action."},
  {"createdAt":"2026-06-26T10:55:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `sess-CURRENT`\n- Exit code: 0"}
]}'
assert_rc "BU-012 agent completion 403 (after dev token, before report) → unfixable" 0 dev_report_bot_unfixable 100 "newsha"

# BU-013: a dev 403 from a PRIOR attempt (before the current dev-dispatch token)
# → out of window → NOT unfixable.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T09:00:00Z","author":{"login":"dev-bot[bot]"},"body":"prior-attempt 403 Resource not accessible by integration on gh pr edit (PR body)"},
  {"createdAt":"2026-06-26T10:45:00Z","author":{"login":"my-claw"},"body":'"$DTOK"'},
  {"createdAt":"2026-06-26T10:50:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s13`"}
]}'
assert_rc "BU-013 403 before the current dev token → out of window → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha"

# BU-014 (#274 review [P1] round-5): a MAINTAINER/OWNER comment (not a review
# agent — so the review-marker exclusion would NOT drop it) quoting the 403 with
# PR-edit text must NOT stall the active attempt. Only the author allow-list
# excludes it.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:45:00Z","author":{"login":"my-claw"},"body":'"$DTOK"'},
  {"createdAt":"2026-06-26T10:50:00Z","author":{"login":"zxkane"},"body":"FYI the bot gets 403 Resource not accessible by integration when it tries gh pr edit on the PR body — Ill handle the metadata myself."},
  {"createdAt":"2026-06-26T10:55:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s14`"}
]}'
assert_rc "BU-014 maintainer quoting 403 (non-review) → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha"

# BU-015: no dev session report at all → dev author unresolvable → fail-open
# (NOT unfixable), even though a dev-looking 403 is present.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:45:00Z","author":{"login":"my-claw"},"body":'"$DTOK"'},
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"dev-bot[bot]"},"body":"403 Resource not accessible by integration on gh pr edit (PR body)"}
]}'
assert_rc "BU-015 no dev session report → unresolvable author → NOT unfixable (fail-open)" 1 dev_report_bot_unfixable 100 "newsha"

# BU-016 (#274 review [P1] round-6 regression): a PRIOR same-HEAD attempt hit a
# 403; a maintainer fixed the PR metadata (no new commit); the issue was
# re-dispatched (a NEW dev-dispatch token); the new same-HEAD attempt did NOT hit
# the 403 (the obstacle is gone). The old 403 must EXPIRE at the new token →
# NOT unfixable, so the new finding gets its bounded retry.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T09:00:00Z","author":{"login":"my-claw"},"body":"<!-- dispatcher-token: old111 at 2026-06-26T09:00:00Z mode=dev-new -->\nDispatching autonomous development..."},
  {"createdAt":"2026-06-26T09:30:00Z","author":{"login":"dev-bot[bot]"},"body":"prior attempt: 403 Resource not accessible by integration on gh pr edit (PR body)"},
  {"createdAt":"2026-06-26T09:40:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s16a`"},
  {"createdAt":"2026-06-26T10:00:00Z","author":{"login":"zxkane"},"body":"Fixed the PR body metadata myself; re-dispatching."},
  {"createdAt":"2026-06-26T10:45:00Z","author":{"login":"my-claw"},"body":'"$DTOK"'},
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"dev-bot[bot]"},"body":"this attempt: addressed the new finding, no permission error this time"},
  {"createdAt":"2026-06-26T11:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s16b`"}
]}'
assert_rc "BU-016 prior same-HEAD 403 expires at the new dev token → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha"

# --- #511: structured dev-blocked-403 marker + success-comment veto + legacy fallback ---

echo ""
echo "=== dev_report_bot_unfixable structured marker + success-veto (#511) ==="

# BU-020 (#485-shape regression): a dev session that COMPLETED SUCCESSFULLY —
# pushed a new commit (HEAD moved from `aaaa785` to `bbbb785` during the
# attempt) and reported `Exit code: 0` — merely QUOTES the 403 signature about
# an incidental courtesy action (retriggering a flaked third-party CI run via
# `gh pr edit`/`gh run rerun`, which it cannot do). This must NOT be classified
# bot-unfixable: the head-move + exit-0 success-veto overrides the legacy
# substring match. Fails before the fix (old code returns unfixable here).
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-07-16T23:30:00Z","author":{"login":"kane-review-agent"},"body":"Review findings:\nReviewed HEAD: `aaaa785`\n1. [P1] fix the widget."},
  {"createdAt":"2026-07-16T23:47:00Z","author":{"login":"my-claw"},"body":"<!-- dispatcher-token: r4tok01 at 2026-07-16T23:47:00Z mode=dev-resume -->\nResuming autonomous development..."},
  {"createdAt":"2026-07-16T23:55:00Z","author":{"login":"dev-bot[bot]"},"body":"Fixed all review findings and pushed. I also tried gh run rerun and gh pr edit to retrigger a flaked third-party CI action, but got 403 Resource not accessible by integration on gh pr edit — that action is optional, please retrigger manually if needed."},
  {"createdAt":"2026-07-17T00:00:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s20`\n- Exit code: 0"}
]}'
assert_rc "BU-020 (#485 regression) success report + head moved + incidental 403 quote → NOT unfixable" 1 dev_report_bot_unfixable 100 "bbbb785"

# BU-021: a structured `dev-blocked-403` marker, dev-authored, in the current
# attempt window, with `head=` matching the caller-supplied current head →
# Branch A fires (unfixable), even with no legacy substring context at all.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:45:00Z","author":{"login":"my-claw"},"body":'"$DTOK"'},
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"dev-bot[bot]"},"body":"<!-- dev-blocked-403: head=newsha21 -->\nThis finding requires editing CODEOWNERS, which my scoped token cannot do."},
  {"createdAt":"2026-06-26T11:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s21`\n- Exit code: 1"}
]}'
assert_rc "BU-021 structured marker, matching head, in-window → unfixable" 0 dev_report_bot_unfixable 100 "newsha21"

# BU-022: the ONLY marker present has a STALE head (≠ the current PR head) —
# not unfixable. Presence of a (non-matching) marker also suppresses the
# legacy substring fallback (design point 3); no legacy text exists here anyway.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:45:00Z","author":{"login":"my-claw"},"body":'"$DTOK"'},
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"dev-bot[bot]"},"body":"<!-- dev-blocked-403: head=staleSHA -->\nBlocked on the old head."},
  {"createdAt":"2026-06-26T11:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s22`\n- Exit code: 1"}
]}'
assert_rc "BU-022 marker with stale head → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha22"

# BU-023a: a marker with a MATCHING head, but authored by a NON-DEV login
# (not the resolved dev agent author) → excluded by the existing author
# allow-list scoping; no legacy text present → NOT unfixable.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:45:00Z","author":{"login":"my-claw"},"body":'"$DTOK"'},
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"zxkane"},"body":"<!-- dev-blocked-403: head=newsha23 -->\nFYI I think this is blocked."},
  {"createdAt":"2026-06-26T11:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s23a`\n- Exit code: 1"}
]}'
assert_rc "BU-023a marker authored by non-dev login → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha23"

# BU-023b: a dev-authored marker with a matching head, but posted BEFORE the
# current dev-dispatch token (a prior attempt) → excluded by the existing
# per-attempt lower-bound scoping; no legacy text present → NOT unfixable.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T09:00:00Z","author":{"login":"dev-bot[bot]"},"body":"<!-- dev-blocked-403: head=newsha23b -->\nPrior-attempt marker."},
  {"createdAt":"2026-06-26T09:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s23b-prior`"},
  {"createdAt":"2026-06-26T10:45:00Z","author":{"login":"my-claw"},"body":'"$DTOK"'},
  {"createdAt":"2026-06-26T11:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s23b`\n- Exit code: 1"}
]}'
assert_rc "BU-023b dev-authored marker before current dispatch token → NOT unfixable" 1 dev_report_bot_unfixable 100 "newsha23b"

# BU-024 (legacy fallback preserved): NO marker anywhere in the window, a
# legacy 403-on-PR-edit substring IS present, and there is NO success-veto
# evidence (no `Exit code: 0` report at all) → still unfixable — INV-85
# protection for genuinely-blocked legacy sessions is preserved.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:45:00Z","author":{"login":"my-claw"},"body":'"$DTOK"'},
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"dev-bot[bot]"},"body":"403 Resource not accessible by integration on gh pr edit (PR body) — cannot proceed"},
  {"createdAt":"2026-06-26T11:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s24`\n- Exit code: 1"}
]}'
assert_rc "BU-024 legacy fallback, no marker, no success-veto evidence → unfixable" 0 dev_report_bot_unfixable 100 "newsha24"

# BU-025 (success-veto specifics): `Exit code: 0` IS present, but the HEAD did
# NOT move during the attempt (the pre-attempt `Reviewed HEAD:` trailer equals
# the caller-supplied current head) → the veto does NOT apply; a no-commit
# session that quotes a legacy 403 may genuinely be blocked → still unfixable.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-06-26T10:30:00Z","author":{"login":"kane-review-agent"},"body":"Review findings:\nReviewed HEAD: `cccc2500`\n1. [P1] fix it."},
  {"createdAt":"2026-06-26T10:45:00Z","author":{"login":"my-claw"},"body":'"$DTOK"'},
  {"createdAt":"2026-06-26T11:00:00Z","author":{"login":"dev-bot[bot]"},"body":"403 Resource not accessible by integration on gh pr edit (PR body) — cannot make the required metadata change"},
  {"createdAt":"2026-06-26T11:10:00Z","author":{"login":"dev-bot[bot]"},"body":"**Agent Session Report (Dev)**\n- Dev Session ID: `s25`\n- Exit code: 0"}
]}'
assert_rc "BU-025 exit-0 report but HEAD unmoved → veto does NOT apply → unfixable" 0 dev_report_bot_unfixable 100 "cccc2500"

echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
