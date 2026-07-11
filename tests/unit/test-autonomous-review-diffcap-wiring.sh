#!/bin/bash
# test-autonomous-review-diffcap-wiring.sh — INV-124 / issue #452.
#
# Proves the WRAPPER-SIDE wiring of the PR-diff-size (over-reach) soft signal
# in autonomous-review.sh: the once-per-review-round computation block
# (extracted verbatim via awk, mirroring test-autonomous-review-verdict-
# via-helper.sh's build_review_prompt-slice strategy) is exercised in a
# sandbox with stubbed chp_pr_diffstat/metrics_emit/log.
#
#   TC-OVERREACH-001: both caps unset → no chp_pr_diffstat call, no metrics
#                     event, _DIFF_CAP_PROMPT_NOTE stays empty.
#   TC-OVERREACH-014: pr_diff_soft_cap metrics event fires exactly ONCE when
#                     a cap is configured (not per fan-out member — this
#                     block runs once regardless).
#   TC-OVERREACH-015: chp_pr_diffstat is the ONLY provider-seam call made —
#                     no raw gh invocation from this block.
#
# Run: env -u PROJECT_DIR bash tests/unit/test-autonomous-review-diffcap-wiring.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
DIFFCAP_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-diffcap.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$desc"
  else bad "$desc"; echo "      expected: |$expected|"; echo "      actual:   |$actual|"; fi
}

[ -f "$WRAPPER" ]     || { echo "FATAL: wrapper missing"; exit 2; }
[ -f "$DIFFCAP_LIB" ] || { echo "FATAL: lib-review-diffcap.sh missing"; exit 2; }

# Extract the once-per-round diffcap block verbatim from the wrapper (the
# unique start marker through the single closing `fi`).
BLOCK_SLICE=$(mktemp)
trap 'rm -f "$BLOCK_SLICE"' EXIT
awk '/^# INV-124 \(#452\): PR-diff-size .* soft signal — computed ONCE per$/,/^fi$/' "$WRAPPER" > "$BLOCK_SLICE"
[ -s "$BLOCK_SLICE" ] || { echo "FATAL: could not extract the INV-124 block from the wrapper — has it moved/been renamed?"; exit 2; }

_run_block() {
  # Args become env assignments the sandbox subshell evaluates before running
  # the block. Captures: PR_DIFFSTAT_CALLS (count), METRICS_CALLS (count),
  # METRICS_LAST_ARGS (the last pr_diff_soft_cap call's args), and the four
  # _DIFF_CAP_* result vars, each printed on its own line.
  (
    set +e
    source "$DIFFCAP_LIB"
    PR_NUMBER=99
    ISSUE_NUMBER=452
    RUN_ID="run-test"
    PR_DIFF_SOFT_CAP_FILES="${1:-}"
    PR_DIFF_SOFT_CAP_LINES="${2:-}"
    _CALL_COUNT_FILE=$(mktemp)
    _METRICS_COUNT_FILE=$(mktemp)
    _METRICS_LAST_FILE=$(mktemp)
    _LOG_FILE=$(mktemp)
    echo 0 > "$_CALL_COUNT_FILE"
    echo 0 > "$_METRICS_COUNT_FILE"
    log() { printf '%s\n' "$*" >> "$_LOG_FILE"; }
    chp_pr_diffstat() {
      local n; n=$(<"$_CALL_COUNT_FILE"); n=$((n + 1)); echo "$n" > "$_CALL_COUNT_FILE"
      printf '%s' "${DIFFSTAT_PAYLOAD:-}"
    }
    metrics_emit() {
      local n; n=$(<"$_METRICS_COUNT_FILE"); n=$((n + 1)); echo "$n" > "$_METRICS_COUNT_FILE"
      printf '%s\n' "$*" > "$_METRICS_LAST_FILE"
    }
    declare -F metrics_emit >/dev/null 2>&1  # sanity: sourced above via the function def, not `declare -F` trickery
    # shellcheck source=/dev/null
    source "$BLOCK_SLICE"
    echo "PR_DIFFSTAT_CALLS=$(<"$_CALL_COUNT_FILE")"
    echo "METRICS_CALLS=$(<"$_METRICS_COUNT_FILE")"
    echo "METRICS_LAST_ARGS=$(cat "$_METRICS_LAST_FILE" 2>/dev/null)"
    echo "OVER_REACH=${_DIFF_CAP_OVER_REACH}"
    echo "PROMPT_NOTE_LEN=${#_DIFF_CAP_PROMPT_NOTE}"
    echo "LOG_OUTPUT=$(cat "$_LOG_FILE" 2>/dev/null | tr '\n' '|')"
    rm -f "$_CALL_COUNT_FILE" "_METRICS_COUNT_FILE" "$_METRICS_LAST_FILE" "$_LOG_FILE" 2>/dev/null
  )
}

_field() { grep "^$2=" <<<"$1" | head -1 | cut -d= -f2-; }

# ===========================================================================
echo "=== TC-OVERREACH-001: both caps unset → zero provider-seam calls, zero metrics events ==="
# ===========================================================================
OUT_DISABLED=$(_run_block "" "")
assert_eq "both unset: chp_pr_diffstat NEVER called" "0" "$(_field "$OUT_DISABLED" PR_DIFFSTAT_CALLS)"
assert_eq "both unset: metrics_emit NEVER called" "0" "$(_field "$OUT_DISABLED" METRICS_CALLS)"
assert_eq "both unset: over_reach stays false" "false" "$(_field "$OUT_DISABLED" OVER_REACH)"
assert_eq "both unset: prompt note stays empty" "0" "$(_field "$OUT_DISABLED" PROMPT_NOTE_LEN)"

# Invalid values (0 / negative / non-numeric) behave identically to unset.
OUT_INVALID=$(_run_block "0" "-5")
assert_eq "invalid values (0/-5) → chp_pr_diffstat NEVER called" "0" "$(_field "$OUT_INVALID" PR_DIFFSTAT_CALLS)"
assert_eq "invalid values (0/-5) → metrics_emit NEVER called" "0" "$(_field "$OUT_INVALID" METRICS_CALLS)"

# ===========================================================================
echo ""
echo "=== TC-OVERREACH-014: exactly ONE chp_pr_diffstat + ONE metrics event when a cap is configured ==="
# ===========================================================================
OUT_ENABLED=$(DIFFSTAT_PAYLOAD='{"changed_files": 45}' _run_block "40" "")
assert_eq "files cap set: chp_pr_diffstat called EXACTLY once" "1" "$(_field "$OUT_ENABLED" PR_DIFFSTAT_CALLS)"
assert_eq "files cap set: metrics_emit called EXACTLY once (not per fan-out member)" "1" "$(_field "$OUT_ENABLED" METRICS_CALLS)"
assert_eq "files cap set + exceeded: over_reach=true" "true" "$(_field "$OUT_ENABLED" OVER_REACH)"
LAST_ARGS=$(_field "$OUT_ENABLED" METRICS_LAST_ARGS)
case "$LAST_ARGS" in
  pr_diff_soft_cap*) ok "metrics_emit's first arg is the event name 'pr_diff_soft_cap'";;
  *) bad "metrics_emit's first arg is not 'pr_diff_soft_cap' (got: $LAST_ARGS)";;
esac
case "$LAST_ARGS" in
  *"over_reach=true"*) ok "metrics_emit call carries over_reach=true";;
  *) bad "metrics_emit call missing over_reach=true (got: $LAST_ARGS)";;
esac
case "$LAST_ARGS" in
  *"changed_files=45"*) ok "metrics_emit call carries the measured changed_files";;
  *) bad "metrics_emit call missing changed_files (got: $LAST_ARGS)";;
esac
case "$LAST_ARGS" in
  *"files_cap=40"*) ok "metrics_emit call carries the configured files_cap";;
  *) bad "metrics_emit call missing files_cap (got: $LAST_ARGS)";;
esac

# Under-cap PR: event still fires (emit-always-when-enabled), but over_reach=false.
OUT_UNDER=$(DIFFSTAT_PAYLOAD='{"changed_files": 5}' _run_block "40" "")
assert_eq "under-cap: metrics_emit still called once (emit-always-when-enabled)" "1" "$(_field "$OUT_UNDER" METRICS_CALLS)"
assert_eq "under-cap: over_reach=false" "false" "$(_field "$OUT_UNDER" OVER_REACH)"

# Read failure (chp_pr_diffstat returns nothing) → over_reach=false, no crash.
OUT_READFAIL=$(DIFFSTAT_PAYLOAD='' _run_block "40" "3000")
assert_eq "diffstat read failure: over_reach=false (fail-open)" "false" "$(_field "$OUT_READFAIL" OVER_REACH)"
assert_eq "diffstat read failure: metrics_emit still called once" "1" "$(_field "$OUT_READFAIL" METRICS_CALLS)"
case "$(_field "$OUT_READFAIL" LOG_OUTPUT)" in
  *"chp_pr_diffstat read failed"*) ok "diffstat read failure: a diagnostic log line names the read failure (debuggability)";;
  *) bad "diffstat read failure: no diagnostic log line emitted"; echo "      got: $(_field "$OUT_READFAIL" LOG_OUTPUT)";;
esac

# The happy path must NOT emit the read-failure diagnostic.
case "$(_field "$OUT_ENABLED" LOG_OUTPUT)" in
  *"chp_pr_diffstat read failed"*) bad "happy path: unexpectedly emitted the read-failure diagnostic";;
  *) ok "happy path: no read-failure diagnostic emitted";;
esac

# ===========================================================================
echo ""
echo "=== TC-OVERREACH-015: no raw gh invocation in the extracted block ==="
# ===========================================================================
if grep -qE '(^|[^A-Za-z_-])gh pr view' "$BLOCK_SLICE"; then
  bad "the INV-124 block contains a raw 'gh pr view' call (provider-seam violation)"
else
  ok "the INV-124 block contains no raw 'gh pr view' — reads only through chp_pr_diffstat"
fi

# ===========================================================================
echo ""
echo "=== TC-OVERREACH-001 (prompt): build_review_prompt() byte-identical when both caps unset ==="
# ===========================================================================
# Golden-render: build_review_prompt() with _DIFF_CAP_* unset (as if the
# INV-124 block never ran — the pre-#452 shape) vs. with it explicitly set to
# the disabled state (over_reach=false, empty stats/caps, empty note) that the
# real wrapper now always produces when both caps are unset. Both renders
# MUST be byte-identical — the note interpolation must vanish completely.
_PROVIDER_PROMPTS_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-provider-prompts.sh"
_RESOLVE_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-resolve.sh"
_ARTIFACT_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-artifact.sh"
_FN_SLICE=$(mktemp)
awk '/^build_review_prompt\(\) \{/,/^}$/' "$WRAPPER" > "$_FN_SLICE"

_render_prompt() {
  # $1: "unset" (no _DIFF_CAP_* vars at all — the literal pre-#452 shape) or
  #     "disabled" (vars set to the real wrapper's disabled-state values).
  (
    set +e
    source "$_PROVIDER_PROMPTS_LIB"
    CODE_HOST=github; ISSUE_PROVIDER=github
    render_bot_review_section() { :; }
    _revalidate_ac_coverage_file() { printf ''; }
    gh() { return 0; }
    PR_NUMBER=210; ISSUE_NUMBER=452; REPO="owner/repo"; REPO_OWNER="owner"
    REPO_NAME="repo"; PR_BRANCH="feat/x"; REVIEW_BOTS_VALIDATED=""; E2E_ACTIVE="false"
    PROJECT_ID="test-proj"
    unset AGENT_REVIEW_MODEL AGENT_REVIEW_MODEL_CLAUDE AGENT_REVIEW_MODEL_CODEX
    source "$_RESOLVE_LIB"
    source "$_ARTIFACT_LIB"
    source "$DIFFCAP_LIB"
    if [ "$1" = "disabled" ]; then
      _DIFF_CAP_OVER_REACH="false"
      _DIFF_CAP_CHANGED_FILES=""
      _DIFF_CAP_CHANGED_LINES=""
      _DIFF_CAP_FILES_CAP=""
      _DIFF_CAP_LINES_CAP=""
    fi
    source "$_FN_SLICE"
    build_review_prompt "claude" "sid-claude"
  )
}

RENDER_UNSET=$(_render_prompt "unset")
RENDER_DISABLED=$(_render_prompt "disabled")
rm -f "$_FN_SLICE"

# Normalize the ONE known source of render-to-render non-determinism unrelated
# to this feature: _verdict_body_lane_dir mints a fresh `mktemp -d` random
# suffix on every build_review_prompt() call, so the SAME render invoked twice
# already differs in that one path component even with zero code changes.
_normalize() { sed -E 's#/tmp/review-test-proj-claude-452-[A-Za-z0-9]+#/tmp/review-test-proj-claude-452-RANDOM#g' <<<"$1"; }
RENDER_UNSET_NORM=$(_normalize "$RENDER_UNSET")
RENDER_DISABLED_NORM=$(_normalize "$RENDER_DISABLED")

if [ "$RENDER_UNSET_NORM" = "$RENDER_DISABLED_NORM" ]; then
  ok "TC-OVERREACH-001: build_review_prompt() output is byte-identical whether _DIFF_CAP_* vars are absent or explicitly disabled"
else
  bad "TC-OVERREACH-001: build_review_prompt() output DIFFERS between the pre-#452 shape and the disabled state"
  diff <(printf '%s' "$RENDER_UNSET_NORM") <(printf '%s' "$RENDER_DISABLED_NORM") | head -20
fi

case "$RENDER_DISABLED" in
  *"Diff-size advisory"*)
    bad "disabled-state render unexpectedly contains the diff-size advisory section";;
  *)
    ok "disabled-state render contains no diff-size advisory section";;
esac

# ===========================================================================
echo ""
echo "=== TC-OVERREACH-016: verdict-aggregation code has ZERO coupling to over_reach ==="
# ===========================================================================
# Structural regression guard for the INV-124 "soft signal, never a gate"
# invariant: none of the verdict-aggregation / gate-classification libs may
# ever reference _DIFF_CAP_*/over_reach/diff_cap. This is a cheap grep-based
# proof that a future edit cannot accidentally wire the signal into a
# PASS/FAIL decision without this test catching it — the aggregation code's
# CURRENT independence from `over_reach` is what makes "toggling over_reach
# leaves aggregation output byte-identical" true by construction.
AGG_LIBS=(
  "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-aggregate.sh"
  "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-classify.sh"
  "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-mergeable.sh"
  "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-request-changes.sh"
  "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-verdict.sh"
)
_agg_hit=0
for _al in "${AGG_LIBS[@]}"; do
  [ -f "$_al" ] || continue
  if grep -qE '_DIFF_CAP|over_reach|diff_cap' "$_al"; then
    bad "TC-OVERREACH-016: $(basename "$_al") references the diff-cap signal — verdict aggregation must have ZERO coupling to over_reach"
    _agg_hit=1
  fi
done
[ "$_agg_hit" -eq 0 ] && ok "TC-OVERREACH-016: no verdict-aggregation/gate-classification lib references _DIFF_CAP/over_reach/diff_cap"

# ===========================================================================
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
