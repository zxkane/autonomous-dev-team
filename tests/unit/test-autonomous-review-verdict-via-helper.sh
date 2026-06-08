#!/bin/bash
# test-autonomous-review-verdict-via-helper.sh — issue #202 / INV-56.
#
# build_review_prompt must route EVERY verdict-post instruction through the
# deterministic helper `scripts/post-verdict.sh` and explicitly forbid a bare
# `gh issue comment` for the verdict. There are THREE spots:
#   1. Decision block — PASS branch
#   2. Decision block — FAIL branch
#   3. INV-55 codex-inline-diff block ("post your verdict comment in THIS turn"
#      / "post the verdict in as few turns as possible")
# The instruction must apply to ALL agents (no per-CLI branch for the verdict
# post), and the first-line phrasing the poller matches (`Review PASSED` /
# `Review findings:`) must be preserved.
#
# Strategy (mirrors test-codex-inline-diff-prompt.sh / test-autonomous-review-prompt.sh):
#   1. Source-of-truth greps against the build_review_prompt function body.
#   2. Behavioral: render the prompt for codex and a non-codex agent in a
#      sandbox and assert the helper instruction appears identically for both.
#
# Run: bash tests/unit/test-autonomous-review-verdict-via-helper.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PROMPT_FN=$(awk '/^build_review_prompt\(\) \{/,/^\}/' "$WRAPPER")

assert_fn_grep() {
  local desc="$1" pattern="$2"
  # NOTE: feed the haystack via a here-string, NOT `printf | grep -q`. With
  # `set -o pipefail`, `grep -q` closes the pipe on its first match and the
  # upstream `printf` dies with SIGPIPE → the pipeline's status becomes 141
  # even though grep matched, so the `if` wrongly takes the FAIL branch
  # (flaky, position-dependent). A here-string has no pipe and no SIGPIPE.
  if grep -qE "$pattern" <<<"$PROMPT_FN"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep_count_ge() {
  local desc="$1" pattern="$2" min="$3"
  local n
  n=$(grep -cE "$pattern" <<<"$PROMPT_FN")
  if [[ "$n" -ge "$min" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc (found $n ≥ $min)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (found $n, need ≥ $min; pattern: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
echo "=== TC-PVP-SRC: build_review_prompt routes verdict through post-verdict.sh ==="
# ---------------------------------------------------------------------------

# TC-PVP-01/02: the Decision block (PASS + FAIL) references the helper. The
# helper string appears at least twice (once per branch).
assert_grep_count_ge "TC-PVP-01/02 post-verdict.sh referenced for both Decision branches" \
  'scripts/post-verdict\.sh' 2

# TC-PVP-04: the prompt explicitly forbids a bare `gh issue comment` for the
# verdict. Match loosely on "NOT ... bare `gh issue comment`" (tolerates the
# markdown bold `**NOT**`, an intervening "use a"/"hand-roll a", and the
# escaped backticks around `gh issue comment`).
assert_fn_grep "TC-PVP-04 forbids bare 'gh issue comment' for the verdict" \
  'NOT.*bare .{0,3}gh issue comment'

# TC-PVP-05: first-line phrasing preserved (poller match unchanged).
assert_fn_grep "TC-PVP-05a 'Review PASSED' phrasing preserved" 'Review PASSED'
assert_fn_grep "TC-PVP-05b 'Review findings:' phrasing preserved" 'Review findings:'

# The helper instruction names the pass/fail verdict argument.
assert_fn_grep "TC-PVP-SRC helper called with a pass verdict arg" \
  'post-verdict\.sh.*pass'
assert_fn_grep "TC-PVP-SRC helper called with a fail verdict arg" \
  'post-verdict\.sh.*fail'

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PVP-BEHAVE: rendered prompt routes verdict via helper for all agents ==="
# ---------------------------------------------------------------------------
_FN_SLICE=$(mktemp)
awk '/^build_review_prompt\(\) \{/,/^}$/' "$WRAPPER" > "$_FN_SLICE"
SANDBOX_OUT=$(
  set +e
  render_bot_review_section() { :; }
  _revalidate_ac_coverage_file() { printf ''; }
  gh() {
    if [[ "${1:-}" == "pr" && "${2:-}" == "diff" ]]; then
      printf 'diff --git a/x b/x\n@@ -1 +1 @@\n-OLD\n+NEW\n'; return 0
    fi
    return 0
  }
  PR_NUMBER=210; ISSUE_NUMBER=202; REPO="owner/repo"; REPO_OWNER="owner"
  REPO_NAME="repo"; PR_BRANCH="feat/x"; REVIEW_BOTS_VALIDATED=""; E2E_ACTIVE="false"
  CODEX_REVIEW_INLINE_DIFF_MAX_BYTES=600000
  source "$_FN_SLICE"
  echo "===CODEX==="
  build_review_prompt "codex" "sid-codex"
  echo "===CLAUDE==="
  build_review_prompt "claude" "sid-claude"
)
rm -f "$_FN_SLICE"

codex_block=$(printf '%s' "$SANDBOX_OUT" | awk '/===CODEX===/{f=1;next}/===CLAUDE===/{f=0}f')
claude_block=$(printf '%s' "$SANDBOX_OUT" | awk '/===CLAUDE===/{f=1;next}f')

check_block() {
  local name="$1" block="$2"
  # here-string (not `printf | grep -q`) to avoid the pipefail+SIGPIPE flake
  # described on assert_fn_grep above.
  if grep -q 'scripts/post-verdict.sh' <<<"$block"; then
    echo -e "  ${GREEN}PASS${NC}: TC-PVP-06 [$name] prompt routes the verdict via post-verdict.sh"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-PVP-06 [$name] prompt does NOT reference post-verdict.sh"
    FAIL=$((FAIL + 1))
  fi
}
check_block "codex" "$codex_block"
check_block "claude" "$claude_block"

# TC-PVP-03: the codex block (which contains the INV-55 inline-diff language)
# must defer the verdict post to the helper, not leave a loose bare-gh post.
# The codex block carries the "in THIS turn" inline-diff verdict language AND
# the helper reference; assert the helper reference is present in the codex block.
if grep -qi 'post.*verdict' <<<"$codex_block" \
   && grep -q 'scripts/post-verdict.sh' <<<"$codex_block"; then
  echo -e "  ${GREEN}PASS${NC}: TC-PVP-03 codex inline-diff verdict language defers to post-verdict.sh"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-PVP-03 codex inline-diff block does not route verdict via post-verdict.sh"
  FAIL=$((FAIL + 1))
fi

# TC-PVP-06b: no bare `gh issue comment` for the verdict in either rendered block.
# (A `gh pr view`/`gh pr checks`/`gh issue view` for reading is fine — only the
# VERDICT post is forbidden via bare gh. We assert the explicit prohibition is
# present and the helper is the named mechanism.)
for nm in codex claude; do
  blk="${nm}_block"
  if grep -qiE 'NOT.*bare .{0,3}gh issue comment' <<<"${!blk}"; then
    echo -e "  ${GREEN}PASS${NC}: TC-PVP-06b [$nm] explicitly forbids bare gh issue comment for the verdict"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-PVP-06b [$nm] missing the bare-gh prohibition"
    FAIL=$((FAIL + 1))
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
