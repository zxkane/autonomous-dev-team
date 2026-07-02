#!/bin/bash
# test-lib-review-postfail.sh — Unit tests for the CLI-agnostic post-failed
# verdict drop-reason detector (INV-69, issue #247).
#
# Every review CLI posts its verdict through the SAME deterministic helper
# `post-verdict.sh` (INV-56), which exits non-zero on a failed `gh issue comment`
# — but that exit code is observed by the agent's own session, not the wrapper,
# so a transient GitHub/API/token error during the post collapses into the same
# opaque `unavailable` (INV-40) as an agent that never reviewed. This lib reads a
# breadcrumb the helper drops on a failed post (pid_dir_for_project()/
# verdict-postfail-<session_id>) and classifies the drop so the wrapper can
# surface a distinct `post-failed` reason. CLI-agnostic — keyed on a session id,
# not a per-CLI log — and evaluated AHEAD of the per-CLI agy/codex/kiro scrapers.
#
# Tests:
#   - _classify_postfail_drop_reason: presence + gh-rc classification from a
#     session-keyed breadcrumb under pid_dir_for_project()
#   - _postfail_drop_reason_phrase: human-facing rendering of a reason token
#   - _postfail_breadcrumb_path: deterministic path derivation
#   - source-of-truth: wrapper sources the lib, calls the classifier on each
#     unavailable agent's session id BEFORE the per-CLI branches, interpolates
#     the reason; CI shellcheck lists the lib.
#
# Run: bash tests/unit/test-lib-review-postfail.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-postfail.sh"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
CI="$PROJECT_ROOT/.github/workflows/ci.yml"

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
    echo "      expected=[$expected]"
    echo "      actual=  [$actual]"
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
    echo "      haystack='${haystack:0:300}'"
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
    echo "      should NOT contain='$needle'"
    echo "      haystack='${haystack:0:300}'"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

[[ -f "$LIB" ]] || {
  echo -e "  ${RED}FAIL${NC}: $LIB not found — implementation step required first"
  echo "  PASS: $PASS"
  echo "  FAIL: $((FAIL + 1))"
  exit 1
}

# Pin the pid dir so _postfail_breadcrumb_path is hermetic and pid_dir_for_project
# (sourced via lib-config.sh) resolves under a temp dir.
PIDDIR="$(mktemp -d)"
export PROJECT_ID=tproj
export AUTONOMOUS_PID_DIR="$PIDDIR"

# lib-review-postfail.sh derives the breadcrumb path via pid_dir_for_project()
# (from lib-config.sh) — source it first so the helper resolves, exactly as the
# wrapper / post-verdict.sh do at runtime.
LIBCONFIG="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-config.sh"
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-config.sh
[[ -f "$LIBCONFIG" ]] && source "$LIBCONFIG"

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-postfail.sh
source "$LIB"

# write_breadcrumb <session_id> [gh_rc] — plant a breadcrumb the way post-verdict.sh
# would, at the path the lib derives. Omit gh_rc to test the no-rc token shape.
write_breadcrumb() {
  local sid="$1" rc="${2:-}"
  local bc; bc=$(_postfail_breadcrumb_path "$sid")
  mkdir -p "$(dirname "$bc")"
  {
    printf 'issue=247\n'
    printf 'agent=agy\n'
    printf 'session=%s\n' "$sid"
    [[ -n "$rc" ]] && printf 'gh_rc=%s\n' "$rc"
  } > "$bc"
}

# ---------------------------------------------------------------------------
echo "=== TC-PF-DET: _classify_postfail_drop_reason ==="
# ---------------------------------------------------------------------------

# TC-PF-DET-01: breadcrumb present with gh_rc=1 → `post-failed:gh-rc 1`.
write_breadcrumb "sid-DET01" 1
assert_eq "TC-PF-DET-01 breadcrumb+rc → post-failed:gh-rc 1" \
  "post-failed:gh-rc 1" "$(_classify_postfail_drop_reason "sid-DET01")"

# TC-PF-DET-02: breadcrumb present, no parseable rc → bare `post-failed`.
write_breadcrumb "sid-DET02"
assert_eq "TC-PF-DET-02 breadcrumb no-rc → post-failed" \
  "post-failed" "$(_classify_postfail_drop_reason "sid-DET02")"

# TC-PF-DET-03: no breadcrumb for the session → empty.
assert_eq "TC-PF-DET-03 no breadcrumb → empty" \
  "" "$(_classify_postfail_drop_reason "sid-DET03-absent")"

# TC-PF-DET-04: breadcrumb path is a directory (unreadable as a file) → empty.
mkdir -p "$(_postfail_breadcrumb_path "sid-DET04")"
assert_eq "TC-PF-DET-04 breadcrumb path is a dir → empty (no crash)" \
  "" "$(_classify_postfail_drop_reason "sid-DET04")"

# TC-PF-DET-05: empty session id arg → empty (no crash).
assert_eq "TC-PF-DET-05 empty session id → empty" \
  "" "$(_classify_postfail_drop_reason "")"

# TC-PF-DET-06: runs under `set -euo pipefail` without aborting (rc 0).
( set -euo pipefail; _classify_postfail_drop_reason "sid-DET06-absent" >/dev/null ); RC=$?
assert_eq "TC-PF-DET-06 classifier returns 0 under set -euo pipefail" "0" "$RC"

# TC-PF-DET-07 (#247 review finding): an EXISTING breadcrumb with NO `gh_rc` line,
# classified under `set -euo pipefail` WITH `inherit_errexit`, must NOT abort and
# must echo `post-failed`. The `grep` for `gh_rc` exits 1, so under `pipefail` the
# whole pipeline exits 1; WITHOUT the `|| true` inside the command substitution
# the failed assignment aborts the function before the bare-token path — but ONLY
# when errexit propagates into the `$(...)`, i.e. under `shopt -s inherit_errexit`.
# `inherit_errexit` is the condition that turns this latent defect active (a future
# wrapper hardening could enable it), so the regression MUST set it — without it
# bash 5.x suppresses errexit inside the substitution and even the buggy code
# passes (DET-02/DET-06 each miss this). Verified red↔green: this fails against the
# pre-`|| true` helper and passes after. Assert BOTH rc 0 (no abort) and the token.
write_breadcrumb "sid-DET07"
( set -euo pipefail; shopt -s inherit_errexit; _classify_postfail_drop_reason "sid-DET07" >/dev/null ); RC=$?
assert_eq "TC-PF-DET-07a existing breadcrumb w/o gh_rc returns 0 under set -e + inherit_errexit (no abort)" "0" "$RC"
assert_eq "TC-PF-DET-07b existing breadcrumb w/o gh_rc → post-failed under set -e + inherit_errexit" \
  "post-failed" "$( set -euo pipefail; shopt -s inherit_errexit; _classify_postfail_drop_reason "sid-DET07" )"

# ---------------------------------------------------------------------------
echo "=== TC-PF-PHR: _postfail_drop_reason_phrase ==="
# ---------------------------------------------------------------------------

# TC-PF-PHR-01: token with rc → human clause names post-failed AND the rc.
PHR=$(_postfail_drop_reason_phrase "post-failed:gh-rc 1")
assert_contains "TC-PF-PHR-01a phrase names post-failed" "post-failed" "$PHR"
assert_contains "TC-PF-PHR-01b phrase names cli rc 1" "cli rc 1" "$PHR"

# TC-PF-PHR-02: bare token → names post-failed, no `cli rc`.
PHR=$(_postfail_drop_reason_phrase "post-failed")
assert_contains "TC-PF-PHR-02a bare phrase names post-failed" "post-failed" "$PHR"
assert_not_contains "TC-PF-PHR-02b bare phrase has no 'cli rc'" "cli rc" "$PHR"

# TC-PF-PHR-03: empty token → empty phrase.
assert_eq "TC-PF-PHR-03 empty token → empty phrase" "" "$(_postfail_drop_reason_phrase "")"

# TC-PF-PHR-04: unknown token → empty phrase (no over-claim).
assert_eq "TC-PF-PHR-04 unknown token → empty phrase" "" "$(_postfail_drop_reason_phrase "garbage-token")"

# ---------------------------------------------------------------------------
echo "=== TC-PF-SRC: source-of-truth wiring (autonomous-review.sh) ==="
# ---------------------------------------------------------------------------

# TC-PF-SRC-01: wrapper sources the lib.
assert_grep "TC-PF-SRC-01 wrapper sources lib-review-postfail.sh" \
  'source .*lib-review-postfail\.sh|lib-review-postfail\.sh' "$WRAPPER"

# TC-PF-SRC-02: wrapper calls the classifier on the agent's session id.
assert_grep "TC-PF-SRC-02 wrapper calls _classify_postfail_drop_reason on AGENT_SESSION_IDS" \
  '_classify_postfail_drop_reason .*AGENT_SESSION_IDS' "$WRAPPER"

# TC-PF-SRC-03: the post-failed check runs BEFORE the per-CLI agy/codex/kiro
# branches. Assert the first _classify_postfail_drop_reason line number is below
# (earlier than) the first _classify_agy_drop_reason CALL SITE in the wrapper.
# Key on the call site (`=$(_classify_…`) — NOT a bare mention — so the source-
# block header comments at the top of the wrapper (which name both helpers) do
# not fool the "first occurrence" heuristic.
PF_LINE=$(grep -n '=\$(_classify_postfail_drop_reason' "$WRAPPER" | head -1 | cut -d: -f1)
AGY_LINE=$(grep -n '=\$(_classify_agy_drop_reason' "$WRAPPER" | head -1 | cut -d: -f1)
if [[ -n "$PF_LINE" && -n "$AGY_LINE" && "$PF_LINE" -lt "$AGY_LINE" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-PF-SRC-03 post-failed check precedes the per-CLI agy branch (line $PF_LINE < $AGY_LINE)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-PF-SRC-03 post-failed check does NOT precede the agy branch (pf=$PF_LINE agy=$AGY_LINE)"
  FAIL=$((FAIL + 1))
fi

# TC-PF-SRC-04: the dropped-agent reason path interpolates the post-failed phrase
# into _dropped_reasons (the same accumulator the agy/codex/kiro reasons use).
assert_grep "TC-PF-SRC-04 wrapper folds the post-failed phrase into _dropped_reasons" \
  '_dropped_reasons\+=.*_postfail_drop_reason_phrase' "$WRAPPER"

# TC-PF-SRC-05: CI shellcheck job lists the new lib.
assert_grep "TC-PF-SRC-05 CI shellcheck lists lib-review-postfail.sh" \
  'lib-review-postfail\.sh' "$CI"

# TC-PF-SRC-06: bash -n parses the lib AND post-verdict.sh AND the wrapper.
for f in "$LIB" \
         "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/post-verdict.sh" \
         "$WRAPPER"; do
  if bash -n "$f" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: TC-PF-SRC-06 bash -n parses $(basename "$f")"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-PF-SRC-06 syntax error in $(basename "$f")"
    FAIL=$((FAIL + 1))
  fi
done

# ---------------------------------------------------------------------------
echo "=== TC-PF-REG: regression ==="
# ---------------------------------------------------------------------------

# TC-PF-REG-01: an unavailable agent with NO breadcrumb yields an empty token, so
# the wrapper keeps the bare `unavailable` wording (no over-claim).
assert_eq "TC-PF-REG-01 no-breadcrumb agent → empty token (bare unavailable kept)" \
  "" "$(_classify_postfail_drop_reason "sid-REG01-absent")"

# TC-PF-REG-03: the precedence is structural (SRC-03) — when no breadcrumb exists
# the per-CLI scrape still runs, so an agy quota drop is unaffected. Asserted at
# the unit level here by confirming the classifier reports nothing for an agent
# whose only failure is on the CLI side (no post breadcrumb).
assert_eq "TC-PF-REG-03 CLI-side-only failure (no post breadcrumb) → empty (per-CLI scrape owns it)" \
  "" "$(_classify_postfail_drop_reason "sid-REG03-clionly")"

rm -rf "$PIDDIR"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
