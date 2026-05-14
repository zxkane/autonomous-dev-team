#!/bin/bash
# test-mark-stalled-liveness.sh — Regression for issue #121 Fix C.
#
# `mark_stalled` previously did `gh issue edit --remove-label pending-dev
# --add-label stalled` + post comment WITHOUT checking whether a wrapper
# was still alive. Once the retry counter was wrong (Fix A), `mark_stalled`
# fired against a healthy wrapper that was making real progress — the
# wrapper subsequently completed work but the issue was already labeled
# stalled, leaving an `approved + stalled` (or similar) inconsistent end
# state.
#
# Fix C: `mark_stalled` queries the dev-wrapper PID file for this issue;
# if `pid_alive` returns ALIVE, defer the stall decision (no label edit,
# post a one-shot deferral comment). Next tick re-evaluates. Existing
# behavior (PID file absent or process dead) preserved.
#
# Run: bash tests/unit/test-mark-stalled-liveness.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-msl
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# Capture every gh call (and its args) so we can assert on what mark_stalled
# tried to do. Stub returns canned outputs based on verb.
_GH_CALLS=()
_MOCK_COMMENTS_JSON=""
gh() {
  _GH_CALLS+=("$*")
  case "$1" in
    issue)
      case "$2" in
        view)
          # mark_stalled doesn't call `issue view`; count_* helpers do.
          # Default to empty comments array so the counters return 0.
          local q=""
          local i=3
          while [[ $i -le $# ]]; do
            if [[ "${!i}" == "-q" ]]; then
              local j=$((i + 1))
              q="${!j}"
              break
            fi
            i=$((i + 1))
          done
          if [[ -n "$q" ]]; then
            jq -r "$q" <<<"${_MOCK_COMMENTS_JSON:-{\"comments\":[]\}}"
          fi
          ;;
        edit|comment)
          # Side-effect verbs — silent success.
          ;;
      esac
      ;;
  esac
}
export -f gh

# Override pid_dir_for_project so mark_stalled and pid_alive look in our
# sandbox dir rather than the user's runtime dir. lib-config.sh defines it
# in scope; we just redefine the function after sourcing.
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"

# Override pid_dir_for_project AFTER source so our sandbox wins. This is
# the same hook autonomous-dev.sh::cleanup uses to find the wrapper PID.
pid_dir_for_project() {
  echo "$TMPDIR"
}
export -f pid_dir_for_project

set +e

assert_match() {
  local desc="$1" pattern="$2" haystack="$3"
  if grep -qE "$pattern" <<<"$haystack"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"
    echo "      haystack:"
    echo "$haystack" | sed 's/^/        /'
    FAIL=$((FAIL + 1))
  fi
}

assert_no_match() {
  local desc="$1" pattern="$2" haystack="$3"
  if ! grep -qE "$pattern" <<<"$haystack"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern '$pattern' should NOT match)"
    echo "      haystack:"
    echo "$haystack" | sed 's/^/        /'
    FAIL=$((FAIL + 1))
  fi
}

# ===================================================================
echo "=== TC-MSL-001..005: mark_stalled liveness check ==="

# TC-MSL-001 & TC-MSL-004 & TC-MSL-005 — wrapper alive: defer
_GH_CALLS=()
# Spawn a real long-lived process and write its PID into the file
# pid_alive will read.
sleep 60 &
LIVE_PID=$!
echo "$LIVE_PID" > "$TMPDIR/issue-101.pid"
mark_stalled 101 >/dev/null
edit_calls=$(printf '%s\n' "${_GH_CALLS[@]}" | grep -E '^issue edit' || true)
comment_calls=$(printf '%s\n' "${_GH_CALLS[@]}" | grep -E '^issue comment' || true)
assert_no_match "TC-MSL-001/005 alive wrapper → no 'issue edit ... stalled' label call" "issue edit.*stalled" "$edit_calls"
assert_match "TC-MSL-004 alive wrapper → deferral comment posted" "issue comment 101" "$comment_calls"
# Make sure the comment text says "deferred" so operators know it's not a stall.
deferral_text=$(printf '%s\n' "${_GH_CALLS[@]}" | grep -E '^issue comment 101' || true)
assert_match "TC-MSL-004 deferral comment mentions 'defer'" "[Dd]efer" "$deferral_text"
# Cleanup the spawned process before next test
kill "$LIVE_PID" 2>/dev/null || true
wait "$LIVE_PID" 2>/dev/null || true
rm -f "$TMPDIR/issue-101.pid"

# TC-MSL-002 — PID file present but process dead: stall fires (existing behavior)
_GH_CALLS=()
# Use a PID that almost certainly doesn't exist (max valid PID + 1 territory).
# `kill -0 999999` will fail on most Linux systems where pid_max is 32768 or
# 4194304. Even if it does happen to exist, the heartbeat-mtime fallback
# requires the file to be recently mtime'd — which a real spawned-then-dead
# wrapper would have but our test setup won't.
echo "999999" > "$TMPDIR/issue-102.pid"
# Backdate the mtime so heartbeat fallback doesn't kick in.
touch -t 200001010000.00 "$TMPDIR/issue-102.pid"
mark_stalled 102 >/dev/null
edit_calls=$(printf '%s\n' "${_GH_CALLS[@]}" | grep -E '^issue edit' || true)
assert_match "TC-MSL-002 dead wrapper → stall label edit fires" "issue edit 102.*stalled" "$edit_calls"
rm -f "$TMPDIR/issue-102.pid"

# TC-MSL-003 — PID file absent: stall fires (existing behavior)
_GH_CALLS=()
# No PID file for issue 103.
mark_stalled 103 >/dev/null
edit_calls=$(printf '%s\n' "${_GH_CALLS[@]}" | grep -E '^issue edit' || true)
assert_match "TC-MSL-003 missing PID file → stall label edit fires" "issue edit 103.*stalled" "$edit_calls"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
