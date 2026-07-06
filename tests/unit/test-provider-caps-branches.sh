#!/bin/bash
# test-provider-caps-branches.sh — issue #286, caps-branch coverage gate
# (TC-CAPS-NNN). Promotes the §7.4 fake degraded-capability fixture provider to a
# COVERAGE GATE for the caps=0 caller-degradation branches.
#
# COVERAGE TAXONOMY (read against issue #286's AC literally).
# ---------------------------------------------------------------------------
# AC #286: "for EACH caps=0 flag … the fake provider exercises the corresponding
# caller degradation branch at least once — asserting the branch is reachable,
# not dead code", and "FAILs if any caller degradation branch is unreachable/dead".
#
# REALITY (spec §4.3, the no-behavior-change / GitHub-only first deliverable):
# "the only live branches are GitHub's current ones." grep proves exactly 8 of the
# 14 caps have a LIVE caller-side branch that reads the cap TODAY; the other 6
# caller branches land later with the GitLab/Asana PRs (or, for `assignees`
# #435, the follow-up ISSUE_FILTER PR-B) — their .caps degraded value is already
# declared, but no caller-side code branches on them yet, and the degraded
# fixture .sh are empty scaffolds — there is NO branch to run). Exercising
# a branch that does not exist is impossible, and writing a test-only consumer to
# fake it would test a path that is not in production (violating §4.3). So this gate
# splits the 14 into two honestly-distinguished sets and is GREEN only because the
# deferred set is explicitly WAIVED with a fail-on-wiring tripwire — never a bare PASS:
#
#   EXERCISED (8): the cap has a live caller branch AND
#     - the degraded value is driveable through the public seam (itp_caps/chp_caps),
#       AND for a representative subset the branch is RUN END-TO-END against the
#       degraded fixture and its degraded observable asserted (so "reachable" is
#       demonstrated by execution, not just by grep + value-read);
#   WAIVED  (6): NO caller branch reads the cap yet (asserted absent). This is NOT
#     a pass — it is a tripwired waiver: if a caller branch EVER appears for a
#     waived cap, TC-CAPS-010..015 FAIL ("wiring landed → move it to EXERCISED and
#     add a real exercise test"), so no future caps=0 branch can ship untested.
#
# The headline prints `exercised=8 waived=6 total=14` and asserts the split sums to
# the full 10 ITP + 4 CHP matrix — the gate cannot go green while hiding an
# unaccounted cap, and cannot claim all 14 are exercised when 6 have no branch.
#
# Fixture: tests/unit/fixtures/provider-degraded/, selected through the PUBLIC seam
# (ISSUE_PROVIDER=degraded / CODE_HOST=degraded + AUTONOMOUS_PROVIDERS_DIR), per
# #280 TC-PROVIDER-DISPATCH-030/031.
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

# The caller-layer files that may carry a caps-keyed degradation branch: the
# cutover caller layer PLUS the standalone consumers (setup-labels.sh, lib-auth.sh,
# mark-issue-checkbox.sh) that also read caps. A cap is "live-branched" iff
# `itp_caps <cap>` / `chp_caps <cap>` appears as executable (non-comment) code here.
# mark-issue-checkbox.sh is a symlink into autonomous-common/scripts/ (the real
# source of the body_checkbox=0 branch); grep follows it transparently.
CALLER_FILES=(
  "$SCRIPTS/lib-dispatch.sh" "$SCRIPTS/autonomous-dev.sh" "$SCRIPTS/autonomous-review.sh"
  "$SCRIPTS/setup-labels.sh" "$SCRIPTS/lib-auth.sh" "$SCRIPTS/mark-issue-checkbox.sh"
)
for f in "$SCRIPTS"/lib-review-*.sh; do CALLER_FILES+=("$f"); done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad()  { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
note() { echo -e "  ${YELLOW}NOTE${NC}: $1"; }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

# Does any caller-layer file have an EXECUTABLE (non-comment) branch reading
# `<seam>_caps <cap>`? Prints the first "file — text" hit, or returns 1.
caller_branch_for() {
  local cap="$1" f rest stripped
  for f in "${CALLER_FILES[@]}"; do
    [ -f "$f" ] || continue
    while IFS= read -r rest; do
      stripped="${rest#"${rest%%[![:space:]]*}"}"
      [ "${stripped:0:1}" = "#" ] && continue
      printf '%s — %s\n' "${f##*/}" "$stripped"
      return 0
    done < <(grep -E "(itp_caps|chp_caps)[[:space:]]+${cap}([[:space:]]|\)|\"|\$)" "$f" 2>/dev/null)
  done
  return 1
}

# Read a cap through the PUBLIC seam against the degraded fixture provider.
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

# 8 caps WITH a live caller branch. "<seam> <cap> <expected-degraded-value>".
# body_checkbox is live-branched in mark-issue-checkbox.sh:137 (the documented
# body_checkbox=0 native-subtask remap error path) — exercised end-to-end below.
LIVE_BRANCH_CAPS=(
  "itp cross_ref_shorthand 0"
  "itp edit_comment 0"
  "itp label_colors 0"
  "itp body_checkbox 0"
  "chp native_issue_pr_link 0"
  "chp rest_request_changes 0"
  "chp review_bots 0"
  "chp merge_closes_issue 0"
)
# 6 caps whose caller branch is NOT yet wired (spec §4.3). "<seam> <cap>".
# `assignees` (#435, ISSUE_FILTER seam PR-A) is a NEW cap this PR — no caller
# branches on it yet; wiring lands with the follow-up ISSUE_FILTER PR-B's
# assignee-atom capability gate (§4.3 pattern: the .caps bit ships now,
# honestly declared, before the caller-side branch exists).
WAIVED_CAPS=(
  "itp server_side_state_and"
  "itp server_side_state_negation"
  "itp distinct_bot_author"
  "itp read_after_write_state"
  "itp marker_channel"
  "itp assignees"
)

EXERCISED=0; WAIVED=0; EXECUTED=0

# ---------------------------------------------------------------------------
echo "=== TC-CAPS-000: tripwire self-test — caller_branch_for is not a no-op grep ==="
# ---------------------------------------------------------------------------
# Prove the detector RETURNS a branch for a known-present cap and NOTHING for a
# known-absent token. Without this, the WAIVED tripwire (TC-CAPS-010..015) could
# be a grep that never matches anything — a silent hole.
if caller_branch_for "label_colors" >/dev/null; then ok "tripwire finds a known-present cap (label_colors)"; else bad "tripwire FAILED to find label_colors — detector is broken"; fi
if caller_branch_for "no_such_cap_zzz_unwired" >/dev/null; then bad "tripwire matched a nonexistent cap — detector over-matches"; else ok "tripwire returns empty for a known-absent token"; fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CAPS-001..008: each LIVE-branch cap is reachable + its degraded value driveable through the seam ==="
# ---------------------------------------------------------------------------
for row in "${LIVE_BRANCH_CAPS[@]}"; do
  read -r seam cap expected <<<"$row"
  if hit="$(caller_branch_for "$cap")"; then
    ok "[$cap] live caller branch reads ${seam}_caps $cap → $hit"
  else
    bad "[$cap] NO caller branch reads ${seam}_caps $cap — declared live but the branch is missing/dead"
  fi
  val="$(read_degraded_cap "$seam" "$cap")"
  if [ "$val" = "$expected" ]; then
    ok "[$cap] degraded fixture reports ${seam}_caps $cap=$val through the public seam (caps=0 path driveable)"
    EXERCISED=$((EXERCISED + 1))
  else
    bad "[$cap] degraded fixture ${seam}_caps $cap='$val' (expected '$expected') — caps=0 path NOT driveable"
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CAPS-008: END-TO-END execution of representative caps=0 branches against the degraded fixture ==="
# ---------------------------------------------------------------------------
# Converts "grep-reachable + value-driveable" into "demonstrably RUN": call the
# REAL caller code with the degraded provider active and assert the degraded
# observable. Even a subset proves the harness drives real branches (so the
# grep-reachability of the rest is a genuine reachability check, not a fig leaf).

# (1) label_colors=0 — run setup-labels.sh as a subprocess with the degraded
#     provider; the documented label_colors=0 error path must fire (exit 1).
e2e1="$(env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
        ISSUE_PROVIDER=degraded AUTONOMOUS_PROVIDERS_DIR="$FAKE_PROVIDER" \
        bash "$SCRIPTS/setup-labels.sh" owner/repo 2>&1)"; e2e1_rc=$?
if [ "$e2e1_rc" -ne 0 ] && grep -q 'label_colors=0' <<<"$e2e1"; then
  ok "[label_colors] END-TO-END: setup-labels.sh ran the label_colors=0 branch (exit $e2e1_rc, documented error emitted)"
  EXECUTED=$((EXECUTED + 1))
else
  bad "[label_colors] END-TO-END did not execute the label_colors=0 branch (rc=$e2e1_rc)"
fi

# (2)+(3) merge_closes_issue=0 + native_issue_pr_link=0 — eval the REAL
#     _render_close_keyword bytes from autonomous-dev.sh (NOT a hand copy) with a
#     degraded chp_caps stub; the non-closing `Related to #N` backref must render.
render_kw() {
  local mc="$1" nipl="$2" issue="$3"
  bash -c '
    eval "$(sed -n "/^_render_close_keyword()/,/^}/p" "'"$SCRIPTS"'/autonomous-dev.sh")"
    chp_caps() { case "$1" in merge_closes_issue) echo "'"$mc"'";; native_issue_pr_link) echo "'"$nipl"'";; *) echo 0;; esac; }
    _render_close_keyword "'"$issue"'"
  '
}
out_related="$(render_kw 0 0 42)"
if [ "$out_related" = "Related to #42" ]; then
  ok "[merge_closes_issue+native_issue_pr_link] END-TO-END: _render_close_keyword(0,0) ran the degraded branch → 'Related to #42'"
  EXECUTED=$((EXECUTED + 1))
else
  bad "[merge_closes_issue+native_issue_pr_link] END-TO-END degraded branch wrong: '$out_related' (expected 'Related to #42')"
fi
# native_issue_pr_link=1 sub-branch → empty backref (the OTHER arm of the same branch).
out_empty="$(render_kw 0 1 42)"
if [ -z "$out_empty" ]; then
  ok "[native_issue_pr_link=1] END-TO-END: _render_close_keyword(0,1) ran the native-link arm → empty backref"
  EXECUTED=$((EXECUTED + 1))
else
  bad "[native_issue_pr_link=1] END-TO-END arm wrong: '$out_empty' (expected empty)"
fi
# Sanity: the NON-degraded default (merge_closes_issue=1) renders the GitHub literal.
out_closes="$(render_kw 1 0 42)"
if [ "$out_closes" = "Closes #42" ]; then
  ok "[merge_closes_issue=1] END-TO-END: default arm renders 'Closes #42' (no behavior change for GitHub)"
else
  bad "[merge_closes_issue=1] default arm wrong: '$out_closes' (expected 'Closes #42')"
fi

# (4) body_checkbox=0 — run mark-issue-checkbox.sh as a subprocess with the
#     degraded provider active and a stub `gh` returning a body that contains the
#     target unchecked checkbox. The script must reach the cap check AFTER the awk
#     rewrite and fire the documented body_checkbox=0 native-subtask-remap error
#     (exit 1) WITHOUT issuing any PATCH — proving the degraded branch executes.
_bc_tmp="$(mktemp -d)"
cat >"$_bc_tmp/gh" <<'STUB'
#!/bin/bash
# Stub gh: any non-PATCH call (the ABSTRACT itp_read_task contract, [W1b]
# #396 — `gh issue view … --json title,body,state,labels,comments`, normalized
# by the leaf) returns a body with the target checkbox; a PATCH must NEVER
# happen on the body_checkbox=0 path (fail loud if it does).
for a in "$@"; do [ "$a" = "PATCH" ] && { echo "STUB-PATCH-CALLED" >&2; exit 99; }; done
printf '{"title":"","body":"- [ ] flip me","state":"OPEN","labels":[],"comments":[]}'
STUB
chmod +x "$_bc_tmp/gh"
e2e_bc="$(env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
          PATH="$_bc_tmp:$PATH" \
          ISSUE_PROVIDER=degraded AUTONOMOUS_PROVIDERS_DIR="$FAKE_PROVIDER" \
          bash "$SCRIPTS/mark-issue-checkbox.sh" 42 "flip me" 2>&1)"; e2e_bc_rc=$?
if [ "$e2e_bc_rc" -ne 0 ] && grep -q 'body_checkbox=0' <<<"$e2e_bc" && ! grep -q 'STUB-PATCH-CALLED' <<<"$e2e_bc"; then
  ok "[body_checkbox] END-TO-END: mark-issue-checkbox.sh ran the body_checkbox=0 branch (exit $e2e_bc_rc, documented error, no PATCH issued)"
  EXECUTED=$((EXECUTED + 1))
else
  bad "[body_checkbox] END-TO-END did not execute the body_checkbox=0 branch (rc=$e2e_bc_rc, out: ${e2e_bc:0:160})"
fi
rm -rf "$_bc_tmp"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CAPS-010..015: each WAIVED cap has NO caller branch yet — tripwired, NOT a free pass (spec §4.3) ==="
# ---------------------------------------------------------------------------
for row in "${WAIVED_CAPS[@]}"; do
  read -r seam cap <<<"$row"
  if hit="$(caller_branch_for "$cap")"; then
    bad "[$cap] WIRING LANDED — a caller branch now reads ${seam}_caps $cap ($hit). MOVE $cap into LIVE_BRANCH_CAPS and add a real exercise/execution test: no caps=0 branch may ship untested (spec §7.4). This waiver tripwire is doing its job."
  else
    ok "[$cap] WAIVED: no caller branch keys on $cap yet (lands with GitLab/Asana, spec §4.3) — tripwire armed"
    WAIVED=$((WAIVED + 1))
  fi
  # The fixture MUST still declare the degraded value (so the future wiring PR has
  # a fixture to drive) — a HARD assertion, not a NOTE.
  val="$(read_degraded_cap "$seam" "$cap")"
  if [ -n "$val" ]; then ok "[$cap] degraded fixture declares the value ($val) — ready for the future wiring PR"; else bad "[$cap] degraded fixture does NOT declare $cap — the future wiring PR has no fixture to drive"; fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CAPS-020: coverage accounting — exercised + waived = 14 (10 ITP + 4 CHP), no cap unaccounted ==="
# ---------------------------------------------------------------------------
n_live=${#LIVE_BRANCH_CAPS[@]}; n_waived=${#WAIVED_CAPS[@]}; total=$((n_live + n_waived))
echo "  COVERAGE: exercised=$EXERCISED (driveable) / executed-end-to-end=$EXECUTED / waived=$WAIVED / declared-live=$n_live declared-waived=$n_waived total=$total"
if [ "$total" -eq 14 ]; then ok "14 caps total ($n_live live + $n_waived waived)"; else bad "cap accounting wrong: $n_live + $n_waived = $total (expected 14)"; fi
if [ "$EXERCISED" -eq "$n_live" ]; then ok "every declared-live cap is reachable + driveable ($EXERCISED/$n_live)"; else bad "only $EXERCISED/$n_live live caps driveable"; fi
if [ "$WAIVED" -eq "$n_waived" ]; then ok "every declared-waived cap is still unwired ($WAIVED/$n_waived) — none silently gained a branch"; else bad "a waived cap gained a branch ($WAIVED/$n_waived still unwired) — see TC-CAPS-010..015"; fi
if [ "$EXECUTED" -ge 3 ]; then ok "at least 3 caps=0 branches RUN end-to-end ($EXECUTED) — 'reachable' is demonstrated by execution, not just grep"; else bad "only $EXECUTED caps=0 branches executed end-to-end (need >=3 to demonstrate the harness drives real branches)"; fi
n_itp=$(printf '%s\n' "${LIVE_BRANCH_CAPS[@]}" "${WAIVED_CAPS[@]}" | awk '$1=="itp"' | wc -l | tr -d ' ')
n_chp=$(printf '%s\n' "${LIVE_BRANCH_CAPS[@]}" "${WAIVED_CAPS[@]}" | awk '$1=="chp"' | wc -l | tr -d ' ')
if [ "$n_itp" -eq 10 ] && [ "$n_chp" -eq 4 ]; then ok "10 ITP + 4 CHP caps (matches §4.1/§4.2)"; else bad "ITP/CHP split wrong: $n_itp ITP + $n_chp CHP (expected 10 + 4)"; fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CAPS-021: degraded fixture sources clean + every cap reads back through the seam ==="
# ---------------------------------------------------------------------------
if bash -n "$FAKE_PROVIDER/itp-degraded.sh" 2>/dev/null && bash -n "$FAKE_PROVIDER/chp-degraded.sh" 2>/dev/null; then
  ok "fake itp-degraded.sh + chp-degraded.sh pass bash -n"
else
  bad "fake degraded provider .sh has a syntax error"
fi
missing=""
for row in "${LIVE_BRANCH_CAPS[@]}" "${WAIVED_CAPS[@]}"; do
  read -r seam cap _ <<<"$row"
  [ -n "$(read_degraded_cap "$seam" "$cap")" ] || missing="$missing $cap"
done
if [ -z "$missing" ]; then ok "all 14 caps resolve through the degraded fixture seam"; else bad "caps with no fixture value:$missing"; fi

# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed (exercised=$EXERCISED executed=$EXECUTED waived=$WAIVED) ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
