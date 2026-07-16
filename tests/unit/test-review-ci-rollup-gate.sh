#!/bin/bash
# test-review-ci-rollup-gate.sh — issue #489 / INV-134.
#
# Reviewed-HEAD CI-rollup hard gate: a red API-visible check on the reviewed
# HEAD can never reach `approved`, regardless of the fan-out agents' verdict.
# Three pronged (the wrapper is too heavy to run end-to-end):
#
#   1. Pure decision-logic harness: source lib-review-ci-rollup.sh and drive
#      _classify_ci_rollup_gate over the full input space.
#   2. Leaf-level harness: drive the REAL chp_github_ci_rollup /
#      chp_gitlab_ci_rollup leaves against canned payloads via a stubbed gh /
#      _gl_api, proving the D1 token-derivation contract (incl. the
#      deliberate SKIPPED-is-green divergence from chp_ci_status).
#   3. Source-of-truth greps against autonomous-review.sh: assert the gate is
#      wired in with the right ordering/routing, without executing the
#      wrapper.
#
# Run: bash tests/unit/test-review-ci-rollup-gate.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
WRAPPER="$SCRIPTS/autonomous-review.sh"
CIR_LIB="$SCRIPTS/lib-review-ci-rollup.sh"
CHP_LIB="$SCRIPTS/lib-code-host.sh"

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

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

# ---------------------------------------------------------------------------
echo "=== TC-CIR-CLS: pure decision logic (_classify_ci_rollup_gate) ==="
# ---------------------------------------------------------------------------
[[ -f "$CIR_LIB" ]] || {
  echo -e "  ${RED}FAIL${NC}: $CIR_LIB not found — implementation step required first"
  FAIL=$((FAIL + 1))
}

if [[ -f "$CIR_LIB" ]]; then
  # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-ci-rollup.sh
  source "$CIR_LIB"

  assert_eq "TC-CIR-CLS-01 green → proceed" \
    "proceed"              "$(_classify_ci_rollup_gate green)"
  assert_eq "TC-CIR-CLS-02 none → proceed (zero checks must not block)" \
    "proceed"              "$(_classify_ci_rollup_gate none)"
  assert_eq "TC-CIR-CLS-03 failed → block-substantive" \
    "block-substantive"    "$(_classify_ci_rollup_gate failed)"
  assert_eq "TC-CIR-CLS-04 pending → block-nonsubstantive" \
    "block-nonsubstantive" "$(_classify_ci_rollup_gate pending)"
  assert_eq "TC-CIR-CLS-05 empty (leaf rc≠0 sentinel) → block-nonsubstantive" \
    "block-nonsubstantive" "$(_classify_ci_rollup_gate '')"
  assert_eq "TC-CIR-CLS-06 garbage/unrecognized → block-nonsubstantive (never proceed)" \
    "block-nonsubstantive" "$(_classify_ci_rollup_gate garbage)"

  # Key property: the ONLY inputs that proceed are green/none.
  _proceed_count=0
  for _in in green none failed pending '' garbage GREEN Green; do
    [[ "$(_classify_ci_rollup_gate "$_in")" == "proceed" ]] && _proceed_count=$((_proceed_count + 1))
  done
  assert_eq "TC-CIR-CLS-07 only green/none proceed (case-SENSITIVE — GREEN/Green do NOT proceed, unlike the mergeable gate's case-fold)" \
    "2" "$_proceed_count"

  # _ci_rollup_wait_max validator (mirrors _gate_breaker_threshold style).
  assert_eq "TC-CIR-WAITMAX-01 default (unset) → 3" \
    "3" "$(CI_ROLLUP_WAIT_MAX="" _ci_rollup_wait_max 2>/dev/null)"
  assert_eq "TC-CIR-WAITMAX-02 valid override → honored" \
    "5" "$(CI_ROLLUP_WAIT_MAX=5 _ci_rollup_wait_max 2>/dev/null)"
  assert_eq "TC-CIR-WAITMAX-03 non-numeric → falls back to 3" \
    "3" "$(CI_ROLLUP_WAIT_MAX=abc _ci_rollup_wait_max 2>/dev/null)"
  assert_eq "TC-CIR-WAITMAX-04 zero (<1 floor) → falls back to 3" \
    "3" "$(CI_ROLLUP_WAIT_MAX=0 _ci_rollup_wait_max 2>/dev/null)"
  assert_eq "TC-CIR-WAITMAX-05 negative → falls back to 3" \
    "3" "$(CI_ROLLUP_WAIT_MAX=-1 _ci_rollup_wait_max 2>/dev/null)"
  _waitmax_warn="$(CI_ROLLUP_WAIT_MAX=abc _ci_rollup_wait_max 2>&1 1>/dev/null)"
  assert_grep "TC-CIR-WAITMAX-06 invalid input logs a WARNING to stderr" \
    "WARNING: CI_ROLLUP_WAIT_MAX=" <(printf '%s' "$_waitmax_warn")

  # _ci_rollup_wait_marker shape.
  _marker="$(_ci_rollup_wait_marker 489 abc1234)"
  assert_eq "TC-CIR-MARKER-01 marker shape" \
    "<!-- ci-rollup-wait: issue=489 head=abc1234 -->" "$_marker"
  _marker_empty_head="$(_ci_rollup_wait_marker 489 "")"
  assert_eq "TC-CIR-MARKER-02 empty head renders as literal 'unknown' placeholder" \
    "<!-- ci-rollup-wait: issue=489 head=unknown -->" "$_marker_empty_head"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CIR-LEAF-GH: chp_github_ci_rollup token derivation (D1) ==="
# ---------------------------------------------------------------------------
# _drive_gh_rollup <gh_stdout> <gh_rc> — source lib-code-host.sh (which
# sources providers/chp-github.sh) under a stubbed gh, drive
# chp_github_ci_rollup, echo "<rc>|<stdout>". Mirrors test-w1d-ci-status-
# mergeable-parity.sh's _drive_leaf_neg pattern.
_drive_gh_rollup() {
  local gh_stdout="$1" gh_rc="$2"
  local out_file; out_file="$(mktemp)"
  env -u PROJECT_DIR -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR \
      REPO=o/r _CIR_GH_STDOUT="$gh_stdout" _CIR_GH_RC="$gh_rc" \
      _CIR_OUT="$out_file" _CIR_CHP_LIB="$CHP_LIB" \
  bash -c '
    gh() { printf "%s" "$_CIR_GH_STDOUT"; return "$_CIR_GH_RC"; }
    source "$_CIR_CHP_LIB" 2>/dev/null
    out=$(chp_ci_rollup 42 2>/dev/null); rc=$?
    printf "%s|%s\n" "$rc" "$out" > "$_CIR_OUT"
  '
  cat "$out_file"
  rm -f "$out_file"
}

row="$(_drive_gh_rollup '[{"name":"a","state":"SUCCESS"},{"name":"b","state":"SUCCESS"}]' 0)"
rc="${row%%|*}"; out="${row#*|}"
assert_eq "TC-CIR-LEAF-GH-01 all-SUCCESS rc=0" "0" "$rc"
assert_eq "TC-CIR-LEAF-GH-01 all-SUCCESS token" "green" "$(jq -r '.token' <<<"$out" 2>/dev/null)"

row="$(_drive_gh_rollup '[{"name":"a","state":"SKIPPED"},{"name":"b","state":"SKIPPED"}]' 1)"
rc="${row%%|*}"; out="${row#*|}"
assert_eq "TC-CIR-LEAF-GH-02 all-SKIPPED rc=0" "0" "$rc"
assert_eq "TC-CIR-LEAF-GH-02 all-SKIPPED → green (divergence from chp_ci_status's pending)" \
  "green" "$(jq -r '.token' <<<"$out" 2>/dev/null)"

row="$(_drive_gh_rollup '[{"name":"a","state":"SKIPPED"},{"name":"b","state":"SUCCESS"}]' 1)"
rc="${row%%|*}"; out="${row#*|}"
assert_eq "TC-CIR-LEAF-GH-03 SKIPPED+SUCCESS → green" \
  "green" "$(jq -r '.token' <<<"$out" 2>/dev/null)"

row="$(_drive_gh_rollup '[{"name":"a","state":"NEUTRAL"},{"name":"b","state":"SUCCESS"}]' 1)"
rc="${row%%|*}"; out="${row#*|}"
assert_eq "TC-CIR-LEAF-GH-03b NEUTRAL+SUCCESS → green (NEUTRAL is non-blocking, same as SUCCESS/SKIPPED)" \
  "green" "$(jq -r '.token' <<<"$out" 2>/dev/null)"

row="$(_drive_gh_rollup '[]' 0)"
rc="${row%%|*}"; out="${row#*|}"
assert_eq "TC-CIR-LEAF-GH-04 empty array → none" \
  "none" "$(jq -r '.token' <<<"$out" 2>/dev/null)"

row="$(_drive_gh_rollup '[{"name":"a","state":"SUCCESS"},{"name":"b","state":"FAILURE"}]' 1)"
rc="${row%%|*}"; out="${row#*|}"
assert_eq "TC-CIR-LEAF-GH-05 mixed-failure → failed" \
  "failed" "$(jq -r '.token' <<<"$out" 2>/dev/null)"
assert_eq "TC-CIR-LEAF-GH-05 failed_checks names only the failing check" \
  '["b"]' "$(jq -c '.failed_checks' <<<"$out" 2>/dev/null)"

row="$(_drive_gh_rollup '[{"name":"a","state":"PENDING"},{"name":"b","state":"FAILURE"}]' 1)"
rc="${row%%|*}"; out="${row#*|}"
assert_eq "TC-CIR-LEAF-GH-06 FAILURE+PENDING → failed (rule 1 beats rule 2)" \
  "failed" "$(jq -r '.token' <<<"$out" 2>/dev/null)"

row="$(_drive_gh_rollup '[{"name":"a","state":"SUCCESS"},{"name":"b","state":"PENDING"}]' 1)"
rc="${row%%|*}"; out="${row#*|}"
assert_eq "TC-CIR-LEAF-GH-07 SUCCESS+PENDING → pending" \
  "pending" "$(jq -r '.token' <<<"$out" 2>/dev/null)"
# D3: the wait-cap give-up finding must name the still-pending checks — the
# leaf's failed_checks lists them for `pending` too, not only for `failed`.
assert_eq "TC-CIR-LEAF-GH-07 failed_checks names only the still-pending check" \
  '["b"]' "$(jq -c '.failed_checks' <<<"$out" 2>/dev/null)"

row="$(_drive_gh_rollup '[{"name":"a","state":"QUANTUM_FUTURE"}]' 1)"
rc="${row%%|*}"; out="${row#*|}"
assert_eq "TC-CIR-LEAF-GH-08 unrecognized future state → pending" \
  "pending" "$(jq -r '.token' <<<"$out" 2>/dev/null)"

row="$(_drive_gh_rollup '{}' 0)"
rc="${row%%|*}"; out="${row#*|}"
assert_eq "TC-CIR-LEAF-GH-09 non-array object payload → leaf rc≠0" "1" "$rc"
assert_eq "TC-CIR-LEAF-GH-09 no partial stdout" "" "$out"

row="$(_drive_gh_rollup '' 1)"
rc="${row%%|*}"; out="${row#*|}"
assert_eq "TC-CIR-LEAF-GH-10 transport failure (empty stdout, gh rc≠0) → leaf rc≠0" "1" "$rc"
assert_eq "TC-CIR-LEAF-GH-10 no partial stdout" "" "$out"

# TC-CIR-LEAF-GH-11 — the gh "no checks reported" quirk: a PR with ZERO
# checks configured makes `gh pr checks` print that message to STDERR with
# EMPTY stdout and rc≠0 — indistinguishable from a transport failure by
# stdout alone. The leaf must map THIS specific case to none/proceed (D3:
# "a repo with zero checks must not block approval"), not to the generic
# fail-closed path. _drive_gh_rollup only stubs stdout, so drive this one
# directly with a gh() stub that also writes stderr.
_drive_gh_rollup_stderr() {
  local gh_stderr="$1" gh_rc="$2"
  local out_file; out_file="$(mktemp)"
  env -u PROJECT_DIR -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR \
      REPO=o/r _CIR_GH_STDERR="$gh_stderr" _CIR_GH_RC="$gh_rc" \
      _CIR_OUT="$out_file" _CIR_CHP_LIB="$CHP_LIB" \
  bash -c '
    gh() { printf "%s" "$_CIR_GH_STDERR" >&2; return "$_CIR_GH_RC"; }
    source "$_CIR_CHP_LIB" 2>/dev/null
    out=$(chp_ci_rollup 42 2>/dev/null); rc=$?
    printf "%s|%s\n" "$rc" "$out" > "$_CIR_OUT"
  '
  cat "$out_file"
  rm -f "$out_file"
}
row="$(_drive_gh_rollup_stderr "no checks reported on the 'main' branch" 1)"
rc="${row%%|*}"; out="${row#*|}"
assert_eq "TC-CIR-LEAF-GH-11 gh no-checks quirk → leaf rc=0" "0" "$rc"
assert_eq "TC-CIR-LEAF-GH-11 gh no-checks quirk → token=none" \
  "none" "$(jq -r '.token' <<<"$out" 2>/dev/null)"
row="$(_drive_gh_rollup_stderr "some other transport error" 1)"
rc="${row%%|*}"; out="${row#*|}"
assert_eq "TC-CIR-LEAF-GH-11 unrelated stderr text stays fail-closed (rc≠0)" "1" "$rc"
assert_eq "TC-CIR-LEAF-GH-11 unrelated stderr text: no partial stdout" "" "$out"

# chp_ci_status itself stays byte-unchanged for the same inputs (issue #489
# "assert the old function's output is untouched for the same inputs").
_drive_gh_status() {
  local gh_stdout="$1" gh_rc="$2"
  local out_file; out_file="$(mktemp)"
  env -u PROJECT_DIR -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR \
      REPO=o/r _CIR_GH_STDOUT="$gh_stdout" _CIR_GH_RC="$gh_rc" \
      _CIR_OUT="$out_file" _CIR_CHP_LIB="$CHP_LIB" \
  bash -c '
    gh() { printf "%s" "$_CIR_GH_STDOUT"; return "$_CIR_GH_RC"; }
    source "$_CIR_CHP_LIB" 2>/dev/null
    out=$(chp_ci_status 42 2>/dev/null); rc=$?
    printf "%s|%s\n" "$rc" "$out" > "$_CIR_OUT"
  '
  cat "$out_file"
  rm -f "$out_file"
}
row="$(_drive_gh_status '[{"name":"a","state":"SKIPPED"},{"name":"b","state":"SKIPPED"}]' 1)"
out="${row#*|}"
assert_eq "TC-CIR-STATUS-UNCHANGED-01 chp_ci_status all-SKIPPED still → pending (byte-unchanged)" \
  "pending" "$out"
row="$(_drive_gh_status '[{"name":"a","state":"SKIPPED"},{"name":"b","state":"SUCCESS"}]' 1)"
out="${row#*|}"
assert_eq "TC-CIR-STATUS-UNCHANGED-02 chp_ci_status SKIPPED+SUCCESS still → pending (byte-unchanged)" \
  "pending" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CIR-SRC: wrapper structure (source-of-truth greps) ==="
# ---------------------------------------------------------------------------
assert_grep "TC-CIR-SRC-01 wrapper sources lib-review-ci-rollup.sh" \
  'source "\$\{LIB_DIR\}/lib-review-ci-rollup.sh"' "$WRAPPER"
assert_grep "TC-CIR-SRC-02 gate queries the rollup via chp_ci_rollup positional" \
  'chp_ci_rollup "\$PR_NUMBER"' "$WRAPPER"
assert_grep "TC-CIR-SRC-03 gate calls _classify_ci_rollup_gate" \
  '_classify_ci_rollup_gate' "$WRAPPER"
assert_grep "TC-CIR-SRC-04 gate guarded by PASSED_VERDICT == true" \
  '\[\[ "\$PASSED_VERDICT" == "true" \]\]' "$WRAPPER"
assert_grep "TC-CIR-SRC-05 failed path posts a [BLOCKING] CI check(s) failed finding" \
  '\[BLOCKING\] CI check\(s\) failed' "$WRAPPER"
assert_grep "TC-CIR-SRC-06 failed path emits failed-substantive trailer with dev-actionable=true" \
  'emit_verdict_trailer "\$ISSUE_NUMBER" "\$REPO" "failed-substantive" "" "true"' "$WRAPPER"
assert_grep "TC-CIR-SRC-07 head-changed path emits failed-non-substantive cause head-changed" \
  'emit_verdict_trailer "\$ISSUE_NUMBER" "\$REPO" "failed-non-substantive" "head-changed"' "$WRAPPER"
assert_grep "TC-CIR-SRC-08 wait path emits failed-non-substantive with a CI_ROLLUP_CAUSE variable (awaiting-ci / ci-status-unavailable)" \
  'emit_verdict_trailer "\$ISSUE_NUMBER" "\$REPO" "failed-non-substantive" "\$CI_ROLLUP_CAUSE"' "$WRAPPER"
assert_grep "TC-CIR-SRC-09 head-changed routes -reviewing +pending-review (never approve on a stale HEAD)" \
  'itp_transition_state "\$ISSUE_NUMBER" "reviewing" "pending-review"' "$WRAPPER"
assert_grep "TC-CIR-SRC-10 failed path routes -reviewing +pending-dev" \
  'itp_transition_state "\$ISSUE_NUMBER" "reviewing" "pending-dev"' "$WRAPPER"
assert_grep "TC-CIR-SRC-11 wait-cap give-up path calls submit_request_changes" \
  'submit_request_changes "\$PR_NUMBER"' "$WRAPPER"
assert_grep "TC-CIR-SRC-12 gate reads CI_ROLLUP_WAIT_MAX via the validator helper" \
  '_ci_rollup_wait_max' "$WRAPPER"
assert_grep "TC-CIR-SRC-13 SHA-bound wait marker helper used" \
  '_ci_rollup_wait_marker "\$ISSUE_NUMBER"' "$WRAPPER"
assert_grep "TC-CIR-SRC-14 [INV-129] round=0 marker posted on the non-substantive routes" \
  '_review_round_marker "\$ISSUE_NUMBER" "\$PR_HEAD_SHA" 0' "$WRAPPER"
assert_grep "TC-CIR-SRC-16 pending-cause reason names the still-pending checks (D3 give-up finding)" \
  'CI_ROLLUP_PENDING_NAMES' "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CIR-ORDER: gate ordering pin (open -> bot -> mergeable -> CI-rollup -> approve) ==="
# ---------------------------------------------------------------------------
_ln_open=$(grep -nE 'PR-still-open guard \(INV-54, #196\) — HOISTED' "$WRAPPER" | head -1 | cut -d: -f1)
_ln_bot=$(grep -nE 'Mandatory-bot-review hard gate' "$WRAPPER" | head -1 | cut -d: -f1)
_ln_mergeable=$(grep -nE '^\s*MERGEABLE_GATE=\$\(_classify_mergeable_gate' "$WRAPPER" | head -1 | cut -d: -f1)
_ln_cirollup=$(grep -nE '^\s*CI_ROLLUP_GATE=\$\(_classify_ci_rollup_gate' "$WRAPPER" | head -1 | cut -d: -f1)
_ln_approve=$(grep -nE '^\s*if chp_approve "\$PR_NUMBER"' "$WRAPPER" | head -1 | cut -d: -f1)

if [[ -n "$_ln_open" && -n "$_ln_bot" && -n "$_ln_mergeable" && -n "$_ln_cirollup" && -n "$_ln_approve" ]]; then
  if [[ "$_ln_open" -lt "$_ln_bot" && "$_ln_bot" -lt "$_ln_mergeable" && "$_ln_mergeable" -lt "$_ln_cirollup" && "$_ln_cirollup" -lt "$_ln_approve" ]]; then
    echo -e "  ${GREEN}PASS${NC}: TC-CIR-ORDER-01 gate chain order is open($_ln_open) -> bot($_ln_bot) -> mergeable($_ln_mergeable) -> CI-rollup($_ln_cirollup) -> approve($_ln_approve)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-CIR-ORDER-01 gate chain out of order: open=$_ln_open bot=$_ln_bot mergeable=$_ln_mergeable cirollup=$_ln_cirollup approve=$_ln_approve"
    FAIL=$((FAIL + 1))
  fi
else
  echo -e "  ${RED}FAIL${NC}: TC-CIR-ORDER-01 could not locate one or more gate anchors (open=$_ln_open bot=$_ln_bot mergeable=$_ln_mergeable cirollup=$_ln_cirollup approve=$_ln_approve)"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CIR-HEAD: head-pinning (before AND after the chp_ci_rollup call) ==="
# ---------------------------------------------------------------------------
# The gate must re-confirm chp_pr_view headRefOid == PR_HEAD_SHA both BEFORE
# and AFTER dispatching chp_ci_rollup — count the _cir_head_matches call
# sites within the CI-rollup gate block (bounded window from the gate's own
# header comment to the next top-level "PASSED_VERDICT was set by the
# unanimous-PASS aggregation" comment that starts the PASS-path block).
_gate_start=$(grep -nE '^# CI-rollup hard gate \(INV-134, issue #489\)$' "$WRAPPER" | head -1 | cut -d: -f1)
_gate_end=$(grep -nE '^# PASSED_VERDICT was set by the unanimous-PASS aggregation above \(INV-40\)\.$' "$WRAPPER" | head -1 | cut -d: -f1)
if [[ -n "$_gate_start" && -n "$_gate_end" && "$_gate_end" -gt "$_gate_start" ]]; then
  _head_check_count=$(sed -n "${_gate_start},${_gate_end}p" "$WRAPPER" | grep -cE '_cir_head_matches "\$\{PR_HEAD_SHA:-\}"')
  assert_eq "TC-CIR-HEAD-01 exactly 2 head-pin checks inside the gate block (before + after chp_ci_rollup)" \
    "2" "$_head_check_count"
else
  echo -e "  ${RED}FAIL${NC}: TC-CIR-HEAD-01 could not bound the gate block (start=$_gate_start end=$_gate_end)"
  FAIL=$((FAIL + 1))
fi
assert_grep "TC-CIR-HEAD-02 head-changed guard requires non-empty PR_HEAD_SHA (empty never matches)" \
  '\[\[ -n "\$reviewed" \]\] \|\| return 1' "$WRAPPER"

# TC-CIR-HEAD-03 — BEHAVIORAL proof (not just a call-count grep) that the two
# head-pin checks are independent LIVE queries, not a cached first answer: a
# regression that made the second check reuse the first query's result would
# leave the TC-CIR-HEAD-01 call-count pattern completely unchanged (the text
# "_cir_head_matches ..." would still appear twice) while silently defeating
# the mid-call HEAD-drift detection the docs claim. Extract the REAL
# _cir_head_matches body verbatim from the wrapper (sed, mirrors the
# _render_close_keyword extraction idiom in run-provider-conformance.sh) and
# CALL IT TWICE in one subshell — exactly like the real gate's before/after
# call sites — against a stubbed chp_pr_view that answers DIFFERENTLY on the
# 2nd call than the 1st, modeling a HEAD that changed mid-gate. Echoes
# "<first_rc>|<second_rc>".
_cir_drive_twice() {
  local reviewed="$1" first_answer="$2" second_answer="$3"
  local call_count_file; call_count_file="$(mktemp)"; printf '0' > "$call_count_file"
  # A counter kept in a plain shell var would NOT persist across the two
  # _cir_head_matches invocations below: each call does `current=$(chp_pr_view
  # | jq ...)`, and command substitution always forks a subshell, so any
  # in-process var chp_pr_view mutates is lost the instant that subshell
  # exits. A file is the only counter that survives both calls.
  env -u PROJECT_DIR PR_NUMBER=42 \
      _CIR_FIRST="$first_answer" _CIR_SECOND="$second_answer" \
      _CIR_CALL_FILE="$call_count_file" \
  bash -c '
    eval "$(sed -n "/^  _cir_head_matches() {/,/^  }$/p" "'"$WRAPPER"'" | sed "s/^  //")"
    chp_pr_view() {
      local n; n=$(<"$_CIR_CALL_FILE"); n=$((n + 1))
      printf "%s" "$n" > "$_CIR_CALL_FILE"
      if [[ "$n" -eq 1 ]]; then
        [[ -n "$_CIR_FIRST" ]] && printf "{\"headRefOid\":\"%s\"}" "$_CIR_FIRST"
      else
        [[ -n "$_CIR_SECOND" ]] && printf "{\"headRefOid\":\"%s\"}" "$_CIR_SECOND"
      fi
    }
    _cir_head_matches "'"$reviewed"'"; rc1=$?
    _cir_head_matches "'"$reviewed"'"; rc2=$?
    printf "%s|%s" "$rc1" "$rc2"
  '
  rm -f "$call_count_file"
}

_res=$(_cir_drive_twice "sha-aaa" "sha-aaa" "sha-aaa")
if [[ "$_res" == "0|0" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CIR-HEAD-03a stable HEAD across both calls -> both match (proceed)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CIR-HEAD-03a stable HEAD across both calls -> expected 0|0, got $_res"
  FAIL=$((FAIL + 1))
fi

_res=$(_cir_drive_twice "sha-aaa" "sha-aaa" "sha-bbb")
if [[ "$_res" == "0|1" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CIR-HEAD-03b HEAD changes between the 1st and 2nd call -> 1st matches, 2nd drifts (never approve)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CIR-HEAD-03b HEAD changes between the 1st and 2nd call -> expected 0|1 (drift caught post-call), got $_res"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CIR-WAITCOUNT: a read failure on the wait-marker count fails CLOSED (already-at-cap), not to 0 ==="
# ---------------------------------------------------------------------------
# A sustained chp_pr_view/jq outage must escalate toward the give-up branch,
# never silently reset the wait clock every tick (which would loop
# pending-review forever). Extract the REAL wait-count block verbatim from
# the wrapper (same sed/awk extraction idiom as TC-CIR-HEAD-03 above and
# run-provider-conformance.sh's _render_close_keyword extraction) and drive
# it in a subshell against a stubbed chp_pr_view/jq, proving the LIVE
# behavior — not just a source-grep of the fix.
CIR_WAITCOUNT_SLICE=$(mktemp)
trap 'rm -f "$CIR_WAITCOUNT_SLICE"' EXIT
awk '/^    CI_ROLLUP_WAIT_MARKER=\$\(_ci_rollup_wait_marker /,/^    fi$/' "$WRAPPER" > "$CIR_WAITCOUNT_SLICE"
[ -s "$CIR_WAITCOUNT_SLICE" ] || { echo "FATAL: could not extract the CI-rollup wait-count block from the wrapper — has it moved/been renamed?"; exit 2; }

# _cir_drive_waitcount <chp_pr_view_rc> <chp_pr_view_stdout> — source the
# extracted slice under stubbed _ci_rollup_wait_marker/_ci_rollup_wait_max/
# chp_pr_view/log, echo "<CI_ROLLUP_WAIT_COUNT>|<CI_ROLLUP_WAIT_MAX_VAL>".
_cir_drive_waitcount() {
  local pv_rc="$1" pv_stdout="$2"
  local out_file; out_file="$(mktemp)"
  env -u PROJECT_DIR ISSUE_NUMBER=489 PR_HEAD_SHA=deadbeef \
      _CIR_PV_RC="$pv_rc" _CIR_PV_STDOUT="$pv_stdout" \
      _CIR_OUT="$out_file" _CIR_SLICE="$CIR_WAITCOUNT_SLICE" \
  bash -c '
    _ci_rollup_wait_marker() { printf "<!-- marker -->"; }
    _ci_rollup_wait_max() { printf "3"; }
    chp_pr_view() { printf "%s" "$_CIR_PV_STDOUT"; return "$_CIR_PV_RC"; }
    log() { :; }
    source "$_CIR_SLICE"
    printf "%s|%s" "$CI_ROLLUP_WAIT_COUNT" "$CI_ROLLUP_WAIT_MAX_VAL"
  ' > "$out_file" 2>/dev/null
  cat "$out_file"
  rm -f "$out_file"
}

_res=$(_cir_drive_waitcount 0 '{"comments":[]}')
assert_eq "TC-CIR-WAITCOUNT-01 a genuinely healthy read with zero prior markers -> count=0 (not at cap)" \
  "0|3" "$_res"

_res=$(_cir_drive_waitcount 0 '{"comments":[{"body":"<!-- ci-rollup-wait: issue=489 head=deadbeef -->"},{"body":"<!-- ci-rollup-wait: issue=489 head=deadbeef -->"}]}')
assert_eq "TC-CIR-WAITCOUNT-02 a genuinely healthy read with 2 prior markers -> count=2 (below cap)" \
  "2|3" "$_res"

_res=$(_cir_drive_waitcount 1 '')
assert_eq "TC-CIR-WAITCOUNT-03 chp_pr_view transport failure (rc≠0, empty stdout) -> count=WAIT_MAX (fail-closed to already-at-cap, NOT 0)" \
  "3|3" "$_res"

_res=$(_cir_drive_waitcount 0 'not json')
assert_eq "TC-CIR-WAITCOUNT-04 chp_pr_view rc=0 but unparseable stdout (jq failure) -> count=WAIT_MAX (fail-closed, NOT 0)" \
  "3|3" "$_res"

_res=$(_cir_drive_waitcount 0 '{"comments":[]}')
if [[ "$_res" == "0|3" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CIR-WAITCOUNT-05 regression guard: the fail-closed branch does not fire on a genuinely healthy zero-marker read"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CIR-WAITCOUNT-05 expected 0|3 (healthy zero-marker read must not be misclassified as a read failure), got $_res"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CIR-D4: existing gates unmodified (INV-46 E2E, INV-64 smoke) ==="
# ---------------------------------------------------------------------------
assert_grep "TC-CIR-D4-01 INV-46 E2E hard gate still present, unmodified" \
  'INV-46 \(#182\): run E2E ONCE in a dedicated lane' "$WRAPPER"
assert_grep "TC-CIR-D4-02 INV-64 pre-fan-out smoke gate still present, unmodified" \
  'PHASE A\.5: pre-fan-out agent-smoke gate \(INV-64, #224\)' "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CIR-D5: provider neutrality (zero raw gh calls added) ==="
# ---------------------------------------------------------------------------
# Bounded window scan for a raw `gh pr checks` / `gh api` call inside the
# gate block — the wrapper must call ONLY chp_ci_rollup / chp_pr_view here.
if [[ -n "$_gate_start" && -n "$_gate_end" ]]; then
  _raw_gh_count=$(sed -n "${_gate_start},${_gate_end}p" "$WRAPPER" | grep -vE '^\s*#' | grep -cE '(^|[^A-Za-z_.-])gh (pr checks|api)')
  assert_eq "TC-CIR-D5-01 zero raw 'gh pr checks'/'gh api' EXECUTABLE calls inside the CI-rollup gate block (comment mentions excluded)" \
    "0" "$_raw_gh_count"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CIR-INV44: INV-44 wording clarification (merge-conflict, not CI) ==="
# ---------------------------------------------------------------------------
assert_grep "TC-CIR-INV44-01 mergeable gate finding clarifies merge-conflict (not CI)" \
  'merge-conflict gate — not a CI-status gate' "$WRAPPER"
# _classify_mergeable_gate itself is BYTE-UNCHANGED (issue #489: "INV-44
# ships byte-unchanged"). Assert against the pre-existing golden table in
# lib-review-mergeable.sh directly rather than re-deriving it here.
MG_LIB="$SCRIPTS/lib-review-mergeable.sh"
if [[ -f "$MG_LIB" ]]; then
  # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-mergeable.sh
  source "$MG_LIB"
  assert_eq "TC-CIR-INV44-02 _classify_mergeable_gate byte-unchanged: MERGEABLE → proceed" \
    "proceed" "$(_classify_mergeable_gate MERGEABLE)"
  assert_eq "TC-CIR-INV44-03 _classify_mergeable_gate byte-unchanged: CONFLICTING → block-substantive" \
    "block-substantive" "$(_classify_mergeable_gate CONFLICTING)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CIR-REG-01: regression — pre-fix approval reachable, post-fix blocked ==="
# ---------------------------------------------------------------------------
# This is the documented regression from issue #489: aggregate PASS + PR
# OPEN + bot review present + MERGEABLE + CI rollup `failed`. Post-fix, the
# gate MUST be wired in (source-of-truth: the gate block exists AND sits
# between the mergeable gate and the approve call — already proven by
# TC-CIR-ORDER-01/TC-CIR-SRC-02/03 above) so that chp_approve is UNREACHABLE
# without first passing _classify_ci_rollup_gate. We assert the negative
# space directly: chp_approve is never called before the CI-rollup gate's
# classify line in the wrapper's byte order.
if [[ -n "$_ln_cirollup" && -n "$_ln_approve" ]]; then
  _approve_before_cirollup=$(awk -v s="$_ln_cirollup" 'NR < s && /if chp_approve "\$PR_NUMBER"/ {c++} END{print c+0}' "$WRAPPER")
  assert_eq "TC-CIR-REG-01 no chp_approve call site precedes the CI-rollup gate (approval is unreachable before the gate decides)" \
    "0" "$_approve_before_cirollup"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CIR-SRC-15: wrapper passes bash -n ==="
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
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
