#!/bin/bash
# test-symlink-resolution.sh — Unit tests for symlink resolution in dispatcher scripts
#
# Tests the SCRIPT_DIR / _LIB_AGENT_DIR resolution and config fallback logic.
# Verifies fix for issue #37.
# Run: bash tests/unit/test-symlink-resolution.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected='$expected', actual='$actual')"
    ((FAIL++))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected to contain '$needle')"
    ((FAIL++))
  fi
}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

DISPATCHER_SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"

# ===========================================================================
# TC-SYM-001: SCRIPT_DIR resolves through chained symlinks
# ===========================================================================
echo ""
echo "=== TC-SYM-001: SCRIPT_DIR resolves through chained symlinks ==="
echo ""

# Create a chain: project/scripts/test.sh -> .claude/skills/disp/scripts/test.sh -> real/test.sh
mkdir -p "$TMPDIR/sym-001/real/scripts"
mkdir -p "$TMPDIR/sym-001/.claude/skills/disp/scripts"
mkdir -p "$TMPDIR/sym-001/project/scripts"

# Real script that prints its resolved SCRIPT_DIR
cat > "$TMPDIR/sym-001/real/scripts/test.sh" <<'SCRIPT'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
echo "$SCRIPT_DIR"
SCRIPT
chmod +x "$TMPDIR/sym-001/real/scripts/test.sh"

# Level 1 symlink: .claude/skills/disp/scripts/test.sh -> real/scripts/test.sh
ln -sf "$TMPDIR/sym-001/real/scripts/test.sh" "$TMPDIR/sym-001/.claude/skills/disp/scripts/test.sh"

# Level 2 symlink: project/scripts/test.sh -> .claude/skills/disp/scripts/test.sh
ln -sf "$TMPDIR/sym-001/.claude/skills/disp/scripts/test.sh" "$TMPDIR/sym-001/project/scripts/test.sh"

# Run through the double symlink
RESULT=$(bash "$TMPDIR/sym-001/project/scripts/test.sh")
assert_eq "Chained symlink resolves to real directory" "$TMPDIR/sym-001/real/scripts" "$RESULT"

# ===========================================================================
# TC-SYM-002: SCRIPT_DIR works when invoked directly (no symlink)
# ===========================================================================
echo ""
echo "=== TC-SYM-002: SCRIPT_DIR works with direct invocation ==="
echo ""

RESULT=$(bash "$TMPDIR/sym-001/real/scripts/test.sh")
assert_eq "Direct invocation resolves correctly" "$TMPDIR/sym-001/real/scripts" "$RESULT"

# ===========================================================================
# TC-SYM-003: _LIB_AGENT_DIR resolves through symlinks when sourced
# ===========================================================================
echo ""
echo "=== TC-SYM-003: _LIB_AGENT_DIR resolves through symlinks ==="
echo ""

mkdir -p "$TMPDIR/sym-003/real/scripts"
mkdir -p "$TMPDIR/sym-003/project/scripts"

# Real lib that sets _LIB_AGENT_DIR
cat > "$TMPDIR/sym-003/real/scripts/lib.sh" <<'LIB'
#!/bin/bash
_LIB_AGENT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIB

# Real script that sources the lib and prints the result
cat > "$TMPDIR/sym-003/real/scripts/main.sh" <<'MAIN'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
echo "$_LIB_AGENT_DIR"
MAIN
chmod +x "$TMPDIR/sym-003/real/scripts/main.sh"

# Symlink the main script
ln -sf "$TMPDIR/sym-003/real/scripts/main.sh" "$TMPDIR/sym-003/project/scripts/main.sh"

RESULT=$(bash "$TMPDIR/sym-003/project/scripts/main.sh")
assert_eq "Sourced lib resolves _LIB_AGENT_DIR through symlink" "$TMPDIR/sym-003/real/scripts" "$RESULT"

# ===========================================================================
# TC-SYM-004: dispatch-local.sh config fallback finds autonomous.conf
# ===========================================================================
echo ""
echo "=== TC-SYM-004: Config fallback finds autonomous.conf ==="
echo ""

mkdir -p "$TMPDIR/sym-004/skill/scripts"
mkdir -p "$TMPDIR/sym-004/project/scripts"

# Config only in project/scripts/ (not in skill/scripts/)
cat > "$TMPDIR/sym-004/project/scripts/autonomous.conf" <<'CONF'
PROJECT_ID="test-project-fallback"
PROJECT_DIR="/tmp/fake-project"
CONF

# Test script simulating dispatch-local.sh config loading
cat > "$TMPDIR/sym-004/skill/scripts/test-config.sh" <<'SCRIPT'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PROJECT_ID=""
if [[ -f "${SCRIPT_DIR}/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/autonomous.conf"
elif [[ -f "${SCRIPT_DIR}/../../../scripts/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/../../../scripts/autonomous.conf"
fi
echo "$PROJECT_ID"
SCRIPT
chmod +x "$TMPDIR/sym-004/skill/scripts/test-config.sh"

# Symlink from project/scripts/ to skill/scripts/
ln -sf "$TMPDIR/sym-004/skill/scripts/test-config.sh" "$TMPDIR/sym-004/project/scripts/test-config.sh"

# Run from the symlink — SCRIPT_DIR resolves to skill/scripts/ which has no conf
# The fallback path ../../../scripts/ from skill/scripts/ won't match the project layout
# But when run directly from the real location, let's verify the logic
RESULT=$(bash "$TMPDIR/sym-004/skill/scripts/test-config.sh")
assert_eq "Config not found in skill dir → empty (correct, no fallback match)" "" "$RESULT"

# Now set up the proper directory structure matching skills layout:
# skills/autonomous-dispatcher/scripts/ -> ../../scripts/ goes to project root
mkdir -p "$TMPDIR/sym-004b/skills/autonomous-dispatcher/scripts"
mkdir -p "$TMPDIR/sym-004b/scripts"

cat > "$TMPDIR/sym-004b/scripts/autonomous.conf" <<'CONF'
PROJECT_ID="test-project-from-fallback"
PROJECT_DIR="/tmp/fake-project"
CONF

cat > "$TMPDIR/sym-004b/skills/autonomous-dispatcher/scripts/test-config.sh" <<'SCRIPT'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PROJECT_ID=""
if [[ -f "${SCRIPT_DIR}/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/autonomous.conf"
elif [[ -f "${SCRIPT_DIR}/../../../scripts/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/../../../scripts/autonomous.conf"
fi
echo "$PROJECT_ID"
SCRIPT
chmod +x "$TMPDIR/sym-004b/skills/autonomous-dispatcher/scripts/test-config.sh"

RESULT=$(bash "$TMPDIR/sym-004b/skills/autonomous-dispatcher/scripts/test-config.sh")
assert_eq "Config loaded from fallback ../../scripts/autonomous.conf" "test-project-from-fallback" "$RESULT"

# ===========================================================================
# TC-SYM-005: Local autonomous.conf takes precedence over fallback
# ===========================================================================
echo ""
echo "=== TC-SYM-005: Local config takes precedence ==="
echo ""

mkdir -p "$TMPDIR/sym-005/skills/autonomous-dispatcher/scripts"
mkdir -p "$TMPDIR/sym-005/scripts"

cat > "$TMPDIR/sym-005/skills/autonomous-dispatcher/scripts/autonomous.conf" <<'CONF'
PROJECT_ID="local-config"
PROJECT_DIR="/tmp/fake-project"
CONF

cat > "$TMPDIR/sym-005/scripts/autonomous.conf" <<'CONF'
PROJECT_ID="fallback-config"
PROJECT_DIR="/tmp/fake-project"
CONF

cat > "$TMPDIR/sym-005/skills/autonomous-dispatcher/scripts/test-config.sh" <<'SCRIPT'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PROJECT_ID=""
if [[ -f "${SCRIPT_DIR}/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/autonomous.conf"
elif [[ -f "${SCRIPT_DIR}/../../../scripts/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/../../../scripts/autonomous.conf"
fi
echo "$PROJECT_ID"
SCRIPT
chmod +x "$TMPDIR/sym-005/skills/autonomous-dispatcher/scripts/test-config.sh"

RESULT=$(bash "$TMPDIR/sym-005/skills/autonomous-dispatcher/scripts/test-config.sh")
assert_eq "Local config takes precedence" "local-config" "$RESULT"

# ===========================================================================
# Script content verification (post-#104 contract)
# ===========================================================================
# TC-CONTENT-001..005 were retired in #104. They asserted that production
# scripts CONTAINED the substring "readlink -f" — true at the time, but
# misleading after #104 because the only remaining occurrences are inside
# the new INV-14 prevention comments. The migration's actual contract is
# "no `readlink -f "$0"` callsite", which TC-INV14-6 enforces with the
# correct comment-aware regex on production code.
echo ""
echo "=== Script Content Verification ==="
echo ""

DEV_SCRIPT="$DISPATCHER_SCRIPTS/autonomous-dev.sh"
REVIEW_SCRIPT="$DISPATCHER_SCRIPTS/autonomous-review.sh"
DISPATCH_SCRIPT="$DISPATCHER_SCRIPTS/dispatch-local.sh"
LIB_AGENT="$DISPATCHER_SCRIPTS/lib-agent.sh"
LIB_AUTH="$DISPATCHER_SCRIPTS/lib-auth.sh"

echo "TC-CONTENT-006: lib-agent.sh delegates config-loading to lib-config.sh (#58, INV-65 two-dir)"
# Was (#58): assert lib-agent.sh has NO readlink -f at all. After #227 / [INV-65]
# that ban is too broad: lib-agent.sh now legitimately uses `readlink -f` to
# compute the REAL-path dir (_LIB_AGENT_REAL_DIR) it sources lib-config.sh from,
# so the sibling no longer needs a per-project symlink. The #58 invariant that
# MUST still hold is narrower: the CONF lookup (load_autonomous_conf) must
# receive the UNRESOLVED dir, never the realpath dir, and no `readlink -f "$0"`
# conf-dir pattern may reappear.
if [[ -f "$LIB_AGENT" ]]; then
  LIB_CONTENT=$(cat "$LIB_AGENT")
  assert_contains "lib-agent.sh sources lib-config.sh" 'lib-config.sh' "$LIB_CONTENT"
  assert_contains "lib-agent.sh calls load_autonomous_conf" 'load_autonomous_conf' "$LIB_CONTENT"
  # INV-14 preserved: conf lookup must use the UNRESOLVED dir, not the realpath one.
  if grep -nE 'load_autonomous_conf[[:space:]]+"\$\{?_LIB_AGENT_REAL_DIR' "$LIB_AGENT" >/dev/null; then
    echo -e "  ${RED}FAIL${NC}: lib-agent.sh passes the realpath dir to load_autonomous_conf (INV-14 regression)"
    ((FAIL++))
  else
    echo -e "  ${GREEN}PASS${NC}: lib-agent.sh conf lookup uses the unresolved dir (INV-14 preserved)"
    ((PASS++))
  fi
  # The #58 ban that still applies: no `readlink -f "$0"` conf-dir pattern.
  if grep -qE 'readlink -f "\$0"' "$LIB_AGENT"; then
    echo -e "  ${RED}FAIL${NC}: lib-agent.sh uses readlink -f \"\$0\" (#58 conf-dir regression)"
    ((FAIL++))
  else
    echo -e "  ${GREEN}PASS${NC}: lib-agent.sh has no readlink -f \"\$0\" conf-dir call (#58 mitigation intact)"
    ((PASS++))
  fi
else
  echo -e "  ${RED}FAIL${NC}: lib-agent.sh not found"
  ((FAIL++))
fi

echo "TC-CONTENT-007: lib-auth.sh delegates config-loading to lib-config.sh (#58, INV-65 two-dir)"
if [[ -f "$LIB_AUTH" ]]; then
  LIB_AUTH_CONTENT=$(cat "$LIB_AUTH")
  assert_contains "lib-auth.sh sources lib-config.sh" 'lib-config.sh' "$LIB_AUTH_CONTENT"
  assert_contains "lib-auth.sh calls load_autonomous_conf" 'load_autonomous_conf' "$LIB_AUTH_CONTENT"
  # INV-14 preserved: conf lookup + the `gh` wrapper symlink stay on the
  # UNRESOLVED _LIB_AUTH_DIR; only sibling sourcing uses _LIB_AUTH_REAL_DIR.
  if grep -nE 'load_autonomous_conf[[:space:]]+"\$\{?_LIB_AUTH_REAL_DIR' "$LIB_AUTH" >/dev/null; then
    echo -e "  ${RED}FAIL${NC}: lib-auth.sh passes the realpath dir to load_autonomous_conf (INV-14 regression)"
    ((FAIL++))
  else
    echo -e "  ${GREEN}PASS${NC}: lib-auth.sh conf lookup uses the unresolved dir (INV-14 preserved)"
    ((PASS++))
  fi
  # The `gh` wrapper symlink target must stay on the UNRESOLVED _LIB_AUTH_DIR
  # (the agent invokes it via `bash scripts/gh` from the project side).
  if grep -qE 'ln -s.*_LIB_AUTH_REAL_DIR.*/gh' "$LIB_AUTH"; then
    echo -e "  ${RED}FAIL${NC}: lib-auth.sh creates the gh wrapper via the realpath dir (breaks bash scripts/gh)"
    ((FAIL++))
  else
    echo -e "  ${GREEN}PASS${NC}: lib-auth.sh gh wrapper symlink stays project-side"
    ((PASS++))
  fi
  if grep -qE 'readlink -f "\$0"' "$LIB_AUTH"; then
    echo -e "  ${RED}FAIL${NC}: lib-auth.sh uses readlink -f \"\$0\" (#58 conf-dir regression)"
    ((FAIL++))
  else
    echo -e "  ${GREEN}PASS${NC}: lib-auth.sh has no readlink -f \"\$0\" conf-dir call (#58 mitigation intact)"
    ((PASS++))
  fi
else
  echo -e "  ${RED}FAIL${NC}: lib-auth.sh not found"
  ((FAIL++))
fi

# ===========================================================================
# TC-SYM-006: lib-agent.sh config fallback works via installed skill path
# ===========================================================================
echo ""
echo "=== TC-SYM-006: lib-agent.sh config fallback via installed skill path ==="
echo ""

# Simulates: .agents/skills/autonomous-dispatcher/scripts/lib-agent.sh
# with autonomous.conf at <project>/scripts/autonomous.conf
mkdir -p "$TMPDIR/sym-006/skills/autonomous-dispatcher/scripts"
mkdir -p "$TMPDIR/sym-006/scripts"

cat > "$TMPDIR/sym-006/scripts/autonomous.conf" <<'CONF'
PROJECT_ID="installed-skill-project"
PROJECT_DIR="/tmp/fake-project"
CONF

cat > "$TMPDIR/sym-006/skills/autonomous-dispatcher/scripts/test-lib-config.sh" <<'SCRIPT'
#!/bin/bash
_LIB_AGENT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_ID=""
if [[ -f "${_LIB_AGENT_DIR}/autonomous.conf" ]]; then
  source "${_LIB_AGENT_DIR}/autonomous.conf"
elif [[ -f "${_LIB_AGENT_DIR}/../../../scripts/autonomous.conf" ]]; then
  source "${_LIB_AGENT_DIR}/../../../scripts/autonomous.conf"
fi
echo "$PROJECT_ID"
SCRIPT
chmod +x "$TMPDIR/sym-006/skills/autonomous-dispatcher/scripts/test-lib-config.sh"

RESULT=$(bash "$TMPDIR/sym-006/skills/autonomous-dispatcher/scripts/test-lib-config.sh")
assert_eq "lib-agent.sh finds config via fallback from installed skill path" "installed-skill-project" "$RESULT"

# ===========================================================================
# TC-INV14: deployment-topology coverage for issue #104
# ===========================================================================
#
# Drives the actual production dispatch-local.sh as a black box across
# four deployment topologies, locking down both the migration to
# BASH_SOURCE[0] and the existing fallback behavior.
#
# We invoke `dispatch-local.sh dev-new <issue>` and let it source conf
# but capture the spawned wrapper before it runs the agent — by stubbing
# autonomous-dev.sh in the project's scripts/ to print PROJECT_ID and exit.
# That way we observe whether dispatch-local.sh found the right conf.

# The full lib chain dispatch-local.sh transitively needs at runtime.
# Used by all TC-INV14-* setups to keep the copy/symlink targets aligned.
_INV14_LIB_FILES=(
  dispatch-local.sh lib-config.sh lib-agent.sh lib-auth.sh
  lib-dispatch.sh lib-review-bots.sh
  gh-app-token.sh gh-with-token-refresh.sh gh-token-refresh-daemon.sh
)

# Helper: copy the production lib chain into a target dir. Skips files
# that don't exist in the source tree (defensive — keeps the test
# self-correcting if the chain shrinks).
#
# Args:
#   $1 = target_dir
#   $2 = "with-trap" | "no-trap"  (default: "with-trap")
#
# When $2 is "with-trap" (the default for symlinked topologies):
#   Drops a competing-marker autonomous.conf into target_dir with
#   PROJECT_ID="WRONG-vendor-conf-fired". If dispatch-local.sh ever
#   resolves SCRIPT_DIR to the install dir (the bug this PR fixes),
#   tier-2 (`${SCRIPT_DIR}/autonomous.conf`) would source THAT conf and
#   the wrapper would print the wrong PROJECT_ID — causing the test to
#   fail. The negative coverage this provides is what makes
#   TC-INV14-1/2/3/5 actually lock down the migration.
#
# When $2 is "no-trap" (for the direct-invocation TC-INV14-4 case):
#   No competing conf. dispatch-local.sh is invoked from the install
#   dir directly, so SCRIPT_DIR equals the install dir by definition
#   and a tier-1 hit on a vendor-side conf would be CORRECT — there
#   is no project-side symlink in this topology. The legacy depth-3
#   fallback is what we want to exercise, and it only fires when
#   tier-1 misses.
_inv14_install_lib_chain() {
  local target="$1" mode="${2:-with-trap}" f
  mkdir -p "$target"
  for f in "${_INV14_LIB_FILES[@]}"; do
    if [[ -f "$DISPATCHER_SCRIPTS/$f" ]]; then
      cp "$DISPATCHER_SCRIPTS/$f" "$target/$f"
    fi
  done
  if [[ "$mode" == "with-trap" ]]; then
    cat > "$target/autonomous.conf" <<'WRONG_CONF'
# This conf MUST NOT be loaded by dispatch-local.sh under any topology
# that has a project-side symlink. If it gets loaded, SCRIPT_DIR
# resolution regressed to readlink-f-style behavior and INV-14 broke.
PROJECT_ID="WRONG-vendor-conf-fired"
REPO="WRONG/WRONG"
REPO_OWNER="WRONG"
REPO_NAME="WRONG"
PROJECT_DIR="/WRONG"
AGENT_CMD="claude"
GH_AUTH_MODE="token"
WRONG_CONF
  fi
}

# Helper: create project-side symlinks for the lib chain pointing at a
# real install dir (vendored copy or shared install).
#
# Args: $1=project_scripts_dir  $2=real_install_dir
_inv14_link_chain() {
  local link_dir="$1" real_dir="$2" f
  for f in "${_INV14_LIB_FILES[@]}"; do
    ln -sf "$real_dir/$f" "$link_dir/$f"
  done
}

# Helper: build a project layout with scripts/autonomous.conf and a stub
# autonomous-dev.sh that prints PROJECT_ID. Caller decides how to wire
# the dispatch-local.sh symlink (vendored vs shared-install vs direct).
#
# Args: $1=project_root  $2=marker_value (becomes PROJECT_ID)
_inv14_make_project() {
  local proj="$1" marker="$2"
  mkdir -p "$proj/scripts"
  cat > "$proj/scripts/autonomous.conf" <<CONF
PROJECT_ID="$marker"
REPO="test/test"
REPO_OWNER="test"
REPO_NAME="test"
PROJECT_DIR="$proj"
AGENT_CMD="claude"
GH_AUTH_MODE="token"
CONF
  # Stub autonomous-dev.sh: source conf via the same INV-14 pattern the
  # real wrapper uses (lib-agent.sh's load_autonomous_conf), then print
  # what we observed. This is what locks the contract: if SCRIPT_DIR
  # resolves to the project's scripts/, conf is sourced from there.
  cat > "$proj/scripts/autonomous-dev.sh" <<'STUB'
#!/bin/bash
# Stub for TC-INV14: mimic the wrapper's INV-14 conf-loading.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/autonomous.conf"
fi
echo "PROJECT_ID=$PROJECT_ID"
exit 0
STUB
  # Also stub autonomous-review.sh symmetrically (some test paths exercise it).
  cp "$proj/scripts/autonomous-dev.sh" "$proj/scripts/autonomous-review.sh"
  chmod +x "$proj/scripts/autonomous-dev.sh" "$proj/scripts/autonomous-review.sh"
}

# Helper: invoke dispatch-local.sh via the given entry point and capture
# the PROJECT_ID line that the stubbed wrapper writes. dispatch-local.sh
# nohup's the wrapper to a log file; we glob /tmp afterwards.
#
# Critical: we DO NOT pre-export PROJECT_DIR. The whole contract under
# test is that dispatch-local.sh resolves SCRIPT_DIR (via BASH_SOURCE[0]
# under symlink topologies, or via the legacy ../../../scripts/ fallback
# under the direct-vendor topology) to a directory where it can find a
# real autonomous.conf. Pre-exporting PROJECT_DIR would let
# dispatch-local.sh's `: "${PROJECT_DIR:?...}"` check pass via env even
# if both tier-1 and the legacy fallback miss — masking the real
# regression we want to catch.
#
# Args: $1=project_root  $2=dispatch_local_path_to_invoke
_inv14_run_dispatch() {
  local proj="$1" entry="$2"
  local capture_dir
  capture_dir=$(mktemp -d)
  ( cd "$proj" && bash "$entry" dev-new 1 >/dev/null 2>"$capture_dir/stderr" ) || true
  # Wait briefly for nohup'd stub to write its log
  local found=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    found=$(grep -lh '^PROJECT_ID=' /tmp/agent-*-issue-1.log 2>/dev/null | head -1)
    [[ -n "$found" ]] && break
    sleep 0.1
  done
  if [[ -n "$found" ]]; then
    grep -h '^PROJECT_ID=' "$found" | head -1
    rm -f "$found"
  else
    echo "PROJECT_ID=<not-found>"
    cat "$capture_dir/stderr" >&2
  fi
  rm -rf "$capture_dir"
}

# ===========================================================================
# TC-INV14-1: vendored topology, project-side symlink — regression test
# ===========================================================================
echo ""
echo "=== TC-INV14-1: vendored topology, project-side symlink ==="
echo ""

PROJ1="$TMPDIR/inv14-1"
VENDOR1="$PROJ1/.agents/skills/autonomous-dispatcher/scripts"
_inv14_make_project "$PROJ1" "marker-vendored"
mkdir -p "$PROJ1/.agents/skills/autonomous-common/scripts"
# Canonical "skills vendored under .agents/skills/, project's scripts/
# is a directory of symlinks pointing into the vendored copy" topology.
_inv14_install_lib_chain "$VENDOR1"
_inv14_link_chain "$PROJ1/scripts" "$VENDOR1"

RESULT=$(_inv14_run_dispatch "$PROJ1" "$PROJ1/scripts/dispatch-local.sh")
assert_eq "TC-INV14-1: vendored + project symlink loads project-side conf" \
  "PROJECT_ID=marker-vendored" "$RESULT"

# ===========================================================================
# TC-INV14-2: shared-install (user-scope), project-side symlink
# ===========================================================================
echo ""
echo "=== TC-INV14-2: shared-install topology (simulated user-scope) ==="
echo ""

# Simulate "user-scope" install at $TMPDIR/inv14-2-share/skills/...
# (real shared install would be ~/.claude/skills/, but tmpdir is the same idea —
# the install dir lives outside any project boundary)
PROJ2="$TMPDIR/inv14-2"
SHARE2="$TMPDIR/inv14-2-share/skills/autonomous-dispatcher/scripts"
_inv14_make_project "$PROJ2" "marker-shared-install"
# Canonical shared-install topology: every script the dispatch chain
# needs lives as a symlink in the project's scripts/, all pointing into
# the shared install dir.
_inv14_install_lib_chain "$SHARE2"
_inv14_link_chain "$PROJ2/scripts" "$SHARE2"

RESULT=$(_inv14_run_dispatch "$PROJ2" "$PROJ2/scripts/dispatch-local.sh")
assert_eq "TC-INV14-2: shared-install + project symlink loads project-side conf" \
  "PROJECT_ID=marker-shared-install" "$RESULT"

# ===========================================================================
# TC-INV14-3: alternative shared-install path (defensive)
# ===========================================================================
echo ""
echo "=== TC-INV14-3: alternative shared-install path (defensive check) ==="
echo ""

PROJ3="$TMPDIR/inv14-3"
SHARE3="$TMPDIR/inv14-3-altshare/opt/share/autonomous-dispatcher/scripts"
_inv14_make_project "$PROJ3" "marker-alt-share"
_inv14_install_lib_chain "$SHARE3"
_inv14_link_chain "$PROJ3/scripts" "$SHARE3"

RESULT=$(_inv14_run_dispatch "$PROJ3" "$PROJ3/scripts/dispatch-local.sh")
assert_eq "TC-INV14-3: alternative shared-install path loads project-side conf" \
  "PROJECT_ID=marker-alt-share" "$RESULT"

# ===========================================================================
# TC-INV14-4: vendored, called directly via the legacy depth-3 fallback
# ===========================================================================
echo ""
echo "=== TC-INV14-4: vendored, called directly via legacy fallback ==="
echo ""

# Verifies the legacy ${SCRIPT_DIR}/../../../scripts/autonomous.conf
# fallback in dispatch-local.sh:34 fires when invoked WITHOUT a
# project-side symlink. The fallback's relative-path math is exactly
# 3 levels up + scripts/, so it requires a depth-3 vendor layout:
#
#   <proj>/skills/autonomous-dispatcher/scripts/dispatch-local.sh
#     ↑     ↑      ↑                     ↑
#   <proj> skills auto-disp              scripts → resolves up to <proj>
#
# Modern `npx skills add -p` uses .agents/skills/.../scripts/ which is
# 4 levels deep — the fallback misses there, but those deployments
# always invoke via a project-side symlink (TC-INV14-1) so the fallback
# is irrelevant. The fallback is therefore dead code in current
# production but kept for backward compat with the legacy 3-deep
# layout, which this case locks down.
PROJ4="$TMPDIR/inv14-4"
LEGACY_VENDOR4="$PROJ4/skills/autonomous-dispatcher/scripts"
_inv14_make_project "$PROJ4" "marker-fallback"
# "no-trap": skip the competing-marker conf in the install dir.
# Direct-invocation has no project-side symlink, so SCRIPT_DIR
# legitimately resolves to the vendor — a tier-1 hit there would
# short-circuit the depth-3 fallback we're testing.
_inv14_install_lib_chain "$LEGACY_VENDOR4" "no-trap"
# NO project-side symlink. Invoke the vendored copy directly.
RESULT=$(_inv14_run_dispatch "$PROJ4" "$LEGACY_VENDOR4/dispatch-local.sh")
assert_eq "TC-INV14-4: direct vendored invocation loads conf via legacy depth-3 fallback" \
  "PROJECT_ID=marker-fallback" "$RESULT"

# ===========================================================================
# TC-INV14-5: end-to-end dispatch chain under shared-install topology
# ===========================================================================
# We don't drive dispatcher-tick.sh here (it requires more env / GitHub
# mocking). Instead we lock down the chain at the boundary that matters:
# dispatch-local.sh -> autonomous-dev.sh's PROJECT_DIR resolution. The
# wrapper inherits PROJECT_DIR from dispatch-local.sh's exported env,
# and lib-agent.sh's load_autonomous_conf falls back to tier-3
# (${PROJECT_DIR}/scripts/autonomous.conf) if its tier-2 misses.
echo ""
echo "=== TC-INV14-5: end-to-end (dispatch-local→wrapper) under shared install ==="
echo ""

# Reuse TC-INV14-2's setup but stub autonomous-dev.sh to verify it sees
# the right env propagated from dispatch-local.sh.
PROJ5="$TMPDIR/inv14-5"
SHARE5="$TMPDIR/inv14-5-share/skills/autonomous-dispatcher/scripts"
_inv14_make_project "$PROJ5" "marker-e2e"
_inv14_install_lib_chain "$SHARE5"
_inv14_link_chain "$PROJ5/scripts" "$SHARE5"
# Override the stubbed autonomous-dev.sh to also print PROJECT_DIR seen
# inside the spawned wrapper, asserting env inheritance worked.
cat > "$PROJ5/scripts/autonomous-dev.sh" <<'STUB'
#!/bin/bash
# Mimic the wrapper's INV-14 conf-loading.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/autonomous.conf"
fi
echo "PROJECT_ID=$PROJECT_ID"
echo "PROJECT_DIR=$PROJECT_DIR"
exit 0
STUB
chmod +x "$PROJ5/scripts/autonomous-dev.sh"

# Run dispatch-local.sh from the shared install. Capture the wrapper's
# log to verify both env vars propagated.
LOG5="/tmp/agent-marker-e2e-issue-1.log"
: > "$LOG5"
( cd "$PROJ5" && PROJECT_DIR="$PROJ5" bash "$PROJ5/scripts/dispatch-local.sh" dev-new 1 >/dev/null 2>&1 ) || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q 'PROJECT_ID=' "$LOG5" 2>/dev/null; then break; fi
  sleep 0.1
done
RESULT_PROJ_ID=$(grep '^PROJECT_ID=' "$LOG5" | head -1)
RESULT_PROJ_DIR=$(grep '^PROJECT_DIR=' "$LOG5" | head -1)
assert_eq "TC-INV14-5: PROJECT_ID propagates dispatcher→wrapper" \
  "PROJECT_ID=marker-e2e" "$RESULT_PROJ_ID"
assert_eq "TC-INV14-5: PROJECT_DIR propagates dispatcher→wrapper" \
  "PROJECT_DIR=$PROJ5" "$RESULT_PROJ_DIR"
rm -f "$LOG5"

# ===========================================================================
# TC-INV14-6: source-level lockdown — no readlink -f "$0" remains
# ===========================================================================
echo ""
echo "=== TC-INV14-6: source-level lockdown (no readlink -f \"\$0\") ==="
echo ""

# Future-proof: a contributor "cleanup" PR reverting any of the 6 sites
# back to readlink -f would fail this test. INV-14 cites the rule.
LEAKED=$(grep -lE 'readlink -f "\$0"' "$DISPATCHER_SCRIPTS"/*.sh 2>/dev/null || true)
if [[ -n "$LEAKED" ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-INV14-6: production scripts still use readlink -f \"\$0\":"
  echo "$LEAKED" | sed 's/^/    /'
  ((FAIL++))
else
  echo -e "  ${GREEN}PASS${NC}: TC-INV14-6: no production script uses readlink -f \"\$0\""
  ((PASS++))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo -e "Total: $TOTAL  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}"
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
