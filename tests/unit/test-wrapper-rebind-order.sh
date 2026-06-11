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
  # Extract from `SCRIPT_DIR=` (the start of the source/rebind block) up
  # to the line immediately before `: "${PROJECT_ID:?...}"` (the start of
  # the post-init validation block). Range is content-anchored so test
  # stays in lock-step even if wrappers gain/lose lines.
  #
  # An earlier version used a hardcoded `22,40p` range. agy review on
  # PR #159 caught it: review wrapper's launcher rebind sits at line 41
  # (post-fix), so the hardcoded range silently truncated the
  # AGENT_LAUNCHER_ARGV rebind out of the simulation. The default-empty
  # AGENT_REVIEW_LAUNCHER_ARGV array made the count assertion pass
  # vacuously. Content anchors fix that class of regression.
  #
  # We feed the extracted block to bash via stdin (NOT via `bash -c "..."`
  # interpolation). The extracted block contains markdown backticks
  # around things like `AGENT_CMD="claude"` inside comments — backtick
  # is command substitution under double-quoted bash -c, which would
  # silently execute the comment. Stdin route bypasses that hazard.
  local tmp_script
  tmp_script=$(mktemp)
  {
    echo 'set -uo pipefail'
    # [INV-65] the wrapper now resolves TWO dirs: SCRIPT_DIR (conf, project-side)
    # and LIB_DIR (real-path, sibling sourcing). In this sandbox both point at
    # the symlink dir, so injecting both is faithful. AUTONOMOUS_CONF_DIR is the
    # var the wrapper exports for the libs' conf lookup; set it to the conf dir.
    echo "SCRIPT_DIR='$conf_dir'"
    echo "LIB_DIR='$conf_dir'"
    echo "AUTONOMOUS_CONF_DIR='$conf_dir'"
    echo "AUTONOMOUS_CONF='$conf_dir/autonomous.conf'"
    awk '
      # Capture the source/rebind block. Skip the resolution preamble (the
      # _SELF= / SCRIPT_DIR= / LIB_DIR= / export AUTONOMOUS_CONF_DIR= lines) —
      # the harness injects those dirs itself so the sandbox symlinks resolve.
      /^SCRIPT_DIR=/ { capture = 1; next }
      capture && /^LIB_DIR=/ { next }
      capture && /^export AUTONOMOUS_CONF_DIR=/ { next }
      # End-anchor: any `: "${VAR:?...}"` style validation. Generalized
      # over a specific name so reordering or renaming the first
      # validated config var does not silently extend the capture into
      # the wrapper body. Per agy P3 follow-up review on PR #159.
      /^: "\$\{[A-Z_]+:\?/ { capture = 0 }
      capture { print }
    ' "$wrapper"
    echo 'echo "AGENT_CMD=$AGENT_CMD"'
    echo 'echo "AGENT_LAUNCHER_ARGV_count=${#AGENT_LAUNCHER_ARGV[@]}"'
  } >"$tmp_script"
  bash "$tmp_script" 2>&1
  rm -f "$tmp_script"
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
assert_eq "review wrapper: AGENT_CMD == kiro (matches AGENT_REVIEW_CMD; regression for downstream consumer review misroute)" \
  "kiro" "$agent_cmd"
assert_eq "review wrapper: AGENT_LAUNCHER_ARGV is empty (no AGENT_REVIEW_LAUNCHER set)" \
  "0" "$launcher_count"

# -----------------------------------------------------------------------
echo ""
echo "=== T3: review wrapper — AGENT_REVIEW_LAUNCHER rebind exercised ==="
# -----------------------------------------------------------------------
# T2 above doesn't actually exercise the launcher rebind line — the
# default-empty AGENT_REVIEW_LAUNCHER_ARGV makes the count assertion
# pass vacuously regardless of whether the rebind ran. T3 closes that
# gap with a separate sandbox where AGENT_REVIEW_LAUNCHER is non-empty
# (and AGENT_REVIEW_CMD=claude so the INV-38 per-side guard accepts
# the launcher). This catches a regression where someone reorders the
# wrapper such that the launcher rebind is dropped or precedes
# `source lib-auth.sh`. agy review on PR #159 caught the original
# version which had this gap.
SANDBOX2=$(mktemp -d)
build_sandbox "$SANDBOX2"
# Override two fields: review CLI must be claude (INV-38 guard) and
# AGENT_REVIEW_LAUNCHER must be non-empty so its argv count is
# distinguishable from the default-empty array.
cat >>"$SANDBOX2/autonomous.conf" <<'CONF'
AGENT_REVIEW_CMD="claude"
AGENT_REVIEW_LAUNCHER='bash -c '\''review-launcher "$@"'\'' --'
CONF
trap 'rm -rf "$SANDBOX" "$SANDBOX2"' EXIT

out=$(simulate_wrapper "$REVIEW_WRAPPER" "$SANDBOX2" | grep -E '^AGENT_CMD=|^AGENT_LAUNCHER_ARGV_count=')
agent_cmd=$(echo "$out" | grep '^AGENT_CMD=' | cut -d= -f2)
launcher_count=$(echo "$out" | grep '^AGENT_LAUNCHER_ARGV_count=' | cut -d= -f2)

assert_eq "review wrapper (T3): AGENT_CMD == claude (matches AGENT_REVIEW_CMD)" \
  "claude" "$agent_cmd"
# AGENT_REVIEW_LAUNCHER tokenizes to 4 argv elements (`bash`, `-c`,
# `<cmd>`, `--`). A count of 0 here would mean the launcher rebind
# line never executed.
assert_eq "review wrapper (T3): AGENT_LAUNCHER_ARGV reflects AGENT_REVIEW_LAUNCHER (4 argv)" \
  "4" "$launcher_count"

echo ""
echo "PASS: $PASS    FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
