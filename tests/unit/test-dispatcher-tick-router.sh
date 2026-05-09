#!/bin/bash
# test-dispatcher-tick-router.sh — Unit tests for the dispatch() router
# added in PR-9 (closes #62 axis 2). Verifies that EXECUTION_BACKEND
# selects the right driver and that step bodies in dispatcher-tick.sh
# call the helper rather than `bash dispatch-local.sh` directly.
#
# Run: bash tests/unit/test-dispatcher-tick-router.sh

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

# ---------------------------------------------------------------------------
echo "=== TC-EB-001/002/003: dispatch() router behavior ==="
# ---------------------------------------------------------------------------
# Strategy: extract the `dispatch()` function from dispatcher-tick.sh into a
# harness, stub the two driver scripts, exercise three EXECUTION_BACKEND
# values, and assert which stub got the call.
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# Sandbox layout that mirrors what dispatch() expects:
#   $PROJECT_DIR/scripts/dispatch-local.sh           (local stub)
#   $SCRIPT_DIR/dispatch-remote-aws-ssm.sh           (remote stub)
PROJECT_DIR_FAKE="$TMPROOT/proj"
SCRIPT_DIR_FAKE="$TMPROOT/skill-scripts"
mkdir -p "$PROJECT_DIR_FAKE/scripts" "$SCRIPT_DIR_FAKE"

cat > "$PROJECT_DIR_FAKE/scripts/dispatch-local.sh" <<'EOF'
#!/bin/bash
echo "LOCAL $*" >> "$DISPATCH_RECORD"
EOF
cat > "$SCRIPT_DIR_FAKE/dispatch-remote-aws-ssm.sh" <<'EOF'
#!/bin/bash
echo "REMOTE $*" >> "$DISPATCH_RECORD"
EOF
chmod +x "$PROJECT_DIR_FAKE/scripts/dispatch-local.sh" "$SCRIPT_DIR_FAKE/dispatch-remote-aws-ssm.sh"

# Extract the dispatch() function definition from the live tick script.
# The function spans from `^dispatch() {` to the next standalone `^}`.
DISPATCH_FN=$(awk '/^dispatch\(\) \{/,/^\}/' "$TICK")
if [[ -z "$DISPATCH_FN" ]]; then
  echo -e "  ${RED}FAIL${NC}: could not extract dispatch() from $TICK"
  FAIL=$((FAIL + 1))
  echo ""
  echo "  Skipping behavior tests."
else
  RECORD="$TMPROOT/record"

  run_case() {
    local backend="$1"; shift
    : > "$RECORD"
    PROJECT_DIR="$PROJECT_DIR_FAKE" \
    SCRIPT_DIR="$SCRIPT_DIR_FAKE" \
    EXECUTION_BACKEND="$backend" \
    DISPATCH_RECORD="$RECORD" \
    bash -c '
      set +e
      log() { :; }    # stub — real log is in tick script
      '"$DISPATCH_FN"'
      dispatch "$@"
      exit $?
    ' bash "$@"
  }

  # TC-EB-001: default (unset) → local
  : > "$RECORD"
  PROJECT_DIR="$PROJECT_DIR_FAKE" \
  SCRIPT_DIR="$SCRIPT_DIR_FAKE" \
  DISPATCH_RECORD="$RECORD" \
  bash -c '
    set +e
    log() { :; }
    '"$DISPATCH_FN"'
    dispatch dev-new 99
  '
  assert_eq "EXECUTION_BACKEND unset → local stub called" "LOCAL dev-new 99" "$(cat "$RECORD")"

  # TC-EB-001: =local → local
  run_case local dev-new 99
  assert_eq "EXECUTION_BACKEND=local → local stub called" "LOCAL dev-new 99" "$(cat "$RECORD")"

  # TC-EB-002: =remote-aws-ssm → remote
  run_case remote-aws-ssm review 42
  assert_eq "EXECUTION_BACKEND=remote-aws-ssm → remote stub called" "REMOTE review 42" "$(cat "$RECORD")"

  # TC-EB-003a: dispatch() helper itself defends against unknown backend
  # (the runtime safety net — should never fire because of upfront check).
  : > "$RECORD"
  PROJECT_DIR="$PROJECT_DIR_FAKE" \
  SCRIPT_DIR="$SCRIPT_DIR_FAKE" \
  EXECUTION_BACKEND=bogus \
  DISPATCH_RECORD="$RECORD" \
  bash -c '
    set +e
    log() { echo "LOG $*" >&2; }
    '"$DISPATCH_FN"'
    dispatch dev-new 99
    echo "rc=$?"
  ' >"$TMPROOT/out" 2>"$TMPROOT/err"
  out=$(cat "$TMPROOT/out")
  err=$(cat "$TMPROOT/err")
  case "$out" in
    *"rc=1"*)
      echo -e "  ${GREEN}PASS${NC}: dispatch() with unknown backend → exit 1"
      PASS=$((PASS + 1)) ;;
    *)
      # Note: H1 fix makes dispatch() use `exit 1` not `return 1`, so the
      # subshell terminates; trailing `echo rc=$?` won't run. That's the
      # intended behavior — verify by checking stderr instead.
      case "$err" in
        *"unknown EXECUTION_BACKEND"*|*"BUG: dispatch"*)
          echo -e "  ${GREEN}PASS${NC}: dispatch() aborted via exit (subshell terminated before echo)"
          PASS=$((PASS + 1)) ;;
        *)
          echo -e "  ${RED}FAIL${NC}: expected exit/error; out=$out err=$err"
          FAIL=$((FAIL + 1)) ;;
      esac ;;
  esac
  assert_eq "bogus backend → no driver called" "" "$(cat "$RECORD")"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-003b: upfront EXECUTION_BACKEND validation aborts BEFORE label transitions (H1) ==="
# ---------------------------------------------------------------------------
# H1 finding: prior to this fix, an unknown EXECUTION_BACKEND caused the
# step body to swap labels and post comments BEFORE dispatch() failed,
# leaving a stuck issue + burning retries. Verify the upfront check exists.
if grep -E '^case "\$\{EXECUTION_BACKEND:-local\}"' "$TICK" | head -1 >/dev/null; then
  # Look for the upfront `case` block (not the dispatch() body) — it must
  # appear BEFORE any `gh issue edit` or `dispatch` invocations.
  upfront_line=$(grep -nE '^case "\$\{EXECUTION_BACKEND:-local\}"' "$TICK" | head -1 | cut -d: -f1)
  # Find the line of the first `dispatch ` callsite or `label_swap` (whichever).
  first_swap=$(grep -nE '^\s*(dispatch [a-z]|label_swap )' "$TICK" | head -1 | cut -d: -f1)
  if [[ -n "$upfront_line" && -n "$first_swap" && "$upfront_line" -lt "$first_swap" ]]; then
    echo -e "  ${GREEN}PASS${NC}: EXECUTION_BACKEND validated upfront (line $upfront_line) before any label/dispatch action (line $first_swap)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: validation order is wrong: validate=$upfront_line first_action=$first_swap"
    FAIL=$((FAIL + 1))
  fi
else
  echo -e "  ${RED}FAIL${NC}: no upfront EXECUTION_BACKEND case-block found in $TICK — H1 regression"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-004: source-of-truth — step bodies use dispatch() helper ==="
# ---------------------------------------------------------------------------
# Step 2/3/4 must call `dispatch dev-new ...`, `dispatch review ...`,
# `dispatch dev-resume ...` — NOT `bash $PROJECT_DIR/scripts/dispatch-local.sh`
# directly. Direct calls would bypass the router and hard-bind to local.
direct_calls=$(grep -cE '^\s*bash\s+"\$PROJECT_DIR/scripts/dispatch-local\.sh"\s+(dev-new|dev-resume|review)\b' "$TICK")
assert_eq "no direct bash dispatch-local.sh in step bodies" "0" "$direct_calls"

dispatch_calls=$(grep -cE '^\s*dispatch\s+(dev-new|dev-resume|review)\b' "$TICK")
[ "$dispatch_calls" -ge 3 ] && {
  echo -e "  ${GREEN}PASS${NC}: at least 3 dispatch() calls in step bodies (got $dispatch_calls)"
  PASS=$((PASS + 1))
} || {
  echo -e "  ${RED}FAIL${NC}: expected >= 3 dispatch() calls, got $dispatch_calls"
  FAIL=$((FAIL + 1))
}

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-019: dispatch-local.sh unchanged from main ==="
# ---------------------------------------------------------------------------
DIFF=$(git -C "$PROJECT_ROOT" diff origin/main -- skills/autonomous-dispatcher/scripts/dispatch-local.sh 2>/dev/null)
if [[ -z "$DIFF" ]]; then
  echo -e "  ${GREEN}PASS${NC}: dispatch-local.sh byte-identical to origin/main"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: dispatch-local.sh has changes vs origin/main:"
  echo "$DIFF" | head -20
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
