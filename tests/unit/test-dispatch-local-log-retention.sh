#!/bin/bash
# test-dispatch-local-log-retention.sh — Unit tests for issue #245.
#
# dispatch-local.sh used to zero the per-issue agent log on EVERY dispatch via
#   install -m 600 /dev/null "${LOG_PREFIX}-{issue,review}-${ISSUE_NUM}.log"
# so a re-dispatch of the same issue destroyed the prior (possibly crashed)
# run's stdout/stderr before the new run started — no forensic trail.
#
# The fix rotates the existing log to a single `…-N.log.1` generation (mode
# 0600) before creating the fresh 0600 current log, so the immediately-prior
# run survives a routine re-dispatch. The deliberate INV-12 / INV-35
# recovery-truncates (lib-dispatch.sh / dispatcher-tick.sh) are left untouched.
#
# Run: bash tests/unit/test-dispatch-local-log-retention.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISPATCHER_SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"

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
    echo "      haystack='$haystack'"
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
    echo "      needle='$needle' (should NOT appear)"
    echo "      haystack='$haystack'"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_missing() {
  local desc="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      path exists but should not: '$path'"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Sandbox: replicate the project-side scripts/ layout dispatch-local.sh expects
# (autonomous.conf + stub dev/review wrappers that record argv and stay alive
# briefly so the post-spawn kill -0 check passes). Mirrors
# test-dispatch-local-empty-session.sh.
# ---------------------------------------------------------------------------

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"; rm -f "/tmp/agent-${PROJECT_ID:-_unset}-"*"-${ISSUE:-_unset}.log"* 2>/dev/null' EXIT

# Unique PROJECT_ID so the /tmp/agent-${PROJECT_ID}-* logs never collide with a
# live wrapper on the shared dev box. ISSUE is fixed; the PID is the entropy.
PROJECT_ID="logret-test-$$"
ISSUE=4242
LOG_PREFIX="/tmp/agent-${PROJECT_ID}"
DEV_LOG="${LOG_PREFIX}-issue-${ISSUE}.log"
DEV_LOG_ROT="${DEV_LOG}.1"
REVIEW_LOG="${LOG_PREFIX}-review-${ISSUE}.log"
REVIEW_LOG_ROT="${REVIEW_LOG}.1"

# Pre-clean any residue from a prior aborted run of this test.
rm -f "$DEV_LOG" "$DEV_LOG_ROT" "$REVIEW_LOG" "$REVIEW_LOG_ROT" 2>/dev/null

PROJ="$TMPROOT/proj"
mkdir -p "$PROJ/scripts" "$PROJ/.pids"

# Stub wrappers: append to the redirected log so we can prove the fresh log is
# a clean new-run file, then stay alive briefly for the kill -0 check.
make_stub() {
  local target="$1"
  cat > "$target" <<'STUB'
#!/bin/bash
echo "NEW-RUN-OUTPUT" >&2
sleep 2
exit 0
STUB
  chmod +x "$target"
}
make_stub "$PROJ/scripts/autonomous-dev.sh"
make_stub "$PROJ/scripts/autonomous-review.sh"

cat > "$PROJ/scripts/autonomous.conf" <<CONF
PROJECT_ID="$PROJECT_ID"
REPO="test/test"
REPO_OWNER="test"
REPO_NAME="test"
PROJECT_DIR="$PROJ"
AGENT_CMD="claude"
GH_AUTH_MODE="token"
PID_DIR="$PROJ/.pids"
CONF

# Symlink the dispatch-local.sh + lib chain into the project scripts/ (the
# production shared-install topology).
LIB_FILES=(
  dispatch-local.sh lib-config.sh lib-agent.sh lib-auth.sh
  lib-dispatch.sh lib-review-bots.sh
  gh-app-token.sh gh-with-token-refresh.sh gh-token-refresh-daemon.sh
)
for f in "${LIB_FILES[@]}"; do
  if [[ -f "$DISPATCHER_SCRIPTS/$f" ]]; then
    ln -sf "$DISPATCHER_SCRIPTS/$f" "$PROJ/scripts/$f"
  fi
done

DISPATCH_ENTRY="$PROJ/scripts/dispatch-local.sh"

# Invoke dispatch-local.sh and wait for the spawned wrapper to be running.
run_dispatch() {
  rm -f "$PROJ/.pids/"*.pid 2>/dev/null
  ( cd "$PROJ" && bash "$DISPATCH_ENTRY" "$@" >/dev/null 2>&1 ) || true
  # Give the nohup'd stub a moment to start writing.
  sleep 0.5
}

mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
echo "=== TC-LOGRET-1: review arm — prior run's log survives re-dispatch ==="
# ---------------------------------------------------------------------------
SENTINEL="CRASHED-RUN-EVIDENCE-REVIEW-$$"
# Simulate a prior (crashed) run that left content in the review log.
install -m 600 /dev/null "$REVIEW_LOG"
printf '%s\n' "$SENTINEL" > "$REVIEW_LOG"

run_dispatch review "$ISSUE"

ROT_CONTENT=$(cat "$REVIEW_LOG_ROT" 2>/dev/null || true)
CUR_CONTENT=$(cat "$REVIEW_LOG" 2>/dev/null || true)
assert_contains "sentinel recoverable in …-review-N.log.1" "$SENTINEL" "$ROT_CONTENT"
assert_not_contains "fresh …-review-N.log is a clean new-run file (no sentinel)" "$SENTINEL" "$CUR_CONTENT"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LOGRET-3/4: perms — fresh current log AND rotated .log.1 are 0600 ==="
# ---------------------------------------------------------------------------
assert_eq "fresh …-review-N.log is mode 600" "600" "$(mode_of "$REVIEW_LOG")"
assert_eq "rotated …-review-N.log.1 is mode 600" "600" "$(mode_of "$REVIEW_LOG_ROT")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LOGRET-2: dev arm — prior run's log survives re-dispatch ==="
# ---------------------------------------------------------------------------
SENTINEL_DEV="CRASHED-RUN-EVIDENCE-DEV-$$"
install -m 600 /dev/null "$DEV_LOG"
printf '%s\n' "$SENTINEL_DEV" > "$DEV_LOG"

run_dispatch dev-new "$ISSUE"

assert_contains "sentinel recoverable in …-issue-N.log.1" "$SENTINEL_DEV" "$(cat "$DEV_LOG_ROT" 2>/dev/null || true)"
assert_eq "fresh …-issue-N.log is mode 600" "600" "$(mode_of "$DEV_LOG")"
assert_eq "rotated …-issue-N.log.1 is mode 600" "600" "$(mode_of "$DEV_LOG_ROT")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LOGRET-5: first dispatch (no prior log) → no spurious .log.1 ==="
# ---------------------------------------------------------------------------
ISSUE2=4343
DEV_LOG2="${LOG_PREFIX}-issue-${ISSUE2}.log"
DEV_LOG2_ROT="${DEV_LOG2}.1"
rm -f "$DEV_LOG2" "$DEV_LOG2_ROT" 2>/dev/null

run_dispatch dev-new "$ISSUE2"

assert_eq "fresh …-issue-N.log is mode 600 on first dispatch" "600" "$(mode_of "$DEV_LOG2")"
assert_file_missing "no …-issue-N.log.1 created when there was nothing to rotate" "$DEV_LOG2_ROT"
rm -f "$DEV_LOG2" "$DEV_LOG2_ROT" 2>/dev/null

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LOGRET-6: disk bound — single generation, no .log.2 ==="
# ---------------------------------------------------------------------------
ISSUE3=4444
DEV_LOG3="${LOG_PREFIX}-issue-${ISSUE3}.log"
DEV_LOG3_ROT="${DEV_LOG3}.1"
DEV_LOG3_ROT2="${DEV_LOG3}.2"
rm -f "$DEV_LOG3"* 2>/dev/null

# Run 1
install -m 600 /dev/null "$DEV_LOG3"; printf 'RUN-1\n' > "$DEV_LOG3"
run_dispatch dev-new "$ISSUE3"
# Seed the now-fresh current log as if run 2 produced output, then re-dispatch.
printf 'RUN-2\n' > "$DEV_LOG3"
run_dispatch dev-new "$ISSUE3"
# And once more for run 3.
printf 'RUN-3\n' > "$DEV_LOG3"
run_dispatch dev-new "$ISSUE3"

assert_file_missing "no second rotated generation (…-issue-N.log.2)" "$DEV_LOG3_ROT2"
assert_contains ".log.1 holds the immediately-preceding run (RUN-3), not the oldest" "RUN-3" "$(cat "$DEV_LOG3_ROT" 2>/dev/null || true)"
assert_not_contains ".log.1 does not retain RUN-1 (oldest discarded)" "RUN-1" "$(cat "$DEV_LOG3_ROT" 2>/dev/null || true)"
rm -f "$DEV_LOG3"* 2>/dev/null

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LOGRET-8: symlinked current log → chmod does NOT follow to victim (CWE-59) ==="
# ---------------------------------------------------------------------------
# If the current log is a symlink to a victim file, rotation must move the
# LINK (not write through it) and must NOT chmod the link target. mv moves the
# symlink itself to .log.1; the guarded chmod skips it because it is a symlink.
ISSUE4=4545
DEV_LOG4="${LOG_PREFIX}-issue-${ISSUE4}.log"
DEV_LOG4_ROT="${DEV_LOG4}.1"
VICTIM="$TMPROOT/victim-0644.txt"
rm -f "$DEV_LOG4"* 2>/dev/null
: > "$VICTIM"; chmod 644 "$VICTIM"
ln -sf "$VICTIM" "$DEV_LOG4"   # current log is a symlink → victim (mode 644)

run_dispatch dev-new "$ISSUE4"

assert_eq "victim's mode is untouched (chmod did not follow the symlink)" "644" "$(mode_of "$VICTIM")"
# .log.1 is the moved symlink; the fresh current log is a new 0600 regular file.
assert_eq "fresh …-issue-N.log is a new 0600 regular file after symlinked-log rotation" "600" "$(mode_of "$DEV_LOG4")"
rm -f "$DEV_LOG4"* "$VICTIM" 2>/dev/null

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LOGRET-7: INV-12 / INV-35 deliberate recovery-truncates preserved ==="
# ---------------------------------------------------------------------------
# Guard against an over-broad fix that disables the intentional recovery-truncate.
LIB_DISPATCH="$DISPATCHER_SCRIPTS/lib-dispatch.sh"
TICK="$DISPATCHER_SCRIPTS/dispatcher-tick.sh"
if grep -Eq ':[[:space:]]*>[[:space:]]*"\$_log_file"' "$LIB_DISPATCH"; then
  echo -e "  ${GREEN}PASS${NC}: INV-35 recovery-truncate ': > \"\$_log_file\"' survives in lib-dispatch.sh"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: INV-35 recovery-truncate missing from lib-dispatch.sh"
  FAIL=$((FAIL + 1))
fi
if grep -Eq ':[[:space:]]*>[[:space:]]*"\$_ptl_log"' "$TICK"; then
  echo -e "  ${GREEN}PASS${NC}: INV-12 PTL recovery-truncate ': > \"\$_ptl_log\"' survives in dispatcher-tick.sh"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: INV-12 PTL recovery-truncate missing from dispatcher-tick.sh"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
