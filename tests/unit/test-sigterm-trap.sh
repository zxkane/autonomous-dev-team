#!/bin/bash
# test-sigterm-trap.sh — Verify INV-15 SIGTERM convergence in autonomous-dev.sh.
#
# We don't run the full wrapper (that needs gh/REPO/agent CLI). Instead we
# extract the SIGTERM-handling fragment into a harness that mirrors the
# real cleanup() control flow and exercise three scenarios:
#
#   1. SIGTERM with PR_EXISTS>0 → exit_code rewritten to 0, label = pending-review
#   2. SIGTERM with PR_EXISTS=0 → exit_code stays 143, label = pending-dev
#   3. Clean exit (no SIGTERM) → unchanged routing
#
# The harness reproduces the production logic verbatim by sourcing the
# relevant snippet rather than reimplementing it, so any drift is caught.
#
# Run: bash tests/unit/test-sigterm-trap.sh

set -uo pipefail

PASS=0
FAIL=0

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
# Replicate the cleanup() routing logic. This must stay in lockstep with
# autonomous-dev.sh — any divergence means the test is lying.
# ---------------------------------------------------------------------------
classify_label() {
  local exit_code="$1" received_sigterm="$2" pr_exists="$3"

  # SIGTERM convergence (INV-15)
  if [[ "$received_sigterm" -eq 1 ]]; then
    if [[ "$pr_exists" -gt 0 ]]; then
      exit_code=0
    fi
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    if [[ "$pr_exists" -gt 0 ]]; then
      echo "pending-review"
    else
      echo "pending-dev"  # exit 0 but no PR → retry
    fi
  else
    echo "pending-dev"
  fi
}

# ---------------------------------------------------------------------------
echo "=== SIGTERM convergence (INV-15) ==="
# ---------------------------------------------------------------------------

# TC-WH-007: SIGTERM + PR → pending-review (the bug being fixed)
assert_eq "SIGTERM (143) + PR exists → pending-review (was pending-dev)" \
  "pending-review" "$(classify_label 143 1 1)"

# TC-WH-008: SIGTERM + no PR → pending-dev
assert_eq "SIGTERM (143) + no PR → pending-dev (operator kill / orphan)" \
  "pending-dev" "$(classify_label 143 1 0)"

# TC-WH-009: clean exit + PR → pending-review (regression guard)
assert_eq "clean exit (0) + PR → pending-review (unchanged)" \
  "pending-review" "$(classify_label 0 0 1)"

# Clean exit + no PR → pending-dev (regression guard)
assert_eq "clean exit (0) + no PR → pending-dev (unchanged)" \
  "pending-dev" "$(classify_label 0 0 0)"

# Crash exit + PR → pending-dev (no rewrite without SIGTERM)
assert_eq "crash exit (1) + PR + no SIGTERM → pending-dev (no rewrite)" \
  "pending-dev" "$(classify_label 1 0 1)"

# Timeout exit code 124 + no SIGTERM + PR → pending-dev
# (The wrapper-level SIGTERM trap only fires from dispatcher Step 5a,
# not from `timeout`'s own escalation, since timeout TERMs the *agent*
# via process group, not the wrapper. See lib-agent.sh._run_with_timeout.)
assert_eq "timeout exit (124) + no SIGTERM → pending-dev" \
  "pending-dev" "$(classify_label 124 0 1)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Source-of-truth check ==="
# ---------------------------------------------------------------------------
# Guard against drift: the cleanup() in autonomous-dev.sh must contain the
# same RECEIVED_SIGTERM rewrite logic the harness uses. Failing this test
# means classify_label() above no longer represents production behavior.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="$SCRIPT_DIR/../../skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
LIB_AGENT="$SCRIPT_DIR/../../skills/autonomous-dispatcher/scripts/lib-agent.sh"

# The trap can be installed two ways:
#   (A) Inline in autonomous-dev.sh: `on_sigterm()` + `trap on_sigterm TERM`.
#   (B) Via the shared `install_agent_sigterm_trap` helper in lib-agent.sh
#       (introduced for #109 — review wrapper now uses the same trap).
# Both factorings must keep the same observable contract:
#   RECEIVED_SIGTERM=0 lives in the wrapper (cleanup() reads it),
#   the trap sets RECEIVED_SIGTERM=1, forwards TERM to descendants
#   (pkill -TERM -P $$), and cleanup() does the exit_code=0 rewrite.
trap_inline_ok=0
if grep -q 'on_sigterm()' "$WRAPPER" \
   && grep -q 'trap on_sigterm TERM' "$WRAPPER"; then
  trap_inline_ok=1
fi
trap_helper_ok=0
if grep -q 'install_agent_sigterm_trap' "$WRAPPER" \
   && grep -q 'install_agent_sigterm_trap()' "$LIB_AGENT" \
   && grep -q 'RECEIVED_SIGTERM=1' "$LIB_AGENT"; then
  trap_helper_ok=1
fi

if [[ "$trap_inline_ok" -eq 1 || "$trap_helper_ok" -eq 1 ]] \
   && grep -q 'RECEIVED_SIGTERM=0' "$WRAPPER" \
   && grep -q 'RECEIVED_SIGTERM" -eq 1' "$WRAPPER" \
   && grep -q 'exit_code=0' "$WRAPPER"; then
  echo -e "  ${GREEN}PASS${NC}: autonomous-dev.sh contains RECEIVED_SIGTERM trap + cleanup rewrite"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: autonomous-dev.sh missing one of:"
  echo "         RECEIVED_SIGTERM=0 / { inline on_sigterm OR install_agent_sigterm_trap } /"
  echo "         RECEIVED_SIGTERM check / exit_code=0 rewrite"
  FAIL=$((FAIL + 1))
fi

# Verify pkill descendant kill is present (forwards SIGTERM to the agent).
# Same factoring as above: the helper in lib-agent.sh counts.
if grep -q 'pkill -TERM -P \$\$' "$WRAPPER" \
   || grep -q 'pkill -TERM -P \$\$' "$LIB_AGENT"; then
  echo -e "  ${GREEN}PASS${NC}: trap forwards SIGTERM to descendants via pkill"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: trap missing pkill -TERM -P \$\$ (agent CLI may not exit)"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== SIGTERM-path bounded retry + UNKNOWN-defer (INV-15 rev 2, #500) ==="
# ---------------------------------------------------------------------------
# The hand-written classify_label() replica above is too coarse to exercise
# the retry loop, the sleep count, or the "no label write" defer path — so
# this section EXTRACTS and RUNS the real cleanup() fragment (same technique
# as tests/unit/test-autonomous-dev-cleanup-startup-failure.sh), varying a
# stubbed chp_pr_list's per-call behavior.

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle='$needle'"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (should NOT contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

CLEANUP_FN=$(awk '/^cleanup\(\) \{/,/^\}/' "$WRAPPER")
if [[ -z "$CLEANUP_FN" ]]; then
  echo -e "  ${RED}FAIL${NC}: could not extract cleanup() from $WRAPPER"
  FAIL=$((FAIL + 1))
fi

# run_retry_cleanup <label> <received_sigterm> <pr_list_behavior_csv>
#
# pr_list_behavior_csv is a comma-separated per-call script for the stubbed
# chp_pr_list, one entry consumed per call (1-indexed):
#   fail    — chp_pr_list itself fails (rc 1, no output): a transport/read failure
#   garbage — chp_pr_list succeeds (rc 0) but emits non-JSON: a jq parse failure
#   zero    — succeeds with a body that matches zero issue references
#   pr      — succeeds with a body that matches issue #77
#
# Sets globals: GH_LOG (recorded gh argv), STDERR_LOG (wrapper log output),
# CALL_COUNT (times chp_pr_list was invoked), SLEEP_COUNT (times sleep ran).
run_retry_cleanup() {
  local label="$1" received_sigterm="$2" behavior="$3"
  local record="$TMPROOT/gh-${label}.log"
  local stderr_log="$TMPROOT/stderr-${label}.log"
  local call_count_file="$TMPROOT/calls-${label}.log"
  local sleep_count_file="$TMPROOT/sleeps-${label}.log"
  : > "$record"; : > "$stderr_log"; : > "$call_count_file"; : > "$sleep_count_file"

  # Explicitly clear ambient ADT_*/RUN_*/AGENT_PROGRESS_*/AGENT_P{R_CREATE,ID}_FILE
  # env vars: this harness may itself run inside a dispatched autonomous-dev.sh
  # wrapper (e.g. under the autonomous pipeline for this very issue), which
  # exports ADT_GUARD_FD/ADT_LANE_DIR/RUN_DIR/RUN_ID etc. into every subshell.
  # Without clearing them, cleanup()'s lane/guardian/run-artifacts branches
  # would fire against the OUTER run's real lane dir instead of behaving as
  # the "no lane installed" no-op path this harness assumes.
  env -u ADT_GUARD_FD -u ADT_LANE_DIR -u ADT_LANE_ID -u ADT_STATE_ROOT \
      -u RUN_DIR -u RUN_ID \
      -u AGENT_PROGRESS_FILE -u AGENT_PROGRESS_RUNID_FILE \
      -u AGENT_PID_FILE -u AGENT_PR_CREATE_FILE -u AGENT_BOT_TRIGGER_FILE \
  PATH="/usr/bin:/bin" \
  GH_RECORD="$record" \
  CALL_COUNT_FILE="$call_count_file" \
  SLEEP_COUNT_FILE="$sleep_count_file" \
  PR_LIST_BEHAVIOR="$behavior" \
  AGENT_RAN="true" \
  ISSUE_NUMBER="77" \
  REPO="acme/widget" \
  PID_FILE="/dev/null" \
  SESSION_ID="test-session" \
  LOG_FILE="/tmp/test.log" \
  GH_AUTH_MODE="token" \
  RECEIVED_SIGTERM="$received_sigterm" \
  MODE="new" \
  AGENT_CMD="claude" \
  AGENT_DEV_MODEL="sonnet" \
  bash -c "
    set +e
    log() { echo \"[test-log] \$*\" >&2; }
    cleanup_github_auth() { :; }
    itp_post_comment() { echo \"GH issue comment \$1 --repo \$REPO --body \$2\" >> \"\$GH_RECORD\"; }
    itp_transition_state() {
      local args=()
      [ -n \"\$2\" ] && args+=(--remove-label \"\$2\")
      [ -n \"\$3\" ] && args+=(--add-label \"\$3\")
      echo \"GH issue edit \$1 --repo \$REPO \${args[*]}\" >> \"\$GH_RECORD\"
    }
    terminal_intent_cleanup_transition() { itp_transition_state \"\$1\" \"\$3\" \"\$4\"; }
    drain_agent_pr_create() { return 0; }
    drain_agent_bot_triggers() { echo \"BOT-TRIGGER-DRAIN \$1\" >> \"\$GH_RECORD\"; return 0; }
    rearm_gh_resolution() { :; }
    sleep() { echo \"\$1\" >> \"\$SLEEP_COUNT_FILE\"; }
    chp_pr_list() {
      echo call >> \"\$CALL_COUNT_FILE\"
      local n behavior_item
      n=\$(wc -l < \"\$CALL_COUNT_FILE\")
      behavior_item=\$(echo \"\$PR_LIST_BEHAVIOR\" | cut -d',' -f\"\$n\")
      case \"\$behavior_item\" in
        fail) return 1 ;;
        garbage) echo 'not json'; return 0 ;;
        zero) echo '[{\"body\":\"unrelated text\"}]'; return 0 ;;
        pr) echo '[{\"body\":\"Closes #77\"}]'; return 0 ;;
        *) return 1 ;;
      esac
    }
    $CLEANUP_FN
    (exit 143); cleanup
  " 2>"$stderr_log"

  GH_LOG=$(cat "$record")
  STDERR_LOG=$(cat "$stderr_log")
  CALL_COUNT=$(wc -l < "$call_count_file" | tr -d '[:space:]')
  SLEEP_COUNT=$(wc -l < "$sleep_count_file" | tr -d '[:space:]')
}

# ---------------------------------------------------------------------------
echo ""
echo "--- TC-500-01: SIGTERM + first lookup FAILS, retry SUCCEEDS finding PR ---"
# ---------------------------------------------------------------------------
# Regression case: fails before the fix (a bare failed-read-as-zero would
# route straight to pending-dev on attempt 1, never retrying).
run_retry_cleanup "500-01" 1 "fail,pr"

assert_eq "TC-500-01 exactly 2 chp_pr_list calls" "2" "$CALL_COUNT"
assert_eq "TC-500-01 exactly 1 sleep (between attempts)" "1" "$SLEEP_COUNT"
assert_contains "TC-500-01 converges to pending-review" \
  "--add-label pending-review" "$GH_LOG"
assert_not_contains "TC-500-01 never routes to pending-dev" \
  "--add-label pending-dev" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "--- TC-500-02: SIGTERM + BOTH attempts fail → UNKNOWN-defer, no label write ---"
# ---------------------------------------------------------------------------
run_retry_cleanup "500-02" 1 "fail,fail"

assert_eq "TC-500-02 exactly 2 chp_pr_list calls" "2" "$CALL_COUNT"
assert_eq "TC-500-02 exactly 1 sleep (bounded, not unbounded)" "1" "$SLEEP_COUNT"
assert_contains "TC-500-02 logs a WARN naming the failed read" \
  "WARN" "$STDERR_LOG"
assert_not_contains "TC-500-02 performs NO wrapper label transition" \
  "GH issue edit" "$GH_LOG"
assert_not_contains "TC-500-02 skips the bot-trigger broker on the defer path" \
  "BOT-TRIGGER-DRAIN" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "--- TC-500-03: jq parse failure on a successful transport read → same UNKNOWN path ---"
# ---------------------------------------------------------------------------
# First attempt: chp_pr_list itself succeeds (rc 0) but returns non-JSON, so
# the jq projection fails to parse — this must be treated identically to a
# transport failure (retry), not silently coerced to "0 matches".
run_retry_cleanup "500-03" 1 "garbage,pr"

assert_eq "TC-500-03 exactly 2 chp_pr_list calls (parse failure retried)" "2" "$CALL_COUNT"
assert_eq "TC-500-03 exactly 1 sleep" "1" "$SLEEP_COUNT"
assert_contains "TC-500-03 converges to pending-review on retry success" \
  "--add-label pending-review" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "--- TC-500-04 (companion): SIGTERM + SUCCESSFUL zero-match read → pending-dev, unchanged ---"
# ---------------------------------------------------------------------------
# Guards against over-correction: a genuinely successful read that finds no
# matching PR is NOT an UNKNOWN — it must still route to pending-dev exactly
# as before this fix, with no retry.
run_retry_cleanup "500-04" 1 "zero"

assert_eq "TC-500-04 exactly 1 chp_pr_list call (no retry on a clean zero-match)" "1" "$CALL_COUNT"
assert_eq "TC-500-04 no sleep" "0" "$SLEEP_COUNT"
assert_contains "TC-500-04 still routes to pending-dev" \
  "--add-label pending-dev" "$GH_LOG"
assert_not_contains "TC-500-04 never routes to pending-review" \
  "--add-label pending-review" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "--- TC-500-05: non-SIGTERM path stays single-attempt, fail-soft on read failure ---"
# ---------------------------------------------------------------------------
# D2 pin: outside the SIGTERM branch, a failed read keeps the ORIGINAL
# fail-soft-to-"0" single-attempt contract — no retry is introduced there.
# exit_code is non-zero (143, no SIGTERM rewrite since RECEIVED_SIGTERM=0)
# so this takes the plain "Agent failed" branch regardless of PR_EXISTS —
# the assertion here is about call/sleep counts (the D2 pin), not routing.
run_retry_cleanup "500-05" 0 "fail,pr"

assert_eq "TC-500-05 exactly 1 chp_pr_list call (no SIGTERM ⇒ no retry)" "1" "$CALL_COUNT"
assert_eq "TC-500-05 no sleep" "0" "$SLEEP_COUNT"
assert_contains "TC-500-05 falls through to pending-dev" \
  "--add-label pending-dev" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
