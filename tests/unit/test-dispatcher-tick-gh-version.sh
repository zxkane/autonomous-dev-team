#!/bin/bash
# test-dispatcher-tick-gh-version.sh — Unit tests for the gh-CLI minimum
# version fail-fast precheck added to dispatcher-tick.sh.
#
# Why: `itp_github_list_comments` (providers/itp-github.sh) shells out to
# `gh api --paginate --slurp`. `--slurp` was added in gh v2.48.0 — an older
# `gh` on PATH prints "unknown flag: --slurp" and the pipeline returns empty,
# which downstream (e.g. count_retries' `-ge` integer comparison) trips
# `set -euo pipefail` and aborts the tick mid-run, well past Step 4, with
# Step 5 (stale detection) never running. The precheck catches this upfront,
# before any gh API call, instead of failing opaquely deep in the tick.
#
# Strategy: same as test-dispatcher-tick-review-bots.sh — a `gh` shim on
# PATH reporting a version, a sandbox autonomous.conf, run dispatcher-tick.sh,
# assert rc/output.
#
# Run: bash tests/unit/test-dispatcher-tick-gh-version.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TICK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"

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
    echo "      haystack='${haystack:0:500}'"
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
    echo "      should not contain: '$needle'"
    FAIL=$((FAIL + 1))
  fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

PROJECT_DIR_FAKE="$TMPROOT/proj"
mkdir -p "$PROJECT_DIR_FAKE/scripts"

BIN="$TMPROOT/bin"
mkdir -p "$BIN"

# write_gh_stub VERSION_STRING — a `gh` on PATH whose `--version` output
# matches the real CLI's format, and which records every call so the test
# can assert the precheck never invokes it for anything else.
write_gh_stub() {
  local version="$1"
  cat > "$BIN/gh" <<EOF
#!/bin/bash
if [[ "\$1" == "--version" ]]; then
  echo "gh version ${version} (2025-01-01)"
  exit 0
fi
echo "GH_CALLED \$*" >> "$TMPROOT/gh-calls"
exit 0
EOF
  chmod +x "$BIN/gh"
}

write_conf() {
  local real_gh_line="${1:-}"
  cat > "$TMPROOT/autonomous.conf" <<EOF
PROJECT_ID="testproj"
REPO="owner/repo"
REPO_OWNER="owner"
REPO_NAME="repo"
PROJECT_DIR="$PROJECT_DIR_FAKE"
MAX_CONCURRENT=5
MAX_RETRIES=3
REVIEW_BOTS=""
$real_gh_line
EOF
}

run_tick() {
  : > "$TMPROOT/gh-calls"
  PATH="$BIN:$PATH" \
  AUTONOMOUS_CONF="$TMPROOT/autonomous.conf" \
  bash "$TICK" 2>&1
}

run_tick_rc() {
  PATH="$BIN:$PATH" AUTONOMOUS_CONF="$TMPROOT/autonomous.conf" \
    bash "$TICK" >/dev/null 2>&1
  echo $?
}

write_conf

# ---------------------------------------------------------------------------
echo "=== TC-DT-GHV-01: gh below the minimum version aborts the tick rc != 0 ==="
# ---------------------------------------------------------------------------
write_gh_stub "2.46.0"
output=$(run_tick)
rc=$(run_tick_rc)

if [[ "$rc" -ne 0 ]]; then
  echo -e "  ${GREEN}PASS${NC}: tick exits non-zero on gh 2.46.0 (rc=$rc)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: tick should exit non-zero on gh 2.46.0 (got rc=0)"
  FAIL=$((FAIL + 1))
fi

assert_contains "stderr names the installed version"  "2.46.0"    "$output"
assert_contains "stderr names the minimum version"     "2.48.0"    "$output"
assert_contains "stderr mentions --slurp"               "--slurp"  "$output"
assert_contains "envelope code present" "ADT_CFG_GH_VERSION_TOO_OLD" "$output"

gh_calls_file="$TMPROOT/gh-calls"
if [[ -s "$gh_calls_file" ]]; then
  echo -e "  ${RED}FAIL${NC}: gh was called (beyond --version) before precheck failure:"
  sed 's/^/      /' "$gh_calls_file"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: gh not called beyond --version — precheck aborts before any API call"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DT-GHV-02: gh at exactly the minimum version does NOT trip the precheck ==="
# ---------------------------------------------------------------------------
write_gh_stub "2.48.0"
output=$(run_tick)
assert_not_contains "no version error at exactly the minimum" \
  "ADT_CFG_GH_VERSION_TOO_OLD" "$output"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DT-GHV-03: gh above the minimum version does NOT trip the precheck ==="
# ---------------------------------------------------------------------------
write_gh_stub "2.96.0"
output=$(run_tick)
assert_not_contains "no version error above the minimum" \
  "ADT_CFG_GH_VERSION_TOO_OLD" "$output"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DT-GHV-04: unparseable gh --version output surfaces a clear error, not an opaque crash ==="
# ---------------------------------------------------------------------------
# A `gh` present on PATH whose --version output the parser can't extract a
# semver from (corrupt install / unexpected banner) must fail the same way as
# "too old" — never silently pass through as "version OK". PATH is NOT reset
# to the real system `gh` here (that would test the host's actual gh, making
# the case non-hermetic); the stub simply reports garbage.
cat > "$BIN/gh" <<'EOF'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
  echo "gh: command not properly initialized"
  exit 0
fi
exit 0
EOF
chmod +x "$BIN/gh"
output=$(run_tick)
rc=$(run_tick_rc)
if [[ "$rc" -ne 0 ]]; then
  echo -e "  ${GREEN}PASS${NC}: tick exits non-zero when gh --version is unparseable (rc=$rc)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: tick should exit non-zero when gh --version is unparseable (got rc=0)"
  FAIL=$((FAIL + 1))
fi
assert_contains "envelope code present for unparseable gh --version" "ADT_CFG_GH_VERSION_TOO_OLD" "$output"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DT-GHV-06: REAL_GH is honored when no bare gh is on PATH ==="
# ---------------------------------------------------------------------------
# gh-with-token-refresh.sh's REAL_GH escape hatch (#92) lets an operator
# point at a gh binary installed outside the minimal non-interactive PATH
# (cron/systemd/SSM never sourced rc files). The version precheck must
# resolve the SAME binary, not always shell out to bare `gh` — otherwise a
# host with a perfectly good REAL_GH but no bare `gh` on PATH gets a false
# "<not found>" FATAL.
REALBIN="$TMPROOT/realbin"
mkdir -p "$REALBIN"
cat > "$REALBIN/gh" <<EOF
#!/bin/bash
if [[ "\$1" == "--version" ]]; then
  echo "gh version 2.96.0 (2026-01-01)"
  exit 0
fi
echo "GH_CALLED \$*" >> "$TMPROOT/gh-calls"
exit 0
EOF
chmod +x "$REALBIN/gh"
rm -f "$BIN/gh"  # no bare `gh` anywhere on PATH — only REAL_GH resolves.
write_conf "REAL_GH=\"$REALBIN/gh\""
output=$(run_tick)
assert_not_contains "REAL_GH resolves — no false 'gh CLI is missing' FATAL" \
  "ADT_CFG_GH_VERSION_TOO_OLD" "$output"
assert_not_contains "REAL_GH resolves — GH_INSTALLED_VERSION is not '<not found>'" \
  "<not found>" "$output"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DT-GHV-07: REAL_GH below the minimum version still aborts ==="
# ---------------------------------------------------------------------------
cat > "$REALBIN/gh" <<EOF
#!/bin/bash
if [[ "\$1" == "--version" ]]; then
  echo "gh version 2.40.0 (2025-01-01)"
  exit 0
fi
exit 0
EOF
chmod +x "$REALBIN/gh"
write_conf "REAL_GH=\"$REALBIN/gh\""
output=$(run_tick)
assert_contains "REAL_GH below minimum still trips the precheck" \
  "ADT_CFG_GH_VERSION_TOO_OLD" "$output"
assert_contains "stderr names the REAL_GH-reported version" "2.40.0" "$output"

# Restore the plain-PATH `gh` stub and default conf (no REAL_GH) for any
# tests appended after this point.
write_gh_stub "2.96.0"
write_conf

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DT-GHV-05: precheck source line in tick script ==="
# ---------------------------------------------------------------------------
if grep -q 'ADT_CFG_GH_VERSION_TOO_OLD' "$TICK"; then
  echo -e "  ${GREEN}PASS${NC}: tick references the ADT_CFG_GH_VERSION_TOO_OLD envelope"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: tick missing the gh-version precheck"
  FAIL=$((FAIL + 1))
fi

# Precheck must come BEFORE any `dispatch ` call or label transition — same
# positional contract as the REVIEW_BOTS / EXECUTION_BACKEND prechecks.
PRECHECK_LINE=$(grep -n 'ADT_CFG_GH_VERSION_TOO_OLD' "$TICK" | head -1 | cut -d: -f1)
FIRST_DISPATCH_LINE=$(grep -n '^[[:space:]]*dispatch ' "$TICK" | head -1 | cut -d: -f1)
if [[ -n "$PRECHECK_LINE" && -n "$FIRST_DISPATCH_LINE" && "$PRECHECK_LINE" -lt "$FIRST_DISPATCH_LINE" ]]; then
  echo -e "  ${GREEN}PASS${NC}: precheck (line $PRECHECK_LINE) runs before any dispatch (line $FIRST_DISPATCH_LINE)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: precheck not positioned before dispatch (precheck=$PRECHECK_LINE, first dispatch=$FIRST_DISPATCH_LINE)"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
