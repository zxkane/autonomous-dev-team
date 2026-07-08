#!/bin/bash
# test-state-manager-bsd-date-tz.sh — Unit tests for issue #446
#
# Verifies fix for issue #446: state-manager.sh `check` action mis-parses
# the stored UTC mark timestamp on BSD `date` (no GNU `date -d`) in a
# non-UTC timezone, because BSD `date -j -f` ignores the trailing `Z` and
# parses the string as local time instead of UTC.
#
# This repo's CI runs Linux only, and GNU `date -d` already handles the
# `Z` suffix correctly, so a plain TZ-only test would pass before the fix
# and prove nothing. The BSD branch is forced via a PATH-shimmed fake
# `date` binary that rejects `-d` (forcing the real code to fall through)
# and emulates BSD `-j -f` semantics for both the pre-fix (no `-u`,
# ignores `Z`) and post-fix (`-u`, honors `Z` as UTC) forms.
#
# Run: bash tests/unit/test-state-manager-bsd-date-tz.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_MANAGER="$PROJECT_ROOT/skills/autonomous-common/hooks/state-manager.sh"
REAL_DATE="$(command -v date)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected exit=$expected, actual=$actual)"
    ((FAIL++))
  fi
}

assert_empty_dir() {
  local desc="$1" dir="$2"
  if [[ ! -d "$dir" ]] || [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (found: $(ls -A "$dir" 2>/dev/null | tr '\n' ' '))"
    ((FAIL++))
  fi
}

TMPDIR=$(mktemp -d)
SHIM_DIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR" "$SHIM_DIR"' EXIT

# ---------------------------------------------------------------------------
# Fake `date` binary. Placed ahead of the real `date` in PATH for the
# forced-BSD-branch cases only.
#
#   date -u +FORMAT / date +%s        -> passthrough to real date
#   date -d ...                       -> exit 1 (forces fallthrough)
#   date -j -f FORMAT VALUE +%s       -> pre-fix BSD emulation: strip
#                                         trailing Z, parse under ambient
#                                         $TZ as local time
#   date -u -j -f FORMAT VALUE +%s    -> post-fix BSD emulation: strip
#                                         trailing Z, parse as UTC
# ---------------------------------------------------------------------------
cat > "$SHIM_DIR/date" <<SHIMEOF
#!/bin/bash
REAL_DATE="$REAL_DATE"
args=("\$@")
for a in "\${args[@]}"; do
  if [[ "\$a" == "-d" ]]; then
    exit 1
  fi
done
use_utc=0
rest=("\${args[@]}")
if [[ "\${rest[0]:-}" == "-u" ]]; then
  use_utc=1
  rest=("\${rest[@]:1}")
fi
if [[ "\${rest[0]:-}" == "-j" ]]; then
  value="\${rest[3]}"
  outfmt="\${rest[4]}"
  stripped="\${value%Z}"
  if [[ \$use_utc -eq 1 ]]; then
    TZ=UTC "\$REAL_DATE" -d "\$stripped" "\$outfmt"
  else
    TZ="\${TZ:-UTC}" "\$REAL_DATE" -d "\$stripped" "\$outfmt"
  fi
  exit \$?
fi
exec "\$REAL_DATE" "\${args[@]}"
SHIMEOF
chmod +x "$SHIM_DIR/date"

setup_project() {
  local dir="$1"
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  mkdir -p "$dir/.claude/state"
  echo "a" > "$dir/a.txt"
  git -C "$dir" add a.txt
  git -C "$dir" commit -q -m "initial"
}

run_mark() {
  local project="$1" action="$2" path_prefix="$3"
  ( cd "$project" && CLAUDE_PROJECT_DIR="$project" PATH="${path_prefix}${path_prefix:+:}$PATH" "$STATE_MANAGER" mark "$action" >/dev/null 2>&1 )
}

run_check() {
  local project="$1" action="$2" path_prefix="$3"
  ( cd "$project" && CLAUDE_PROJECT_DIR="$project" PATH="${path_prefix}${path_prefix:+:}$PATH" "$STATE_MANAGER" check "$action" >/dev/null 2>&1; echo $? )
}

# Backdates a state file's timestamp by N minutes, using the REAL date
# binary directly (test scaffolding, not the code under test).
backdate_state() {
  local project="$1" action="$2" minutes="$3"
  local state_file="$project/.claude/state/${action}.json"
  local old_ts
  old_ts=$("$REAL_DATE" -u -d "$minutes minutes ago" +"%Y-%m-%dT%H:%M:%SZ")
  jq --arg ts "$old_ts" '.timestamp = $ts' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
}

# ===========================================================================
echo ""
echo "=== TC-SMTZ-001: forced-BSD branch + positive offset (Asia/Shanghai) is fresh ==="
echo ""
PROJECT1="$TMPDIR/proj1"
setup_project "$PROJECT1"
export TZ="Asia/Shanghai"
run_mark "$PROJECT1" "pr-review" "$SHIM_DIR"
exit_code=$(TZ="Asia/Shanghai" run_check "$PROJECT1" "pr-review" "$SHIM_DIR")
assert_exit "check returns 0 for a fresh mark under UTC+8 forced-BSD parsing" "0" "$exit_code"
unset TZ

# ===========================================================================
echo ""
echo "=== TC-SMTZ-002: forced-BSD branch + negative offset (America/New_York) rejects stale mark ==="
echo ""
PROJECT2="$TMPDIR/proj2"
setup_project "$PROJECT2"
export TZ="America/New_York"
run_mark "$PROJECT2" "pr-review" "$SHIM_DIR"
backdate_state "$PROJECT2" "pr-review" 45
exit_code=$(TZ="America/New_York" run_check "$PROJECT2" "pr-review" "$SHIM_DIR")
assert_exit "check returns 1 for a 45-minute-old mark under UTC-5 forced-BSD parsing" "1" "$exit_code"
unset TZ

# ===========================================================================
echo ""
echo "=== TC-SMTZ-003: GNU date -d branch unaffected (no shim, real date) ==="
echo ""
PROJECT3="$TMPDIR/proj3"
setup_project "$PROJECT3"
export TZ="Asia/Shanghai"
run_mark "$PROJECT3" "pr-review" ""
exit_code=$(TZ="Asia/Shanghai" run_check "$PROJECT3" "pr-review" "")
assert_exit "check returns 0 for a fresh mark via real GNU date -d under UTC+8" "0" "$exit_code"
unset TZ

# ===========================================================================
echo ""
echo "=== TC-SMTZ-004: state isolation — repo's own state dirs untouched ==="
echo ""
assert_empty_dir "repo .claude/state has no test-created marks" "$PROJECT_ROOT/.claude/state"
assert_empty_dir "repo .kiro/state has no test-created marks" "$PROJECT_ROOT/.kiro/state"
assert_empty_dir "repo .agents/state has no test-created marks" "$PROJECT_ROOT/.agents/state"

# Summary
echo ""
echo "========================================"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "========================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
