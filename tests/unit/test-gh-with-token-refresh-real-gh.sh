#!/bin/bash
# test-gh-with-token-refresh-real-gh.sh — verify the REAL_GH override added in
# closure of issue #92. Drives the wrapper under `env -i` so the test models
# the non-interactive spawn (cron / SSM / nohup) where the bug actually fires.
#
# Run: bash tests/unit/test-gh-with-token-refresh-real-gh.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/gh-with-token-refresh.sh"

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

# Recording stub for the "real" gh. Writes its argv + selected env to a record
# file so each case can assert which stub was invoked and what env it saw.
make_stub_gh() {
  local path="$1" tag="$2"
  cat > "$path" <<EOF
#!/bin/bash
echo "STUB_GH=$tag args=\$* GH_TOKEN=\${GH_TOKEN:-<unset>}" >> "\$STUB_RECORD"
echo "stub gh ($tag) ok"
exit 0
EOF
  chmod +x "$path"
}

# Stub at the canonical override location.
OVERRIDE_DIR="$TMPROOT/override"
mkdir -p "$OVERRIDE_DIR"
make_stub_gh "$OVERRIDE_DIR/gh" "override"

# Stub on a fake PATH dir.
PATH_DIR="$TMPROOT/pathdir"
mkdir -p "$PATH_DIR"
make_stub_gh "$PATH_DIR/gh" "pathdir"

# A non-existent path for negative cases.
MISSING_GH="$TMPROOT/does-not-exist/gh"

# PATH-without-gh: guaranteed to contain NO gh binary but still resolve
# bash + coreutils. We can't use `/usr/bin:/bin` directly because the test
# host may have gh installed there. Build a tmpdir of symlinks to the
# coreutils + bash we need, omitting gh.
NOGH_PATH_DIR="$TMPROOT/nogh-path"
mkdir -p "$NOGH_PATH_DIR"
for cmd in bash sh cat echo grep tr sed dirname readlink command sleep; do
  src=$(command -v "$cmd" 2>/dev/null)
  [[ -n "$src" ]] && ln -sf "$src" "$NOGH_PATH_DIR/$cmd"
done

# ---------------------------------------------------------------------------
echo "=== TC-RG-001: REAL_GH=executable wins over PATH ==="
# ---------------------------------------------------------------------------
RECORD="$TMPROOT/rec-001"
: > "$RECORD"
out=$(env -i HOME="$HOME" \
  PATH="/usr/bin:/bin" \
  REAL_GH="$OVERRIDE_DIR/gh" \
  STUB_RECORD="$RECORD" \
  bash "$WRAPPER" status 2>&1)
rc=$?
assert_eq "rc=0" 0 "$rc"
assert_contains "stub override produced output" "stub gh (override) ok" "$out"
record=$(cat "$RECORD")
assert_contains "override stub recorded the call" "STUB_GH=override" "$record"
assert_not_contains "PATH stub NOT consulted" "STUB_GH=pathdir" "$record"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RG-002: REAL_GH set but not executable → fall through to PATH ==="
# ---------------------------------------------------------------------------
RECORD="$TMPROOT/rec-002"
: > "$RECORD"
out=$(env -i HOME="$HOME" \
  PATH="$PATH_DIR:/usr/bin:/bin" \
  REAL_GH="$MISSING_GH" \
  STUB_RECORD="$RECORD" \
  bash "$WRAPPER" status 2>&1)
rc=$?
assert_eq "rc=0 — fell through to PATH" 0 "$rc"
record=$(cat "$RECORD")
assert_contains "PATH stub was used" "STUB_GH=pathdir" "$record"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RG-003: REAL_GH bad + no PATH gh → error includes Set REAL_GH hint ==="
# ---------------------------------------------------------------------------
# Use an empty PATH dir (no gh binary anywhere) so the negative case is
# deterministic regardless of whether the host has /usr/bin/gh installed.
out=$(env -i HOME="$HOME" \
  PATH="$NOGH_PATH_DIR" \
  REAL_GH="$MISSING_GH" \
  STUB_RECORD="/dev/null" \
  bash "$WRAPPER" status 2>&1)
rc=$?
assert_eq "rc=1" 1 "$rc"
assert_contains "error message has original needle" "Cannot find real gh binary" "$out"
assert_contains "error message has new hint" "Set REAL_GH" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RG-004: REAL_GH empty + gh on PATH → unchanged behavior ==="
# ---------------------------------------------------------------------------
RECORD="$TMPROOT/rec-004"
: > "$RECORD"
out=$(env -i HOME="$HOME" \
  PATH="$PATH_DIR:/usr/bin:/bin" \
  STUB_RECORD="$RECORD" \
  bash "$WRAPPER" status 2>&1)
rc=$?
assert_eq "rc=0" 0 "$rc"
assert_contains "PATH stub was used" "STUB_GH=pathdir" "$(cat "$RECORD")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RG-005: REAL_GH unset + no PATH gh → error has Set REAL_GH hint ==="
# ---------------------------------------------------------------------------
out=$(env -i HOME="$HOME" \
  PATH="$NOGH_PATH_DIR" \
  STUB_RECORD="/dev/null" \
  bash "$WRAPPER" status 2>&1)
rc=$?
assert_eq "rc=1" 1 "$rc"
assert_contains "error message has Set REAL_GH hint" "Set REAL_GH" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RG-006: REAL_GH path inherits GH_TOKEN_FILE flow ==="
# ---------------------------------------------------------------------------
TOKEN_FILE="$TMPROOT/token"
echo "ghs_test_token_abc" > "$TOKEN_FILE"
RECORD="$TMPROOT/rec-006"
: > "$RECORD"
out=$(env -i HOME="$HOME" \
  PATH="/usr/bin:/bin" \
  REAL_GH="$OVERRIDE_DIR/gh" \
  GH_TOKEN_FILE="$TOKEN_FILE" \
  STUB_RECORD="$RECORD" \
  bash "$WRAPPER" status 2>&1)
rc=$?
assert_eq "rc=0" 0 "$rc"
record=$(cat "$RECORD")
assert_contains "stub saw token from file" "GH_TOKEN=ghs_test_token_abc" "$record"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
