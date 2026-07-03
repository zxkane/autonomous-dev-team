#!/bin/bash
# test-controller-dispatch-dedup-361.sh — [INV-106] / issue #361 (302b).
#
# Unit tests for the controller-side per-(issue,mode) dispatch dedup marker
# (acquire_dispatch_marker, lib-dispatch.sh) and the dispatch-token run= field
# (post_dispatch_token / _dispatcher_run_id).
#
# Covers:
#   - R1: exactly one of N concurrent acquire_dispatch_marker calls for the
#     SAME (issue, mode) proceeds; the losers return 1 cleanly (no exception,
#     no dispatch()-adjacent side effect implied by the caller contract).
#   - R1: a DIFFERENT mode for the same issue is an independent marker (does
#     not collide with an in-flight marker for another mode).
#   - R3: an expired (backdated mtime) marker does not block a fresh acquire;
#     a live (fresh) marker does.
#   - R2: post_dispatch_token's comment body carries a `run=` field; existing
#     token-parsing readers (latest_dispatch_token_age_seconds /
#     is_within_grace_period) still match a legacy token WITHOUT `run=`
#     (backward compat) and a new token WITH it (forward compat).
#   - Fail-open: acquire_dispatch_marker proceeds (rc 0) when the marker
#     directory cannot be resolved, rather than freezing dispatch.
#
# Test IDs: TC-DEDUP-361-*.
#
# Run: bash tests/unit/test-controller-dispatch-dedup-361.sh

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
export PROJECT_ID="test-dedup-361-$$"
export MAX_RETRIES=3
export MAX_CONCURRENT=5

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
export AUTONOMOUS_PID_DIR="$TMPDIR"

# Mocked gh — mirrors test-dispatcher-reliability-99.sh's pattern. Only the
# two verbs post_dispatch_token/latest_dispatch_token_age_seconds need:
# `issue comment ... --body ...` (capture) and `issue view ... -q ...`
# (canned comments JSON).
_MOCK_COMMENTS_JSON=""
_MOCK_LAST_COMMENT_BODY=""
gh() {
  local cmd="${1:-}" sub="${2:-}"
  if [[ "$cmd" == "issue" && "$sub" == "comment" ]]; then
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--body" ]]; then
        _MOCK_LAST_COMMENT_BODY="$2"
        return 0
      fi
      shift
    done
    return 0
  fi
  local q_expr=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -q) q_expr="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ -n "$q_expr" && -n "$_MOCK_COMMENTS_JSON" ]]; then
    jq -r "$q_expr" <<<"$_MOCK_COMMENTS_JSON"
  fi
}
export -f gh

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

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

assert_true() {
  local desc="$1" rc="$2"
  if [[ "$rc" -eq 0 ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (rc=$rc, expected 0)"
    FAIL=$((FAIL + 1))
  fi
}

assert_false() {
  local desc="$1" rc="$2"
  if [[ "$rc" -ne 0 ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (rc=$rc, expected non-zero)"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
echo "=== TC-DEDUP-361-001/002: exactly-one-proceeds under concurrency (R1) ==="
# ---------------------------------------------------------------------------
# Fan N subshells racing acquire_dispatch_marker for the SAME (issue, mode)
# against the SAME AUTONOMOUS_PID_DIR sandbox. Each subshell is its own
# process (a real fork), so this exercises the mkdir syscall's actual
# atomicity guarantee, not just in-process bash state.
N=10
RESULT_DIR="$TMPDIR/conc-results"
mkdir -p "$RESULT_DIR"

for i in $(seq 1 "$N"); do
  (
    export AUTONOMOUS_PID_DIR="$TMPDIR"
    # shellcheck disable=SC1090
    export REPO REPO_OWNER PROJECT_ID MAX_RETRIES MAX_CONCURRENT
    source "$LIB" 2>/dev/null
    if acquire_dispatch_marker 501 dev-new; then
      echo "won" > "$RESULT_DIR/outcome-$i"
    fi
  ) &
done
wait

WINNER_COUNT=$(grep -l '^won$' "$RESULT_DIR"/outcome-* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "TC-DEDUP-361-001 exactly ONE winner among $N concurrent acquires (same issue+mode)" "1" "$WINNER_COUNT"

# TC-DEDUP-361-002: the marker directory itself exists after the race (the
# winner's mkdir landed).
if [[ -d "$TMPDIR/dispatch-marker-501-dev-new" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-DEDUP-361-002 marker directory exists post-race"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-002 marker directory missing post-race"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DEDUP-361-003/004: single-process sequential dedup + loser is clean (rc 1, no exception) ==="
# ---------------------------------------------------------------------------
rm -rf "$TMPDIR/dispatch-marker-502-dev-new"
acquire_dispatch_marker 502 dev-new
assert_true "TC-DEDUP-361-003 first acquire for (502, dev-new) succeeds" $?

acquire_dispatch_marker 502 dev-new
assert_false "TC-DEDUP-361-003 second acquire for SAME (502, dev-new) within grace fails cleanly (rc 1)" $?

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DEDUP-361-005: a DIFFERENT mode for the same issue is an independent marker ==="
# ---------------------------------------------------------------------------
acquire_dispatch_marker 502 review
assert_true "TC-DEDUP-361-005 (502, review) is independent of the held (502, dev-new) marker" $?

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DEDUP-361-006/007: TTL expiry (R3) ==="
# ---------------------------------------------------------------------------
rm -rf "$TMPDIR/dispatch-marker-503-dev-new"
DISPATCH_MARKER_TTL_SECONDS=2 acquire_dispatch_marker 503 dev-new
assert_true "TC-DEDUP-361-006 fresh acquire for (503, dev-new) succeeds" $?

# Still fresh (age < TTL) — a second acquire is blocked.
DISPATCH_MARKER_TTL_SECONDS=600 acquire_dispatch_marker 503 dev-new
assert_false "TC-DEDUP-361-006 live (non-expired) marker blocks a second acquire" $?

# Backdate the marker's mtime well past any TTL, then confirm expiry reclaims it.
touch -t 200001010000.00 "$TMPDIR/dispatch-marker-503-dev-new"
DISPATCH_MARKER_TTL_SECONDS=600 acquire_dispatch_marker 503 dev-new
assert_true "TC-DEDUP-361-007 expired (backdated) marker does NOT block a fresh acquire — reclaimed" $?

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DEDUP-361-008: DISPATCH_MARKER_TTL_SECONDS defaults to DISPATCH_GRACE_PERIOD_SECONDS ==="
# ---------------------------------------------------------------------------
rm -rf "$TMPDIR/dispatch-marker-504-dev-new"
unset DISPATCH_MARKER_TTL_SECONDS
export DISPATCH_GRACE_PERIOD_SECONDS=5
acquire_dispatch_marker 504 dev-new
touch -t 200001010000.00 "$TMPDIR/dispatch-marker-504-dev-new"
acquire_dispatch_marker 504 dev-new
assert_true "TC-DEDUP-361-008 backdated marker reclaimed using DISPATCH_GRACE_PERIOD_SECONDS default" $?
unset DISPATCH_GRACE_PERIOD_SECONDS

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DEDUP-361-009: fail-open when the marker directory cannot be resolved ==="
# ---------------------------------------------------------------------------
# pid_dir_for_project echoes empty + rc 1 when it cannot create the dir (e.g.
# a stale symlink at the resolved path). Simulate that by overriding the
# function directly (same technique test-mark-stalled-liveness.sh uses).
pid_dir_for_project() { return 1; }
export -f pid_dir_for_project
acquire_dispatch_marker 505 dev-new 2>/dev/null
assert_true "TC-DEDUP-361-009 acquire_dispatch_marker fails OPEN (rc 0) when pid_dir_for_project is unavailable" $?
unset -f pid_dir_for_project

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DEDUP-361-010: symlinked marker path is rejected (fails open, not a hard error) ==="
# ---------------------------------------------------------------------------
rm -rf "$TMPDIR/dispatch-marker-506-dev-new"
ln -s /tmp "$TMPDIR/dispatch-marker-506-dev-new"
acquire_dispatch_marker 506 dev-new 2>/dev/null
assert_true "TC-DEDUP-361-010 symlinked marker path fails open (rc 0) rather than using it" $?
rm -f "$TMPDIR/dispatch-marker-506-dev-new"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DEDUP-361-011..014: post_dispatch_token run= field (R2) ==="
# ---------------------------------------------------------------------------
_MOCK_LAST_COMMENT_BODY=""
post_dispatch_token 601 "dev-new"
if [[ "$_MOCK_LAST_COMMENT_BODY" == *"<!-- dispatcher-token: "*"mode=dev-new"*"run="*" -->"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-DEDUP-361-011 post_dispatch_token body carries a run= field after mode="
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-011 run= field missing/misordered"
  echo "      body='${_MOCK_LAST_COMMENT_BODY}'"
  FAIL=$((FAIL + 1))
fi

# TC-DEDUP-361-012: DISPATCHER_RUN_ID env override is honored verbatim.
_MOCK_LAST_COMMENT_BODY=""
_DISPATCHER_RUN_ID_CACHE=""   # reset the per-process cache so the override takes effect
DISPATCHER_RUN_ID="tick-abc-123" post_dispatch_token 602 "review"
assert_eq "TC-DEDUP-361-012 DISPATCHER_RUN_ID override is used verbatim in run=" "1" \
  "$(grep -c "run=tick-abc-123" <<<"$_MOCK_LAST_COMMENT_BODY")"
_DISPATCHER_RUN_ID_CACHE=""   # reset cache so later cases mint their own id

# TC-DEDUP-361-013: two post_dispatch_token calls in the SAME process share
# the identical run id (a tick's own identity is stable across its steps).
_MOCK_LAST_COMMENT_BODY=""
post_dispatch_token 603 "dev-new"
first_body="$_MOCK_LAST_COMMENT_BODY"
first_run="$(grep -oE 'run=[^ ]+' <<<"$first_body")"
_MOCK_LAST_COMMENT_BODY=""
post_dispatch_token 604 "dev-resume"
second_run="$(grep -oE 'run=[^ ]+' <<<"$_MOCK_LAST_COMMENT_BODY")"
assert_eq "TC-DEDUP-361-013 run= is stable across calls within one process" "$first_run" "$second_run"

# TC-DEDUP-361-013b (regression): the cache must survive a REAL wall-clock
# second boundary — `_dispatcher_run_id` sets a global as a side effect
# rather than echoing, specifically so a caller reading it directly (not via
# `$(...)`) never fork-loses the cache write. A `$(_dispatcher_run_id)`-style
# call site would re-mint a fresh id every time (defeating the cache) because
# command substitution runs in a subshell whose variable writes never
# propagate to the parent. Sleep past a second boundary to prove the id is
# genuinely cached, not merely coincidentally identical (two calls in the
# same wall-clock second would look "stable" even with the subshell bug).
_DISPATCHER_RUN_ID_CACHE=""
_dispatcher_run_id
pre_sleep_run_id="$_DISPATCHER_RUN_ID_CACHE"
sleep 1.2
_dispatcher_run_id
post_sleep_run_id="$_DISPATCHER_RUN_ID_CACHE"
assert_eq "TC-DEDUP-361-013b _dispatcher_run_id cache survives a real 1.2s wall-clock gap" \
  "$pre_sleep_run_id" "$post_sleep_run_id"
_DISPATCHER_RUN_ID_CACHE=""   # reset cache so later cases mint their own id

# TC-DEDUP-361-014: backward compat — a LEGACY token comment (no run= field,
# the pre-#361 shape) still parses via latest_dispatch_token_age_seconds.
T_RECENT=$(date -u -d "-60 seconds" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -v-60S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
_MOCK_COMMENTS_JSON="{\"comments\":[
  {\"body\":\"<!-- dispatcher-token: aaaaaaa at ${T_RECENT} mode=dev-new -->\nDispatching autonomous development...\"}
]}"
age=$(latest_dispatch_token_age_seconds 999)
if [[ "$age" =~ ^[0-9]+$ ]] && (( age >= 0 && age <= 120 )); then
  echo -e "  ${GREEN}PASS${NC}: TC-DEDUP-361-014 legacy token WITHOUT run= still parses (age=$age)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-014 legacy token failed to parse (age='$age')"
  FAIL=$((FAIL + 1))
fi

# TC-DEDUP-361-015: a NEW token comment WITH run= also parses (forward shape).
_MOCK_COMMENTS_JSON="{\"comments\":[
  {\"body\":\"<!-- dispatcher-token: bbbbbbb at ${T_RECENT} mode=dev-resume run=12345-1783000000 -->\nResuming autonomous development...\"}
]}"
age=$(latest_dispatch_token_age_seconds 999)
if [[ "$age" =~ ^[0-9]+$ ]] && (( age >= 0 && age <= 120 )); then
  echo -e "  ${GREEN}PASS${NC}: TC-DEDUP-361-015 new token WITH run= parses (age=$age)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-015 new-shape token failed to parse (age='$age')"
  FAIL=$((FAIL + 1))
fi

# TC-DEDUP-361-016: is_within_grace_period also still works against the
# new run=-bearing shape (the other existing reader of this marker).
export DISPATCH_GRACE_PERIOD_SECONDS=600
is_within_grace_period 999
assert_true "TC-DEDUP-361-016 is_within_grace_period matches a run=-bearing token" $?
unset DISPATCH_GRACE_PERIOD_SECONDS

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DEDUP-361-017: dispatcher-tick.sh source-of-truth — every dispatch() call site is guarded ==="
# ---------------------------------------------------------------------------
TICK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"
acquire_calls=$(grep -cE '^\s*if\s+!\s+acquire_dispatch_marker\s' "$TICK")
if [[ "$acquire_calls" -ge 4 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-DEDUP-361-017 dispatcher-tick.sh has >= 4 acquire_dispatch_marker guards (got $acquire_calls)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-017 expected >= 4 acquire_dispatch_marker guards in dispatcher-tick.sh, got $acquire_calls"
  FAIL=$((FAIL + 1))
fi

# TC-DEDUP-361-018: lib-dispatch.sh's own INV-35 fresh-dev branch
# (handle_completed_session_routing Branch C) is also guarded — the second
# entry point into the dev-new dispatch path (Step 4a.5 delegation, [INV-98]).
lib_acquire_calls=$(grep -cE '^\s*if\s+!\s+acquire_dispatch_marker\s' "$LIB")
if [[ "$lib_acquire_calls" -ge 1 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-DEDUP-361-018 lib-dispatch.sh guards its own dev-new dispatch site (handle_completed_session_routing)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-018 lib-dispatch.sh has no acquire_dispatch_marker guard"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
