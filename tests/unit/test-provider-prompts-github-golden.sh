#!/bin/bash
# test-provider-prompts-github-golden.sh — issue #421 R3/AC2 golden-pin.
#
# Renders EVERY fragment key in providers/prompts-github.sh with a fixed args
# seed (SEED0/SEED1/SEED2 by position) and diffs against the checked-in golden
# at tests/unit/fixtures/provider-prompts-github/golden.txt. The migration
# (#421) moved ~20 hardcoded prompt-prose sites out of autonomous-dev.sh /
# autonomous-review.sh / lib-review-bots.sh into this fragment file — it is a
# RENAME, not a rewrite, so github rendering must stay byte-identical. A
# mismatch here means the github prose text changed; regenerate the golden
# ONLY as a deliberate, reviewed prose edit (never to silently paper over a
# migration bug):
#   bash tests/unit/test-provider-prompts-github-golden.sh --generate \
#     > tests/unit/fixtures/provider-prompts-github/golden.txt
#
# Also covers AC1 (unknown key / unknown provider fail LOUD, rc!=0) and R1's
# argc-mismatch guard.
#
# Run: bash tests/unit/test-provider-prompts-github-golden.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
LIB="$SCRIPTS/lib-provider-prompts.sh"
GOLDEN="$SCRIPT_DIR/fixtures/provider-prompts-github/golden.txt"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

[ -f "$LIB" ] || { echo "missing $LIB"; exit 1; }

# render_all — echo every fragment key (sorted) rendered with a fixed args
# seed (SEED0/SEED1/SEED2 by position, matching each key's declared argc).
render_all() {
  # shellcheck disable=SC1090
  source "$LIB"
  CODE_HOST=github
  ISSUE_PROVIDER=github
  _pp_load_provider github
  local -a SEED=(SEED0 SEED1 SEED2)
  local key argc args
  for key in $(printf '%s\n' "${!FRAGMENT_AXIS[@]}" | sort); do
    argc="${_PP_GITHUB_ARGC[$key]:-0}"
    args=()
    for ((i = 0; i < argc; i++)); do args+=("${SEED[$i]}"); done
    echo "=== $key ==="
    CODE_HOST=github ISSUE_PROVIDER=github provider_prompt_fragment "$key" "${args[@]}"
    echo "=== END $key ==="
  done
}

if [[ "${1:-}" == "--generate" ]]; then
  render_all
  exit 0
fi

# ---------------------------------------------------------------------------
echo "=== TC-P36-001: github rendering is byte-identical to the checked-in golden ==="
# ---------------------------------------------------------------------------
[ -f "$GOLDEN" ] || { echo "missing golden fixture: $GOLDEN"; exit 1; }
ACTUAL="$(render_all)"
if diff -u "$GOLDEN" <(printf '%s\n' "$ACTUAL") > /tmp/pp-golden-diff.$$ 2>&1; then
  ok "TC-P36-001 all github fragments render byte-identical to golden"
else
  bad "TC-P36-001 github rendering diverged from golden (full delta below)"
  cat /tmp/pp-golden-diff.$$
fi
rm -f /tmp/pp-golden-diff.$$

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-P36-002: unknown fragment key fails LOUD (rc!=0, stderr) ==="
# ---------------------------------------------------------------------------
out=$(bash -c "source '$LIB'; CODE_HOST=github; provider_prompt_fragment nonexistent.key" 2>&1); rc=$?
if [[ $rc -ne 0 ]] && [[ "$out" == *"unknown fragment key"* ]]; then
  ok "TC-P36-002 unknown key fails loud: rc=$rc, msg='$out'"
else
  bad "TC-P36-002 unknown key did not fail loud (rc=$rc, out='$out')"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-P36-003: unknown provider fails LOUD (rc!=0, stderr) ==="
# ---------------------------------------------------------------------------
out=$(bash -c "source '$LIB'; CODE_HOST=nonexistent_provider; provider_prompt_fragment review.check_mergeable 1 2" 2>&1); rc=$?
if [[ $rc -ne 0 ]] && [[ "$out" == *"unknown provider"* ]]; then
  ok "TC-P36-003 unknown provider fails loud: rc=$rc, msg='$out'"
else
  bad "TC-P36-003 unknown provider did not fail loud (rc=$rc, out='$out')"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-P36-004: argc mismatch fails LOUD (rc!=0, stderr) ==="
# ---------------------------------------------------------------------------
out=$(bash -c "source '$LIB'; CODE_HOST=github; provider_prompt_fragment review.check_mergeable only-one-arg" 2>&1); rc=$?
if [[ $rc -ne 0 ]] && [[ "$out" == *"expects 2 arg(s), got 1"* ]]; then
  ok "TC-P36-004 argc mismatch fails loud: rc=$rc, msg='$out'"
else
  bad "TC-P36-004 argc mismatch did not fail loud (rc=$rc, out='$out')"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-P36-005: every FRAGMENT_AXIS key has BOTH a github fragment and matching argc ==="
# ---------------------------------------------------------------------------
missing=0
bash -c "
  source '$LIB'
  _pp_load_provider github
  for key in \"\${!FRAGMENT_AXIS[@]}\"; do
    [[ -n \"\${_PP_GITHUB_FRAGMENT[\$key]:-}\" ]] || { echo \"MISSING FRAGMENT: \$key\"; exit 1; }
    [[ -n \"\${_PP_GITHUB_ARGC[\$key]+set}\" ]] || { echo \"MISSING ARGC: \$key\"; exit 1; }
  done
" 2>/tmp/pp-missing.$$ || missing=1
if [[ $missing -eq 0 ]]; then
  ok "TC-P36-005 every FRAGMENT_AXIS key resolves to a github fragment + argc"
else
  bad "TC-P36-005 a FRAGMENT_AXIS key is missing from prompts-github.sh: $(cat /tmp/pp-missing.$$)"
fi
rm -f /tmp/pp-missing.$$

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
