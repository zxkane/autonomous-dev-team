#!/bin/bash
# test-issue-402-session-report-teardown-resilience.sh — regression gate for
# issue #402.
#
# BUG: `cleanup()` posted the Agent Session Report (carrying the load-bearing
# `Dev Session ID:` marker) and performed the success-path label flip LATE —
# after the INV-79 brokers (drain_agent_pr_create / drain_agent_bot_triggers)
# and the PR-exists lookup. If the per-run auth shim dir (GH_WRAPPER_DIR)
# vanished mid-cleanup, bash's command hash for `gh` still pointed at the dead
# path (PATH is only re-searched when there is no cached location, never when
# a cached location stops existing) — every subsequent `gh` call in the
# wrapper's shell failed rc=127, losing BOTH the session report and the label
# flip. With no `Dev Session ID:` comment ever posted, a later review-FAIL
# against the same HEAD parks forever in the dispatcher's stale-verdict
# residual branch (extract_dev_session_id has nothing to extract).
#
# FIX (two layers, this file covers both):
#   Layer 1 — reorder: post the session report BEFORE the INV-79 brokers /
#             PR-exists lookup (it needs neither).
#   Layer 2 — gh-resolution resilience: detect a vanished GH_WRAPPER_DIR at
#             cleanup entry, `hash -d gh`, and strip the dead PATH entry so
#             bare `gh` falls back to the system binary.
#
# Layer 3 (the dispatcher self-heal extension) is covered by
# test-issue-402-dispatcher-self-heal.sh.
#
# Run: bash tests/unit/test-issue-402-session-report-teardown-resilience.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

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
    echo "      should NOT contain: '$needle'"
    FAIL=$((FAIL + 1))
  fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# ---------------------------------------------------------------------------
# TC-STR-001: source-order pin — the session-report post precedes the INV-79
# brokers in cleanup(). Block-scoped (grep the whole function body), not a
# fragile ±N-line proximity check.
# ---------------------------------------------------------------------------
echo "=== TC-STR-001: session-report post precedes drain_agent_pr_create / drain_agent_bot_triggers ==="

CLEANUP_FN=$(awk '/^cleanup\(\) \{/,/^\}/' "$WRAPPER")
if [[ -z "$CLEANUP_FN" ]]; then
  echo -e "${RED}FAIL${NC}: could not extract cleanup() from $WRAPPER"
  exit 1
fi

report_line=$(grep -n 'Agent Session Report (Dev)' <<<"$CLEANUP_FN" | tail -1 | cut -d: -f1)
pr_create_line=$(grep -n 'drain_agent_pr_create "\$ISSUE_NUMBER"' <<<"$CLEANUP_FN" | head -1 | cut -d: -f1)
bot_trigger_line=$(grep -n 'drain_agent_bot_triggers "\$ISSUE_NUMBER"' <<<"$CLEANUP_FN" | head -1 | cut -d: -f1)
pr_exists_line=$(grep -n 'local PR_EXISTS' <<<"$CLEANUP_FN" | head -1 | cut -d: -f1)

if [[ -n "$report_line" && -n "$pr_create_line" && -n "$bot_trigger_line" && -n "$pr_exists_line" ]] \
   && [[ "$report_line" -lt "$pr_create_line" ]] \
   && [[ "$report_line" -lt "$pr_exists_line" ]] \
   && [[ "$report_line" -lt "$bot_trigger_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-STR-001 session-report post (line $report_line) precedes drain_agent_pr_create ($pr_create_line), PR_EXISTS ($pr_exists_line), drain_agent_bot_triggers ($bot_trigger_line)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-STR-001 ordering violated (report=$report_line pr_create=$pr_create_line pr_exists=$pr_exists_line bot_trigger=$bot_trigger_line)"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# Regression harness — extends test-autonomous-dev-cleanup-startup-failure.sh's
# run_cleanup pattern with a shim dir that the harness can delete BEFORE
# invoking cleanup(), simulating the mid-run vanish. The stub `gh` lives at
# a SEPARATE "system" location so a successful PATH fallback is observable
# (a call that resolves through the vanished shim path fails rc=127; a call
# that falls back to the system stub succeeds and is recorded).
# ---------------------------------------------------------------------------
SHIM_DIR="$TMPROOT/shim"
SYSTEM_DIR="$TMPROOT/system-bin"
mkdir -p "$SHIM_DIR" "$SYSTEM_DIR"

cat > "$SYSTEM_DIR/gh" <<'EOF'
#!/bin/bash
echo "GH $*" >> "$GH_RECORD"
echo "GH_TOKEN_SEEN=${GH_TOKEN:-<unset>}" >> "$GH_RECORD"
exit 0
EOF
chmod +x "$SYSTEM_DIR/gh"

# The shim itself is a symlink to the system stub — mirrors production
# (GH_WRAPPER_DIR/gh -> gh-with-token-refresh.sh). Deleting the SHIM_DIR
# (not the symlink target) is what simulates the vanish.
ln -sf "$SYSTEM_DIR/gh" "$SHIM_DIR/gh"

run_cleanup_with_vanished_shim() {
  local label="$1" issue_num="$2" want_exit="$3"
  local record="$TMPROOT/gh-${label}.log"
  local stderr_log="$TMPROOT/stderr-${label}.log"
  : > "$record"
  : > "$stderr_log"

  # PATH: shim dir FIRST (as setup_github_auth would prepend it), system dir
  # second — so once the shim dir's `gh` disappears, a fresh PATH search
  # (post `hash -d`) finds the system stub next in line.
  PATH="$SHIM_DIR:$SYSTEM_DIR:$PATH" \
  GH_WRAPPER_DIR="$SHIM_DIR" \
  GH_RECORD="$record" \
  AGENT_RAN="true" \
  ISSUE_NUMBER="$issue_num" \
  REPO="acme/widget" \
  PID_FILE="/dev/null" \
  SESSION_ID="test-session-402" \
  LOG_FILE="/tmp/test.log" \
  GH_AUTH_MODE="token" \
  RECEIVED_SIGTERM=0 \
  MODE="new" \
  AGENT_CMD="claude" \
  AGENT_DEV_MODEL="sonnet" \
  GH_TOKEN="fresh-token-402" \
  bash -c "
    set +e
    log() { echo \"[test-log] \$*\" >&2; }
    cleanup_github_auth() { :; }
    itp_post_comment() { gh issue comment \"\$1\" --repo \"\$REPO\" --body \"\$2\"; }
    itp_transition_state() {
      local args=()
      [ -n \"\$2\" ] && args+=(--remove-label \"\$2\")
      [ -n \"\$3\" ] && args+=(--add-label \"\$3\")
      gh issue edit \"\$1\" --repo \"\$REPO\" \"\${args[@]}\"
    }
    terminal_intent_cleanup_transition() { itp_transition_state \"\$1\" \"\$3\" \"\$4\"; }
    chp_pr_list() { gh pr list \"\$@\"; printf %s '[{\"body\":\"Closes #402\"}]'; }
    drain_agent_pr_create() { gh drain-pr-create-probe; return 0; }
    drain_agent_bot_triggers() { gh drain-bot-triggers-probe; return 0; }
    _strip_path_entry() {
      local path=\"\$1\" entry=\"\$2\"
      [[ -n \"\$entry\" ]] || { printf '%s' \"\$path\"; return 0; }
      local out='' seg
      local IFS=':'
      for seg in \$path; do
        [[ \"\$seg\" == \"\$entry\" ]] && continue
        if [[ -z \"\$out\" ]]; then out=\"\$seg\"; else out=\"\${out}:\${seg}\"; fi
      done
      printf '%s' \"\$out\"
    }
    # [INV-111] (#402 review round-1 [P1]) same shared helper cleanup() now
    # calls before EACH load-bearing write — real definition, byte-identical
    # to lib-auth.sh (this harness stubs lib-auth's OTHER functions but must
    # exercise the REAL rearm logic to prove the per-write re-arm works).
    rearm_gh_resolution() {
      hash -d gh 2>/dev/null || true
      if [[ -n \"\${GH_WRAPPER_DIR:-}\" ]] && [[ ! -x \"\${GH_WRAPPER_DIR}/gh\" ]]; then
        echo \"WARN: [INV-111] GH_WRAPPER_DIR (\${GH_WRAPPER_DIR}) is gone — dropped the stale 'gh' command hash and PATH entry so this write falls back to the system 'gh'.\" >&2
        PATH=\"\$(_strip_path_entry \"\$PATH\" \"\$GH_WRAPPER_DIR\")\"
        export PATH
      fi
    }
    $CLEANUP_FN
    # Prime bash's command hash for 'gh' by resolving it once BEFORE the
    # shim vanishes — mirrors production, where auth setup (setup_github_auth)
    # and/or the agent's own bare 'gh' calls already resolved+hashed the
    # shim path long before cleanup() runs. Without this priming call, PATH
    # would simply be re-searched fresh on the next 'gh' invocation and the
    # bug this test guards against (a STALE hash surviving the vanish) could
    # never reproduce.
    gh --help >/dev/null 2>&1
    # Simulate the vanish AFTER auth setup but BEFORE cleanup() runs (the
    # exact race window the issue describes) — remove the shim dir so the
    # hashed 'gh' at \$SHIM_DIR/gh is gone.
    rm -rf '$SHIM_DIR'
    (exit $want_exit); cleanup
  " 2>"$stderr_log"
  GH_LOG=$(cat "$record" 2>/dev/null || true)
  STDERR_LOG=$(cat "$stderr_log")
}

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-STR-002: shim dir vanishes mid-cleanup → session report AND label flip still land ==="
# ---------------------------------------------------------------------------
run_cleanup_with_vanished_shim "002" "402" 0

assert_contains "TC-STR-002 session-report comment posted (via system gh fallback)" \
  "Agent Session Report (Dev)" "$GH_LOG"
assert_contains "TC-STR-002 Dev Session ID marker present" \
  "test-session-402" "$GH_LOG"
assert_contains "TC-STR-002 label flip to pending-review landed" \
  "--add-label pending-review" "$GH_LOG"
assert_contains "TC-STR-002 stderr shows the INV-111 vanished-shim WARNING" \
  "INV-111" "$STDERR_LOG"
assert_not_contains "TC-STR-002 no rc=127 'No such file or directory' error" \
  "No such file or directory" "$STDERR_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-STR-010/012: the fresh GH_TOKEN reaches the system gh fallback ==="
# ---------------------------------------------------------------------------
assert_contains "TC-STR-010/012 system gh stub observed the fresh GH_TOKEN" \
  "GH_TOKEN_SEEN=fresh-token-402" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-STR-011: shim dir INTACT (normal case) → no hash -d / PATH mutation noise ==="
# ---------------------------------------------------------------------------
run_cleanup_intact_shim() {
  local record="$TMPROOT/gh-intact.log"
  local stderr_log="$TMPROOT/stderr-intact.log"
  : > "$record"; : > "$stderr_log"
  # Recreate the shim (TC-STR-002 removed it).
  mkdir -p "$SHIM_DIR"
  ln -sf "$SYSTEM_DIR/gh" "$SHIM_DIR/gh"

  PATH="$SHIM_DIR:$SYSTEM_DIR:$PATH" \
  GH_WRAPPER_DIR="$SHIM_DIR" \
  GH_RECORD="$record" \
  AGENT_RAN="true" \
  ISSUE_NUMBER="403" \
  REPO="acme/widget" \
  PID_FILE="/dev/null" \
  SESSION_ID="test-session-intact" \
  LOG_FILE="/tmp/test.log" \
  GH_AUTH_MODE="token" \
  RECEIVED_SIGTERM=0 \
  MODE="new" \
  AGENT_CMD="claude" \
  AGENT_DEV_MODEL="sonnet" \
  GH_TOKEN="fresh-token-intact" \
  bash -c "
    set +e
    log() { echo \"[test-log] \$*\" >&2; }
    cleanup_github_auth() { :; }
    itp_post_comment() { gh issue comment \"\$1\" --repo \"\$REPO\" --body \"\$2\"; }
    itp_transition_state() {
      local args=()
      [ -n \"\$2\" ] && args+=(--remove-label \"\$2\")
      [ -n \"\$3\" ] && args+=(--add-label \"\$3\")
      gh issue edit \"\$1\" --repo \"\$REPO\" \"\${args[@]}\"
    }
    terminal_intent_cleanup_transition() { itp_transition_state \"\$1\" \"\$3\" \"\$4\"; }
    chp_pr_list() { gh pr list \"\$@\"; printf %s '[]'; }
    drain_agent_pr_create() { gh drain-pr-create-probe; return 0; }
    drain_agent_bot_triggers() { gh drain-bot-triggers-probe; return 0; }
    $CLEANUP_FN
    (exit 0); cleanup
  " 2>"$stderr_log"
  GH_LOG_INTACT=$(cat "$record" 2>/dev/null || true)
  STDERR_LOG_INTACT=$(cat "$stderr_log")
}
run_cleanup_intact_shim

assert_not_contains "TC-STR-011 no INV-111 WARNING when shim is intact" \
  "INV-111" "$STDERR_LOG_INTACT"
assert_contains "TC-STR-011 session report still posted normally" \
  "Agent Session Report (Dev)" "$GH_LOG_INTACT"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-STR-013: shim vanishes DURING the no-PR retry comment → pending-dev flip still lands (round-3 [P1]) ==="
# ---------------------------------------------------------------------------
# The no-PR branch (exit 0, PR_EXISTS=0) does itp_post_comment then the
# LOAD-BEARING itp_transition_state. A successful comment re-hashes `gh`
# back to the shim path — so a shim vanish in the window BETWEEN those two
# writes strands the flip (issue stuck `in-progress`) unless a fresh rearm
# precedes the flip. Simulate the mid-window vanish from INSIDE the gh stub:
# the retry-comment invocation itself deletes the shim dir after recording.
run_cleanup_vanish_mid_retry_comment() {
  local record="$TMPROOT/gh-013.log"
  local stderr_log="$TMPROOT/stderr-013.log"
  : > "$record"; : > "$stderr_log"
  # Recreate the shim as a REAL script (not a symlink): it must delete its
  # own dir when it sees the retry comment, then still record the call.
  mkdir -p "$SHIM_DIR"
  cat > "$SHIM_DIR/gh" <<EOF
#!/bin/bash
echo "GH \$*" >> "\$GH_RECORD"
echo "GH_TOKEN_SEEN=\${GH_TOKEN:-<unset>}" >> "\$GH_RECORD"
case "\$*" in *"no PR was created"*) rm -rf "$SHIM_DIR" ;; esac
exit 0
EOF
  chmod +x "$SHIM_DIR/gh"

  PATH="$SHIM_DIR:$SYSTEM_DIR:$PATH" \
  GH_WRAPPER_DIR="$SHIM_DIR" \
  GH_RECORD="$record" \
  AGENT_RAN="true" \
  ISSUE_NUMBER="413" \
  REPO="acme/widget" \
  PID_FILE="/dev/null" \
  SESSION_ID="test-session-013" \
  LOG_FILE="/tmp/test.log" \
  GH_AUTH_MODE="token" \
  RECEIVED_SIGTERM=0 \
  MODE="new" \
  AGENT_CMD="claude" \
  AGENT_DEV_MODEL="sonnet" \
  GH_TOKEN="fresh-token-013" \
  bash -c "
    set +e
    log() { echo \"[test-log] \$*\" >&2; }
    cleanup_github_auth() { :; }
    itp_post_comment() { gh issue comment \"\$1\" --repo \"\$REPO\" --body \"\$2\"; }
    itp_transition_state() {
      local args=()
      [ -n \"\$2\" ] && args+=(--remove-label \"\$2\")
      [ -n \"\$3\" ] && args+=(--add-label \"\$3\")
      gh issue edit \"\$1\" --repo \"\$REPO\" \"\${args[@]}\"
    }
    terminal_intent_cleanup_transition() { itp_transition_state \"\$1\" \"\$3\" \"\$4\"; }
    chp_pr_list() { gh pr list \"\$@\"; printf %s '[]'; }   # empty array = the no-PR branch
    drain_agent_pr_create() { gh drain-pr-create-probe; return 0; }
    drain_agent_bot_triggers() { gh drain-bot-triggers-probe; return 0; }
    _strip_path_entry() {
      local path=\"\$1\" entry=\"\$2\"
      [[ -n \"\$entry\" ]] || { printf '%s' \"\$path\"; return 0; }
      local out='' seg
      local IFS=':'
      for seg in \$path; do
        [[ \"\$seg\" == \"\$entry\" ]] && continue
        if [[ -z \"\$out\" ]]; then out=\"\$seg\"; else out=\"\${out}:\${seg}\"; fi
      done
      printf '%s' \"\$out\"
    }
    # Real rearm helper, byte-identical to lib-auth.sh (same rationale as
    # the TC-STR-002 harness: stub the rest, exercise the REAL rearm).
    rearm_gh_resolution() {
      hash -d gh 2>/dev/null || true
      if [[ -n \"\${GH_WRAPPER_DIR:-}\" ]] && [[ ! -x \"\${GH_WRAPPER_DIR}/gh\" ]]; then
        echo \"WARN: [INV-111] GH_WRAPPER_DIR (\${GH_WRAPPER_DIR}) is gone — dropped the stale 'gh' command hash and PATH entry so this write falls back to the system 'gh'.\" >&2
        PATH=\"\$(_strip_path_entry \"\$PATH\" \"\$GH_WRAPPER_DIR\")\"
        export PATH
      fi
    }
    $CLEANUP_FN
    # Prime the hash on the SHIM path (mirrors production).
    gh --help >/dev/null 2>&1
    (exit 0); cleanup
  " 2>"$stderr_log"
  GH_LOG_013=$(cat "$record" 2>/dev/null || true)
  STDERR_LOG_013=$(cat "$stderr_log")
}
run_cleanup_vanish_mid_retry_comment

assert_contains "TC-STR-013 the no-PR retry comment landed (pre-vanish)" \
  "no PR was created" "$GH_LOG_013"
assert_contains "TC-STR-013 the pending-dev label flip STILL landed after the mid-window vanish" \
  "--add-label pending-dev" "$GH_LOG_013"
assert_not_contains "TC-STR-013 no rc=127 'No such file or directory' on the flip" \
  "No such file or directory" "$STDERR_LOG_013"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
