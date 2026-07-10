#!/bin/bash
# test-lib-github-transport.sh — direct unit test for
# skills/autonomous-dispatcher/scripts/providers/lib-github-transport.sh.
#
# Companion to test-dispatcher-tick-gh-version.sh (which exercises the
# precheck end-to-end through dispatcher-tick.sh). This file drives
# gh_version_ok / _gh_version_ge / _gh_transport_binary directly — the
# numeric-comparator edge cases and the REAL_GH resolution order are cheaper
# and clearer to pin at this level than through a full tick invocation.
#
# Run: bash tests/unit/test-lib-github-transport.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/lib-github-transport.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

[[ -f "$LIB" ]] || { echo "FATAL: $LIB not found"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
echo "=== TC-GHT-001: _gh_version_ge numeric comparison (not lexical sort -V) ==="
# ---------------------------------------------------------------------------
# Each case run in a fresh subshell so module-scope state never leaks.
_case_ge() {
  local min="$1" installed="$2" want_rc="$3" desc="$4"
  local got_rc
  ( source "$LIB"; _gh_version_ge "$min" "$installed" )
  got_rc=$?
  if [[ "$got_rc" -eq "$want_rc" ]]; then
    ok "$desc (rc=$got_rc)"
  else
    bad "$desc — want rc=$want_rc got rc=$got_rc"
  fi
}
_case_ge "2.48.0" "2.46.0" 1 "TC-GHT-001a below minimum -> false"
_case_ge "2.48.0" "2.48.0" 0 "TC-GHT-001b exactly minimum -> true"
_case_ge "2.48.0" "2.96.0" 0 "TC-GHT-001c above minimum -> true"
# The load-bearing case a naive lexical/sort -V comparator can get wrong:
# "9" > "48" numerically per-component, but "2.9.0" < "2.48.0" as a version.
_case_ge "2.48.0" "2.9.0" 1 "TC-GHT-001d 2.9.0 < 2.48.0 (numeric per-component, not lexical)"
_case_ge "2.48.0" "2.100.0" 0 "TC-GHT-001e 2.100.0 > 2.48.0 (3-digit minor)"
_case_ge "2.48.0" "10.2.0" 0 "TC-GHT-001f 10.2.0 > 2.48.0 (major version bump)"
_case_ge "2.48.0" "2.48.1" 0 "TC-GHT-001g patch-level bump above minimum -> true"
_case_ge "2.48.0" "2.47.99" 1 "TC-GHT-001h high patch on a lower minor still below minimum -> false"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-GHT-010: gh_version_ok resolves bare gh on PATH when REAL_GH is unset ==="
# ---------------------------------------------------------------------------
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'EOF'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
  echo "gh version 2.96.0 (2026-01-01)"
  exit 0
fi
exit 0
EOF
chmod +x "$BIN/gh"

OUT=$(env -u REAL_GH PATH="$BIN:$PATH" bash -c '
  source "'"$LIB"'"
  gh_version_ok "2.48.0"
  echo "rc=$? installed=$GH_INSTALLED_VERSION"
')
if [[ "$OUT" == *"rc=0"* ]]; then
  ok "TC-GHT-010a bare gh on PATH resolves and passes (no REAL_GH set)"
else
  bad "TC-GHT-010a expected rc=0, got: $OUT"
fi
if [[ "$OUT" == *"installed=gh version 2.96.0"* ]]; then
  ok "TC-GHT-010b GH_INSTALLED_VERSION captures the bare-gh --version output"
else
  bad "TC-GHT-010b GH_INSTALLED_VERSION not populated as expected: $OUT"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-GHT-020: gh_version_ok honors REAL_GH when no bare gh is on PATH ==="
# ---------------------------------------------------------------------------
# The #92 escape hatch: REAL_GH points at an install outside the minimal
# non-interactive PATH (cron/systemd/SSM). The precheck must resolve THIS
# binary, not report "<not found>" just because bare `gh` isn't reachable.
REALBIN="$WORK/realbin"
mkdir -p "$REALBIN"
cat > "$REALBIN/gh" <<'EOF'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
  echo "gh version 2.96.0 (2026-01-01)"
  exit 0
fi
exit 0
EOF
chmod +x "$REALBIN/gh"

EMPTYBIN="$WORK/emptybin"
mkdir -p "$EMPTYBIN"
for c in bash grep head sed cat; do
  command -v "$c" >/dev/null 2>&1 && ln -sf "$(command -v "$c")" "$EMPTYBIN/$c"
done

OUT=$(REAL_GH="$REALBIN/gh" PATH="$EMPTYBIN" bash -c '
  source "'"$LIB"'"
  gh_version_ok "2.48.0"
  echo "rc=$? installed=$GH_INSTALLED_VERSION"
')
if [[ "$OUT" == *"rc=0"* ]]; then
  ok "TC-GHT-020a REAL_GH resolves even with no bare gh on PATH"
else
  bad "TC-GHT-020a expected rc=0, got: $OUT"
fi
if [[ "$OUT" != *"<not found>"* ]]; then
  ok "TC-GHT-020b GH_INSTALLED_VERSION is not the false '<not found>' sentinel"
else
  bad "TC-GHT-020b got the false '<not found>' regression: $OUT"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-GHT-021: REAL_GH below the minimum version still fails closed ==="
# ---------------------------------------------------------------------------
cat > "$REALBIN/gh" <<'EOF'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
  echo "gh version 2.40.0 (2025-01-01)"
  exit 0
fi
exit 0
EOF
chmod +x "$REALBIN/gh"

OUT=$(REAL_GH="$REALBIN/gh" PATH="$EMPTYBIN" bash -c '
  source "'"$LIB"'"
  gh_version_ok "2.48.0"
  echo "rc=$? installed=$GH_INSTALLED_VERSION"
')
if [[ "$OUT" == *"rc=1"* ]]; then
  ok "TC-GHT-021a REAL_GH below minimum correctly fails"
else
  bad "TC-GHT-021a expected rc=1, got: $OUT"
fi
if [[ "$OUT" == *"2.40.0"* ]]; then
  ok "TC-GHT-021b GH_INSTALLED_VERSION reports the REAL_GH-resolved version"
else
  bad "TC-GHT-021b version not captured: $OUT"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-GHT-022: a non-executable REAL_GH falls back to bare gh on PATH ==="
# ---------------------------------------------------------------------------
# Mirrors gh-with-token-refresh.sh's own fallback contract: REAL_GH is only
# honored when it points at an EXECUTABLE file (-x test).
NONEXEC="$WORK/nonexec-gh"
: > "$NONEXEC"  # exists, not executable

OUT=$(REAL_GH="$NONEXEC" PATH="$BIN:$PATH" bash -c '
  source "'"$LIB"'"
  gh_version_ok "2.48.0"
  echo "rc=$? installed=$GH_INSTALLED_VERSION"
')
if [[ "$OUT" == *"rc=0"* && "$OUT" == *"2.96.0"* ]]; then
  ok "TC-GHT-022 non-executable REAL_GH is ignored, bare gh on PATH resolves instead"
else
  bad "TC-GHT-022 expected fallback to bare gh (rc=0, 2.96.0), got: $OUT"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-GHT-030: neither REAL_GH nor bare gh resolves -> fails closed, not found sentinel ==="
# ---------------------------------------------------------------------------
OUT=$(env -u REAL_GH PATH="$EMPTYBIN" bash -c '
  source "'"$LIB"'"
  gh_version_ok "2.48.0"
  echo "rc=$? installed=$GH_INSTALLED_VERSION"
')
if [[ "$OUT" == *"rc=1"* && "$OUT" == *"installed=<not found>"* ]]; then
  ok "TC-GHT-030 no gh anywhere -> fails closed with the <not found> sentinel"
else
  bad "TC-GHT-030 expected rc=1 + '<not found>', got: $OUT"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
