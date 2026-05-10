#!/bin/bash
# test-dispatcher-tick-review-bots.sh — Unit tests for the REVIEW_BOTS
# fail-fast precheck added to dispatcher-tick.sh in PR-12.
#
# Why: a typo in autonomous.conf (e.g. REVIEW_BOTS="q codx") would
# previously let dispatcher-tick.sh swap an issue's label to `reviewing`
# and spawn the review wrapper, which then exits 1 at startup — burning
# a retry slot every tick until MAX_RETRIES. The precheck aborts the
# whole tick before any side-effect.
#
# Strategy: build a sandbox autonomous.conf with the bad value, run
# dispatcher-tick.sh, assert it exits non-zero with a clear error and
# WITHOUT calling out to gh/dispatch-local.sh.
#
# Run: bash tests/unit/test-dispatcher-tick-review-bots.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TICK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected='$expected'"
    echo "      actual=  '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle='$needle'"
    echo "      haystack='${haystack:0:500}'"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      should not contain: '$needle'"
    FAIL=$((FAIL + 1))
  fi
}

# Sandbox: fake AUTONOMOUS_CONF with all the required vars so dispatcher-tick
# clears its other validation gates and reaches the REVIEW_BOTS precheck.
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# Stub PROJECT_DIR with a scripts/ subdir (some helpers want it).
PROJECT_DIR_FAKE="$TMPROOT/proj"
mkdir -p "$PROJECT_DIR_FAKE/scripts"

# A bin/ shim for `gh` so the test never hits the real GitHub API even if
# the precheck is missing/broken — the gh shim records calls so we can
# assert the precheck aborted BEFORE any gh invocation.
BIN="$TMPROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<EOF
#!/bin/bash
echo "GH_CALLED \$*" >> "$TMPROOT/gh-calls"
exit 0
EOF
chmod +x "$BIN/gh"

write_conf() {
  local review_bots_value="$1"
  cat > "$TMPROOT/autonomous.conf" <<EOF
PROJECT_ID="testproj"
REPO="owner/repo"
REPO_OWNER="owner"
REPO_NAME="repo"
PROJECT_DIR="$PROJECT_DIR_FAKE"
MAX_CONCURRENT=5
MAX_RETRIES=3
REVIEW_BOTS="$review_bots_value"
EOF
}

run_tick() {
  : > "$TMPROOT/gh-calls"
  PATH="$BIN:$PATH" \
  AUTONOMOUS_CONF="$TMPROOT/autonomous.conf" \
  bash "$TICK" 2>&1
}

# ---------------------------------------------------------------------------
echo "=== TC-DT-RB-01: bad REVIEW_BOTS aborts the tick with rc != 0 ==="
# ---------------------------------------------------------------------------
write_conf "q codx"
output=$(run_tick) || true
rc=$?
# bash quirk: `output=$(... ) || true` masks the rc. Re-run for the rc.
PATH="$BIN:$PATH" AUTONOMOUS_CONF="$TMPROOT/autonomous.conf" \
  bash "$TICK" >/dev/null 2>&1
rc=$?

if [[ "$rc" -ne 0 ]]; then
  echo -e "  ${GREEN}PASS${NC}: tick exits non-zero on bad REVIEW_BOTS (rc=$rc)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: tick should exit non-zero on bad REVIEW_BOTS (got rc=0)"
  FAIL=$((FAIL + 1))
fi

assert_contains "stderr names the bad bot"        "codx"        "$output"
assert_contains "stderr mentions REVIEW_BOTS"     "REVIEW_BOTS" "$output"
assert_contains "stderr mentions autonomous.conf" "autonomous.conf" "$output"

# Critical: the precheck runs BEFORE any gh API call. If `gh` was invoked,
# we already swapped a label / posted a comment — defeating the point.
gh_calls_file="$TMPROOT/gh-calls"
if [[ -s "$gh_calls_file" ]]; then
  echo -e "  ${RED}FAIL${NC}: gh was called before precheck failure:"
  sed 's/^/      /' "$gh_calls_file"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: gh not called — precheck aborts before label/comment side-effects"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DT-RB-02: empty REVIEW_BOTS does NOT trip the precheck ==="
# ---------------------------------------------------------------------------
# Empty REVIEW_BOTS is a valid setting (bot enforcement disabled). The
# precheck should clear; the tick may still fail later on auth/etc, but
# the FAILURE marker we check for is the "REVIEW_BOTS validation failed"
# string from the precheck specifically.
write_conf ""
output=$(run_tick) || true
assert_not_contains "no REVIEW_BOTS validation error for empty value" \
  "REVIEW_BOTS validation failed" "$output"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DT-RB-03: precheck source line in tick script ==="
# ---------------------------------------------------------------------------
# Source-of-truth grep: confirm the precheck calls parse_review_bots and
# bails on failure with the FATAL marker.
if grep -q 'parse_review_bots "${REVIEW_BOTS:-}"' "$TICK"; then
  echo -e "  ${GREEN}PASS${NC}: tick calls parse_review_bots on REVIEW_BOTS"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: tick missing parse_review_bots precheck"
  FAIL=$((FAIL + 1))
fi

if grep -q 'REVIEW_BOTS validation failed' "$TICK"; then
  echo -e "  ${GREEN}PASS${NC}: tick has FATAL message for REVIEW_BOTS"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: tick missing FATAL message for REVIEW_BOTS"
  FAIL=$((FAIL + 1))
fi

# Precheck must come BEFORE any `dispatch ` call or label transition.
# Cheap proxy: line number of `parse_review_bots "${REVIEW_BOTS:-}"`
# is less than the first occurrence of `dispatch `.
PRECHECK_LINE=$(grep -n 'parse_review_bots "${REVIEW_BOTS:-}"' "$TICK" | head -1 | cut -d: -f1)
FIRST_DISPATCH_LINE=$(grep -n '^[[:space:]]*dispatch ' "$TICK" | head -1 | cut -d: -f1)
if [[ -n "$PRECHECK_LINE" && -n "$FIRST_DISPATCH_LINE" && "$PRECHECK_LINE" -lt "$FIRST_DISPATCH_LINE" ]]; then
  echo -e "  ${GREEN}PASS${NC}: precheck (line $PRECHECK_LINE) runs before any dispatch (line $FIRST_DISPATCH_LINE)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: precheck not positioned before dispatch (precheck=$PRECHECK_LINE, first dispatch=$FIRST_DISPATCH_LINE)"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
