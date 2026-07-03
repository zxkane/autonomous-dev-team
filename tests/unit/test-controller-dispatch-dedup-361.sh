#!/bin/bash
# test-controller-dispatch-dedup-361.sh — [INV-108] / issue #361 (302b).
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
assert_false "TC-DEDUP-361-004 second acquire for SAME (502, dev-new) within grace fails cleanly (rc 1)" $?

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
#
# Deliberately NOT `export -f` + `unset -f`: bash's `unset -f` on a
# previously-exported function does not restore the ORIGINAL definition —
# once a function is redefined at global scope, the redefinition is
# permanent for the rest of the process (and its subshells); `unset -f` only
# deletes it outright, leaving `pid_dir_for_project` undefined for every
# later test in this file (a real bug this suite hit and fixed — the
# corruption silently broke TC-019..023 below, which call the real function
# from a subshell). Running the override + call in a SUBSHELL confines the
# redefinition to that subshell's own function table; the parent shell's
# `pid_dir_for_project` (sourced from lib-config.sh) is never touched.
(
  pid_dir_for_project() { return 1; }
  acquire_dispatch_marker 505 dev-new 2>/dev/null
)
assert_true "TC-DEDUP-361-009 acquire_dispatch_marker fails OPEN (rc 0) when pid_dir_for_project is unavailable" $?

# TC-DEDUP-361-009b (#361 round-7 [P1]): the fail-open must hold with `set -e`
# ACTIVE and the call NOT in a condition context. A bare `var=$(cmd)` assignment
# propagates cmd's rc, so without the `|| base_dir=""` guard the subshell below
# dies at the assignment line (exit 1) before the fail-open branch — the exact
# whole-tick-abort the finding describes. The marker echo after the call proves
# the function RETURNED (fail-open) rather than the shell aborting.
_R=$(
  set -e
  pid_dir_for_project() { return 1; }
  acquire_dispatch_marker 505 dev-new 2>/dev/null
  echo "SURVIVED:$?"
)
assert_eq "TC-DEDUP-361-009b fail-open survives set -e outside a condition context (no tick abort)" "SURVIVED:0" "$_R"

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
echo "=== TC-DEDUP-361-010b/c: marker-CREATION failure (non-EEXIST) fails OPEN (#361 round-6 [P1]) ==="
# ---------------------------------------------------------------------------
# pid_dir_for_project succeeds but the mkdir of the marker itself fails for a
# non-EEXIST reason (permissions drift / ENOSPC after the base dir resolved).
# Pre-fix, acquire fell through to _mtime_epoch on a NONEXISTENT path → rc 1 →
# every caller skipped the issue as "held" with no marker to ever expire.
# Simulate by making the base dir read-only so mkdir fails EACCES.
_RO_BASE="$TMPDIR/ro-marker-base"
mkdir -p "$_RO_BASE"
chmod 0555 "$_RO_BASE"
if mkdir "$_RO_BASE/probe" 2>/dev/null; then
  # Running as root or on a perm-ignoring FS — the EACCES simulation cannot
  # work; skip LOUDLY rather than asserting a vacuous pass.
  rmdir "$_RO_BASE/probe"
  echo "  SKIP: TC-DEDUP-361-010b/c cannot simulate EACCES (perms not enforced here)"
else
  (
    pid_dir_for_project() { echo "$_RO_BASE"; }
    acquire_dispatch_marker 507 dev-new 2>/dev/null
  )
  assert_true "TC-DEDUP-361-010b marker-creation failure (EACCES) fails OPEN (rc 0), not held" $?
  (
    pid_dir_for_project() { echo "$_RO_BASE"; }
    acquire_dispatch_marker 507 dev-new 2>&1 | grep -q 'dispatch-marker creation failed'
  )
  assert_true "TC-DEDUP-361-010c marker-creation failure emits the WARN naming the fail-open" $?
fi
chmod 0755 "$_RO_BASE"; rm -rf "$_RO_BASE"

# TC-DEDUP-361-010d: a plain-FILE obstruction at the marker path is NOT the
# creation-failure class — it exists, so it takes the mtime path (fresh file
# → held, rc 1). Pins the [ ! -e ] guard's boundary.
rm -rf "$TMPDIR/dispatch-marker-508-dev-new"
touch "$TMPDIR/dispatch-marker-508-dev-new"
acquire_dispatch_marker 508 dev-new 2>/dev/null
assert_false "TC-DEDUP-361-010d plain-file obstruction (fresh mtime) is treated as held (rc 1), not fail-open" $?
rm -f "$TMPDIR/dispatch-marker-508-dev-new"

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
echo "=== TC-DEDUP-361-019..022: skip-path is actually taken through the REAL guard text (not a stub) ==="
# ---------------------------------------------------------------------------
# TC-DEDUP-361-017/018 above only prove the guard TEXT exists (grep -c on the
# source); they never execute it. This section extracts each real
# `if ! acquire_dispatch_marker "$issue_num" "<mode>"; then ... fi` block
# verbatim out of dispatcher-tick.sh (same technique
# test-dispatcher-tick-router.sh uses for dispatch()) and runs it against
# the REAL acquire_dispatch_marker sourced above, with a pre-planted HELD
# marker — proving the shipped code actually takes the skip branch (`continue`,
# no side effect) rather than merely containing the guard's text. Guards
# a future accidental inversion (`if acquire_dispatch_marker ...; then continue; fi`)
# that grep -c alone cannot catch.
extract_guard_block() {
  local mode="$1" occurrence="$2"
  awk -v mode="$mode" -v occ="$occurrence" '
    BEGIN { count = 0; in_block = 0 }
    $0 ~ ("acquire_dispatch_marker \"\\$issue_num\" \"" mode "\"") {
      count++
      if (count == occ) { in_block = 1 }
    }
    in_block { print; if ($0 ~ /^[ \t]*fi[ \t]*$/) { in_block = 0; exit } }
  ' "$TICK"
}

# `continue` is only meaningful inside an actual `for`/`while`/`until` loop —
# outside one it's a bash no-op (with a stderr warning) and execution falls
# through to the next statement regardless. The real guard block always
# lives inside dispatcher-tick.sh's `for i in $(seq ...); do ... done` loops,
# so the harness MUST wrap the eval'd block in a real `for` loop too, or this
# test would report "skip" even when the guard's `continue` did nothing.
#
# Args: <block> <issue> <mode> <plant_marker: 0|1>
# Returns: 0 if code AFTER the guard was reached, 1 if it was NOT reached.
run_guard_block() {
  local block="$1" issue="$2" mode="$3" plant_marker="$4"
  rm -rf "$TMPDIR/dispatch-marker-${issue}-${mode}"
  [[ "$plant_marker" = "1" ]] && mkdir "$TMPDIR/dispatch-marker-${issue}-${mode}"
  rm -f "$TMPDIR/reached-${issue}-${mode}"
  (
    issue_num="$issue"
    log() { :; }
    set +e
    for _once in 1; do
      eval "$block"
      echo "REACHED_AFTER_GUARD" > "$TMPDIR/reached-${issue}-${mode}"
    done
  )
  local reached=1
  [[ -f "$TMPDIR/reached-${issue}-${mode}" ]] && reached=0
  rm -f "$TMPDIR/reached-${issue}-${mode}"
  rm -rf "$TMPDIR/dispatch-marker-${issue}-${mode}"
  return "$reached"
}

DEV_NEW_BLOCK_1=$(extract_guard_block "dev-new" 1)
run_guard_block "$DEV_NEW_BLOCK_1" 701 "dev-new" 1
assert_false "TC-DEDUP-361-019 Step 2 (dev-new) real guard: held marker → continue fires, code after the guard is NOT reached" $?

REVIEW_BLOCK_1=$(extract_guard_block "review" 1)
run_guard_block "$REVIEW_BLOCK_1" 702 "review" 1
assert_false "TC-DEDUP-361-020 Step 3 (review) real guard: held marker → continue fires, code after the guard is NOT reached" $?

DEV_NEW_BLOCK_2=$(extract_guard_block "dev-new" 2)
run_guard_block "$DEV_NEW_BLOCK_2" 703 "dev-new" 1
assert_false "TC-DEDUP-361-021 Step 4 PTL (dev-new) real guard: held marker → continue fires, code after the guard is NOT reached" $?

DEV_RESUME_BLOCK_1=$(extract_guard_block "dev-resume" 1)
run_guard_block "$DEV_RESUME_BLOCK_1" 704 "dev-resume" 1
assert_false "TC-DEDUP-361-022 Step 4c (dev-resume) real guard: held marker → continue fires, code after the guard is NOT reached" $?

# TC-DEDUP-361-023 (control): the SAME extracted block, with NO pre-planted
# marker (fresh acquire succeeds), DOES reach past the guard — proving
# TC-019..022's negative result is the guard actually firing, not a broken
# harness that always suppresses execution.
run_guard_block "$DEV_NEW_BLOCK_1" 705 "dev-new" 0
assert_true "TC-DEDUP-361-023 control — fresh acquire (no held marker) DOES reach past the guard" $?

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DEDUP-361-024..032: release on pre-spawn failure (codex review [P1], #361) ==="
# ---------------------------------------------------------------------------
# codex finding: acquire_dispatch_marker runs before label edits, notice
# comments, log resets, and the dispatch() call, but nothing released it when
# one of THOSE steps aborted before a wrapper actually launched — a marker
# then sits for the full TTL even though no wrapper is running, turning a
# transient failure into a ~10 minute false stall. This section proves the
# fix: acquire_dispatch_marker now tracks every real acquire in a pending
# list; dispatch_marker_confirm_launched drops an entry (marker lives out its
# TTL); release_dispatch_marker removes the on-disk marker directly AND drops
# the pending entry; _dispatch_marker_release_pending (the tick's EXIT-trap
# handler) sweeps everything still pending.

# TC-DEDUP-361-024: acquiring populates the pending list.
rm -rf "$TMPDIR/dispatch-marker-801-dev-new"
_DISPATCH_MARKER_PENDING=()
acquire_dispatch_marker 801 dev-new
assert_eq "TC-DEDUP-361-024 acquire adds (issue,mode) to the pending list" "801:dev-new" "${_DISPATCH_MARKER_PENDING[*]:-}"

# TC-DEDUP-361-025: release_dispatch_marker removes the on-disk marker AND
# drops the pending entry (so the later EXIT-trap sweep doesn't redundantly
# try again).
release_dispatch_marker 801 dev-new
if [[ -d "$TMPDIR/dispatch-marker-801-dev-new" ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-025 release_dispatch_marker did not remove the on-disk marker"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-DEDUP-361-025 release_dispatch_marker removes the on-disk marker"
  PASS=$((PASS + 1))
fi
assert_eq "TC-DEDUP-361-025 release_dispatch_marker also drops the pending entry" "" "${_DISPATCH_MARKER_PENDING[*]:-}"

# TC-DEDUP-361-025b (#361 round-9 [P1]): release is GATED on ownership — a
# release for a pair NOT in the pending list must NOT touch the on-disk
# marker. Scenario: THIS tick's acquire fail-opened (infra unavailable →
# nothing created, nothing pending), infra recovered, a CONCURRENT tick
# acquired the marker for real, then this tick's soft-failure branch calls
# release. Pre-fix the blind `rm -rf` deleted the concurrent tick's live
# marker, reopening the duplicate-dispatch race.
rm -rf "$TMPDIR/dispatch-marker-803-dev-new"
mkdir "$TMPDIR/dispatch-marker-803-dev-new"      # the CONCURRENT tick's live marker
_DISPATCH_MARKER_PENDING=()                       # ours fail-opened: pending is empty
release_dispatch_marker 803 dev-new
if [[ -d "$TMPDIR/dispatch-marker-803-dev-new" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-DEDUP-361-025b not-owned release leaves a foreign live marker untouched"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-025b not-owned release DELETED a foreign live marker (dup-dispatch race reopened)"
  FAIL=$((FAIL + 1))
fi
rm -rf "$TMPDIR/dispatch-marker-803-dev-new"

# TC-DEDUP-361-025c: control — an OWNED release (pair in pending) still removes
# the marker, so the gate does not break the round-4 release-on-failure fix.
rm -rf "$TMPDIR/dispatch-marker-804-dev-new"
acquire_dispatch_marker 804 dev-new
release_dispatch_marker 804 dev-new
if [[ -d "$TMPDIR/dispatch-marker-804-dev-new" ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-025c owned release failed to remove the marker (gate over-blocks)"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-DEDUP-361-025c owned release still removes the marker"
  PASS=$((PASS + 1))
fi

# TC-DEDUP-361-026: dispatch_marker_confirm_launched drops the pending entry
# WITHOUT touching the on-disk marker (it must survive to live out its TTL —
# a wrapper is now actually running and depends on Step 5's grace window).
rm -rf "$TMPDIR/dispatch-marker-802-dev-new"
_DISPATCH_MARKER_PENDING=()
acquire_dispatch_marker 802 dev-new
dispatch_marker_confirm_launched 802 dev-new
assert_eq "TC-DEDUP-361-026 confirm drops the pending entry" "" "${_DISPATCH_MARKER_PENDING[*]:-}"
if [[ -d "$TMPDIR/dispatch-marker-802-dev-new" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-DEDUP-361-026 confirm leaves the on-disk marker in place (lives out its TTL)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-026 confirm should NOT remove the on-disk marker"
  FAIL=$((FAIL + 1))
fi
rm -rf "$TMPDIR/dispatch-marker-802-dev-new"

# TC-DEDUP-361-027: the EXIT-trap handler releases an unconfirmed marker...
rm -rf "$TMPDIR/dispatch-marker-803-review"
_DISPATCH_MARKER_PENDING=()
acquire_dispatch_marker 803 review
_dispatch_marker_release_pending
if [[ -d "$TMPDIR/dispatch-marker-803-review" ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-027 unconfirmed marker survived the EXIT-trap sweep"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-DEDUP-361-027 unconfirmed marker is released by the EXIT-trap sweep"
  PASS=$((PASS + 1))
fi
assert_eq "TC-DEDUP-361-027 pending list is empty after the sweep" "" "${_DISPATCH_MARKER_PENDING[*]:-}"

# TC-DEDUP-361-028: ...but a CONFIRMED marker survives the same sweep (mixed
# pending list — one confirmed, one not — proves the trap discriminates
# correctly rather than sweeping everything indiscriminately).
rm -rf "$TMPDIR/dispatch-marker-804-dev-new" "$TMPDIR/dispatch-marker-805-review"
_DISPATCH_MARKER_PENDING=()
acquire_dispatch_marker 804 dev-new
acquire_dispatch_marker 805 review
dispatch_marker_confirm_launched 804 dev-new    # 804 confirmed; 805 left pending
_dispatch_marker_release_pending
if [[ -d "$TMPDIR/dispatch-marker-804-dev-new" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-DEDUP-361-028 confirmed marker (804) survives the EXIT-trap sweep"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-028 confirmed marker (804) was wrongly swept"
  FAIL=$((FAIL + 1))
fi
if [[ -d "$TMPDIR/dispatch-marker-805-review" ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-028 unconfirmed marker (805) survived the sweep"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-DEDUP-361-028 unconfirmed marker (805) was correctly swept"
  PASS=$((PASS + 1))
fi
rm -rf "$TMPDIR/dispatch-marker-804-dev-new"

# TC-DEDUP-361-029: after release, an immediate re-acquire for the SAME
# (issue,mode) succeeds (rc 0) — proving the whole point of releasing early:
# the NEXT tick (or, here, an immediate retry) is not blocked for the TTL.
rm -rf "$TMPDIR/dispatch-marker-806-dev-new"
_DISPATCH_MARKER_PENDING=()
acquire_dispatch_marker 806 dev-new
release_dispatch_marker 806 dev-new
acquire_dispatch_marker 806 dev-new
assert_true "TC-DEDUP-361-029 re-acquire immediately after release succeeds (no ~10min false stall)" $?
release_dispatch_marker 806 dev-new

# TC-DEDUP-361-030 (behavioral, real code): extract the PTL branch's
# log-truncate-failure path VERBATIM from dispatcher-tick.sh (the exact
# codex-flagged branch) and run it for real, with _reset_session_log stubbed
# to fail. Assert the marker acquired at the top of the branch does NOT
# survive — this is the literal P1 scenario, executed against shipped code,
# not a reimplementation.
extract_ptl_failure_block() {
  awk '
    /if ! acquire_dispatch_marker "\$issue_num" "dev-new"; then/ { n++; if (n == 2) start = 1 }
    start { print }
    start && /^        continue$/ { c++; if (c == 2) { getline; print; exit } }
  ' "$TICK"
}
PTL_BLOCK=$(extract_ptl_failure_block)
if [[ -z "$PTL_BLOCK" ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-030 could not extract the PTL branch from dispatcher-tick.sh (source drifted?)"
  FAIL=$((FAIL + 1))
else
  rm -rf "$TMPDIR/dispatch-marker-807-dev-new"
  _DISPATCH_MARKER_PENDING=()
  (
    issue_num=807
    session_id="sid-807"
    log() { :; }
    itp_list_comments() { echo '[]'; }
    itp_post_comment() { :; }
    _reset_session_log() { return 1; }   # force the truncate-failure branch
    for _once in 1; do
      eval "$PTL_BLOCK"
    done
  ) 2>/dev/null
  if [[ -d "$TMPDIR/dispatch-marker-807-dev-new" ]]; then
    echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-030 marker survived a real (extracted) PTL log-truncate failure — the #361 review [P1] regression"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${NC}: TC-DEDUP-361-030 real PTL branch releases the marker on a log-truncate failure"
    PASS=$((PASS + 1))
  fi
  rm -rf "$TMPDIR/dispatch-marker-807-dev-new"
fi

# TC-DEDUP-361-031: source-of-truth — every acquire_dispatch_marker call site
# in dispatcher-tick.sh has a corresponding dispatch_marker_confirm_launched
# call site (same file), so a future call site cannot forget to confirm.
acquire_count=$(grep -c "acquire_dispatch_marker \"\$issue_num\"" "$TICK")
confirm_count=$(grep -c "dispatch_marker_confirm_launched \"\$issue_num\"" "$TICK")
assert_eq "TC-DEDUP-361-031 dispatcher-tick.sh: acquire_dispatch_marker and dispatch_marker_confirm_launched call counts match" \
  "$acquire_count" "$confirm_count"

# TC-DEDUP-361-031b (PR review follow-up): the SAME parity check for
# lib-dispatch.sh's own Branch C site (handle_completed_session_routing) —
# TC-031 only covers dispatcher-tick.sh, so a removed confirm call in
# lib-dispatch.sh would slip past it silently. Verified by mutation testing:
# deleting the dispatch_marker_confirm_launched call at Branch C left the
# full suite green before this check existed.
lib_acquire_count=$(grep -c "acquire_dispatch_marker \"\$issue_num\"" "$LIB")
lib_confirm_count=$(grep -c "dispatch_marker_confirm_launched \"\$issue_num\"" "$LIB")
assert_eq "TC-DEDUP-361-031b lib-dispatch.sh: acquire_dispatch_marker and dispatch_marker_confirm_launched call counts match" \
  "$lib_acquire_count" "$lib_confirm_count"

# TC-DEDUP-361-033 (PR review follow-up, behavioral, real code): the sibling
# of TC-030 for lib-dispatch.sh's OWN Branch C release-on-failure path.
# TC-030 only extracts and exercises the dispatcher-tick.sh PTL branch;
# Branch C's release_dispatch_marker call (handle_completed_session_routing,
# on _reset_session_log failure) had NO behavioral coverage — verified by
# mutation testing: deleting that release call left the full suite green.
# Extracts the real Branch C failure block verbatim (from the acquire guard
# through the failure-branch's `return 0`) and runs it against the REAL
# acquire_dispatch_marker/release_dispatch_marker with _reset_session_log
# stubbed to fail.
extract_branch_c_failure_block() {
  awk '
    /if ! acquire_dispatch_marker "\$issue_num" "dev-new"; then/ { start = 1 }
    start { print }
    start && /^        return 0$/ { c++; if (c == 2) { getline; print; exit } }
  ' "$LIB"
}
BRANCH_C_BLOCK=$(extract_branch_c_failure_block)
if [[ -z "$BRANCH_C_BLOCK" ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-033 could not extract Branch C's failure block from lib-dispatch.sh (source drifted?)"
  FAIL=$((FAIL + 1))
else
  rm -rf "$TMPDIR/dispatch-marker-808-dev-new"
  _DISPATCH_MARKER_PENDING=()
  (
    issue_num=808
    session_id="sid-808"
    log() { :; }
    itp_list_comments() { echo '[]'; }
    itp_post_comment() { :; }
    _reset_session_log() { return 1; }   # force the truncate-failure branch
    for _once in 1; do
      eval "$BRANCH_C_BLOCK"
    done
  ) 2>/dev/null
  if [[ -d "$TMPDIR/dispatch-marker-808-dev-new" ]]; then
    echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-033 marker survived a real (extracted) Branch C log-truncate failure"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${NC}: TC-DEDUP-361-033 real Branch C releases the marker on a log-truncate failure"
    PASS=$((PASS + 1))
  fi
  rm -rf "$TMPDIR/dispatch-marker-808-dev-new"
fi

# TC-DEDUP-361-035 (#361 round-12 [P1]): a NON-race stale-reclaim rename
# failure (parent dir read-only — the marker is still there, still stale,
# nobody raced us) must fail OPEN (rc 0, WARN), not loop "held" forever.
# TC-035b control: a rename failure where the path was RE-CREATED FRESH by a
# concurrent winner stays rc 1 (that race is legitimate hold semantics).
_RO_PARENT="$TMPDIR/ro-reclaim-parent"
rm -rf "$_RO_PARENT"; mkdir -p "$_RO_PARENT/dispatch-marker-810-dev-new"
# backdate the stale marker beyond TTL
touch -d '2020-01-01' "$_RO_PARENT/dispatch-marker-810-dev-new" 2>/dev/null || touch -t 202001010000 "$_RO_PARENT/dispatch-marker-810-dev-new"
chmod 0555 "$_RO_PARENT"
if rmdir "$_RO_PARENT/dispatch-marker-810-dev-new" 2>/dev/null; then
  mkdir -p "$_RO_PARENT/dispatch-marker-810-dev-new"  # restore; perms not enforced (root)
  echo "  SKIP: TC-DEDUP-361-035 cannot simulate read-only parent (perms not enforced here)"
else
  (
    pid_dir_for_project() { echo "$_RO_PARENT"; }
    acquire_dispatch_marker 810 dev-new 2>/dev/null
  )
  assert_true "TC-DEDUP-361-035 non-race stale-reclaim rename failure fails OPEN (rc 0)" $?
  (
    pid_dir_for_project() { echo "$_RO_PARENT"; }
    acquire_dispatch_marker 810 dev-new 2>&1 | grep -q 'stale-marker reclaim rename failed'
  )
  assert_true "TC-DEDUP-361-035c the reclaim fail-open emits its WARN" $?
fi
chmod 0755 "$_RO_PARENT" 2>/dev/null; rm -rf "$_RO_PARENT"

# TC-DEDUP-361-035b: rename-race control — mv fails because a concurrent
# winner already renamed-and-recreated a FRESH marker at the path. Simulated
# by overriding _mtime_epoch's second read to report FRESH (the marker at the
# path post-mv-failure is the winner's new one). Expected: rc 1 (held).
rm -rf "$TMPDIR/dispatch-marker-811-dev-new"
mkdir "$TMPDIR/dispatch-marker-811-dev-new"
_MT_COUNTER="$TMPDIR/mt-calls-811"
: > "$_MT_COUNTER"
(
  # _mtime_epoch is invoked via $(...) — in-memory counters don't propagate
  # out of command substitution, so count calls through a FILE.
  _mtime_epoch() {
    echo x >> "$_MT_COUNTER"
    if [ "$(wc -l < "$_MT_COUNTER")" -le 1 ]; then echo 1000000000; else date -u +%s; fi  # stale 1st read, fresh 2nd
  }
  mv() { return 1; }   # rename always loses
  acquire_dispatch_marker 811 dev-new 2>/dev/null
)
assert_false "TC-DEDUP-361-035b rename-race with a FRESH recreated marker stays held (rc 1)" $?
rm -rf "$TMPDIR/dispatch-marker-811-dev-new"

# TC-DEDUP-361-037 (#361 round-13 [P1]): DISPATCH_GRACE_PERIOD_SECONDS=0 (the
# documented "disable cold-start grace" setting) must NOT cascade into a 0s
# marker TTL — with ttl=0 a fresh marker is instantly stale and a second
# overlapping acquire immediately reclaims it (dup dispatch reopened).
rm -rf "$TMPDIR/dispatch-marker-814-dev-new"
(
  DISPATCH_GRACE_PERIOD_SECONDS=0
  unset DISPATCH_MARKER_TTL_SECONDS
  acquire_dispatch_marker 814 dev-new >/dev/null 2>&1
  acquire_dispatch_marker 814 dev-new 2>/dev/null
)
assert_false "TC-DEDUP-361-037 GRACE=0 does not zero the marker TTL — second acquire still held (rc 1)" $?
rm -rf "$TMPDIR/dispatch-marker-814-dev-new"

# TC-DEDUP-361-037b: an EXPLICIT DISPATCH_MARKER_TTL_SECONDS=0 is clamped to
# the default too (a 0s dedup window is never a coherent request).
rm -rf "$TMPDIR/dispatch-marker-815-dev-new"
(
  DISPATCH_MARKER_TTL_SECONDS=0
  acquire_dispatch_marker 815 dev-new >/dev/null 2>&1
  acquire_dispatch_marker 815 dev-new 2>/dev/null
)
assert_false "TC-DEDUP-361-037b explicit TTL=0 clamps to default — second acquire held (rc 1)" $?
rm -rf "$TMPDIR/dispatch-marker-815-dev-new"

# TC-DEDUP-361-037c (round-13 local review [P2]): a HUGE TTL (would make the
# marker effectively permanent, violating R3) clamps to the default — a
# backdated-stale marker is still reclaimable.
rm -rf "$TMPDIR/dispatch-marker-816-dev-new"
(
  DISPATCH_MARKER_TTL_SECONDS=2147483647
  acquire_dispatch_marker 816 dev-new >/dev/null 2>&1
  touch -t 200001010000.00 "$TMPDIR/dispatch-marker-816-dev-new"
  acquire_dispatch_marker 816 dev-new 2>/dev/null
)
assert_true "TC-DEDUP-361-037c huge TTL clamps to default — backdated marker still reclaimed (rc 0)" $?
rm -rf "$TMPDIR/dispatch-marker-816-dev-new"

# TC-DEDUP-361-036 (round-12 local review [P2]): a marker that EXISTS but is
# UNSTATTABLE (stat broken — simulated by overriding _mtime_epoch to empty)
# must fail OPEN, not repeat rc-1 "held" deterministically forever.
rm -rf "$TMPDIR/dispatch-marker-812-dev-new"; mkdir "$TMPDIR/dispatch-marker-812-dev-new"
(
  _mtime_epoch() { echo ""; }
  acquire_dispatch_marker 812 dev-new 2>/dev/null
)
assert_true "TC-DEDUP-361-036 present-but-unstattable marker fails OPEN (rc 0)" $?
rm -rf "$TMPDIR/dispatch-marker-812-dev-new"

# TC-DEDUP-361-036b control: empty mtime because the path VANISHED (true
# TOCTOU) stays rc 1 — one-tick hold, next tick re-evaluates. Simulated by a
# marker that exists for the top-of-function checks but is deleted before
# the stat (a _mtime_epoch override that deletes then reports empty).
rm -rf "$TMPDIR/dispatch-marker-813-dev-new"; mkdir "$TMPDIR/dispatch-marker-813-dev-new"
(
  _mtime_epoch() { command rm -rf "$TMPDIR/dispatch-marker-813-dev-new"; echo ""; }
  acquire_dispatch_marker 813 dev-new 2>/dev/null
)
assert_false "TC-DEDUP-361-036b vanished-during-stat (true TOCTOU) stays held for one tick (rc 1)" $?
rm -rf "$TMPDIR/dispatch-marker-813-dev-new"

# TC-DEDUP-361-034 (#361 round-9 [P1] finding 1): the Branch C DELEGATED entry
# (`if handle_pending_dev_pr_exists ...`) runs the whole router with bash
# errexit SUPPRESSED (function called in an `if` condition). A dispatch()
# failure therefore does NOT abort — pre-fix, execution fell through to
# dispatch_marker_confirm_launched, dropping ownership while NO wrapper ran
# (marker stuck for full TTL) and posting a phantom per-HEAD attempt marker.
# Post-fix the explicit `if ! label_swap || ! post_dispatch_token ||
# ! dispatch` guard releases the marker and bails BEFORE confirm/marker-post.
# Source-of-truth + behavioral hybrid: extract the guarded block, run it with
# dispatch stubbed to FAIL under suppressed errexit, assert (a) the marker is
# gone (released), (b) no attempt marker was posted.
extract_branch_c_dispatch_block() {
  awk '
    /if ! acquire_dispatch_marker "\$issue_num" "dev-new"; then/ { start = 1 }
    start { print }
    start && /^      return 0$/ { exit }
  ' "$LIB"
}
BRANCH_C_FULL=$(extract_branch_c_dispatch_block)
if [[ -z "$BRANCH_C_FULL" ]] || ! grep -q '! dispatch dev-new' <<<"$BRANCH_C_FULL"; then
  echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-034 could not extract Branch C's guarded dispatch block (source drifted, or the round-9 explicit guard is missing)"
  FAIL=$((FAIL + 1))
else
  rm -rf "$TMPDIR/dispatch-marker-809-dev-new"
  _DISPATCH_MARKER_PENDING=()
  _POSTED_LOG="$TMPDIR/posted-809.log"
  : > "$_POSTED_LOG"
  _tc034_runner() {   # function wrapper so `if _tc034_runner` suppresses errexit — the delegated-entry shape
    local issue_num=809 session_id="sid-809" _np_current_head="deadbeef809"
    log() { :; }
    itp_list_comments() { echo '[]'; }
    itp_post_comment() { echo "$2" >> "$_POSTED_LOG"; }
    _reset_session_log() { return 0; }
    label_swap() { return 0; }
    post_dispatch_token() { return 0; }
    dispatch() { return 1; }             # the round-9 scenario: spawn fails
    eval "$BRANCH_C_FULL"
  }
  set -e
  if _tc034_runner; then :; fi
  set +e
  _tc034_ok=1
  if [[ -d "$TMPDIR/dispatch-marker-809-dev-new" ]]; then
    echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-034 marker survived a failed dispatch on the delegated (errexit-suppressed) route"
    FAIL=$((FAIL + 1)); _tc034_ok=0
  fi
  if grep -q 'no-progress-substantive-attempt' "$_POSTED_LOG"; then
    echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-034 phantom per-HEAD attempt marker posted despite failed dispatch"
    FAIL=$((FAIL + 1)); _tc034_ok=0
  fi
  if [[ "$_tc034_ok" == 1 ]]; then
    echo -e "  ${GREEN}PASS${NC}: TC-DEDUP-361-034 delegated-route dispatch failure releases the marker and posts no attempt marker"
    PASS=$((PASS + 1))
  fi
  rm -rf "$TMPDIR/dispatch-marker-809-dev-new"
fi

# TC-DEDUP-361-038 (#361 round-14 [P1]): every held-marker skip in
# dispatcher-tick.sh must ALSO protect the concurrent winner from THIS tick's
# Step 5 stale detection (JUST_DISPATCHED append) — the winner may have
# label-swapped but not yet posted its token/PID, and without the append the
# losing tick's Step 5 could classify it as crashed and flip the issue back
# (next tick then double-dispatches in a DIFFERENT mode, which the
# per-(issue,mode) marker cannot catch). Source-of-truth: each of the 4 guard
# blocks carries the append between the held-marker log line and `continue`.
_guard_count=$(grep -c 'dispatch marker held by a concurrent tick — skipping' "$TICK")
_protected_count=$(awk '
  /dispatch marker held by a concurrent tick — skipping/ { inblock=1 }
  inblock && /JUST_DISPATCHED\+=/ { protected++; inblock=0 }
  inblock && /continue/ { inblock=0 }
  END { print protected+0 }
' "$TICK")
assert_eq "TC-DEDUP-361-038 all ${_guard_count} held-marker skips append JUST_DISPATCHED before continue" \
  "$_guard_count" "$_protected_count"

# TC-DEDUP-361-039 (round-14 local review NO-GO): may_stall_now must DEFER
# (rc 1) while a FRESH dispatch marker exists for the issue in ANY mode — the
# cold-start window where the winner's wrapper hasn't written its PID yet.
rm -rf "$TMPDIR/dispatch-marker-820-dev-new"
mkdir "$TMPDIR/dispatch-marker-820-dev-new"     # fresh marker (mtime = now)
(
  pid_alive() { return 1; }                      # probe says DEAD (no PID yet)
  get_pid() { echo ""; }
  may_stall_now 820 2>/dev/null
)
assert_false "TC-DEDUP-361-039 fresh dispatch marker defers may_stall_now (rc 1) despite DEAD pid probe" $?

# TC-DEDUP-361-039b control: an EXPIRED marker does not defer — stall
# eligibility is restored once the TTL passes (never wedges stalling).
touch -t 200001010000.00 "$TMPDIR/dispatch-marker-820-dev-new"
(
  pid_alive() { return 1; }
  get_pid() { echo ""; }
  may_stall_now 820 2>/dev/null
)
assert_true "TC-DEDUP-361-039b expired marker does not defer — stall eligible again (rc 0)" $?
rm -rf "$TMPDIR/dispatch-marker-820-dev-new"

# TC-DEDUP-361-032: source-of-truth — dispatcher-tick.sh installs the
# EXIT-trap handler (the backstop for any bare-command set -e abort between
# acquire and confirm that an explicit release call cannot reach).
if grep -qE '^trap _dispatch_marker_release_pending EXIT' "$TICK"; then
  echo -e "  ${GREEN}PASS${NC}: TC-DEDUP-361-032 dispatcher-tick.sh installs the _dispatch_marker_release_pending EXIT trap"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-DEDUP-361-032 dispatcher-tick.sh is missing the EXIT trap — a set -e abort between acquire and confirm would leak the marker for the full TTL"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
