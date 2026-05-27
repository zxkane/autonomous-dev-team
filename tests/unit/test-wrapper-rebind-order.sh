#!/bin/bash
# test-wrapper-rebind-order.sh — Behavioral regression for INV-37 / INV-38
# rebind order. Asserts that after sourcing both lib-agent.sh AND
# lib-auth.sh in the order the wrappers do, the per-side rebind survives
# (i.e. AGENT_CMD reflects the requested side).
#
# Bug fixed by this test (discovered 2026-05-26):
#   autonomous-review.sh used to rebind AGENT_CMD="$AGENT_REVIEW_CMD"
#   AFTER `source lib-agent.sh` but BEFORE `source lib-auth.sh`.
#   lib-auth.sh transitively re-sources autonomous.conf via
#   lib-config.sh::load_autonomous_conf, and the conf's unconditional
#   `AGENT_CMD="claude"` line silently overwrote the rebind. Result:
#   review wrapper invoked `claude` even though the operator had set
#   AGENT_REVIEW_CMD=kiro.
#
# Run: bash tests/unit/test-wrapper-rebind-order.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS_DIR="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
DEV_WRAPPER="$SCRIPTS_DIR/autonomous-dev.sh"
REVIEW_WRAPPER="$SCRIPTS_DIR/autonomous-review.sh"

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

# -----------------------------------------------------------------------
# Helper: simulate the wrapper's source order in a sandbox conf, then
# print the post-rebind state.
#
# We extract just the source/rebind block from the actual wrapper file
# (not a separately-maintained copy) so the test stays in lock-step
# with the wrapper.
# -----------------------------------------------------------------------
simulate_wrapper() {
  local wrapper="$1"
  local conf_dir="$2"
  # Pull lines 22..40 — the source/rebind block in the wrappers as of
  # this fix. Slightly over-greedy is fine; we just need everything from
  # `source lib-agent.sh` through the last rebind.
  local extract
  extract=$(sed -n '22,40p' "$wrapper")

  bash -c "
    set -uo pipefail
    SCRIPT_DIR='$conf_dir'
    AUTONOMOUS_CONF='$conf_dir/autonomous.conf'
    $extract
    echo \"AGENT_CMD=\$AGENT_CMD\"
    echo \"AGENT_LAUNCHER_ARGV_count=\${#AGENT_LAUNCHER_ARGV[@]}\"
  " 2>&1
}

# -----------------------------------------------------------------------
# Build a sandbox project whose autonomous.conf mimics podcast-curation
# in mixed-CLI mode: dev=claude, review=kiro.
# -----------------------------------------------------------------------
build_sandbox() {
  local sandbox="$1"
  mkdir -p "$sandbox"

  # Symlink the lib-* and gh-* files so the sandbox's source statements
  # resolve relative to SCRIPT_DIR=$sandbox. Mimics the per-project
  # symlink-vendor topology that real deployments use.
  for f in lib-agent.sh lib-auth.sh lib-config.sh lib-review-bots.sh \
           lib-review-verdict.sh gh-app-token.sh gh-with-token-refresh.sh; do
    ln -sf "$SCRIPTS_DIR/$f" "$sandbox/$f"
  done

  cat >"$sandbox/autonomous.conf" <<'CONF'
PROJECT_ID="test-sandbox"
REPO="example/test"
REPO_OWNER="example"
REPO_NAME="test"
PROJECT_DIR="/tmp/sandbox"
AGENT_CMD="claude"
AGENT_DEV_CMD="claude"
AGENT_REVIEW_CMD="kiro"
AGENT_DEV_MODEL="opus[1m]"
AGENT_REVIEW_MODEL="claude-sonnet-4.6"
AGENT_PERMISSION_MODE="bypassPermissions"
KIRO_AGENT_NAME="autonomous-review"
AGENT_TIMEOUT="4h"
AGENT_DEV_LAUNCHER='bash -c '\''source ~/.bash_aliases && cc "$@"'\'' --'
GH_AUTH_MODE="token"
CONF
}

echo "=== test-wrapper-rebind-order.sh — INV-37/38 rebind order regression ==="

# -----------------------------------------------------------------------
echo ""
echo "=== T1: dev wrapper — AGENT_CMD survives lib-auth re-source ==="
# -----------------------------------------------------------------------
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
build_sandbox "$SANDBOX"

out=$(simulate_wrapper "$DEV_WRAPPER" "$SANDBOX" | grep -E '^AGENT_CMD=|^AGENT_LAUNCHER_ARGV_count=')
agent_cmd=$(echo "$out" | grep '^AGENT_CMD=' | cut -d= -f2)
launcher_count=$(echo "$out" | grep '^AGENT_LAUNCHER_ARGV_count=' | cut -d= -f2)

assert_eq "dev wrapper: AGENT_CMD == claude (matches AGENT_DEV_CMD)" \
  "claude" "$agent_cmd"
# AGENT_DEV_LAUNCHER is set in conf to a non-empty cc-bridge command,
# tokenizes to 4 argv elements (`bash`, `-c`, `<cmd>`, `--`).
assert_eq "dev wrapper: AGENT_LAUNCHER_ARGV reflects AGENT_DEV_LAUNCHER" \
  "4" "$launcher_count"

# -----------------------------------------------------------------------
echo ""
echo "=== T2: review wrapper — AGENT_CMD survives lib-auth re-source ==="
# -----------------------------------------------------------------------
out=$(simulate_wrapper "$REVIEW_WRAPPER" "$SANDBOX" | grep -E '^AGENT_CMD=|^AGENT_LAUNCHER_ARGV_count=')
agent_cmd=$(echo "$out" | grep '^AGENT_CMD=' | cut -d= -f2)
launcher_count=$(echo "$out" | grep '^AGENT_LAUNCHER_ARGV_count=' | cut -d= -f2)

# THIS IS THE CORE REGRESSION: prior to the fix, `claude` was returned
# here because the conf re-source overwrote the rebind to AGENT_REVIEW_CMD.
assert_eq "review wrapper: AGENT_CMD == kiro (matches AGENT_REVIEW_CMD; regression for podcast-curation #333/#334)" \
  "kiro" "$agent_cmd"
assert_eq "review wrapper: AGENT_LAUNCHER_ARGV is empty (no AGENT_REVIEW_LAUNCHER set)" \
  "0" "$launcher_count"

echo ""
echo "PASS: $PASS    FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
