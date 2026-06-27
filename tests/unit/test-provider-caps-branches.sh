#!/bin/bash
# test-provider-caps-branches.sh — issue #286, caps-branch coverage gate
# (TC-CAPS-NNN). Promotes the §7.4 fake degraded-capability fixture provider to a
# COVERAGE GATE: for every caps=0/degraded flag that has a LIVE caller
# degradation branch on this HEAD, the fake provider drives it through the public
# seam and the test asserts the branch is REACHABLE (not dead code); for every
# flag whose caller branch is NOT yet wired (it lands with the GitLab/Asana PRs,
# spec §4.3), the test asserts NO caller branch keys on it yet — a structural
# "nothing to cover" that a future wiring PR is FORCED to flip (and thus add its
# coverage test).
#
# Spec §4.3: GitHub's .caps = today's behavior; "the only live branches are
# GitHub's current ones". On this GitHub-only HEAD, grep proves exactly 7 of the
# 13 caps have a live caller branch reading the cap; the other 6 degradations are
# defined in the provider/spec but not yet wired into a caller branch.
#
# The fake provider is selected through the PUBLIC seam (ISSUE_PROVIDER=degraded
# / CODE_HOST=degraded + AUTONOMOUS_PROVIDERS_DIR pointed at the fixture dir),
# exactly the #280 TC-PROVIDER-DISPATCH-030/031 harness — NOT by reading .caps
# directly.
#
# Run: bash tests/unit/test-provider-caps-branches.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
ITP_LIB="$SCRIPTS/lib-issue-provider.sh"
CHP_LIB="$SCRIPTS/lib-code-host.sh"
FAKE_PROVIDER="$SCRIPT_DIR/fixtures/provider-degraded"

# The caller-layer files that may carry a caps-keyed degradation branch. This is
# the cutover caller layer PLUS the two standalone consumers (setup-labels.sh,
# lib-auth.sh) that also read caps — the FULL set a degradation branch could live
# in. A cap is "live-branched" iff `itp_caps <cap>` / `chp_caps <cap>` appears in
# one of these as executable (non-comment) code.
CALLER_FILES=(
  "$SCRIPTS/lib-dispatch.sh" "$SCRIPTS/autonomous-dev.sh" "$SCRIPTS/autonomous-review.sh"
  "$SCRIPTS/setup-labels.sh" "$SCRIPTS/lib-auth.sh"
)
for f in "$SCRIPTS"/lib-review-*.sh; do CALLER_FILES+=("$f"); done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad()  { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
note() { echo -e "  ${YELLOW}NOTE${NC}: $1"; }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

# Does any caller-layer file have an EXECUTABLE (non-comment) branch reading
# `<seam>_caps <cap>`? Returns the "file:line — text" of the first hit, or empty.
caller_branch_for() {
  local cap="$1" f rest
  for f in "${CALLER_FILES[@]}"; do
    [ -f "$f" ] || continue
    # Match `itp_caps <cap>` or `chp_caps <cap>`, skip comment lines.
    while IFS= read -r rest; do
      local stripped="${rest#"${rest%%[![:space:]]*}"}"
      [ "${stripped:0:1}" = "#" ] && continue
      printf '%s — %s\n' "${f##*/}" "$stripped"
      return 0
    done < <(grep -E "(itp_caps|chp_caps)[[:space:]]+${cap}([[:space:]]|\)|\"|\$)" "$f" 2>/dev/null)
  done
  return 1
}

# Read a cap through the PUBLIC seam against the degraded fixture provider.
#   read_degraded_cap <itp|chp> <cap> → prints the value (or empty on miss).
read_degraded_cap() {
  local seam="$1" cap="$2"
  env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      ISSUE_PROVIDER=degraded CODE_HOST=degraded AUTONOMOUS_PROVIDERS_DIR="$FAKE_PROVIDER" \
  bash -c '
    source "'"$ITP_LIB"'" 2>/dev/null
    source "'"$CHP_LIB"'" 2>/dev/null
    '"${seam}"'_caps "'"$cap"'" 2>/dev/null
  '
}

# The 7 caps WITH a live caller degradation branch on this HEAD. Each row:
# "<seam> <cap> <expected-degraded-value>".
LIVE_BRANCH_CAPS=(
  "itp cross_ref_shorthand 0"
  "itp edit_comment 0"
  "itp label_colors 0"
  "chp native_issue_pr_link 0"
  "chp rest_request_changes 0"
  "chp review_bots 0"
  "chp merge_closes_issue 0"
)
# The 6 caps whose caller branch is NOT yet wired (degradation lands with the
# GitLab/Asana PRs; spec §4.3). Each row: "<seam> <cap>".
NO_BRANCH_CAPS=(
  "itp server_side_state_and"
  "itp server_side_state_negation"
  "itp distinct_bot_author"
  "itp read_after_write_state"
  "itp body_checkbox"
  "itp marker_channel"
)

# ---------------------------------------------------------------------------
echo "=== TC-CAPS-001..007: each LIVE-branch cap is reachable + driven through the degraded fixture ==="
# ---------------------------------------------------------------------------
for row in "${LIVE_BRANCH_CAPS[@]}"; do
  read -r seam cap expected <<<"$row"
  # (a) a live caller branch reads the cap (reachable, not dead).
  if hit="$(caller_branch_for "$cap")"; then
    ok "[$cap] live caller branch reads ${seam}_caps $cap → $hit"
  else
    bad "[$cap] NO caller branch reads ${seam}_caps $cap — the degradation branch is missing or dead (this cap was declared live-branched)"
  fi
  # (b) the fake degraded provider reports the degraded value through the seam,
  #     so the branch's caps=0 path is actually driveable end-to-end.
  val="$(read_degraded_cap "$seam" "$cap")"
  if [ "$val" = "$expected" ]; then
    ok "[$cap] degraded fixture reports ${seam}_caps $cap=$val through the public seam (caps=0 branch driveable)"
  else
    bad "[$cap] degraded fixture ${seam}_caps $cap='$val' (expected '$expected') — caps=0 branch NOT driveable"
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CAPS-010..015: each NO-LIVE-BRANCH cap has NO caller branch yet (structural 'nothing to cover'; spec §4.3) ==="
# ---------------------------------------------------------------------------
# These degradations are DEFINED in the fixture/spec but not yet wired into a
# caller branch (they land with the GitLab/Asana PRs). Asserting their ABSENCE
# is the coverage guard: when a future PR wires one, this flips red and FORCES a
# coverage assertion to be added (moving the cap into LIVE_BRANCH_CAPS).
for row in "${NO_BRANCH_CAPS[@]}"; do
  read -r seam cap <<<"$row"
  if hit="$(caller_branch_for "$cap")"; then
    bad "[$cap] a caller branch now reads ${seam}_caps $cap ($hit) — wiring landed; MOVE $cap into LIVE_BRANCH_CAPS and add a driven-branch assertion (no caps=0 branch may ship untested, spec §7.4)"
  else
    ok "[$cap] no caller branch keys on $cap yet (degradation lands with GitLab/Asana; nothing to cover on this GitHub-only HEAD — spec §4.3)"
  fi
  # The fixture STILL declares the degraded value (so the future wiring has a
  # fixture to drive). Confirm it is readable through the seam.
  val="$(read_degraded_cap "$seam" "$cap")"
  if [ -n "$val" ]; then
    note "[$cap] fixture declares the degraded value ($val) ready for the future wiring PR"
  else
    bad "[$cap] degraded fixture does NOT declare $cap — the future wiring PR will have no fixture to drive"
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CAPS-020: all 13 caps accounted for (7 live + 6 deferred = 9 ITP + 4 CHP) ==="
# ---------------------------------------------------------------------------
n_live=${#LIVE_BRANCH_CAPS[@]}
n_def=${#NO_BRANCH_CAPS[@]}
total=$((n_live + n_def))
if [ "$total" -eq 13 ]; then ok "13 caps total ($n_live live + $n_def deferred)"; else bad "cap accounting wrong: $n_live + $n_def = $total (expected 13)"; fi
# ITP = 9 (8 listed by name in §4.1 + marker_channel), CHP = 4.
n_itp=$(printf '%s\n' "${LIVE_BRANCH_CAPS[@]}" "${NO_BRANCH_CAPS[@]}" | awk '$1=="itp"' | wc -l | tr -d ' ')
n_chp=$(printf '%s\n' "${LIVE_BRANCH_CAPS[@]}" "${NO_BRANCH_CAPS[@]}" | awk '$1=="chp"' | wc -l | tr -d ' ')
if [ "$n_itp" -eq 9 ] && [ "$n_chp" -eq 4 ]; then ok "9 ITP + 4 CHP caps (matches §4.1/§4.2)"; else bad "ITP/CHP split wrong: $n_itp ITP + $n_chp CHP (expected 9 + 4)"; fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CAPS-021: degraded fixture sources clean through the seam + every cap reads back ==="
# ---------------------------------------------------------------------------
if bash -n "$FAKE_PROVIDER/itp-degraded.sh" 2>/dev/null && bash -n "$FAKE_PROVIDER/chp-degraded.sh" 2>/dev/null; then
  ok "fake itp-degraded.sh + chp-degraded.sh pass bash -n"
else
  bad "fake degraded provider .sh has a syntax error"
fi
# Every one of the 13 caps must read back a non-empty value through the seam.
missing=""
for row in "${LIVE_BRANCH_CAPS[@]}" "${NO_BRANCH_CAPS[@]}"; do
  read -r seam cap _ <<<"$row"
  [ -n "$(read_degraded_cap "$seam" "$cap")" ] || missing="$missing $cap"
done
if [ -z "$missing" ]; then ok "all 13 caps resolve through the degraded fixture seam"; else bad "caps with no fixture value:$missing"; fi

# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
