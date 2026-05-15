#!/bin/bash
# test-autonomous-review-reviewed-head-annotation.sh — verify that
# autonomous-review.sh's `Reviewed HEAD:` trailer carries `agent` /
# `model` attribution so multi-CLI deployments can tell which review CLI /
# model produced each verdict from the historical issue thread (#128).
#
# Strategy mirrors test-autonomous-dev-cleanup-startup-failure.sh: extract
# the trailer-emit block from autonomous-review.sh, run it inside a
# harness with a stubbed `gh`, and assert the recorded --body argv.
#
# Catches three failure modes that a static grep on the wrapper source
# would miss:
#   - wrong default fallback (the :-sonnet dead-code case from #128's body)
#   - broken backtick escaping (a refactor that doubles or drops one)
#   - annotation accidentally landing in a different gh --body call
#
# Run: bash tests/unit/test-autonomous-review-reviewed-head-annotation.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle='$needle'"
    echo "      haystack='$haystack'"
    FAIL=$((FAIL + 1))
  fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# Extract the trailer-emit block. Matches the `if` line that contains the
# unique conjunction `LATEST_COMMENT" && -n "$PR_HEAD_SHA"` through the
# next standalone `fi` at column 0.
TRAILER_BLOCK=$(awk '
  /^if \[\[ -n "\$LATEST_COMMENT" && -n "\$PR_HEAD_SHA" \]\]; then$/ { in_block=1 }
  in_block { print }
  in_block && /^fi$/ { exit }
' "$WRAPPER")
if [[ -z "$TRAILER_BLOCK" ]]; then
  echo -e "${RED}FAIL${NC}: could not extract trailer-emit block from $WRAPPER"
  exit 1
fi

# Recording stub for gh on PATH. Captures argv to a record file.
STUB_DIR="$TMPROOT/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
echo "GH $*" >> "$GH_RECORD"
exit 0
EOF
chmod +x "$STUB_DIR/gh"

run_trailer() {
  local label="$1" pr_head_sha="$2" agent_cmd="$3" review_model="$4"
  local record="$TMPROOT/gh-${label}.log"
  : > "$record"

  PATH="$STUB_DIR:$PATH" \
  GH_RECORD="$record" \
  LATEST_COMMENT="Review PASSED" \
  PR_HEAD_SHA="$pr_head_sha" \
  ISSUE_NUMBER="42" \
  SESSION_ID="test-session" \
  REPO="acme/widget" \
  AGENT_CMD="$agent_cmd" \
  AGENT_REVIEW_MODEL="$review_model" \
  bash -c "
    set +e
    log() { echo \"[test-log] \$*\" >&2; }
    $TRAILER_BLOCK
  " 2>/dev/null
  GH_LOG=$(cat "$record")
}

# ---------------------------------------------------------------------------
echo "=== TC-RHA-001: trailer body contains agent + model with backticks intact ==="
# ---------------------------------------------------------------------------
run_trailer "001" "deadbeef" "opencode" "sonnet"

assert_contains "trailer fired (gh issue comment)" \
  "GH issue comment 42 --repo acme/widget --body" "$GH_LOG"
assert_contains "leading SHA backtick-pair preserved (dispatcher anchor)" \
  "Reviewed HEAD: \`deadbeef\`" "$GH_LOG"
assert_contains "trailer carries agent backtick-pair" \
  "agent \`opencode\`" "$GH_LOG"
assert_contains "trailer carries model backtick-pair" \
  "model \`sonnet\`" "$GH_LOG"
assert_contains "trailer carries session backtick-pair" \
  "session \`test-session\`" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RHA-002: default AGENT_REVIEW_MODEL=sonnet renders model: \`sonnet\` ==="
# ---------------------------------------------------------------------------
# Locks in the lib-agent.sh:43 default. The issue body's "dead-code fix"
# is to write ${AGENT_REVIEW_MODEL} directly (Option A) — the variable is
# already defaulted upstream to `sonnet`, so the trailer renders that
# value verbatim for unconfigured deployments.
run_trailer "002" "cafef00d" "claude" "sonnet"

assert_contains "TC-RHA-002 default model rendered as sonnet" \
  "model \`sonnet\`" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RHA-003: long bedrock model id passes through unmangled ==="
# ---------------------------------------------------------------------------
run_trailer "003" "abcdef0" "opencode" "amazon-bedrock/global.anthropic.claude-opus-4-7"

assert_contains "TC-RHA-003 long bedrock model survives" \
  "model \`amazon-bedrock/global.anthropic.claude-opus-4-7\`" "$GH_LOG"
assert_contains "TC-RHA-003 leading SHA still anchors first" \
  "Reviewed HEAD: \`abcdef0\`" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
