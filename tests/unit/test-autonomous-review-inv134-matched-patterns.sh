#!/bin/bash
# test-autonomous-review-inv134-matched-patterns.sh — INV-134 / issue #488 D4.
#
# Proves the WRAPPER-SIDE wiring of the matched-protected-path-pattern
# stall-notice diagnostics in autonomous-review.sh: the block that computes
# `_AGG_MATCHED_PATTERNS` from the per-agent `AGENT_MATCHED_PATTERNS` array
# and — when non-empty — posts a dedicated findings comment carrying the
# `<!-- inv92-matched-patterns: ... -->` marker. Extracted verbatim via awk
# (mirroring test-autonomous-review-diffcap-wiring.sh's block-slice strategy)
# and driven in a sandbox with stubbed itp_post_comment.
#
#   TC-INV134-D4-05: aggregate dev-actionable=false, matched patterns present
#                     on the FAILing agent → comment posted naming the
#                     pattern(s) + the REVIEW_PROTECTED_PATHS conf lever +
#                     the machine-readable marker.
#   TC-INV134-D4-06: aggregate dev-actionable=true → no comment posted.
#   TC-INV134-D4-07: aggregate dev-actionable=false but no FAILing agent
#                     recorded a matched pattern → no comment posted.
#
# Run: bash tests/unit/test-autonomous-review-inv134-matched-patterns.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$desc"
  else bad "$desc"; echo "      expected: |$expected|"; echo "      actual:   |$actual|"; fi
}

[ -f "$WRAPPER" ] || { echo "FATAL: wrapper missing"; exit 2; }

# Extract the INV-134 D4 block verbatim from the wrapper: from the comment
# marking the start of the matched-patterns aggregation through the closing
# `fi` of the comment-post `if` (the SECOND top-level `if`/`fi` pair after the
# start marker — a plain `/start/,/^    fi$/` range would stop at the first
# block's own closing `fi`).
BLOCK_SLICE=$(mktemp)
trap 'rm -f "$BLOCK_SLICE"' EXIT
awk '
  /^    # INV-134 \(#488\) D4: when the aggregate derivation above forced$/ { active=1 }
  active {
    print
    if ($0 == "    fi") { fi_count++; if (fi_count == 2) { exit } }
  }
' "$WRAPPER" > "$BLOCK_SLICE"
[ -s "$BLOCK_SLICE" ] || { echo "FATAL: could not extract the INV-134 D4 block from the wrapper — has it moved/been renamed?"; exit 2; }
# Sanity: the slice must contain both the aggregation loop and the comment post.
grep -q 'AGENT_MATCHED_PATTERNS' "$BLOCK_SLICE" || { echo "FATAL: extracted slice missing AGENT_MATCHED_PATTERNS reference"; exit 2; }
grep -q 'inv92-matched-patterns' "$BLOCK_SLICE" || { echo "FATAL: extracted slice missing the marker literal"; exit 2; }

# _run_block <agg_dev_actionable> <agent_names_csv> <agent_verdicts_csv> <agent_matched_patterns_pipe_sep>
#
# agent_matched_patterns_pipe_sep: one field per agent, multiple patterns
# within a field separated by `;` (mapped to newlines inside the sandbox).
_run_block() {
  (
    set +e
    ISSUE_NUMBER=488
    _AGG_DEV_ACTIONABLE="$1"
    IFS=',' read -r -a AGENT_NAMES <<<"$2"
    IFS=',' read -r -a AGENT_VERDICTS <<<"$3"
    IFS=',' read -r -a _raw_patterns <<<"$4"
    declare -a AGENT_MATCHED_PATTERNS=()
    local _p
    for _p in "${_raw_patterns[@]}"; do
      AGENT_MATCHED_PATTERNS+=("${_p//;/$'\n'}")
    done
    _COMMENT_COUNT_FILE=$(mktemp)
    _COMMENT_BODY_FILE=$(mktemp)
    echo 0 > "$_COMMENT_COUNT_FILE"
    itp_post_comment() {
      local n; n=$(<"$_COMMENT_COUNT_FILE"); n=$((n + 1)); echo "$n" > "$_COMMENT_COUNT_FILE"
      printf '%s' "$2" > "$_COMMENT_BODY_FILE"
    }
    # shellcheck source=/dev/null
    source "$BLOCK_SLICE"
    echo "COMMENT_COUNT=$(<"$_COMMENT_COUNT_FILE")"
    echo "COMMENT_BODY=$(cat "$_COMMENT_BODY_FILE" 2>/dev/null | tr '\n' '|')"
    echo "AGG_MATCHED_PATTERNS=$(printf '%s' "${_AGG_MATCHED_PATTERNS:-}" | tr '\n' ',')"
    rm -f "$_COMMENT_COUNT_FILE" "$_COMMENT_BODY_FILE" 2>/dev/null
  )
}

_field() { grep "^$2=" <<<"$1" | head -1 | cut -d= -f2-; }

# ---------------------------------------------------------------------------
echo "=== TC-INV134-D4-05: dev-actionable=false, matched patterns present → comment posted ==="
# ---------------------------------------------------------------------------
OUT=$(_run_block "false" "codex" "fail" ".github/workflows/**;CODEOWNERS")
assert_eq "TC-INV134-D4-05 exactly one comment posted" "1" "$(_field "$OUT" COMMENT_COUNT)"
BODY=$(_field "$OUT" COMMENT_BODY)
case "$BODY" in
  *"Matched protected-path pattern(s): \`.github/workflows/**\`, \`CODEOWNERS\`"*) ok "TC-INV134-D4-05 comment names both matched patterns";;
  *) bad "TC-INV134-D4-05 comment should name both matched patterns"; echo "      got: $BODY";;
esac
case "$BODY" in
  *"REVIEW_PROTECTED_PATHS"*) ok "TC-INV134-D4-05 comment names the REVIEW_PROTECTED_PATHS conf lever";;
  *) bad "TC-INV134-D4-05 comment should name the REVIEW_PROTECTED_PATHS conf lever";;
esac
case "$BODY" in
  *"<!-- inv92-matched-patterns: .github/workflows/** CODEOWNERS -->"*) ok "TC-INV134-D4-05 comment carries the machine-readable marker";;
  *) bad "TC-INV134-D4-05 comment should carry the inv92-matched-patterns marker"; echo "      got: $BODY";;
esac

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-INV134-D4-06: dev-actionable=true → no matched-patterns comment ==="
# ---------------------------------------------------------------------------
OUT=$(_run_block "true" "codex" "fail" "")
assert_eq "TC-INV134-D4-06 no comment posted" "0" "$(_field "$OUT" COMMENT_COUNT)"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-INV134-D4-07: dev-actionable=false but no FAILing agent recorded a matched pattern → no comment ==="
# ---------------------------------------------------------------------------
# Aggregate false can arise from an agent self-reporting actionable_by_dev_agent:false
# on a NON-protected path (no matched pattern to name).
OUT=$(_run_block "false" "codex" "fail" "")
assert_eq "TC-INV134-D4-07 no comment posted (nothing matched)" "0" "$(_field "$OUT" COMMENT_COUNT)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Bonus: only FAILing agents contribute; a PASS-voting agent's matched patterns are ignored ==="
# ---------------------------------------------------------------------------
OUT=$(_run_block "false" "codex,claude" "pass,fail" ".github/workflows/**,CODEOWNERS")
BODY=$(_field "$OUT" COMMENT_BODY)
case "$BODY" in
  *"CODEOWNERS"*) ok "TC-INV134-D4-BONUS only the FAILing agent's (index 1) matched pattern is named";;
  *) bad "TC-INV134-D4-BONUS should name only the FAILing agent's pattern"; echo "      got: $BODY";;
esac

echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
