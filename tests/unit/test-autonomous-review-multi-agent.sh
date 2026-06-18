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
echo "=== TC-MAR-MAL-E2E: malformed codex prompt-echo contributes no vote; surviving agent decides (INV-73, #252) ==="
# ---------------------------------------------------------------------------
# Stub-fleet E2E: a 2-agent fan-out (codex + claude) where codex's `codex review`
# exits rc 0 but emits a prompt-echo / startup-trace (no verdict). Drive the FULL
# chain against the real libs:
#   - codex stdout → _codex_review_classify_stdout → `malformed` (NOT a phantom
#     [P1] FAIL) → leaves codex with NO vote → the post-window sweep resolves it
#     `unavailable` (`_classify_noverdict_agent` on a clean rc-0 no-verdict);
#   - the drop-reason loop names it `malformed-output` (rendered phrase);
#   - claude posts a real PASS;
#   - _aggregate_review_verdicts(unavailable pass) → `pass` — the surviving agent
#     decides, the phantom FAIL is gone. This is the end-to-end #252 regression.
CODEX_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-codex.sh"
FIXTURES="$SCRIPT_DIR/fixtures"
if [[ -f "$AGG_LIB" && -f "$CODEX_LIB" ]]; then
  (
    set -uo pipefail
    # _aggregate_review_verdicts AND _classify_noverdict_agent both live in
    # lib-review-aggregate.sh (the rc → pass|fail|unavailable|timed-out mapping the
    # post-window sweep uses); the codex lib supplies the classifier + drop reason.
    source "$AGG_LIB"
    source "$CODEX_LIB"

    # 1. codex emitted a prompt-echo at rc 0 → classifier says `malformed`.
    cx_verdict=$(_codex_review_classify_stdout "$FIXTURES/codex-review-stdout-prompt-echo.txt")
    assert_eq "TC-MAR-MAL-E2E-01 codex prompt-echo → classified malformed (no phantom FAIL)" \
      "malformed" "$cx_verdict"

    # 2. the wrapper does NOT post a verdict for a `malformed` classification, so
    #    codex stays no-verdict and the terminal sweep resolves it via the REAL
    #    _classify_noverdict_agent (clean rc 0 no-verdict → unavailable).
    cx_resolved=$(_classify_noverdict_agent 0)
    assert_eq "TC-MAR-MAL-E2E-02 malformed codex (rc 0, no verdict) → resolves unavailable (no vote)" \
      "unavailable" "$cx_resolved"

    # 3. the drop-reason loop names it `malformed-output`.
    cx_token=$(_classify_codex_drop_reason "$FIXTURES/codex-review-stdout-prompt-echo.txt" 0)
    assert_eq "TC-MAR-MAL-E2E-03 dropped codex → malformed-output token" \
      "malformed-output" "$cx_token"
    cx_phrase=$(_codex_drop_reason_phrase "$cx_token")
    case "$cx_phrase" in
      *malformed-output*prompt*) echo -e "  ${GREEN}PASS${NC}: TC-MAR-MAL-E2E-04 drop reason phrase names the malformed-output cause"; PASS=$((PASS + 1)) ;;
      *) echo -e "  ${RED}FAIL${NC}: TC-MAR-MAL-E2E-04 drop reason phrase missing (got: $cx_phrase)"; FAIL=$((FAIL + 1)) ;;
    esac

    # 4. a surviving claude posts a real PASS, and the aggregate is decided by it —
    #    NOT vetoed by a phantom codex FAIL.
    agg=$(_aggregate_review_verdicts "$cx_resolved" pass)
    assert_eq "TC-MAR-MAL-E2E-05 aggregate(unavailable codex, pass claude) → pass (surviving agent decides)" \
      "pass" "$agg"

    # 5. CONTRAST — the pre-fix behavior would have classified the SAME stdout as a
    #    blocking FAIL (the prompt's quoted `[P1]`), vetoing the clean PR. Prove the
    #    fix changed it: a malformed classification is NEITHER pass NOR fail.
    if [[ "$cx_verdict" != "fail" && "$cx_verdict" != "pass" ]]; then
      echo -e "  ${GREEN}PASS${NC}: TC-MAR-MAL-E2E-06 malformed is neither pass nor fail (no phantom verdict, #252)"; PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${NC}: TC-MAR-MAL-E2E-06 malformed leaked into a pass/fail verdict ($cx_verdict)"; FAIL=$((FAIL + 1))
    fi

    echo "PASS=$PASS FAIL=$FAIL" > "$SCRIPT_DIR/.mar_mal_counts.$$"
  )
  # The subshell can't mutate PASS/FAIL in the parent; fold its counts back.
  if [[ -f "$SCRIPT_DIR/.mar_mal_counts.$$" ]]; then
    # shellcheck disable=SC1090
    _mc=$(cat "$SCRIPT_DIR/.mar_mal_counts.$$"); rm -f "$SCRIPT_DIR/.mar_mal_counts.$$"
    PASS=$(sed -E 's/^PASS=([0-9]+).*/\1/' <<<"$_mc")
    FAIL=$(sed -E 's/.*FAIL=([0-9]+)$/\1/' <<<"$_mc")
  fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-MAR-MALEXIT: malformed-output on the all-unavailable path routes NON-substantive (INV-73, #252 5th-round [P1] #1) ==="
# ---------------------------------------------------------------------------
# 5th-round review finding [P1] #1: when a codex prompt-echo stays malformed after
# retries it is left unresolved with launch rc 0. In a SINGLE-agent codex fleet, the
# terminal all-unavailable path routed rc0 + no-comment through the `failed-substantive`
# legacy branch (AGENT_EXIT=0 → request-changes), so the malformed output STILL became a
# blocking review FAIL instead of a non-substantive `unavailable`/no-vote drop. The fix:
# the all-unavailable AGENT_EXIT scan ALSO raises AGENT_EXIT=1 (→ failed-non-substantive,
# re-dispatchable infra drop) when a dropped agent's reason is `malformed-output`, even at
# rc 0. Replicate the wrapper's routing loop and assert the malformed-output case → 1.
CODEX_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-codex.sh"
FIXTURES="$SCRIPT_DIR/fixtures"
if [[ -f "$CODEX_LIB" ]]; then
  (
    set -uo pipefail
    source "$CODEX_LIB"
    # Single-agent codex fleet, malformed-output (rc 0, no verdict, unavailable).
    AGENT_NAMES=(codex)
    AGENT_SESSION_IDS=(sid-cx)
    AGENT_CODEX_LOGS=("$FIXTURES/codex-review-stdout-prompt-echo.txt")
    declare -A AGENT_LAUNCH_RC=([sid-cx]=0)            # malformed prompt-echo exits rc 0
    AGENT_VERDICTS=(unavailable)                        # left unresolved → swept to unavailable

    # --- the wrapper's all-unavailable AGENT_EXIT routing, replicated with the fix ---
    AGENT_EXIT=0
    for _i in "${!AGENT_NAMES[@]}"; do
      # genuine CLI crash (rc != 0) → non-substantive
      if [[ "${AGENT_LAUNCH_RC[${AGENT_SESSION_IDS[$_i]}]:-1}" -ne 0 ]]; then AGENT_EXIT=1; break; fi
      # INV-73 5th-round: a malformed-output drop (rc 0) is ALSO non-substantive.
      if [[ "${AGENT_VERDICTS[$_i]}" == "unavailable" && "${AGENT_NAMES[$_i]}" == "codex" ]]; then
        _tok=$(_classify_codex_drop_reason "${AGENT_CODEX_LOGS[$_i]:-}" "${AGENT_LAUNCH_RC[${AGENT_SESSION_IDS[$_i]}]:-1}")
        if [[ "$_tok" == "malformed-output" ]]; then AGENT_EXIT=1; break; fi
      fi
    done
    echo "AGENT_EXIT=$AGENT_EXIT" > "$SCRIPT_DIR/.mar_malexit.$$"
  )
  if [[ -f "$SCRIPT_DIR/.mar_malexit.$$" ]]; then
    _ae=$(sed -E 's/AGENT_EXIT=//' "$SCRIPT_DIR/.mar_malexit.$$"); rm -f "$SCRIPT_DIR/.mar_malexit.$$"
    assert_eq "TC-MAR-MALEXIT-01 single-agent malformed-output (rc 0, unavailable) → AGENT_EXIT=1 (non-substantive, not failed-substantive)" "1" "$_ae"
  fi
fi
# Source-of-truth: the wrapper's drop loop flags an rc-0 codex infra drop, and the
# all-unavailable branch raises AGENT_EXIT on that flag (the fix must be wired into
# the REAL wrapper, not just the replicated logic above).
# 6th-round finding ([P1], session 5732e287): the flag must fire for ANY non-empty
# rc-0 codex infra-drop token, NOT only the exact `malformed-output` string — the
# classifier checks stream-error BEFORE malformed-output, so an rc-0 prompt-echo that
# echoes `Reconnecting... N/M` / `stream disconnected` text tokenizes `stream-error:*`
# and the old `== "malformed-output"` check missed it (re-routing to failed-substantive).
assert_grep "TC-MAR-MALEXIT-02a wrapper flags any rc-0 codex infra drop as non-substantive (not only malformed-output)" \
  '"\$_codex_launch_rc" == "0" && -n "\$_codex_reason_token" \]\] && _any_nonsubstantive_drop=true' "$WRAPPER"
assert_grep "TC-MAR-MALEXIT-02b all-unavailable branch raises AGENT_EXIT=1 on the non-substantive-drop flag" \
  '\[\[ "\$_any_nonsubstantive_drop" == true \]\] && AGENT_EXIT=1' "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-MAR-MALEXIT-03: rc-0 prompt-echo that ALSO echoes stream-error text routes NON-substantive (INV-73, #254 6th-round [P1]) ==="
# ---------------------------------------------------------------------------
# 6th-round review finding [P1] (session 5732e287): the all-unavailable fix only set
# `_any_nonsubstantive_drop` when the drop token was EXACTLY `malformed-output`. But
# `_classify_codex_drop_reason` scans for stream-error BEFORE the malformed check, so a
# malformed rc-0 prompt-echo whose echoed issue/comment text happens to contain
# `Reconnecting... N/M` or `stream disconnected before completion` tokenizes as
# `stream-error:*`. Because launch rc is still 0, the all-unavailable rc scan left
# AGENT_EXIT=0 and a single-agent codex fleet routed to `failed-substantive` AGAIN —
# the exact loop the 5th-round fix was meant to close. The fix: raise the flag for ANY
# NON-EMPTY codex drop token at launch rc 0 (the classifier only emits a token for a
# genuine infra drop — config-error / stream-error / malformed-output; a substantive
# no-verdict drop yields EMPTY). Replicate the wrapper's FIXED routing and assert → 1.
if [[ -f "$CODEX_LIB" ]]; then
  (
    set -uo pipefail
    source "$CODEX_LIB"
    # Single-agent codex fleet: malformed prompt-echo (rc 0) whose echoed text ALSO
    # contains stream-error phrases → classifier returns `stream-error:5/5`, NOT
    # `malformed-output`. The old exact-match check would miss this.
    AGENT_NAMES=(codex)
    AGENT_SESSION_IDS=(sid-cx)
    AGENT_CODEX_LOGS=("$FIXTURES/codex-review-stdout-prompt-echo-streamtext.txt")
    declare -A AGENT_LAUNCH_RC=([sid-cx]=0)            # malformed prompt-echo exits rc 0
    AGENT_VERDICTS=(unavailable)                        # left unresolved → swept to unavailable

    # --- the wrapper's all-unavailable AGENT_EXIT routing, replicated with the FIXED rule ---
    AGENT_EXIT=0
    for _i in "${!AGENT_NAMES[@]}"; do
      _lrc="${AGENT_LAUNCH_RC[${AGENT_SESSION_IDS[$_i]}]:-1}"
      # genuine CLI crash (rc != 0) → non-substantive
      if [[ "$_lrc" -ne 0 ]]; then AGENT_EXIT=1; break; fi
      # INV-73 6th-round: ANY rc-0 codex infra-drop token (malformed-output OR
      # stream-error:* OR config-error:*) is non-substantive, not just the exact
      # `malformed-output` string.
      if [[ "${AGENT_VERDICTS[$_i]}" == "unavailable" && "${AGENT_NAMES[$_i]}" == "codex" ]]; then
        _tok=$(_classify_codex_drop_reason "${AGENT_CODEX_LOGS[$_i]:-}" "$_lrc")
        if [[ "$_lrc" == "0" && -n "$_tok" ]]; then AGENT_EXIT=1; break; fi
      fi
    done
    echo "AGENT_EXIT=$AGENT_EXIT token=$(_classify_codex_drop_reason "${AGENT_CODEX_LOGS[0]}" 0)" > "$SCRIPT_DIR/.mar_malexit3.$$"
  )
  if [[ -f "$SCRIPT_DIR/.mar_malexit3.$$" ]]; then
    _line=$(cat "$SCRIPT_DIR/.mar_malexit3.$$"); rm -f "$SCRIPT_DIR/.mar_malexit3.$$"
    _ae=$(printf '%s\n' "$_line" | sed -E 's/^AGENT_EXIT=([0-9]+).*/\1/')
    _tok=$(printf '%s\n' "$_line" | sed -E 's/.* token=//')
    assert_eq "TC-MAR-MALEXIT-03a the overlap capture classifies stream-error (NOT malformed-output) — pins the bug's premise" \
      "stream-error:5/5" "$_tok"
    assert_eq "TC-MAR-MALEXIT-03b rc-0 prompt-echo with echoed stream-error text → AGENT_EXIT=1 (non-substantive, not failed-substantive)" \
      "1" "$_ae"
  fi
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
# TC-MAR-SRC-09 (regression for the fan-out hang): the wrapper MUST observe only
# the backgrounded fan-out subshells by their COLLECTED PIDs — never a bare
# `wait`. A bare `wait` blocks on ALL background jobs, including the long-lived
# gh-token-refresh-daemon and the heartbeat sleep loop, which never exit — so
# the wrapper would hang forever after the agents finish, stranding the issue
# in `reviewing`. Therefore: (a) each `) &` subshell's PID is appended to a
# fan-out PID array, and (b) the completion-observe loop iterates THAT array
# (INV-78 [P1] #2, #233: a bounded loop that breaks when all `_fanout_pids`
# exited via `kill -0` OR all artifacts landed — replacing the prior bare
# `wait "${_fanout_pids[@]}"`; still PID-array-scoped, never the daemon/heartbeat),
# and (c) there is NO bare `wait` line anywhere in the wrapper.
assert_grep "TC-MAR-SRC-09a fan-out collects each subshell PID (\$!)" \
  '_fanout_pids\+=\("?\$!"?\)' "$WRAPPER"
assert_grep "TC-MAR-SRC-09b completion-observe loop iterates the COLLECTED fan-out PIDs via kill -0 (not bare wait, not the daemon)" \
  'for _fp in "\$\{_fanout_pids\[@\]\}"' "$WRAPPER"
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
# Phase-A.5 smoke-FAIL abort path (#224: failed-non-substantive smoke-config-error)
# PLUS the two INV-78 mandatory-bot-review gate paths (#234: awaiting-bot-review
# wait non-substantive + the max-waits substantive FAIL),
# all of which sit OUTSIDE the collection loop = 13.
EMIT_COUNT=$(grep -cE '^\s*emit_verdict_trailer ' "$WRAPPER")
assert_eq "TC-MAR-SRC-12 emit_verdict_trailer call count is 13 (6 legacy + 2 INV-44 gate + 2 INV-46 E2E gate + 1 INV-64 smoke abort + 2 INV-78 bot-review gate, none in collection loop)" \
  "13" "$EMIT_COUNT"

# ---------------------------------------------------------------------------
# TC-MAR-SRC-METRICS (#228 round-8 finding 2): review-side token_usage. The
# fan-out records a GENERIC per-agent log for EVERY member, and the post-fan-out
# metrics loop parses it (metrics_parse_tokens) to emit token_usage side=review
# keyed by issue/pr/agent_name — so cost-per-merged-PR counts review tokens too,
# not just dev-side.
# ---------------------------------------------------------------------------
assert_grep "TC-MAR-SRC-METRICS-01 captures AGENT_GENERIC_LOGS per member" \
  'AGENT_GENERIC_LOGS\+=' "$WRAPPER"
assert_grep "TC-MAR-SRC-METRICS-02 emits review-side token_usage" \
  'metrics_emit token_usage side=review' "$WRAPPER"
assert_grep "TC-MAR-SRC-METRICS-03 parses the generic log via metrics_parse_tokens" \
  'metrics_parse_tokens "\$\{AGENT_GENERIC_LOGS' "$WRAPPER"

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
