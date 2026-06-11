#!/bin/bash
# test-entry-point-startup-e2e.sh — TC-ENTRY-SHIM-030 (issue #227)
#
# Scripted E2E: a temp project with a project-side SYMLINK to the REAL
# autonomous-dev.sh entry + a project-side autonomous.conf, and exactly ONE
# lib (lib-agent.sh) deliberately NOT symlinked into the project. Drive the
# wrapper's startup path (lib sourcing + config load) and assert it reaches the
# first post-startup line WITHOUT the missing-lib-symlink crash signature
# (`No such file or directory`).
#
# This is the end-to-end proof that [INV-65] kills the crash class: pre-#227
# the wrapper died on `source "${SCRIPT_DIR}/lib-agent.sh"` because the project
# had no lib-agent.sh symlink; post-#227 it sources lib-agent.sh from the real
# skill tree via LIB_DIR.
#
# Lives under tests/unit/ so CI (which runs tests/unit/test-*.sh) executes it;
# there is no separate e2e harness in this repo.
#
# Run: bash tests/unit/test-entry-point-startup-e2e.sh

set -uo pipefail

PASS=0
FAIL=0
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
DISPATCHER_SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# A "shared install" skill tree holding the REAL production scripts.
SKILL="$TMPDIR/skill/autonomous-dispatcher/scripts"
mkdir -p "$SKILL"
# Copy the full production set the wrapper sources transitively. We copy the
# whole dir so the chain (lib-agent → lib-config, lib-auth → lib-config /
# gh-app-token, …) resolves from the real tree.
cp "$DISPATCHER_SCRIPTS"/*.sh "$SKILL/"
chmod +x "$SKILL"/*.sh

# Temp project: scripts/ holds ONLY a project-side symlink to the entry + a
# real autonomous.conf. NO lib symlinks at all — that's the whole point.
PROJ="$TMPDIR/proj"
mkdir -p "$PROJ/scripts"
ln -s "$SKILL/autonomous-dev.sh" "$PROJ/scripts/autonomous-dev.sh"

# Sanity: confirm the project has NO lib-agent.sh symlink (the lib the wrapper
# would have crashed on pre-#227).
echo "=== TC-ENTRY-SHIM-030: real-entry startup with NO project lib symlinks ==="
if [[ ! -e "$PROJ/scripts/lib-agent.sh" ]]; then
  echo -e "  ${GREEN}PASS${NC}: project scripts/ has NO lib-agent.sh symlink (the crash precondition)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: unexpected project-side lib-agent.sh"
  FAIL=$((FAIL + 1))
fi

# A complete-enough conf so the wrapper sails past config validation and stops
# at the post-startup arg check. Token auth + a dummy GH_TOKEN keeps auth a
# no-op so the test is hermetic (no network, no gh login).
cat > "$PROJ/scripts/autonomous.conf" <<CONF
PROJECT_ID="entry-e2e"
REPO="example/entry-e2e"
REPO_OWNER="example"
REPO_NAME="entry-e2e"
PROJECT_DIR="$PROJ"
AGENT_CMD="claude"
GH_AUTH_MODE="token"
CONF

# Invoke the entry through the PROJECT-SIDE SYMLINK with no --issue. Startup
# order is: source all libs → AGENT_CMD rebind → config validation → auth
# (token, no-op) → arg parse → "Usage:" exit. Reaching "Usage:" proves every
# lib sourced and conf loaded. We give it no args so it stops deterministically
# at the usage gate without ever invoking the agent CLI.
OUT=$(cd "$PROJ" && GH_TOKEN="dummy-token-for-e2e" \
  bash "$PROJ/scripts/autonomous-dev.sh" 2>&1); RC=$?

# 1. The crash-class signature MUST NOT appear.
if grep -qi 'No such file or directory' <<<"$OUT"; then
  echo -e "  ${RED}FAIL${NC}: startup hit a missing-file crash (the #227 class):"
  echo "$OUT" | sed 's/^/    /'
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: no 'No such file or directory' — all libs sourced from skill tree"
  PASS=$((PASS + 1))
fi

# 2. It must NOT have died at config validation (which would mean conf didn't
#    load from the project-side CONF_DIR). The wrapper reaching the usage gate
#    proves both lib sourcing AND conf loading worked.
if grep -q 'Usage:' <<<"$OUT"; then
  echo -e "  ${GREEN}PASS${NC}: reached the post-startup usage gate (libs + conf both loaded)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: did not reach the usage gate (rc=$RC); output:"
  echo "$OUT" | sed 's/^/    /'
  FAIL=$((FAIL + 1))
fi

# 3. It must NOT have tripped a `${REPO:?...}`-style unset-config error (which
#    would mean conf failed to load from CONF_DIR).
if grep -qiE 'Set (REPO|PROJECT_ID|PROJECT_DIR) in autonomous.conf' <<<"$OUT"; then
  echo -e "  ${RED}FAIL${NC}: config validation failed — conf did not load from CONF_DIR:"
  echo "$OUT" | sed 's/^/    /'
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: config validation passed — conf loaded from the symlink dir (CONF_DIR)"
  PASS=$((PASS + 1))
fi

echo ""
echo "=== Results ==="
echo -e "Total: $((PASS + FAIL))  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}"
[[ $FAIL -gt 0 ]] && exit 1
exit 0
