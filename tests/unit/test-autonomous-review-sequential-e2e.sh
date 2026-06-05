#!/bin/bash
# test-autonomous-review-sequential-e2e.sh — issue #182 / INV-46.
#
# Run E2E ONCE in a dedicated lane, sequentially, BEFORE the review fan-out —
# not once per fan-out review agent. The N×-redundant-E2E this kills:
# AGENT_REVIEW_AGENTS with N CLIs used to inject the E2E execution block into
# every agent's prompt, so the heavy E2E_COMMAND_PRE_HOOKS (container build) ran
# N times per review round.
#
# Three-pronged (the wrapper is too heavy to run end-to-end):
#   1. pure-logic harness for _classify_e2e_gate / _run_command_e2e_lane /
#      _fetch_sha_evidence (sourced from lib-review-e2e.sh in isolation, mirrors
#      lib-review-aggregate.sh / lib-review-poll.sh);
#   2. source-of-truth greps against autonomous-review.sh for the structural
#      pieces (lane runs before fan-out, command lane is shell, setsid+timeout,
#      PGID in trap+reaper, build_review_prompt drops the E2E execution block);
#   3. aggregation truth table (E2E gate ∧ review unanimity) + doc presence.
#
# Run: bash tests/unit/test-autonomous-review-sequential-e2e.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
E2E_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-e2e.sh"
AGG_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-aggregate.sh"
REF="$PROJECT_ROOT/skills/autonomous-review/references/e2e-command-mode.md"
INVARIANTS="$PROJECT_ROOT/docs/pipeline/invariants.md"
FLOW="$PROJECT_ROOT/docs/pipeline/review-agent-flow.md"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected=[$expected]"; echo "      actual=  [$actual]"; FAIL=$((FAIL + 1))
  fi
}

assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"; FAIL=$((FAIL + 1))
  fi
}

assert_not_grep() {
  local desc="$1" pattern="$2" file="$3"
  if ! grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (matched: $pattern)"; FAIL=$((FAIL + 1))
  fi
}

assert_lt() {
  local desc="$1" a="$2" b="$3"
  if [[ "$a" =~ ^[0-9]+$ ]] && [[ "$b" =~ ^[0-9]+$ ]] && [[ "$a" -lt "$b" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected $a < $b)"; FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
echo "=== TC-SE2E-GATE: _classify_e2e_gate truth table ==="
# ---------------------------------------------------------------------------
[[ -f "$E2E_LIB" ]] || { echo -e "  ${RED}FAIL${NC}: $E2E_LIB not found"; FAIL=$((FAIL + 1)); }
if [[ -f "$E2E_LIB" ]]; then
  # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-e2e.sh
  source "$E2E_LIB"

  assert_eq "TC-SE2E-GATE-01 rc=0 + evidence → pass" \
    "pass" "$(_classify_e2e_gate 0 1)"
  assert_eq "TC-SE2E-GATE-02 rc=0 + no evidence → block-nonsubstantive (fail-closed)" \
    "block-nonsubstantive" "$(_classify_e2e_gate 0 0)"
  assert_eq "TC-SE2E-GATE-03 rc=1 + evidence → fail (stale-present does not rescue)" \
    "fail" "$(_classify_e2e_gate 1 1)"
  assert_eq "TC-SE2E-GATE-04 rc=1 + no evidence → fail" \
    "fail" "$(_classify_e2e_gate 1 0)"
  # The lane normalizes 124-with-recovered-artifact to rc=0 BEFORE the gate; a
  # 124 that reaches the gate (no recovery) is a fail.
  assert_eq "TC-SE2E-GATE-05 rc=124 (no recovery) → fail" \
    "fail" "$(_classify_e2e_gate 124 1)"
  assert_eq "TC-SE2E-GATE-06 rc=124 + no evidence → fail" \
    "fail" "$(_classify_e2e_gate 124 0)"
  assert_eq "TC-SE2E-GATE-07 non-numeric rc → fail (defensive)" \
    "fail" "$(_classify_e2e_gate abc 1)"
fi

# ---------------------------------------------------------------------------
echo "=== TC-SE2E-LANE: _run_command_e2e_lane harness (stub gh + hooks) ==="
# ---------------------------------------------------------------------------
if [[ -f "$E2E_LIB" ]]; then
  # Harness: a clean temp HOME + stubbed gh/pre-hook/verify/parser. The lane
  # reads E2E_COMMAND_*_RENDERED + PR_NUMBER/REPO/PR_HEAD_SHA from env.
  _lane_harness() {
    # $1 = setup snippet (exports + stub bodies), echoed into the sub-bash.
    local setup="$1"
    env -i PATH="$PATH" bash -c "
      set -uo pipefail
      source '$E2E_LIB'
      log() { :; }                     # silence the lane's log()
      TMPD=\$(mktemp -d)
      export PR_NUMBER=42 REPO=owner/repo PR_HEAD_SHA=deadbeefcafe
      # Default stubs (overridable in \$setup):
      PREHOOK_COUNT=\"\$TMPD/prehook.count\"; : > \"\$PREHOOK_COUNT\"
      gh() { :; }                      # swallow gh pr comment by default
      $setup
      RCFILE=\"\$TMPD/lane.rc\"
      _run_command_e2e_lane \"\$RCFILE\"
      echo \"RC=\$(cat \"\$RCFILE\" 2>/dev/null || echo MISSING)\"
      echo \"PREHOOK_CALLS=\$(cat \"\$PREHOOK_COUNT\" 2>/dev/null | wc -l | tr -d ' ')\"
      echo \"PARSER_RAN=\${PARSER_RAN_MARKER:-no}\"
    "
  }

  # TC-SE2E-LANE-01: pre-hook non-zero → .rc != 0, parser NOT invoked, sidecar WRITTEN.
  out=$(_lane_harness '
    _fetch_sha_evidence() { return 0; }   # no existing evidence
    export E2E_COMMAND_PRE_HOOKS_RENDERED="exit 7"
    export E2E_COMMAND_RENDERED="echo SHOULD_NOT_RUN; exit 0"
    export E2E_COMMAND_EVIDENCE_PARSER_RENDERED="echo PARSER_SHOULD_NOT_RUN"
  ')
  assert_eq "TC-SE2E-LANE-01 pre-hook non-zero → .rc=7 (sidecar written under set -e)" \
    "RC=7" "$(printf '%s\n' "$out" | grep '^RC=')"

  # TC-SE2E-LANE-02: verify exit 0 → parser → evidence posted → .rc==0.
  out=$(_lane_harness '
    _fetch_sha_evidence() { return 0; }
    export E2E_COMMAND_PRE_HOOKS_RENDERED=""
    export E2E_COMMAND_RENDERED="exit 0"
    export E2E_COMMAND_EVIDENCE_PARSER_RENDERED="printf %s \"## E2E Evidence\n<!-- e2e-evidence: complete sha=\\\"deadbeefcafe\\\" -->\""
  ')
  assert_eq "TC-SE2E-LANE-02 verify 0 → parser → .rc=0" \
    "RC=0" "$(printf '%s\n' "$out" | grep '^RC=')"

  # TC-SE2E-LANE-03: verify exit 124 with recovered SHA-marked artifact → .rc==0.
  out=$(_lane_harness '
    _fetch_sha_evidence() { return 0; }
    _run_command_e2e_verify() { return 124; }   # simulate timeout
    export E2E_COMMAND_PRE_HOOKS_RENDERED=""
    export E2E_COMMAND_RENDERED="sleep 999"
    export E2E_COMMAND_EVIDENCE_PARSER_RENDERED="printf %s \"## E2E Evidence (partial, timeout)\n<!-- e2e-evidence: complete sha=\\\"deadbeefcafe\\\" -->\""
  ')
  assert_eq "TC-SE2E-LANE-03 verify 124 + recovered artifact → .rc=0" \
    "RC=0" "$(printf '%s\n' "$out" | grep '^RC=')"

  # TC-SE2E-LANE-04: verify exit other (3) → parser SKIPPED → log-tail → .rc!=0.
  out=$(_lane_harness '
    _fetch_sha_evidence() { return 0; }
    _run_command_e2e_verify() { return 3; }
    export E2E_COMMAND_PRE_HOOKS_RENDERED=""
    export E2E_COMMAND_RENDERED="exit 3"
    export E2E_COMMAND_EVIDENCE_PARSER_RENDERED="echo PARSER_RAN_MARKER=yes >&2; printf PARSED"
  ')
  assert_eq "TC-SE2E-LANE-04 verify exit 3 → .rc=3 (parser skipped)" \
    "RC=3" "$(printf '%s\n' "$out" | grep '^RC=')"

  # TC-SE2E-LANE-05: SHA-matching evidence already present → reuse/skip, .rc==0,
  # pre-hook NOT invoked.
  out=$(_lane_harness '
    _fetch_sha_evidence() { printf "## E2E Evidence\n<!-- e2e-evidence: complete sha=\"deadbeefcafe\" -->\n"; }
    export E2E_COMMAND_PRE_HOOKS_RENDERED="echo prehook >> \"$PREHOOK_COUNT\""
    export E2E_COMMAND_RENDERED="echo SHOULD_NOT_RUN"
    export E2E_COMMAND_EVIDENCE_PARSER_RENDERED="echo SHOULD_NOT_RUN"
  ')
  assert_eq "TC-SE2E-LANE-05 SHA-match present → reuse, .rc=0" \
    "RC=0" "$(printf '%s\n' "$out" | grep '^RC=')"
  assert_eq "TC-SE2E-LANE-05b SHA-match present → pre-hook NOT invoked" \
    "PREHOOK_CALLS=0" "$(printf '%s\n' "$out" | grep '^PREHOOK_CALLS=')"

  # TC-SE2E-LANE-06: stale-SHA evidence (no match for the current HEAD) → the
  # idempotency re-fetch returns EMPTY, so the lane does NOT reuse — it re-runs
  # the pre-hook + verify. This is the load-bearing negative idempotency guard:
  # stale evidence from a prior commit must NOT short-circuit re-verification of
  # newer code. _fetch_sha_evidence returns empty (the real jq `contains(sha=
  # "<HEAD>")` filter finds no match for a stale comment), so the pre-hook runs.
  out=$(_lane_harness '
    _fetch_sha_evidence() { return 0; }   # stale comment exists but no SHA match → empty
    export E2E_COMMAND_PRE_HOOKS_RENDERED="echo prehook >> \"$PREHOOK_COUNT\""
    export E2E_COMMAND_RENDERED="exit 0"
    export E2E_COMMAND_EVIDENCE_PARSER_RENDERED="printf %s \"## E2E\n<!-- e2e-evidence: complete sha=\\\"deadbeefcafe\\\" -->\""
  ')
  assert_eq "TC-SE2E-LANE-06 stale-SHA (no match) → does NOT reuse, .rc=0 after re-run" \
    "RC=0" "$(printf '%s\n' "$out" | grep '^RC=')"
  assert_eq "TC-SE2E-LANE-06b stale-SHA (no match) → pre-hook IS invoked (re-run)" \
    "PREHOOK_CALLS=1" "$(printf '%s\n' "$out" | grep '^PREHOOK_CALLS=')"

  # TC-SE2E-LANE-07: set -e discipline — failing pre-hook still WRITES the sidecar.
  out=$(_lane_harness '
    _fetch_sha_evidence() { return 0; }
    export E2E_COMMAND_PRE_HOOKS_RENDERED="false"
    export E2E_COMMAND_RENDERED="exit 0"
    export E2E_COMMAND_EVIDENCE_PARSER_RENDERED="echo x"
  ')
  assert_not_grep "TC-SE2E-LANE-07 failing pre-hook still writes sidecar (not MISSING)" \
    "RC=MISSING" <(printf '%s\n' "$out")
fi

# ---------------------------------------------------------------------------
echo "=== TC-SE2E-FETCH: _fetch_sha_evidence present/absent + bounded retry ==="
# ---------------------------------------------------------------------------
if [[ -f "$E2E_LIB" ]]; then
  _fetch_harness() {
    local setup="$1"
    env -i PATH="$PATH" bash -c "
      set -uo pipefail
      source '$E2E_LIB'
      export PR_NUMBER=42 REPO=owner/repo PR_HEAD_SHA=deadbeefcafe
      $setup
      _fetch_sha_evidence \${RETRIES:-1} 0
    "
  }

  # TC-SE2E-FETCH-01: SHA-matching comment present → echoes body.
  out=$(_fetch_harness '
    gh() { printf "## E2E Evidence\n<!-- e2e-evidence: complete sha=\"deadbeefcafe\" -->\n"; }
  ')
  assert_grep "TC-SE2E-FETCH-01 SHA-match present → echoes body" \
    "e2e-evidence: complete" <(printf '%s\n' "$out")

  # TC-SE2E-FETCH-02: only stale-SHA comment → empty (the contains filter is on gh
  # side; stub returns empty for the non-matching SHA).
  out=$(_fetch_harness '
    gh() { printf ""; }   # jq contains filter found no matching SHA
  ')
  assert_eq "TC-SE2E-FETCH-02 stale-SHA only → empty" "" "$out"

  # TC-SE2E-FETCH-03: bounded retry then still empty → returns empty, no hang.
  out=$(_fetch_harness '
    gh() { printf ""; }
    RETRIES=3
  ')
  assert_eq "TC-SE2E-FETCH-03 bounded-retry-then-empty → empty (no hang)" "" "$out"
fi

# ---------------------------------------------------------------------------
echo "=== TC-SE2E-STAMP: _stamp_browser_evidence_marker stamps the REPORT, fails closed otherwise (codex review, #182) ==="
# ---------------------------------------------------------------------------
# The browser lane must stamp the SHA marker ONTO the LLM-posted
# '## E2E Verification Report' comment — NOT post a standalone marker-only
# comment. A marker-only comment would (a) let the gate pass with no real
# evidence and (b) hand reviewers a comment with no tables/screenshots/AC. The
# helper edits the report comment via REST PATCH, or returns 1 (gate fails
# closed) when no report exists.
if [[ -f "$E2E_LIB" ]]; then
  # Harness: stub `gh api` to model the REST endpoints the helper hits:
  #   GET  issues/<pr>/comments            → the comment list (jq filtered)
  #   GET  issues/comments/<id>            → a single comment body
  #   PATCH issues/comments/<id> -f body=… → records the new body
  # The stub records whether a PATCH happened and whether a standalone
  # marker-only `gh pr comment` was ever posted (it must NOT be).
  _stamp_harness() {
    local setup="$1"
    env -i PATH="$PATH" bash -c "
      set -uo pipefail
      source '$E2E_LIB'
      log() { :; }
      TMPD=\$(mktemp -d)
      export PR_NUMBER=42 REPO=owner/repo REPO_OWNER=owner REPO_NAME=repo \\
        PR_HEAD_SHA=deadbeefcafe BOT_LOGIN=bot WRAPPER_START_TS=2026-01-01T00:00:00Z
      export PATCH_FLAG=\"\$TMPD/patched\"; : > \"\$PATCH_FLAG\"
      $setup
      if _stamp_browser_evidence_marker; then echo 'STAMP_RC=0'; else echo \"STAMP_RC=\$?\"; fi
      echo \"PATCHED=\$([[ -s \"\$PATCH_FLAG\" ]] && echo yes || echo no)\"
    "
  }

  # TC-SE2E-STAMP-01: a real report comment present → helper PATCHes it, returns 0.
  # The stub models the two GET queries the helper issues (the comment-list query,
  # which the helper --jq-reduces to the report comment's .id, and the
  # single-comment body fetch) plus the PATCH edit. Because the helper passes its
  # own --jq, the stub returns the already-reduced value (the .id / the body).
  out=$(_stamp_harness '
    gh() {
      local is_patch=0; for a in "$@"; do [[ "$a" == "PATCH" ]] && is_patch=1; done
      if [[ "$is_patch" == 1 ]]; then echo edited > "$PATCH_FLAG"; return 0; fi
      case "$*" in
        *"issues/42/comments"*) echo 99 ;;                 # list query → .id of the report
        *"issues/comments/99"*) printf "## E2E Verification Report\n| Total | 1 |" ;;  # body
      esac
    }
  ')
  assert_grep "TC-SE2E-STAMP-01 report present → stamp returns 0" \
    "STAMP_RC=0" <(printf '%s\n' "$out")
  assert_grep "TC-SE2E-STAMP-01b report present → PATCH happened (marker stamped onto report)" \
    "PATCHED=yes" <(printf '%s\n' "$out")

  # TC-SE2E-STAMP-02 (CORE REGRESSION): NO report comment → helper returns 1
  # (gate fails closed) and does NOT PATCH anything.
  out=$(_stamp_harness '
    gh() {
      local is_patch=0; for a in "$@"; do [[ "$a" == "PATCH" ]] && is_patch=1; done
      if [[ "$is_patch" == 1 ]]; then echo edited > "$PATCH_FLAG"; return 0; fi
      case "$*" in
        *"issues/42/comments"*) printf "" ;;   # list query → no report comment found (empty .id)
      esac
    }
  ')
  assert_grep "TC-SE2E-STAMP-02 no report comment → stamp returns non-zero (fail closed)" \
    "STAMP_RC=1" <(printf '%s\n' "$out")
  assert_grep "TC-SE2E-STAMP-02b no report comment → no PATCH attempted" \
    "PATCHED=no" <(printf '%s\n' "$out")

  # TC-SE2E-STAMP-03 (idempotent): report ALREADY carries the SHA marker → 0, no PATCH.
  out=$(_stamp_harness '
    gh() {
      local is_patch=0; for a in "$@"; do [[ "$a" == "PATCH" ]] && is_patch=1; done
      if [[ "$is_patch" == 1 ]]; then echo edited > "$PATCH_FLAG"; return 0; fi
      case "$*" in
        *"issues/42/comments"*) echo 99 ;;
        *"issues/comments/99"*) printf "## E2E Verification Report\n<!-- e2e-evidence: complete sha=\"deadbeefcafe\" -->" ;;
      esac
    }
  ')
  assert_grep "TC-SE2E-STAMP-03 already-stamped report → returns 0 (idempotent)" \
    "STAMP_RC=0" <(printf '%s\n' "$out")
  assert_grep "TC-SE2E-STAMP-03b already-stamped report → no redundant PATCH" \
    "PATCHED=no" <(printf '%s\n' "$out")

  # TC-SE2E-STAMP-04 (source-of-truth, the codex finding): the wrapper must NOT
  # post a standalone marker-only `gh pr comment … <!-- e2e-evidence: complete
  # sha=… -->` for the browser SHA marker — it routes the stamp through
  # _stamp_browser_evidence_marker (which edits the report) instead. Check that
  # no `gh pr comment` body line in the wrapper is a bare e2e-evidence marker.
  if grep -nE 'gh pr comment .*--body "<!-- e2e-evidence: complete sha=' "$WRAPPER" >/dev/null 2>&1 \
     || grep -nE '^\s*--body "<!-- e2e-evidence: complete sha=' "$WRAPPER" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC}: TC-SE2E-STAMP-04 wrapper still posts a marker-only e2e-evidence comment"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${NC}: TC-SE2E-STAMP-04 wrapper does not post a marker-only e2e-evidence comment"
    PASS=$((PASS + 1))
  fi
  assert_grep "TC-SE2E-STAMP-05 wrapper calls _stamp_browser_evidence_marker in the browser lane" \
    '_stamp_browser_evidence_marker' "$WRAPPER"
  assert_grep "TC-SE2E-STAMP-06 stamp failure forces E2E FAIL (no marker-only pass)" \
    'if ! _stamp_browser_evidence_marker; then' "$WRAPPER"
  assert_grep "TC-SE2E-STAMP-07 helper PATCHes the report comment in place (REST edit)" \
    'gh api -X PATCH .*issues/comments' "$E2E_LIB"
fi

# ---------------------------------------------------------------------------
echo "=== TC-SE2E-REG: pre-hook invoked EXACTLY ONCE per N=3 round (CRITICAL) ==="
# ---------------------------------------------------------------------------
# The N×-build regression this design exists to kill. The lane runs in Phase A
# BEFORE any fan-out, so the pre-hook runs once regardless of agent count.
if [[ -f "$E2E_LIB" ]]; then
  REGTMP=$(mktemp -d)
  REGCOUNTER="$REGTMP/prehook.count"; : > "$REGCOUNTER"
  REGOUT=$(env -i PATH="$PATH" COUNTER="$REGCOUNTER" bash -c '
    set -uo pipefail
    source "'"$E2E_LIB"'"
    log() { :; }
    export PR_NUMBER=42 REPO=owner/repo PR_HEAD_SHA=deadbeefcafe
    gh() { :; }
    _fetch_sha_evidence() { return 0; }
    export E2E_COMMAND_PRE_HOOKS_RENDERED="echo build >> \"$COUNTER\""
    export E2E_COMMAND_RENDERED="exit 0"
    export E2E_COMMAND_EVIDENCE_PARSER_RENDERED="printf %s \"## E2E
<!-- e2e-evidence: complete sha=\\\"deadbeefcafe\\\" -->\""
    # Simulate an N=3 review round: the E2E lane runs ONCE up front, then 3
    # review agents would fan out (they no longer run E2E at all).
    _run_command_e2e_lane "$COUNTER.rc"
    # (review fan-out: 3 PURE review agents — no E2E execution; nothing here)
    echo "PREHOOK_CALLS=$(wc -l < "$COUNTER" | tr -d " ")"
  ')
  assert_eq "TC-SE2E-REG-01 pre-hook invoked exactly once for N=3 round" \
    "PREHOOK_CALLS=1" "$(printf '%s\n' "$REGOUT" | grep '^PREHOOK_CALLS=')"
fi

# ---------------------------------------------------------------------------
echo "=== TC-SE2E-AGG: aggregation truth table (E2E gate ∧ review unanimity) ==="
# ---------------------------------------------------------------------------
# The wrapper's final decision: final PASS ≡ (E2E inactive OR gate==pass) AND
# review-unanimity==pass. Drive a tiny pure compose harness using the real
# _aggregate_review_verdicts for the review side and _classify_e2e_gate for E2E.
if [[ -f "$E2E_LIB" && -f "$AGG_LIB" ]]; then
  _compose() {
    # $1 = e2e_active(true|false) $2 = e2e_rc $3 = e2e_evidence $4.. = review verdicts
    local active="$1" rc="$2" ev="$3"; shift 3
    env -i PATH="$PATH" bash -c "
      source '$E2E_LIB'; source '$AGG_LIB'
      review=\$(_aggregate_review_verdicts $*)
      if [[ '$active' == 'false' ]]; then gate='pass'; else gate=\$(_classify_e2e_gate '$rc' '$ev'); fi
      if [[ \"\$gate\" == 'pass' && \"\$review\" == 'pass' ]]; then echo PASS;
      elif [[ \"\$gate\" == 'block-nonsubstantive' ]]; then echo REQUEUE;
      else echo FAIL; fi
    "
  }
  assert_eq "TC-SE2E-AGG-01 E2E pass + review unanimous-pass → PASS" \
    "PASS" "$(_compose true 0 1 pass pass)"
  assert_eq "TC-SE2E-AGG-02 E2E fail + review unanimous-pass → FAIL (gate overrides)" \
    "FAIL" "$(_compose true 1 0 pass pass)"
  assert_eq "TC-SE2E-AGG-03 E2E pass + one blocking review → FAIL" \
    "FAIL" "$(_compose true 0 1 pass fail)"
  assert_eq "TC-SE2E-AGG-04 E2E pass + all review unavailable → FAIL" \
    "FAIL" "$(_compose true 0 1 unavailable unavailable)"
  assert_eq "TC-SE2E-AGG-05 E2E inactive + review unanimous-pass → PASS (no gate)" \
    "PASS" "$(_compose false 0 0 pass pass)"
  assert_eq "TC-SE2E-AGG-06 E2E configured but no evidence (rc0) → REQUEUE non-substantive" \
    "REQUEUE" "$(_compose true 0 0 pass pass)"
fi

# ---------------------------------------------------------------------------
echo "=== TC-SE2E-SRC: source-of-truth greps (wrapper + build_review_prompt) ==="
# ---------------------------------------------------------------------------
[[ -f "$WRAPPER" ]] || { echo -e "  ${RED}FAIL${NC}: $WRAPPER not found"; FAIL=$((FAIL + 1)); }
if [[ -f "$WRAPPER" ]]; then
  assert_grep "TC-SE2E-SRC-01 wrapper sources lib-review-e2e.sh" \
    'source .*lib-review-e2e\.sh' "$WRAPPER"

  # TC-SE2E-SRC-02: the E2E lane runs BEFORE the fan-out loop. Anchor on the
  # ACTUAL lane-dispatch call (_run_command_e2e_lane — the command-mode lane,
  # which is the first lane call in the Phase-A block) and require it to precede
  # the fan-out `for` loop. (A non-matching probe like `_run_e2e_lane` would make
  # this vacuous — lane_line=0 always < fanout_line — so we grep the real name.)
  lane_line=$(grep -nE '_run_command_e2e_lane "\$_E2E_RC_FILE"' "$WRAPPER" | head -1 | cut -d: -f1)
  fanout_line=$(grep -nE '^for _agent in "\$\{REVIEW_AGENTS_LIST' "$WRAPPER" | head -1 | cut -d: -f1)
  # Guard against a vacuous pass: lane_line MUST be a real, non-zero line number.
  if [[ -n "$lane_line" && "$lane_line" -gt 0 ]]; then
    assert_lt "TC-SE2E-SRC-02 E2E command-lane call precedes the fan-out loop" \
      "$lane_line" "${fanout_line:-0}"
  else
    echo -e "  ${RED}FAIL${NC}: TC-SE2E-SRC-02 could not locate the _run_command_e2e_lane call"
    FAIL=$((FAIL + 1))
  fi

  # TC-SE2E-SRC-03: command-mode lane is shell — the _run_command_e2e_lane +
  # _run_command_e2e_verify function BODIES do NOT call run_agent (only the
  # browser lane uses run_agent, and only its doc comment may mention it). Scope
  # the check to the command-lane functions (extracted via awk) so a comment
  # elsewhere in the lib mentioning run_agent doesn't false-fail.
  CMD_LANE_FNS=$(awk '/^_run_command_e2e_lane\(\) \{/,/^\}/; /^_run_command_e2e_verify\(\) \{/,/^\}/' "$E2E_LIB")
  if printf '%s' "$CMD_LANE_FNS" | grep -qE 'run_agent'; then
    echo -e "  ${RED}FAIL${NC}: TC-SE2E-SRC-03 command E2E lane calls run_agent (must be pure shell)"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${NC}: TC-SE2E-SRC-03 command E2E lane is shell (no run_agent in the command-lane functions)"
    PASS=$((PASS + 1))
  fi

  # TC-SE2E-SRC-04: command-mode lane runs under setsid + timeout --kill-after.
  assert_grep "TC-SE2E-SRC-04 command lane uses setsid" \
    'setsid' "$E2E_LIB"
  assert_grep "TC-SE2E-SRC-04b command lane uses timeout --kill-after" \
    'timeout --kill-after' "$E2E_LIB"

  # TC-SE2E-SRC-05: the E2E lane PGID is in the SIGTERM trap kill-set + reaper.
  assert_grep "TC-SE2E-SRC-05 E2E lane PGID added to reaper arg list" \
    '_E2E_LANE_PGID' "$WRAPPER"

  # TC-SE2E-SRC-06: build_review_prompt no longer contains the E2E EXECUTION block.
  # Extract the build_review_prompt function body and assert the execution-block
  # markers are gone.
  PROMPT_FN=$(awk '/^build_review_prompt\(\) \{/,/^\}/' "$WRAPPER")
  if printf '%s' "$PROMPT_FN" | grep -qE 'Run pre-hooks|timeout \$\{E2E_COMMAND_TIMEOUT|E2E_COMMAND_RENDERED'; then
    echo -e "  ${RED}FAIL${NC}: TC-SE2E-SRC-06 build_review_prompt still contains the E2E execution block"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${NC}: TC-SE2E-SRC-06 build_review_prompt drops the E2E execution block"
    PASS=$((PASS + 1))
  fi

  # TC-SE2E-SRC-07: the review prompt tells agents to READ the posted evidence.
  if printf '%s' "$PROMPT_FN" | grep -qiE 'e2e.evidence|evidence comment|posted evidence'; then
    echo -e "  ${GREEN}PASS${NC}: TC-SE2E-SRC-07 review prompt instructs reading the posted evidence"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-SE2E-SRC-07 review prompt does not reference the posted evidence"
    FAIL=$((FAIL + 1))
  fi

  # TC-SE2E-SRC-08: gate-fail path emits a verdict trailer + routes pending-dev
  # and there is NO fan-out between gate-fail and that route. We assert the
  # gate-fail block appears before the fan-out loop (same as SRC-02) AND emits a
  # trailer — i.e. a known-bad PR is failed without spawning N agents.
  assert_grep "TC-SE2E-SRC-08 E2E gate references INV-46" \
    'INV-46' "$WRAPPER"

  # TC-SE2E-SRC-09: browser-mode lane is ONE run_agent + wrapper stamps the SHA marker.
  assert_grep "TC-SE2E-SRC-09 browser lane stamps the SHA marker in the wrapper" \
    'e2e-evidence: complete sha=' "$WRAPPER"

  # TC-SE2E-SRC-11: _classify_e2e_gate defined in the lib; gate placed before the
  # INV-44 mergeable block.
  assert_grep "TC-SE2E-SRC-11 _classify_e2e_gate defined in lib" \
    '_classify_e2e_gate\(\)' "$E2E_LIB"
  gate_call=$(grep -nE '_classify_e2e_gate ' "$WRAPPER" | head -1 | cut -d: -f1)
  merge_block=$(grep -nE 'Mergeable hard gate \(INV-44' "$WRAPPER" | head -1 | cut -d: -f1)
  assert_lt "TC-SE2E-SRC-11b E2E gate call precedes INV-44 mergeable block" \
    "${gate_call:-0}" "${merge_block:-0}"

  # TC-SE2E-SRC-10: bash -n parses the wrapper + lib clean.
  if bash -n "$WRAPPER" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: TC-SE2E-SRC-10 bash -n wrapper clean"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-SE2E-SRC-10 bash -n wrapper FAILED"; FAIL=$((FAIL + 1))
  fi
  if bash -n "$E2E_LIB" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: TC-SE2E-SRC-10b bash -n lib clean"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-SE2E-SRC-10b bash -n lib FAILED"; FAIL=$((FAIL + 1))
  fi
fi

# ---------------------------------------------------------------------------
echo "=== TC-SE2E-DOC: doc presence (INV-46 + flow + ref) ==="
# ---------------------------------------------------------------------------
assert_grep "TC-SE2E-DOC-01 INV-46 entry in invariants.md" \
  'INV-46' "$INVARIANTS"
assert_grep "TC-SE2E-DOC-02 review-agent-flow.md documents the sequential E2E lane" \
  'INV-46|sequential E2E|E2E lane' "$FLOW"
assert_grep "TC-SE2E-DOC-03 e2e-command-mode.md updated for the wrapper-run lane" \
  'INV-46|run.{0,4}once|wrapper.{0,12}lane' "$REF"

# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo -e "  ${GREEN}PASS: $PASS${NC}"
echo -e "  ${RED}FAIL: $FAIL${NC}"
[[ "$FAIL" -eq 0 ]] || exit 1
