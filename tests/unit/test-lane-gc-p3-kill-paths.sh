#!/bin/bash
# test-lane-gc-p3-kill-paths.sh — Unit tests for issue #379 (Lane-GC series
# PR-3, design docs/designs/lane-containment-gc.md §4-C4; INV-111/INV-112).
#
# Covers:
#   - lib-lane.sh: _kill_group_escalate (shared TERM->grace->KILL primitive),
#     lane_kill refactored onto it, lane_reap (the cleanup()-facing reap-first
#     helper), _bounded_call (60s wall-clock bound on teardown network calls).
#   - lib-agent.sh: _agent_sigterm_handler / install_agent_sigterm_trap
#     iterating registry pgids (fixes the review-side dead arm where
#     _AGENT_RUN_PID is empty in the main shell) + the ordering pin
#     (pkill -P $$ before backgrounding escalators).
#   - dispatch-local.sh: _pid_or_group_alive (leader-OR-group liveness) and
#     kill_stale_wrapper's escalation gate at both call sites.
#   - autonomous-dev.sh / autonomous-review.sh: cleanup() reap-first ordering
#     + _teardown_call bounding every network-work call site.
#   - grep-pins: TERM precedes KILL at every kill site; no pkill -f widening.
#
# Full scenario list: docs/test-cases/lane-gc-p3-kill-paths.md (TC-LGC3-*).
#
# Run: bash tests/unit/test-lane-gc-p3-kill-paths.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
LIB_LANE="$SCRIPTS/lib-lane.sh"
LIB_AGENT="$SCRIPTS/lib-agent.sh"
LIB_CONFIG="$SCRIPTS/lib-config.sh"
DISPATCH_LOCAL="$SCRIPTS/dispatch-local.sh"
DEV_WRAPPER="$SCRIPTS/autonomous-dev.sh"
REVIEW_WRAPPER="$SCRIPTS/autonomous-review.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert_pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
assert_fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then assert_pass "$desc"; else assert_fail "$desc (expected [$expected] got [$actual])"; fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then assert_pass "$desc"; else assert_fail "$desc (needle='$needle' not found)"; fi
}

for f in "$LIB_LANE" "$LIB_AGENT" "$DISPATCH_LOCAL" "$DEV_WRAPPER" "$REVIEW_WRAPPER"; do
  [[ -f "$f" ]] || { echo -e "${RED}FATAL${NC}: $f not found"; exit 1; }
done

TMPROOT=$(mktemp -d)
trap 'pkill -f "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT

# ===========================================================================
echo ""
echo "=== TC-LGC3-001/002/003: _kill_group_escalate ==="
# ===========================================================================
OUT001=$(bash -c '
  source "'"$LIB_LANE"'"
  setsid sleep 30 & PG=$!
  START=$SECONDS
  _kill_group_escalate "$PG" 5
  END=$SECONDS
  kill -0 -- "-$PG" 2>/dev/null && echo "ALIVE" || echo "GONE:$((END-START))"
' 2>&1)
if [[ "$OUT001" == GONE:* ]]; then
  ELAPSED="${OUT001#GONE:}"
  assert_pass "TC-LGC3-001: _kill_group_escalate TERM-reaps a live cooperative group"
  if [[ "$ELAPSED" -le 2 ]]; then
    assert_pass "TC-LGC3-001b: cooperative reap does not wait out the grace window"
  else
    assert_fail "TC-LGC3-001b: took ${ELAPSED}s — expected a fast TERM-reap, not a full grace wait"
  fi
else
  assert_fail "TC-LGC3-001: group survived _kill_group_escalate ($OUT001)"
fi

OUT002=$(bash -c '
  source "'"$LIB_LANE"'"
  setsid bash -c "trap \"\" TERM; sleep 30" & PG=$!
  disown 2>/dev/null || true
  sleep 0.2
  START=$SECONDS
  _kill_group_escalate "$PG" 2
  END=$SECONDS
  # Small settle: SIGKILL was just sent — give the kernel a moment to reap
  # before the liveness check, else kill -0 can transiently still see it.
  sleep 0.3
  kill -0 -- "-$PG" 2>/dev/null && echo "ALIVE" || echo "GONE:$((END-START))"
' 2>/dev/null)
if [[ "$OUT002" == GONE:* ]]; then
  ELAPSED="${OUT002#GONE:}"
  assert_pass "TC-LGC3-002: _kill_group_escalate escalates to KILL against a TERM-resistant group"
  if [[ "$ELAPSED" -ge 2 ]]; then
    assert_pass "TC-LGC3-002b: escalation respects the grace window (did not KILL early)"
  else
    assert_fail "TC-LGC3-002b: escalated in ${ELAPSED}s — grace window was not honored"
  fi
else
  assert_fail "TC-LGC3-002: TERM-resistant group survived escalation ($OUT002)"
fi

OUT003=$(bash -c '
  source "'"$LIB_LANE"'"
  setsid sleep 0.1 & PG=$!
  wait "$PG" 2>/dev/null
  START=$SECONDS
  _kill_group_escalate "$PG" 10
  END=$SECONDS
  echo "rc=$? elapsed=$((END-START))"
' 2>&1)
assert_contains "TC-LGC3-003: _kill_group_escalate against an already-dead pgid returns fast" "rc=0" "$OUT003"
ELAPSED3=$(grep -oE 'elapsed=[0-9]+' <<<"$OUT003" | cut -d= -f2)
if [[ -n "$ELAPSED3" && "$ELAPSED3" -le 2 ]]; then
  assert_pass "TC-LGC3-003b: dead-pgid miss short-circuits instead of waiting out the 10s grace"
else
  assert_fail "TC-LGC3-003b: took ${ELAPSED3:-?}s — should short-circuit on an initial TERM miss"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC3-004: lane_kill refactor preserves multi-pgid concurrent reap ==="
# ===========================================================================
OUT004=$(bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state004"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint myproj review 4)
  LANE_DIR=$(lane_install myproj "$LANE_ID")
  setsid sleep 30 & PG1=$!
  disown 2>/dev/null || true
  setsid bash -c "trap \"\" TERM; sleep 30" & PG2=$!
  disown 2>/dev/null || true
  sleep 0.2
  lane_record_pgid "$LANE_DIR" "$PG1" agent
  lane_record_pgid "$LANE_DIR" "$PG2" agent
  START=$SECONDS
  lane_kill "$LANE_DIR" 3
  END=$SECONDS
  # Small settle: the KILL escalation may have just fired — give the kernel
  # a moment to reap before the liveness check (same rationale as TC-LGC3-002).
  sleep 0.3
  A=$(kill -0 -- "-$PG1" 2>/dev/null && echo alive || echo gone)
  B=$(kill -0 -- "-$PG2" 2>/dev/null && echo alive || echo gone)
  echo "A=$A B=$B elapsed=$((END-START))"
' 2>/dev/null)
assert_contains "TC-LGC3-004: lane_kill reaps the cooperative group" "A=gone" "$OUT004"
assert_contains "TC-LGC3-004b: lane_kill escalates the TERM-resistant group too" "B=gone" "$OUT004"
ELAPSED4=$(grep -oE 'elapsed=[0-9]+' <<<"$OUT004" | cut -d= -f2)
if [[ -n "$ELAPSED4" && "$ELAPSED4" -le 6 ]]; then
  assert_pass "TC-LGC3-004c: concurrent escalation — wall-clock stays ~grace, not grace*2"
else
  assert_fail "TC-LGC3-004c: took ${ELAPSED4:-?}s — escalation should run concurrently, not serially"
fi

# TC-LGC3-005 — lane_kill escalator survives a group-SIGKILL against its
# CALLER's pgid (review round-8 [P1], the lane_kill instance of the same
# escalator-isolation class the sigterm-trap fix covers): reproduce the
# reported scenario — lane_kill running in one setsid shell, the caller's
# whole group SIGKILLed 1s in (mid-grace) — and require the TERM-resistant
# recorded pgid to STILL be KILLed once the grace elapses. Pre-fix (bare
# `_kill_group_escalate … &`), the escalator died with the caller's group
# and the target survived indefinitely.
OUT005=$(bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state005"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint myproj review 5)
  LANE_DIR=$(lane_install myproj "$LANE_ID")
  setsid bash -c "trap \"\" TERM; sleep 30" & PG=$!
  disown 2>/dev/null || true
  sleep 0.2
  lane_record_pgid "$LANE_DIR" "$PG" agent
  # The caller: its own setsid group runs lane_kill with a 4s grace…
  # (\$1/\$2 escape the MIDDLE shell so the INNER bash expands its own args)
  setsid bash -c "source \$1; lane_kill \$2 4" _ "'"$LIB_LANE"'" "$LANE_DIR" & CALLER=$!
  sleep 1
  # …and gets group-SIGKILLed mid-grace (the kill_stale_wrapper shape).
  kill -9 -- "-$CALLER" 2>/dev/null
  # Wait out the remaining grace + settle; the isolated escalator must
  # still deliver the follow-up KILL to the TERM-resistant target.
  sleep 5
  kill -0 -- "-$PG" 2>/dev/null && echo "VERDICT:TARGET-ALIVE" || echo "VERDICT:TARGET-GONE"
  kill -9 -- "-$PG" 2>/dev/null || true
' 2>/dev/null | grep '^VERDICT:')
assert_contains "TC-LGC3-005: lane_kill escalator survives a group-SIGKILL against its caller mid-grace and still KILLs the TERM-resistant target (pre-fix: target leaked)" "VERDICT:TARGET-GONE" "$OUT005"

# ===========================================================================
echo ""
echo "=== TC-LGC3-010/011: wrapper TERM trap iterates registry pgids (review-side dead-arm fix) ==="
# ===========================================================================
OUT010=$(bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state010"
  source "'"$LIB_LANE"'"
  source "'"$LIB_CONFIG"'" 2>/dev/null || true
  source "'"$LIB_AGENT"'"
  LANE_ID=$(lane_mint myproj dev 10)
  ADT_LANE_DIR=$(lane_install myproj "$LANE_ID")
  export ADT_LANE_DIR

  # _AGENT_RUN_PID-tracked group (dev-side shape).
  setsid sleep 30 & _AGENT_RUN_PID=$!
  lane_record_pgid "$ADT_LANE_DIR" "$_AGENT_RUN_PID" agent

  # Registry-only group with NO _AGENT_RUN_PID tracking, TERM-resistant
  # (the review-side fan-out-member shape this fix targets).
  setsid bash -c "trap \"\" TERM; sleep 30" & PG2=$!
  sleep 0.2
  lane_record_pgid "$ADT_LANE_DIR" "$PG2" "fanout:codex"

  RECEIVED_SIGTERM=0
  install_agent_sigterm_trap
  kill -TERM $$
  sleep 7
  A=$(kill -0 -- "-$_AGENT_RUN_PID" 2>/dev/null && echo alive || echo gone)
  B=$(kill -0 -- "-$PG2" 2>/dev/null && echo alive || echo gone)
  echo "SIGTERM=$RECEIVED_SIGTERM A=$A B=$B"
' 2>&1)
assert_contains "TC-LGC3-010: TERM trap sets RECEIVED_SIGTERM" "SIGTERM=1" "$OUT010"
assert_contains "TC-LGC3-010b: _AGENT_RUN_PID-tracked group is reaped" "A=gone" "$OUT010"
assert_contains "TC-LGC3-011: registry-only (no _AGENT_RUN_PID) TERM-resistant group is STILL reaped within grace — the review-side dead-arm fix" "B=gone" "$OUT010"

OUT011=$(bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state011"
  source "'"$LIB_LANE"'"
  source "'"$LIB_CONFIG"'" 2>/dev/null || true
  source "'"$LIB_AGENT"'"
  LANE_ID=$(lane_mint myproj review 11)
  ADT_LANE_DIR=$(lane_install myproj "$LANE_ID")
  export ADT_LANE_DIR
  unset _AGENT_RUN_PID

  setsid bash -c "trap \"\" TERM; sleep 30" & PG=$!
  sleep 0.2
  lane_record_pgid "$ADT_LANE_DIR" "$PG" "fanout:agy"

  RECEIVED_SIGTERM=0
  install_agent_sigterm_trap
  kill -TERM $$
  sleep 7
  kill -0 -- "-$PG" 2>/dev/null && echo "ALIVE" || echo "GONE"
' 2>&1)
assert_contains "TC-LGC3-011b: with _AGENT_RUN_PID entirely UNSET (exact review-wrapper main-shell condition), the registry pgid is still reached purely via the pgids-file read" "GONE" "$OUT011"

# ===========================================================================
echo ""
echo "=== TC-LGC3-012: ordering pin — pkill -P \$\$ precedes escalator backgrounding ==="
# ===========================================================================
HANDLER_SRC=$(awk '/^_agent_sigterm_handler\(\) \{$/,/^}$/' "$LIB_AGENT")
PKILL_LINE=$(grep -n 'pkill -TERM -P \$\$' <<<"$HANDLER_SRC" | head -1 | cut -d: -f1)
# The escalator is backgrounded inside a setsid-isolated `bash -c` (round-5
# [P1]: an unisolated escalator shares the wrapper's pgid and a group-form
# SIGKILL aimed there collaterally kills it mid-grace) — pin on the
# single-quoted _kill_group_escalate body inside that isolation wrapper.
ESCALATE_LINE=$(grep -n "bash -c '_kill_group_escalate" <<<"$HANDLER_SRC" | head -1 | cut -d: -f1)
if [[ -n "$PKILL_LINE" && -n "$ESCALATE_LINE" && "$PKILL_LINE" -lt "$ESCALATE_LINE" ]]; then
  assert_pass "TC-LGC3-012: source-of-truth — pkill -P \$\$ (line $PKILL_LINE) precedes the escalator backgrounding loop (line $ESCALATE_LINE)"
else
  assert_fail "TC-LGC3-012: pkill -P \$\$ (line ${PKILL_LINE:-MISSING}) does NOT precede escalator backgrounding (line ${ESCALATE_LINE:-MISSING}) — this is the exact bug that silently aborts KILL follow-through"
fi

# Behavioral regression proof: even with a TERM-resistant registry pgid AND
# a same-named direct child (pre-spawn-race fallback target), the trap must
# still reap the registry pgid within grace — this is precisely what breaks
# if pkill -P $$ runs AFTER backgrounding (it kills the backgrounded
# escalator subshell mid-grace-wait).
OUT012=$(bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state012"
  source "'"$LIB_LANE"'"
  source "'"$LIB_CONFIG"'" 2>/dev/null || true
  source "'"$LIB_AGENT"'"
  LANE_ID=$(lane_mint myproj dev 12)
  ADT_LANE_DIR=$(lane_install myproj "$LANE_ID")
  export ADT_LANE_DIR
  unset _AGENT_RUN_PID

  setsid bash -c "trap \"\" TERM; sleep 30" & PG=$!
  sleep 0.2
  lane_record_pgid "$ADT_LANE_DIR" "$PG" agent

  RECEIVED_SIGTERM=0
  install_agent_sigterm_trap
  kill -TERM $$
  sleep 7
  kill -0 -- "-$PG" 2>/dev/null && echo "ALIVE" || echo "GONE"
' 2>&1)
assert_contains "TC-LGC3-012b: behavioral proof — TERM-resistant registry pgid is KILLed within grace despite the pre-spawn-race pkill fallback running in the same trap" "GONE" "$OUT012"

# ===========================================================================
echo ""
echo "=== TC-LGC3-013: degrade path when _kill_group_escalate is unavailable ==="
# ===========================================================================
OUT013=$(bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state013"
  # Deliberately do NOT source lib-lane.sh — _kill_group_escalate stays undefined.
  source "'"$LIB_CONFIG"'" 2>/dev/null || true
  source "'"$LIB_AGENT"'"
  ADT_LANE_DIR="'"$TMPROOT"'/state013-lane"
  mkdir -p "$ADT_LANE_DIR"
  export ADT_LANE_DIR

  setsid sleep 30 & PG=$!
  echo "$PG agent 0" > "$ADT_LANE_DIR/pgids"

  declare -F _kill_group_escalate >/dev/null 2>&1 && echo "HELPER-PRESENT" && exit 1

  RECEIVED_SIGTERM=0
  install_agent_sigterm_trap
  kill -TERM $$
  sleep 7
  kill -0 -- "-$PG" 2>/dev/null && echo "ALIVE" || echo "GONE"
' 2>&1)
assert_contains "TC-LGC3-013: degrade path (no lib-lane.sh) still reaps the registry pgid via the inline TERM+KILL fallback" "GONE" "$OUT013"

# ===========================================================================
echo ""
echo "=== TC-LGC3-020/021/022: _pid_or_group_alive ==="
# ===========================================================================
# dispatch-local.sh is an entry-point script (set -euo pipefail + positional
# arg validation at the top) — it cannot be sourced directly without argv, so
# extract just the helper function, same technique the other dispatch-local.sh
# test files (test-kill-before-spawn.sh etc.) already use.
PGA_SLICE=$(mktemp)
awk '/^_pid_or_group_alive\(\) \{$/,/^}$/' "$DISPATCH_LOCAL" > "$PGA_SLICE"

OUT020=$(bash -c '
  source "'"$PGA_SLICE"'"
  sleep 30 & P=$!
  _pid_or_group_alive "$P" && echo "TRUE" || echo "FALSE"
  kill -9 "$P" 2>/dev/null
' 2>&1 | tail -1)
assert_eq "TC-LGC3-020: leader alive -> _pid_or_group_alive true" "TRUE" "$OUT020"

OUT021=$(bash -c '
  source "'"$PGA_SLICE"'"
  # To simulate "leader dead, member alive" we need a genuine multi-process
  # group: spawn a leader shell that backgrounds a sleep into the SAME group
  # (via setsid) and then execs into that same sleep, then kill the ORIGINAL
  # backgrounded child (which is now the leader per setsid, PID==PGID) while
  # its sibling group member survives.
  setsid bash -c "sleep 30 & CHILD=\$!; echo \$CHILD > '"$TMPROOT"'/child021.pid; wait \$CHILD" & LEADER=$!
  sleep 0.4
  CHILD=$(cat "'"$TMPROOT"'/child021.pid" 2>/dev/null)
  kill -9 "$LEADER" 2>/dev/null
  sleep 0.3
  # LEADER itself is now dead; but its pgid (== LEADER, since setsid) still
  # has a live member (CHILD, which shares the same pgid).
  _pid_or_group_alive "$LEADER" && echo "TRUE" || echo "FALSE"
  kill -9 "$CHILD" 2>/dev/null
' 2>&1 | tail -1)
assert_eq "TC-LGC3-021: leader dead but a group member alive -> _pid_or_group_alive true (the exact case the leader-only gate missed)" "TRUE" "$OUT021"

OUT022=$(bash -c '
  source "'"$PGA_SLICE"'"
  sleep 0.1 & P=$!
  wait "$P" 2>/dev/null
  _pid_or_group_alive "$P" && echo "TRUE" || echo "FALSE"
' 2>&1 | tail -1)
assert_eq "TC-LGC3-022: neither leader nor group alive -> _pid_or_group_alive false" "FALSE" "$OUT022"
rm -f "$PGA_SLICE"

# ===========================================================================
echo ""
echo "=== TC-LGC3-023/024: kill_stale_wrapper leader-OR-group escalation gate ==="
# ===========================================================================
KSW_SLICE=$(mktemp)
awk '
  /^(_pid_or_group_alive|kill_stale_wrapper)\(\) \{$/ { in_fn=1 }
  in_fn { print }
  in_fn && /^\}$/ { in_fn=0 }
' "$DISPATCH_LOCAL" > "$KSW_SLICE"

# Fixture shape (shared by 023a/023): a leader that dies on plain TERM
# (`exec sleep 30`) plus a PERSISTENT TERM-trapping member in the SAME pgid.
# The member must be a `while` loop that re-spawns its own sleep — a bare
# `trap "" TERM &` child installs the trap and exits immediately (its body
# is empty), leaving nothing behind for the gate to miss; and a
# `(trap ""; sleep 30)` subshell survives the TERM itself but exits the
# moment its (untrapped, group-signalled) sleep child dies. Only the
# respawning loop actually OUTLIVES the group TERM.
KSW_FIXTURE='setsid bash -c "(trap \"\" TERM; while :; do sleep 1; done) & disown; exec sleep 30" & LEADER=$!'

# TC-LGC3-023a — fixture self-validation (review-caught: the prior fixture
# never reproduced the scenario, so 023 passed even against the OLD
# leader-only gate). Prove that a PLAIN group TERM — what the pre-fix code
# effectively ended at, since its leader-only `kill -0` gate saw the leader
# dead and skipped SIGKILL — leaves the trapping member running. This is
# the failing-precondition proof that makes TC-LGC3-023 a real regression
# gate rather than a vacuous pass.
OUT023A=$(bash -c '
  '"$KSW_FIXTURE"'
  sleep 0.5
  kill -TERM -- "-$LEADER" 2>/dev/null
  sleep 1
  if kill -0 "$LEADER" 2>/dev/null; then echo "LEADER-STILL-ALIVE"
  elif kill -0 -- "-$LEADER" 2>/dev/null; then echo "LEADER-DEAD-MEMBER-ALIVE"
  else echo "GROUP-GONE"
  fi
  kill -KILL -- "-$LEADER" 2>/dev/null || true
' 2>&1 | tail -1)
assert_contains "TC-LGC3-023a (fixture proof): a plain group TERM kills the leader but the trapping member survives — the exact shape the old leader-only gate leaked" "LEADER-DEAD-MEMBER-ALIVE" "$OUT023A"

OUT023=$(bash -c '
  set -uo pipefail
  ISSUE_NUM="test023"
  KILL_STALE_PGREP_FALLBACK=false
  source "'"$KSW_SLICE"'"
  '"$KSW_FIXTURE"'
  sleep 0.5
  echo "$LEADER" > "'"$TMPROOT"'/ksw023.pid"
  kill_stale_wrapper "'"$TMPROOT"'/ksw023.pid"
  sleep 0.3
  kill -0 -- "-$LEADER" 2>/dev/null && echo "GROUP-ALIVE" || echo "GROUP-GONE"
' 2>&1 | tail -1)
assert_contains "TC-LGC3-023: kill_stale_wrapper (PID-file path) reaps the full process group even when the leader alone would have looked dead post-TERM" "GROUP-GONE" "$OUT023"

# TC-LGC3-024 — the leader-dies/member-survives shape through the
# pgrep-FALLBACK orphan sweep (no PID file at all), in the PRODUCTION spawn
# shape (codex review round-3 [P1]): the wrapper is launched via `nohup … &`
# so it is NOT a process-group leader (it inherits the spawning shell's
# pgid), and its TERM-trapping child lives in its OWN setsid group whose
# cmdline the pgrep pattern never matches. The old sweep's `kill -- -${op}`
# was ESRCH (no group numbered op exists) → leader-only TERM → the setsid
# child never received any KILL pass. The fixed sweep walks the descendant
# tree at scan time, collects every REAL pgid, and TERM→KILLs that set.
# PROJECT_DIR is a per-run temp dir, so the pgrep project anchor can never
# match a real wrapper on this host.
PROJ024="$TMPROOT/proj024"
mkdir -p "$PROJ024/scripts"
cat > "$PROJ024/scripts/autonomous-dev.sh" <<'FIXTURE024'
#!/bin/bash
setsid bash -c 'trap "" TERM; while :; do sleep 1; done' &
echo "$!" > "${CHILD_PID_FILE:?}"
sleep 30
FIXTURE024
chmod +x "$PROJ024/scripts/autonomous-dev.sh"

OUT024=$(bash -c '
  set -uo pipefail
  ISSUE_NUM="240379"
  TYPE="dev-new"
  PROJECT_ID="test024"
  PROJECT_DIR="'"$PROJ024"'"
  KILL_STALE_PGREP_FALLBACK=true
  source "'"$KSW_SLICE"'"
  export CHILD_PID_FILE="'"$TMPROOT"'/tc024-child.pid"
  rm -f "$CHILD_PID_FILE"
  nohup bash "'"$PROJ024"'/scripts/autonomous-dev.sh" --issue 240379 >/dev/null 2>&1 & WRAPPER=$!
  for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [[ -s "$CHILD_PID_FILE" ]] && break; sleep 0.1
  done
  CHILD=$(cat "$CHILD_PID_FILE" 2>/dev/null || true)
  # No PID file — the fallback sweep is the only path that can find this tree.
  kill_stale_wrapper "'"$TMPROOT"'/ksw024-nonexistent.pid"
  sleep 0.3
  WRAPPER_ALIVE=no; CHILD_ALIVE=no
  kill -0 "$WRAPPER" 2>/dev/null && WRAPPER_ALIVE=yes
  [[ -n "$CHILD" ]] && kill -0 "$CHILD" 2>/dev/null && CHILD_ALIVE=yes
  echo "VERDICT:wrapper=$WRAPPER_ALIVE child=$CHILD_ALIVE"
  [[ -n "$CHILD" ]] && kill -9 -- "-$CHILD" 2>/dev/null
  kill -9 "$WRAPPER" 2>/dev/null || true
' 2>&1 | grep '^VERDICT:')
assert_contains "TC-LGC3-024: pgrep-fallback sweep reaps a nohup-launched (non-leader) wrapper AND its TERM-trapping setsid child (descendant-walk pgid set)" "VERDICT:wrapper=no child=no" "$OUT024"

# TC-LGC3-024b — codex review round-4 [P1] regression: a descendant spawned
# WITHOUT its own `setsid` shares dispatch-local.sh's OWN pgid at spawn time
# (the normal shape when the dispatcher's own session has no setsid boundary
# between it and the `nohup`-launched wrapper). The round-3 fix's self-guard
# excludes our own pgid from every GROUP-form kill (so the sweep never
# suicides its own group) — but round-3 only ever sent GROUP-form signals,
# so a same-pgid descendant was silently dropped entirely: reproduced
# against the round-3 code with a nohup-launched wrapper backgrounding a
# bare (non-setsid) TERM-trapping child — the wrapper died, the child
# survived (`wrapper=no child=yes`). The round-4 fix adds an INDIVIDUAL-PID
# kill pass over every walked pid (not just the top-level pgrep matches),
# which reaches a same-pgid descendant without ever group-signalling our
# own pgid.
cat > "$PROJ024/scripts/autonomous-dev.sh" <<'FIXTURE024B'
#!/bin/bash
bash -c 'trap "" TERM; while :; do sleep 1; done' &
echo "$!" > "${CHILD_PID_FILE:?}"
sleep 30
FIXTURE024B
chmod +x "$PROJ024/scripts/autonomous-dev.sh"

OUT024B=$(bash -c '
  set -uo pipefail
  ISSUE_NUM="240380"
  TYPE="dev-new"
  PROJECT_ID="test024b"
  PROJECT_DIR="'"$PROJ024"'"
  KILL_STALE_PGREP_FALLBACK=true
  source "'"$KSW_SLICE"'"
  export CHILD_PID_FILE="'"$TMPROOT"'/tc024b-child.pid"
  rm -f "$CHILD_PID_FILE"
  nohup bash "'"$PROJ024"'/scripts/autonomous-dev.sh" --issue 240380 >/dev/null 2>&1 & WRAPPER=$!
  for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [[ -s "$CHILD_PID_FILE" ]] && break; sleep 0.1
  done
  CHILD=$(cat "$CHILD_PID_FILE" 2>/dev/null || true)
  echo "SPAWN_PGIDS: self=$(ps -o pgid= -p $$ | tr -d " ") wrapper=$(ps -o pgid= -p "$WRAPPER" 2>/dev/null | tr -d " ") child=$(ps -o pgid= -p "$CHILD" 2>/dev/null | tr -d " ")" >&2
  kill_stale_wrapper "'"$TMPROOT"'/ksw024b-nonexistent.pid"
  sleep 0.3
  WRAPPER_ALIVE=no; CHILD_ALIVE=no
  kill -0 "$WRAPPER" 2>/dev/null && WRAPPER_ALIVE=yes
  [[ -n "$CHILD" ]] && kill -0 "$CHILD" 2>/dev/null && CHILD_ALIVE=yes
  echo "VERDICT:wrapper=$WRAPPER_ALIVE child=$CHILD_ALIVE"
  [[ -n "$CHILD" ]] && kill -9 "$CHILD" 2>/dev/null
  kill -9 "$WRAPPER" 2>/dev/null || true
' 2>&1 | grep '^VERDICT:')
assert_contains "TC-LGC3-024b (round-4 regression): pgrep-fallback sweep reaps a same-pgid (non-setsid) TERM-trapping descendant via individual-PID kill, not just group-form" "VERDICT:wrapper=no child=no" "$OUT024B"
rm -f "$KSW_SLICE"

# ===========================================================================
echo ""
echo "=== TC-LGC3-030/031: lane_reap + cleanup() ordering ==="
# ===========================================================================
OUT030=$(bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state030"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint myproj dev 30)
  LANE_DIR=$(lane_install myproj "$LANE_ID")
  setsid sleep 30 & PG=$!
  lane_record_pgid "$LANE_DIR" "$PG" agent
  echo "BEFORE:$(lane_get "$LANE_DIR" STATE)"
  lane_reap "$LANE_DIR" 3
  echo "AFTER:$(lane_get "$LANE_DIR" STATE)"
  sleep 0.3
  kill -0 -- "-$PG" 2>/dev/null && echo "PG:ALIVE" || echo "PG:GONE"
' 2>&1)
assert_contains "TC-LGC3-030: lane_reap starts from STATE=live" "BEFORE:live" "$OUT030"
assert_contains "TC-LGC3-030b: lane_reap ends at STATE=cleaning (caller's own lifecycle owns clean-exit)" "AFTER:cleaning" "$OUT030"
assert_contains "TC-LGC3-030c: lane_reap actually reaps the recorded pgid" "PG:GONE" "$OUT030"

OUT030d=$(bash -c '
  source "'"$LIB_LANE"'"
  lane_reap "'"$TMPROOT"'/nonexistent-lane-dir" 3
  echo "rc=$?"
' 2>&1)
assert_contains "TC-LGC3-030d: lane_reap against a missing lane dir is a clean no-op" "rc=0" "$OUT030d"

for f in "$DEV_WRAPPER" "$REVIEW_WRAPPER"; do
  name=$(basename "$f")
  REAP_LINE=$(grep -n 'lane_reap "\$ADT_LANE_DIR"' "$f" | head -1 | cut -d: -f1)
  PIDFILE_RM_LINE=$(grep -n 'rm -f "\$PID_FILE"' "$f" | head -1 | cut -d: -f1)
  if [[ -n "$REAP_LINE" && -n "$PIDFILE_RM_LINE" && "$REAP_LINE" -lt "$PIDFILE_RM_LINE" ]]; then
    assert_pass "TC-LGC3-031 ($name): cleanup()'s lane_reap call (line $REAP_LINE) precedes PID-file removal (line $PIDFILE_RM_LINE)"
  else
    assert_fail "TC-LGC3-031 ($name): lane_reap (line ${REAP_LINE:-MISSING}) does not precede PID-file removal (line ${PIDFILE_RM_LINE:-MISSING})"
  fi
  # Anchored on the actual CALL (line begins with the function name, or the
  # _teardown_call wrapper, modulo leading whitespace) — a bare substring
  # search would also match doc-comment mentions of these names earlier in
  # the file (e.g. "drain_agent_pr_create" appears in a comment near the top
  # explaining the PR-create broker), which are not cleanup()'s call sites.
  FIRST_NET_LINE=$(grep -nE '^\s*(_teardown_call )?(itp_post_comment|itp_transition_state|chp_pr_list|drain_agent_pr_create|drain_agent_bot_triggers|get_gh_app_token|emit_verdict_trailer)' "$f" | head -1 | cut -d: -f1)
  if [[ -n "$REAP_LINE" && -n "$FIRST_NET_LINE" && "$REAP_LINE" -lt "$FIRST_NET_LINE" ]]; then
    assert_pass "TC-LGC3-031b ($name): lane_reap precedes the first network-work call site (line $FIRST_NET_LINE)"
  else
    assert_fail "TC-LGC3-031b ($name): lane_reap does not precede the first network-work call site"
  fi
done

# ===========================================================================
echo ""
echo "=== TC-LGC3-032/033: _bounded_call ==="
# ===========================================================================
OUT032=$(bash -c '
  source "'"$LIB_LANE"'"
  fast_fn() { echo "stdout-line"; echo "stderr-line" >&2; return 7; }
  OUT=$(_bounded_call 5 fast_fn 2>&1)
  RC=$?
  echo "OUT=[$OUT] RC=$RC"
' 2>&1)
assert_contains "TC-LGC3-032: _bounded_call preserves a fast function's stdout" "stdout-line" "$OUT032"
assert_contains "TC-LGC3-032b: _bounded_call preserves a fast function's stderr" "stderr-line" "$OUT032"
assert_contains "TC-LGC3-032c: _bounded_call preserves a fast function's exit code" "RC=7" "$OUT032"

# Regression: stdout and stderr must stay on SEPARATE streams so a real
# call site's own `2>/dev/null` (e.g. `chp_pr_list … 2>/dev/null || echo 0`)
# still drops stderr, exactly as if the call had run inline unwrapped. An
# earlier draft merged both into one tmpfile, which silently defeated every
# caller's own stderr redirection and corrupted `$(...)`-captured values
# with a spurious extra line whenever the wrapped function logged anything
# to stderr before printing its real stdout payload.
OUT032D=$(bash -c '
  source "'"$LIB_LANE"'"
  noisy_fn() { echo "benign stderr diagnostic" >&2; echo "3"; }
  VAL=$(_bounded_call 5 noisy_fn 2>/dev/null || echo "0")
  echo "VAL=[$VAL]"
' 2>&1)
assert_contains "TC-LGC3-032d: caller's own 2>/dev/null on the _bounded_call invocation still drops the wrapped function's stderr (stdout/stderr stay on separate streams)" "VAL=[3]" "$OUT032D"

OUT033=$(bash -c '
  source "'"$LIB_LANE"'"
  hang_fn() { sleep 30; echo "never"; }
  START=$SECONDS
  OUT=$(_bounded_call 2 hang_fn 2>/dev/null)
  RC=$?
  END=$SECONDS
  echo "RC=$RC ELAPSED=$((END-START)) OUT=[$OUT]"
' 2>&1)
assert_contains "TC-LGC3-033: _bounded_call terminates a hanging function and returns 124" "RC=124" "$OUT033"
assert_contains "TC-LGC3-033b: hanging function never reaches its own echo" "OUT=[]" "$OUT033"
ELAPSED33=$(grep -oE 'ELAPSED=[0-9]+' <<<"$OUT033" | cut -d= -f2)
if [[ -n "$ELAPSED33" && "$ELAPSED33" -le 5 ]]; then
  assert_pass "TC-LGC3-033c: bound enforced close to the configured 2s (not the full 30s hang)"
else
  assert_fail "TC-LGC3-033c: took ${ELAPSED33:-?}s — bound was not enforced"
fi

# Regression: a wrapped function that itself forks a GRANDCHILD via command
# substitution (e.g. `out=$(curl ...)`, the exact shape of get_gh_app_token's
# HTTP calls) must not leak that grandchild past the timeout escalation. An
# earlier draft used a plain (non-group) kill on the direct child only,
# which never reaches a grandchild in a different process — that grandchild
# then survives indefinitely. Uses `exec -a` to give the grandchild a
# unique, greppable name (a bare `pgrep -f "sleep 20"` would false-match
# unrelated shell text containing that substring, e.g. this very test's own
# source code visible in `ps`).
OUT033D=$(bash -c '
  source "'"$LIB_LANE"'"
  fn_with_grandchild() {
    local out
    out=$(exec -a MARKER_TC_LGC3_033D_SLEEP sleep 20)
    echo "$out"
  }
  _bounded_call 2 fn_with_grandchild >/dev/null 2>&1
  sleep 0.5
  MATCH=$(pgrep -f "MARKER_TC_LGC3_033D_SLEEP\$" 2>/dev/null || true)
  if [[ -n "$MATCH" ]]; then
    kill -9 $MATCH 2>/dev/null || true
    echo "LEAKED:$MATCH"
  else
    echo "CLEAN"
  fi
' 2>&1)
assert_contains "TC-LGC3-033d: _bounded_call does not leak a grandchild forked via command substitution inside the wrapped function (setsid + group-kill on escalation)" "CLEAN" "$OUT033D"

# Regression: `wait`'s own exit status mirrors the waited-on child's — a
# bare `wait "$cpid"` (not `wait "$cpid" || rc=$?`) for a NON-ZERO-exiting
# wrapped call would abort the CALLING shell right there under `set -e`
# (every real _teardown_call site runs inside a `set -euo pipefail`
# wrapper), before the intended `return "$rc"` line ever executes. Calls
# `_bounded_call` BARE (no `||`/`if`/`$(...)` guard) so a regression here
# would abort this test's own subshell before it reaches its `echo`.
OUT033E=$(bash -c '
  set -euo pipefail
  source "'"$LIB_LANE"'"
  fn_nonzero() { echo "ran"; return 5; }
  _bounded_call 5 fn_nonzero
  echo "SCRIPT_RC=$?"
' 2>&1)
SCRIPT_EXIT033E=$?
assert_eq "TC-LGC3-033e: _bounded_call under set -e propagates the wrapped call's real exit code as its OWN return, rather than aborting the caller mid-wait" "5" "$SCRIPT_EXIT033E"
assert_contains "TC-LGC3-033e-out: wrapped function's stdout still reached the caller before the non-zero return" "ran" "$OUT033E"

# ===========================================================================
echo ""
echo "=== TC-LGC3-034: coreutils timeout cannot wrap a bash function directly ==="
# ===========================================================================
OUT034=$(bash -c '
  myfunc() { echo "should not print"; }
  timeout 2 myfunc 2>&1
  echo "rc=$?"
' 2>&1)
assert_contains "TC-LGC3-034: documents the design constraint — timeout <n> <bash-function> fails outright, justifying _bounded_call's background+poll approach" "rc=127" "$OUT034"

# ===========================================================================
echo ""
echo "=== TC-LGC3-035: cleanup() with a hung gh-shaped stub completes well under 90s ==="
# ===========================================================================
OUT035=$(bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state035"
  source "'"$LIB_LANE"'"
  # Reproduce cleanup()s own _teardown_call closure and drive it against
  # several hung network-call-shaped stubs, same as the wrapper would.
  _teardown_call() {
    if declare -F _bounded_call >/dev/null 2>&1; then
      _bounded_call 3 "$@"
    else
      "$@"
    fi
  }
  itp_post_comment() { sleep 30; }
  itp_transition_state() { sleep 30; }
  chp_pr_list() { sleep 30; }
  START=$SECONDS
  _teardown_call itp_post_comment "1" "body" 2>/dev/null
  _teardown_call itp_transition_state "1" "a" "b" 2>/dev/null
  _teardown_call chp_pr_list --state open 2>/dev/null
  END=$SECONDS
  echo "ELAPSED=$((END-START))"
' 2>&1)
ELAPSED35=$(grep -oE 'ELAPSED=[0-9]+' <<<"$OUT035" | cut -d= -f2)
if [[ -n "$ELAPSED35" && "$ELAPSED35" -le 90 ]]; then
  assert_pass "TC-LGC3-035: three hung network-call-shaped stubs bounded at 3s each complete in ${ELAPSED35}s, well under the 90s AC ceiling"
else
  assert_fail "TC-LGC3-035: took ${ELAPSED35:-?}s — exceeds the 90s AC ceiling"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC3-036: concurrent lane_kill/lane_reap serialize on reap.lock (no double-KILL) ==="
# ===========================================================================
OUT036=$(bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state036"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint myproj dev 36)
  LANE_DIR=$(lane_install myproj "$LANE_ID")
  # TERM-trapping fixture (review-caught: a plain `setsid sleep 30` always
  # dies on the first TERM, so KILL_CALLS is vacuously 0 regardless of
  # whether a double-KILL bug exists — the assertion below could never
  # fail). This group survives the TERM and forces BOTH racing lane_kill
  # calls to actually reach the escalation branch, so a double-KILL
  # regression (KILL_CALLS=2) is observable.
  setsid bash -c "trap \"\" TERM; while :; do sleep 1; done" & PG=$!
  lane_record_pgid "$LANE_DIR" "$PG" agent

  COUNTER_FILE="'"$TMPROOT"'/counter036"
  : > "$COUNTER_FILE"
  # Wrap kill -KILL to count invocations against this specific pgid — the
  # double-KILL race this test guards against would show up as this
  # counter incrementing more than once for the SAME pgid.
  kill() {
    if [[ "$1" == "-KILL" ]]; then
      echo "kill" >> "'"$TMPROOT"'/counter036"
    fi
    command kill "$@"
  }
  export -f kill

  lane_kill "$LANE_DIR" 2 &
  P1=$!
  lane_kill "$LANE_DIR" 2 &
  P2=$!
  wait "$P1" "$P2" 2>/dev/null
  echo "KILL_CALLS=$(wc -l < "$COUNTER_FILE")"
  kill -9 -- "-$PG" 2>/dev/null || true
' 2>&1)
# Both concurrent lane_kill calls target the same (single) pgid; the
# reap.lock should serialize them so the group is TERM-reaped by the first
# to acquire the lock and the second finds it already gone. The numeric
# count (not merely the string's presence) is the actual invariant: exactly
# ONE KILL against this pgid, never two (a double-KILL regression) or zero
# (an escalation that never fired against a TERM-resistant group).
assert_eq "TC-LGC3-036: concurrent lane_kill invocations issue exactly ONE SIGKILL against the shared pgid (no double-KILL)" "KILL_CALLS=1" "$(grep -o 'KILL_CALLS=[0-9]*' <<<"$OUT036")"

# ===========================================================================
echo ""
echo "=== TC-LGC3-037/038: review-side crash-path reap + idempotency ==="
# ===========================================================================
OUT037=$(bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state037"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint myproj review 37)
  LANE_DIR=$(lane_install myproj "$LANE_ID")
  # Simulate two fan-out members recorded by DIFFERENT subshells, as the
  # review wrapper would during a real fan-out.
  setsid sleep 30 & PG1=$!
  disown 2>/dev/null || true
  setsid bash -c "trap \"\" TERM; sleep 30" & PG2=$!
  disown 2>/dev/null || true
  sleep 0.2
  lane_record_pgid "$LANE_DIR" "$PG1" "fanout:q"
  lane_record_pgid "$LANE_DIR" "$PG2" "fanout:codex"
  # Simulate a SIGTERM-mid-fan-out crash: cleanup()s lane_reap runs BEFORE
  # any graceful _reap_fanout_processes call ever executes.
  lane_reap "$LANE_DIR" 3
  # Small settle: PG2s KILL escalation may have just fired.
  sleep 0.3
  A=$(kill -0 -- "-$PG1" 2>/dev/null && echo alive || echo gone)
  B=$(kill -0 -- "-$PG2" 2>/dev/null && echo alive || echo gone)
  echo "A=$A B=$B"
' 2>/dev/null)
assert_contains "TC-LGC3-037: cleanup()s lane_reap alone (no graceful fan-out reap ever ran) reaps every registry-recorded fan-out PGID" "A=gone" "$OUT037"
assert_contains "TC-LGC3-037b: including a TERM-resistant fan-out member" "B=gone" "$OUT037"

OUT038=$(bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state038"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint myproj review 38)
  LANE_DIR=$(lane_install myproj "$LANE_ID")
  setsid sleep 30 & PG=$!
  lane_record_pgid "$LANE_DIR" "$PG" "fanout:q"
  # Graceful path reaps it first (simulating _reap_fanout_processes already
  # having run in the main body).
  kill -TERM -- "-$PG" 2>/dev/null
  sleep 0.3
  # Now cleanup()s lane_reap runs against the SAME already-dead pgid.
  lane_reap "$LANE_DIR" 2
  echo "rc=$?"
' 2>&1)
assert_contains "TC-LGC3-038: lane_reap is idempotent against a pgid the graceful fan-out reap already killed — no error, no spurious re-kill" "rc=0" "$OUT038"

# ===========================================================================
echo ""
echo "=== TC-LGC3-041: grep-pin — TERM precedes KILL at every kill site ==="
# ===========================================================================
check_term_before_kill() {
  local file="$1" fn_name="$2" label="$3"
  local body
  # Pass the function name as an awk VARIABLE (-v), never interpolated into
  # the program text — the target names contain no regex metacharacters
  # that need escaping, but building an escaped literal through multiple
  # shell quoting layers is fragile (verified: an earlier draft double-
  # escaped incorrectly and silently extracted an empty body).
  body=$(awk -v fn="$fn_name" '$0 == fn"() {" {p=1} p {print} p && /^}$/ {p=0}' "$file")
  local term_line kill_line
  term_line=$(grep -n -m1 'kill -TERM' <<<"$body" | cut -d: -f1)
  kill_line=$(grep -n -m1 'kill -KILL\|kill -9\|kill -9\b' <<<"$body" | cut -d: -f1)
  if [[ -z "$term_line" ]]; then
    assert_fail "TC-LGC3-041 ($label): no TERM found — cannot verify ordering"
    return
  fi
  if [[ -z "$kill_line" ]]; then
    assert_pass "TC-LGC3-041 ($label): TERM present, no unconditional KILL line to compare (escalation delegated to a helper) — ordering enforced elsewhere"
    return
  fi
  if [[ "$term_line" -lt "$kill_line" ]]; then
    assert_pass "TC-LGC3-041 ($label): TERM (line $term_line) precedes KILL (line $kill_line)"
  else
    assert_fail "TC-LGC3-041 ($label): TERM (line $term_line) does NOT precede KILL (line $kill_line)"
  fi
}
check_term_before_kill "$LIB_LANE" "_kill_group_escalate" "lib-lane.sh::_kill_group_escalate"
check_term_before_kill "$DISPATCH_LOCAL" "kill_stale_wrapper" "dispatch-local.sh::kill_stale_wrapper"

# ===========================================================================
echo ""
echo "=== TC-LGC3-042: grep-pin — no pkill -f 'autonomous-' widening anywhere ==="
# ===========================================================================
HITS=$(grep -rn "pkill.*-f ['\"]*autonomous-" "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/" 2>/dev/null | grep -v "^\S*:\s*#" || true)
if [[ -z "$HITS" ]]; then
  assert_pass "TC-LGC3-042: no 'pkill -f autonomous-*' widening found anywhere in the dispatcher scripts"
else
  assert_fail "TC-LGC3-042: found forbidden pkill -f widening: $HITS"
fi

# Confirm the ONE narrow, correct form still exists (regression floor).
NARROW_HIT=$(grep -rn 'pkill -TERM -P \$\$' "$LIB_AGENT" 2>/dev/null || true)
if [[ -n "$NARROW_HIT" ]]; then
  assert_pass "TC-LGC3-042b: the narrow -P \$\$ form is present (not accidentally removed)"
else
  assert_fail "TC-LGC3-042b: the narrow pkill -P \$\$ direct-children fallback is missing"
fi

# ===========================================================================
echo ""
echo "=== Results ==="
echo "PASS: $PASS  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
