#!/bin/bash
# test-autonomous-review-multi-agent.sh — issue #166 / INV-40.
#
# Multi-agent parallel review with unanimous-PASS aggregation. Two pronged
# (the wrapper is too heavy to run end-to-end):
#
#   1. Pure aggregation-logic harness: source lib-review-aggregate.sh and
#      drive _aggregate_review_verdicts over the full truth table.
#   2. Source-of-truth greps against autonomous-review.sh: assert the
#      structural pieces the design requires (config resolution, backgrounded
#      fan-out, per-subshell overrides, per-agent jq predicate, aggregation,
#      crash fallback) without executing the wrapper.
#
# Run: bash tests/unit/test-autonomous-review-multi-agent.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
AGG_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-aggregate.sh"

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
    echo "      expected=[$expected]"
    echo "      actual=  [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

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
echo "=== TC-MAR-AGG: pure aggregation logic (_aggregate_review_verdicts) ==="
# ---------------------------------------------------------------------------
# _aggregate_review_verdicts <outcome...> — each arg is one agent's outcome:
#   pass | fail | unavailable
# Echoes the aggregate decision: pass | fail | all-unavailable
[[ -f "$AGG_LIB" ]] || {
  echo -e "  ${RED}FAIL${NC}: $AGG_LIB not found — implementation step required first"
  FAIL=$((FAIL + 1))
}

if [[ -f "$AGG_LIB" ]]; then
  # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-aggregate.sh
  source "$AGG_LIB"

  assert_eq "TC-MAR-AGG-01 both PASS → pass"            "pass"            "$(_aggregate_review_verdicts pass pass)"
  assert_eq "TC-MAR-AGG-02 pass+fail → fail"            "fail"            "$(_aggregate_review_verdicts pass fail)"
  assert_eq "TC-MAR-AGG-03 fail+fail → fail"            "fail"            "$(_aggregate_review_verdicts fail fail)"
  assert_eq "TC-MAR-AGG-04 pass+unavailable → pass"     "pass"            "$(_aggregate_review_verdicts pass unavailable)"
  assert_eq "TC-MAR-AGG-05 all unavailable → fallback"  "all-unavailable" "$(_aggregate_review_verdicts unavailable unavailable)"
  assert_eq "TC-MAR-AGG-06 unavailable+fail → fail"     "fail"            "$(_aggregate_review_verdicts unavailable fail)"
  assert_eq "TC-MAR-AGG-07 single pass → pass"          "pass"            "$(_aggregate_review_verdicts pass)"
  assert_eq "TC-MAR-AGG-08 single fail → fail"          "fail"            "$(_aggregate_review_verdicts fail)"
  assert_eq "TC-MAR-AGG-09 single unavailable → fallback" "all-unavailable" "$(_aggregate_review_verdicts unavailable)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-MAR-SRC: wrapper structure (source-of-truth greps) ==="
# ---------------------------------------------------------------------------
assert_grep "TC-MAR-SRC-01 reads AGENT_REVIEW_AGENTS" \
  'AGENT_REVIEW_AGENTS' "$WRAPPER"
# N=1 collapse: empty AGENT_REVIEW_AGENTS → REVIEW_AGENTS_LIST=("$AGENT_CMD")
assert_grep "TC-MAR-SRC-02 REVIEW_AGENTS_LIST collapses to (\$AGENT_CMD)" \
  'REVIEW_AGENTS_LIST=\("\$AGENT_CMD"\)' "$WRAPPER"
assert_grep "TC-MAR-SRC-03 build_review_prompt is a function taking name + session" \
  'build_review_prompt\(\)' "$WRAPPER"
assert_grep "TC-MAR-SRC-04 prompt emits a Review Agent: discriminator instruction" \
  'Review Agent: ' "$WRAPPER"
# Fan-out backgrounds each agent. run_agent is invoked inside a subshell that
# is itself backgrounded (`) &`) — the subshell is required so the per-agent
# AGENT_CMD / launcher / AGENT_PID_FILE overrides are local to that agent.
assert_grep "TC-MAR-SRC-05a fan-out calls run_agent inside the per-agent subshell" \
  'run_agent "\$_agent_session_id"' "$WRAPPER"
assert_grep "TC-MAR-SRC-05b the per-agent subshell is backgrounded (\) &)" \
  '\) &' "$WRAPPER"
assert_grep "TC-MAR-SRC-06 per-subshell AGENT_CMD override" \
  'AGENT_CMD="\$' "$WRAPPER"
assert_grep "TC-MAR-SRC-07 launcher neutralized for non-claude member (INV-38)" \
  'AGENT_LAUNCHER_ARGV=\(\)' "$WRAPPER"
# TC-MAR-SRC-08: the per-agent subshell must NOT let run_agent rewrite the
# SHARED review-N.pid. Originally this was an `unset AGENT_PID_FILE`; INV-43
# (#172) changed it to point AGENT_PID_FILE at a PRIVATE per-agent PGID sidecar
# under _FANOUT_DIR (so the agent's setsid PGID is captured for the reaper)
# WITHOUT touching the shared review-N.pid. Either way the contract is: the
# subshell's AGENT_PID_FILE is reassigned away from the wrapper's $PID_FILE.
assert_grep "TC-MAR-SRC-08 per-agent subshell reassigns AGENT_PID_FILE to a private sidecar (no shared-PID thrash)" \
  'AGENT_PID_FILE="\$\{_FANOUT_DIR\}/\$\{?_agent_session_id\}?\.pgid"|unset AGENT_PID_FILE' "$WRAPPER"
# TC-MAR-SRC-09 (regression for the fan-out hang): the wrapper MUST wait only
# the backgrounded fan-out subshells by their COLLECTED PIDs — never a bare
# `wait`. A bare `wait` blocks on ALL background jobs, including the long-lived
# gh-token-refresh-daemon and the heartbeat sleep loop, which never exit — so
# the wrapper would hang forever after the agents finish, stranding the issue
# in `reviewing`. Therefore: (a) each `) &` subshell's PID is appended to a
# fan-out PID array, and (b) the wait targets that array, and (c) there is NO
# bare `wait` line anywhere in the wrapper.
assert_grep "TC-MAR-SRC-09a fan-out collects each subshell PID (\$!)" \
  '_fanout_pids\+=\("?\$!"?\)' "$WRAPPER"
assert_grep "TC-MAR-SRC-09b wrapper waits the COLLECTED fan-out PIDs (not bare wait)" \
  'wait "\$\{_fanout_pids\[@\]\}"' "$WRAPPER"
assert_not_grep "TC-MAR-SRC-09c no bare \`wait\` (would also wait the token-refresh daemon + heartbeat → hang)" \
  '^[[:space:]]*wait[[:space:]]*(#.*)?$|^[[:space:]]*wait[[:space:]]*;' "$WRAPPER"
assert_grep "TC-MAR-SRC-10 per-agent jq verdict predicate keys on Review Agent:" \
  'Review Agent: ' "$WRAPPER"
assert_grep "TC-MAR-SRC-11 all-unavailable sets AGENT_EXIT=1 on a genuine CLI crash" \
  'AGENT_EXIT=1' "$WRAPPER"
# The per-agent subshell must capture run_agent's rc WITHOUT letting set -e
# abort before recording it (review finding): the run_agent invocation ends
# with `|| _rc=$?` (on its own continuation line), and the sidecar records
# `$_rc`, not a bare `$?`. grep is line-oriented, so we assert the two
# load-bearing tokens independently.
assert_grep "TC-MAR-SRC-11b per-agent rc captured under set -e (|| _rc=\$?)" \
  '\|\| _rc=\$\?' "$WRAPPER"
assert_grep "TC-MAR-SRC-11b sidecar records the captured _rc (not a bare \$?)" \
  "printf '%s.n' \"\\\$_rc\" > \"\\\$_agent_rc_file\"" "$WRAPPER"
# all-unavailable preserves the legacy N=1 distinction: AGENT_EXIT defaults to
# 0 (clean-but-silent → failed-substantive) and is only raised to 1 when an
# agent's launch rc was non-zero (genuine crash).
assert_grep "TC-MAR-SRC-11c all-unavailable defaults AGENT_EXIT=0 (legacy N=1 parity)" \
  'AGENT_EXIT=0' "$WRAPPER"
assert_grep "TC-MAR-SRC-13 dropped-agent summary comment on partial unavailability" \
  '[Dd]ropped' "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-MAR-SRC-12: exactly one aggregated verdict trailer (none in collection loop) ==="
# ---------------------------------------------------------------------------
# The aggregation must funnel through the SAME downstream PASS/FAIL/crash
# branches as the single-agent path. There must be NO emit_verdict_trailer
# call inside the per-agent verdict-collection loop. We assert the total
# emit_verdict_trailer call count: the historical six (crash trap, no-pr, pass,
# auto-merge-fail, fail-substantive, fail-non-substantive) PLUS the two
# INV-44 mergeable-gate block paths (CONFLICTING substantive + UNKNOWN
# non-substantive) PLUS the two INV-46 E2E-gate block paths (#182: E2E-fail
# substantive + E2E-evidence-missing non-substantive) PLUS the one INV-64
# Phase-A.5 smoke-FAIL abort path (#224: failed-non-substantive smoke-config-error),
# all of which sit OUTSIDE the collection loop = 11.
EMIT_COUNT=$(grep -cE '^\s*emit_verdict_trailer ' "$WRAPPER")
assert_eq "TC-MAR-SRC-12 emit_verdict_trailer call count is 11 (6 legacy + 2 INV-44 gate + 2 INV-46 E2E gate + 1 INV-64 smoke abort, none in collection loop)" \
  "11" "$EMIT_COUNT"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-MAR-SRC-14: wrapper passes bash -n ==="
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
echo "=== TC-MAR-SRC-15: kiro drop-reason classifier wired into the drop loop (INV-61, #215) ==="
# ---------------------------------------------------------------------------
# The drop-reason assembly loop must enrich a dropped `kiro` member's reason in
# addition to agy (INV-58) and codex (INV-59): the wrapper sources the kiro lib,
# captures the kiro per-agent log into AGENT_KIRO_LOGS during fan-out, classifies
# via _classify_kiro_drop_reason, and interpolates _kiro_drop_reason_phrase — so a
# fan-out dropping any of {agy, codex, kiro} lists a distinct reason for each.
assert_grep "TC-MAR-SRC-15a wrapper sources lib-review-kiro.sh" \
  'source "\$\{LIB_DIR\}/lib-review-kiro.sh"' "$WRAPPER"
assert_grep "TC-MAR-SRC-15b wrapper captures the per-agent kiro log (AGENT_KIRO_LOGS)" \
  'AGENT_KIRO_LOGS' "$WRAPPER"
assert_grep "TC-MAR-SRC-15c drop loop classifies a dropped kiro (_classify_kiro_drop_reason)" \
  '_classify_kiro_drop_reason' "$WRAPPER"
assert_grep "TC-MAR-SRC-15d drop loop interpolates the kiro reason phrase (_kiro_drop_reason_phrase)" \
  '_kiro_drop_reason_phrase' "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
