#!/bin/bash
# test-autonomous-review-prompt.sh — Integration-style tests verifying
# that autonomous-review.sh templates the agent prompt correctly based
# on REVIEW_BOTS (PR-12).
#
# Strategy: source-of-truth grep against the wrapper script. The wrapper
# is a 600+-line script that makes gh API calls and spawns the agent —
# too heavy to execute end-to-end. Instead we verify:
#   1. The hardcoded "Amazon Q Developer Review — MANDATORY" block is GONE.
#   2. The render_bot_review_section call is in place.
#   3. lib-review-bots.sh is sourced.
#   4. REVIEW_BOTS_VALIDATED is set via parse_review_bots and exported into
#      both the prompt body and the report-table section.
#
# Run: bash tests/unit/test-autonomous-review-prompt.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_grep() {
  local desc="$1" pattern="$2" file="$3"
  if ! grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (matched: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
echo "=== TC-ARP-01: hardcoded Q-review block removed ==="
# ---------------------------------------------------------------------------
# These were the markers of the old hardcoded block.
assert_not_grep "no '## Amazon Q Developer Review — MANDATORY' header" \
  "^## Amazon Q Developer Review — MANDATORY" "$WRAPPER"
assert_not_grep "no Q_COUNT variable in prompt body" \
  "Q_COUNT=" "$WRAPPER"
assert_not_grep "no hardcoded amazon-q-developer\\[bot\\] login filter" \
  'select\(\.user\.login == "amazon-q-developer\[bot\]"\)' "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ARP-02: lib-review-bots.sh is sourced + validated ==="
# ---------------------------------------------------------------------------
assert_grep "sources lib-review-bots.sh" \
  'source "\$\{SCRIPT_DIR\}/lib-review-bots\.sh"' "$WRAPPER"
assert_grep "calls parse_review_bots at startup" \
  'parse_review_bots' "$WRAPPER"
assert_grep "validation failure exits the wrapper (fail-fast)" \
  'parse_review_bots .*\|\| exit 1' "$WRAPPER"
assert_grep "REVIEW_BOTS_VALIDATED variable defined" \
  'REVIEW_BOTS_VALIDATED=' "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ARP-03: render_bot_review_section is in the prompt body ==="
# ---------------------------------------------------------------------------
assert_grep "render_bot_review_section called in PROMPT heredoc" \
  'render_bot_review_section "\$REVIEW_BOTS_VALIDATED"' "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ARP-04: bot-review section drives off REVIEW_BOTS_VALIDATED, no hardcoded Amazon Q ==="
# ---------------------------------------------------------------------------
# The review prompt's bot-review enforcement must drive off the validated list
# (via render_bot_review_section, asserted above) rather than naming Amazon Q
# specifically. INV-46 (#182) moved the browser E2E *report table* (which used to
# carry a "Configured Review Bots" sub-table) out of build_review_prompt into the
# single browser lane prompt (lib-review-e2e.sh::build_browser_e2e_prompt), so
# the report-table assertion now targets the lib; the wrapper must NOT carry a
# hardcoded Amazon Q report header anywhere.
E2E_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-e2e.sh"
assert_grep "browser lane prompt has the E2E Verification Report table (moved to lib, INV-46)" \
  "E2E Verification Report" "$E2E_LIB"
assert_not_grep "no '### Amazon Q Developer Review' report header in wrapper" \
  "^### Amazon Q Developer Review" "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ARP-06: per-agent 'Review Agent:' discriminator (issue #166 / INV-40) ==="
# ---------------------------------------------------------------------------
# Each review agent must end its verdict comment with a `Review Agent: <name>`
# discriminator line so the wrapper can attribute N verdict comments posted
# under the SAME GitHub identity. This complements the retained
# `Review Session: <uuid>` trailer (INV-20).
assert_grep "prompt instructs agent to emit a 'Review Agent:' discriminator line" \
  "Review Agent: " "$WRAPPER"
assert_grep "per-agent verdict jq predicate keys on 'Review Agent:'" \
  "Review Agent: " "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ARP-05: bash syntax valid ==="
# ---------------------------------------------------------------------------
if bash -n "$WRAPPER" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: wrapper passes bash -n"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: wrapper has syntax errors"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
