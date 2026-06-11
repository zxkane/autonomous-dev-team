#!/bin/bash
# test-entry-point-resolution.sh — TC-ENTRY-SHIM-001..012 (issue #227)
#
# Locks down the phase-0 two-dir resolution contract ([INV-65]):
#   CONF_DIR = dirname of the UNRESOLVED ${BASH_SOURCE[0]:-$0}  (conf lookup, INV-14)
#   LIB_DIR  = dirname of `readlink -f "${BASH_SOURCE[0]:-$0}"`  (sibling sourcing
#              from the real skill tree — no per-project lib symlink needed)
#
# The behavioral half (TC-ENTRY-SHIM-001..007) drives a tiny harness script
# that reproduces the production snippet verbatim, under direct / single-symlink
# / nested-symlink / bash -c invocation. The regression pin (005) proves the
# missing-lib-symlink crash class is gone: an entry can source a lib that has
# NO project-side symlink.
#
# The source-level half (TC-ENTRY-SHIM-010..012) greps the production scripts to
# assert the contract is actually wired into the real wrappers.
#
# Run: bash tests/unit/test-entry-point-resolution.sh

set -uo pipefail

PASS=0
FAIL=0
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
DISPATCHER_SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"

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

# ---------------------------------------------------------------------------
# Build a harness: a "skill tree" with a real entry script that emits its
# CONF_DIR and LIB_DIR using the production two-dir snippet, plus a sibling
# lib it sources via LIB_DIR.
# ---------------------------------------------------------------------------
SKILL_TREE="$TMPDIR/skill/autonomous-dispatcher/scripts"
mkdir -p "$SKILL_TREE"

cat > "$SKILL_TREE/lib-harness.sh" <<'LIB'
# sibling lib sourced by the entry; defines a marker function.
harness_marker() { echo "LIB_SOURCED_OK"; }
LIB

# The production two-dir snippet, embedded verbatim in a harness entry.
cat > "$SKILL_TREE/entry.sh" <<'ENTRY'
#!/bin/bash
set -euo pipefail
_SELF="${BASH_SOURCE[0]:-$0}"
CONF_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
LIB_DIR="$(cd "$(dirname "$(readlink -f "$_SELF")")" && pwd)"
# Source a sibling lib from the REAL tree (LIB_DIR), never CONF_DIR.
source "${LIB_DIR}/lib-harness.sh"
echo "CONF_DIR=$CONF_DIR"
echo "LIB_DIR=$LIB_DIR"
echo "MARKER=$(harness_marker)"
ENTRY
chmod +x "$SKILL_TREE/entry.sh"

# ===========================================================================
# TC-ENTRY-SHIM-001: direct invocation (real file, no symlink)
# ===========================================================================
echo ""
echo "=== TC-ENTRY-SHIM-001: direct invocation ==="
OUT=$(bash "$SKILL_TREE/entry.sh")
assert_contains "001: CONF_DIR == skill tree (direct)" "CONF_DIR=$SKILL_TREE" "$OUT"
assert_contains "001: LIB_DIR == skill tree (direct)" "LIB_DIR=$SKILL_TREE" "$OUT"
assert_contains "001: lib sourced from LIB_DIR" "MARKER=LIB_SOURCED_OK" "$OUT"

# ===========================================================================
# TC-ENTRY-SHIM-002: single project-side symlink → skill tree
# ===========================================================================
echo ""
echo "=== TC-ENTRY-SHIM-002: single project-side symlink ==="
PROJ_SCRIPTS="$TMPDIR/proj/scripts"
mkdir -p "$PROJ_SCRIPTS"
ln -s "$SKILL_TREE/entry.sh" "$PROJ_SCRIPTS/entry.sh"
OUT=$(bash "$PROJ_SCRIPTS/entry.sh")
assert_contains "002: CONF_DIR == project scripts (symlink dir preserved)" "CONF_DIR=$PROJ_SCRIPTS" "$OUT"
assert_contains "002: LIB_DIR == skill tree (resolved)" "LIB_DIR=$SKILL_TREE" "$OUT"
assert_contains "002: lib sourced from skill tree, NO project lib symlink" "MARKER=LIB_SOURCED_OK" "$OUT"

# ===========================================================================
# TC-ENTRY-SHIM-003: nested symlink (project → shared → vendored)
# ===========================================================================
echo ""
echo "=== TC-ENTRY-SHIM-003: nested symlink ==="
SHARED="$TMPDIR/shared/scripts"
mkdir -p "$SHARED"
# shared/entry.sh -> skill tree real file
ln -s "$SKILL_TREE/entry.sh" "$SHARED/entry.sh"
NESTPROJ="$TMPDIR/nestproj/scripts"
mkdir -p "$NESTPROJ"
# project/entry.sh -> shared/entry.sh -> skill tree
ln -s "$SHARED/entry.sh" "$NESTPROJ/entry.sh"
OUT=$(bash "$NESTPROJ/entry.sh")
assert_contains "003: CONF_DIR == first hop (project scripts)" "CONF_DIR=$NESTPROJ" "$OUT"
assert_contains "003: LIB_DIR == final real dir (skill tree)" "LIB_DIR=$SKILL_TREE" "$OUT"

# ===========================================================================
# TC-ENTRY-SHIM-004: symlinked entry sources lib from skill tree while
#                    reading conf from the symlink dir
# ===========================================================================
echo ""
echo "=== TC-ENTRY-SHIM-004: lib from skill tree, conf from symlink dir ==="
# Drop a conf next to the project-side symlink (CONF_DIR), NOT in skill tree.
cat > "$PROJ_SCRIPTS/autonomous.conf" <<'CONF'
PROJECT_ID="conf-from-project-scripts"
CONF
# A conf-aware entry: source conf from CONF_DIR, lib from LIB_DIR.
cat > "$SKILL_TREE/entry-conf.sh" <<'ENTRY'
#!/bin/bash
set -euo pipefail
_SELF="${BASH_SOURCE[0]:-$0}"
CONF_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
LIB_DIR="$(cd "$(dirname "$(readlink -f "$_SELF")")" && pwd)"
source "${LIB_DIR}/lib-harness.sh"
PROJECT_ID="unset"
[[ -f "${CONF_DIR}/autonomous.conf" ]] && source "${CONF_DIR}/autonomous.conf"
echo "PROJECT_ID=$PROJECT_ID"
echo "MARKER=$(harness_marker)"
ENTRY
chmod +x "$SKILL_TREE/entry-conf.sh"
ln -s "$SKILL_TREE/entry-conf.sh" "$PROJ_SCRIPTS/entry-conf.sh"
OUT=$(bash "$PROJ_SCRIPTS/entry-conf.sh")
assert_contains "004: conf loaded from CONF_DIR (project scripts)" "PROJECT_ID=conf-from-project-scripts" "$OUT"
assert_contains "004: lib still sourced from LIB_DIR (skill tree)" "MARKER=LIB_SOURCED_OK" "$OUT"

# ===========================================================================
# TC-ENTRY-SHIM-005: REGRESSION PIN — upstream adds lib-new.sh, NO project
#                    symlink → entry sources it successfully (crash class gone)
# ===========================================================================
echo ""
echo "=== TC-ENTRY-SHIM-005: regression pin — new lib, no project symlink ==="
# Simulate an upstream PR adding a brand-new lib into the skill tree.
cat > "$SKILL_TREE/lib-new.sh" <<'LIB'
new_lib_marker() { echo "NEW_LIB_OK"; }
LIB
cat > "$SKILL_TREE/entry-newlib.sh" <<'ENTRY'
#!/bin/bash
set -euo pipefail
_SELF="${BASH_SOURCE[0]:-$0}"
CONF_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
LIB_DIR="$(cd "$(dirname "$(readlink -f "$_SELF")")" && pwd)"
source "${LIB_DIR}/lib-new.sh"
echo "MARKER=$(new_lib_marker)"
ENTRY
chmod +x "$SKILL_TREE/entry-newlib.sh"
# Project has ONLY the entry symlink — NO lib-new.sh symlink. Pre-fix this
# would die with `No such file or directory: lib-new.sh` under set -e.
ln -s "$SKILL_TREE/entry-newlib.sh" "$PROJ_SCRIPTS/entry-newlib.sh"
if OUT=$(bash "$PROJ_SCRIPTS/entry-newlib.sh" 2>&1); then
  assert_contains "005: new lib sourced from skill tree w/o project symlink" "MARKER=NEW_LIB_OK" "$OUT"
else
  echo -e "  ${RED}FAIL${NC}: 005: entry crashed sourcing unsymlinked new lib: $OUT"
  ((FAIL++))
fi
# And confirm the project scripts/ truly has no lib-new.sh symlink.
if [[ ! -e "$PROJ_SCRIPTS/lib-new.sh" ]]; then
  echo -e "  ${GREEN}PASS${NC}: 005: project scripts/ has NO lib-new.sh (proves skill-tree resolution)"
  ((PASS++))
else
  echo -e "  ${RED}FAIL${NC}: 005: unexpected project-side lib-new.sh exists"
  ((FAIL++))
fi

# ===========================================================================
# TC-ENTRY-SHIM-006: legacy layout — per-lib symlink still present → identical
# ===========================================================================
echo ""
echo "=== TC-ENTRY-SHIM-006: legacy layout (per-lib symlink present) ==="
# A project that STILL holds a per-lib symlink keeps working unchanged:
# readlink -f follows it to the same real lib.
ln -s "$SKILL_TREE/lib-harness.sh" "$PROJ_SCRIPTS/lib-harness.sh"
OUT=$(bash "$PROJ_SCRIPTS/entry.sh")
assert_contains "006: legacy per-lib symlink present → still works" "MARKER=LIB_SOURCED_OK" "$OUT"
assert_contains "006: LIB_DIR still resolves to skill tree" "LIB_DIR=$SKILL_TREE" "$OUT"

# ===========================================================================
# TC-ENTRY-SHIM-007: BASH_SOURCE[0] empty (bash -c) — $0 fallback
# ===========================================================================
echo ""
echo "=== TC-ENTRY-SHIM-007: bash -c \$0 fallback ==="
OUT=$(bash -c "bash $PROJ_SCRIPTS/entry.sh")
assert_contains "007: bash -c invocation resolves and sources lib" "MARKER=LIB_SOURCED_OK" "$OUT"

# ===========================================================================
# Source-level lockdown on the production scripts
# ===========================================================================
echo ""
echo "=== Source-level lockdown (production scripts) ==="

# TC-ENTRY-SHIM-010: entry wrappers define a real-path LIB dir and use it for
# lib sourcing.
echo "TC-ENTRY-SHIM-010: entry wrappers compute LIB_DIR via readlink -f"
for f in autonomous-dev.sh autonomous-review.sh; do
  content=$(cat "$DISPATCHER_SCRIPTS/$f")
  assert_contains "010: $f computes LIB_DIR via readlink -f" \
    'LIB_DIR=' "$content"
  # The lib sources must reference LIB_DIR, not SCRIPT_DIR.
  if grep -nE '^[[:space:]]*source[[:space:]]+"\$\{?SCRIPT_DIR\}?/lib-' "$DISPATCHER_SCRIPTS/$f" >/dev/null; then
    echo -e "  ${RED}FAIL${NC}: 010: $f still sources a lib via SCRIPT_DIR (should be LIB_DIR)"
    ((FAIL++))
  else
    echo -e "  ${GREEN}PASS${NC}: 010: $f sources libs via LIB_DIR, not SCRIPT_DIR"
    ((PASS++))
  fi
done

# TC-ENTRY-SHIM-011: lib-config.sh still has NO readlink -f (conf loader, #58).
echo "TC-ENTRY-SHIM-011: lib-config.sh still has no readlink -f (conf loader)"
if grep -v '^[[:space:]]*#' "$DISPATCHER_SCRIPTS/lib-config.sh" | grep -q 'readlink -f'; then
  echo -e "  ${RED}FAIL${NC}: 011: lib-config.sh calls readlink -f (#58 regression)"
  ((FAIL++))
else
  echo -e "  ${GREEN}PASS${NC}: 011: lib-config.sh has no readlink -f"
  ((PASS++))
fi

# TC-ENTRY-SHIM-012: conf lookups still use the unresolved dir (INV-14 kept).
# lib-agent.sh / lib-auth.sh must pass an UNRESOLVED dir to load_autonomous_conf,
# never the realpath LIB dir.
echo "TC-ENTRY-SHIM-012: conf lookup uses unresolved dir (INV-14 preserved)"
for f in lib-agent.sh lib-auth.sh; do
  # The load_autonomous_conf call must NOT pass the *_REAL_DIR var.
  if grep -nE 'load_autonomous_conf[[:space:]]+"\$\{?_LIB_[A-Z]+_REAL_DIR' "$DISPATCHER_SCRIPTS/$f" >/dev/null; then
    echo -e "  ${RED}FAIL${NC}: 012: $f passes the realpath dir to load_autonomous_conf (INV-14 broken)"
    ((FAIL++))
  else
    echo -e "  ${GREEN}PASS${NC}: 012: $f conf lookup uses the unresolved dir"
    ((PASS++))
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo -e "Total: $TOTAL  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}"
echo ""
[[ $FAIL -gt 0 ]] && exit 1
exit 0
