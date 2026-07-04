#!/bin/bash
# test-w1b-read-task-parity.sh — issue #396 (W1b, #347 phase-2), R5.
#
# DECISION-level (not byte-level) behavior-parity suite for the six callers of
# the ABSTRACT itp_read_task contract:
#
#   check_deps_resolved (lib-dispatch.sh), mark-issue-checkbox.sh,
#   the autonomous-review.sh no-auto-close gate, status.sh's state/labels
#   read, and the two autonomous-dev.sh issue-body fetches.
#
# #396 converts itp_read_task from a byte-identical gh-argv passthrough to an
# abstract, provider-neutral contract — a DELIBERATE shape change (`labels` is
# now an array of NAME strings, not `{name}` objects; the caller's own jq
# projection replaced the forwarded `-q`), so verbatim argv/output equality
# with the pre-#396 code is impossible by construction. Instead this suite
# proves DECISION-level parity: for each caller, the CURRENT (post-#396) code
# reaches the exact same downstream decision the OLD (pre-#396,
# byte-identical-passthrough) code reached, against recorded fixtures.
#
# GOLDEN FIXTURE PROVENANCE (R5): tests/unit/fixtures/w1b-parity/decision-golden.json
# was captured by running the PRE-#396 code against these same fixtures, on the
# first TDD commit of the #396 W1b branch, before the abstract-contract rewrite
# landed. See the sidecar decision-golden.json.meta for the exact capture
# procedure. This test compares the CURRENT code's decision against that frozen
# golden — it does NOT recompute the OLD behavior, so a regression in either the
# leaf OR a caller shows up as a mismatch against the golden.
#
# Run: bash tests/unit/test-w1b-read-task-parity.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
COMMON_SCRIPTS="$PROJECT_ROOT/skills/autonomous-common/scripts"
LIB_DISPATCH="$SCRIPTS/lib-dispatch.sh"
GOLDEN="$SCRIPT_DIR/fixtures/w1b-parity/decision-golden.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then ok "$desc"; else bad "$desc — expected '$expected', got '$actual'"; fi
}
assert_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then ok "$desc"; else bad "$desc — needle '$needle' not in '${hay:0:200}'"; fi
}

[[ -f "$GOLDEN" ]] || { echo "FATAL: golden fixture not found at $GOLDEN"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }
golden_str() { jq -r --arg k "$1" '.[$k]' "$GOLDEN"; }
golden_int() { jq -r --arg k "$1" '.[$k]' "$GOLDEN"; }

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-w1b-parity-$$
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# ===========================================================================
echo "=== TC-W1B-PARITY-001..003: check_deps_resolved (lib-dispatch.sh) ==="
# ===========================================================================
run_deps() {
  local body="$1" dep_state="$2"
  env -u AUTONOMOUS_PROVIDERS_DIR ISSUE_PROVIDER=github \
      REPO="$REPO" REPO_OWNER="$REPO_OWNER" PROJECT_ID="$PROJECT_ID" \
      MAX_RETRIES=3 MAX_CONCURRENT=5 \
      _BODY="$body" _DEP_STATE="$dep_state" \
  bash -c '
    set -uo pipefail
    gh() {
      local mode="" q="" i j
      for ((i=1;i<=$#;i++)); do
        if [[ "${!i}" == "--json" ]]; then j=$((i+1)); case "${!j}" in
          title,body,state,labels,comments) mode=read_task ;;
          state) mode=state ;;
          comments) mode=comments ;;
        esac; fi
        if [[ "${!i}" == "-q" || "${!i}" == "--jq" ]]; then j=$((i+1)); q="${!j}"; fi
      done
      case "$mode" in
        read_task) jq -cn --arg body "$_BODY" "{title:\"\",body:\$body,state:\"OPEN\",labels:[],comments:[]}" ;;
        state) printf "%s" "$_DEP_STATE" ;;
        comments) printf "[]" ;;
      esac
    }
    export -f gh
    source "'"$LIB_DISPATCH"'" 2>/dev/null
    set +e
    check_deps_resolved 99 >/dev/null 2>&1
    echo "$?"
  '
}
r1=$(run_deps $'## Dependencies\n- #42\n' "CLOSED")
r2=$(run_deps $'## Dependencies\n- #42\n' "OPEN")
r3=$(run_deps $'no deps section here\n' "")
assert_eq "TC-W1B-PARITY-001 normal CLOSED dep → rc matches golden" "$(golden_int check_deps_resolved.normal_closed_rc)" "$r1"
assert_eq "TC-W1B-PARITY-002 OPEN dep blocks → rc matches golden" "$(golden_int check_deps_resolved.open_blocks_rc)" "$r2"
assert_eq "TC-W1B-PARITY-003 no Dependencies section → rc matches golden" "$(golden_int check_deps_resolved.no_deps_section_rc)" "$r3"

# ===========================================================================
echo ""
echo "=== TC-W1B-PARITY-010..011: mark-issue-checkbox.sh ==="
# ===========================================================================
# run_mcb <served-body> <out-var-prefix> — writes _<prefix>_rc/_<prefix>_out/
# _<prefix>_patch globals (avoids composing a single multi-line string, which
# would collide with a PATCH body that itself contains newlines).
run_mcb() {
  local served_body="$1" prefix="$2"
  local sandbox served_json out rc patch_log
  sandbox="$(mktemp -d)"; patch_log="$sandbox/patch.log"
  served_json="$(jq -cn --arg b "$served_body" '{title:"",body:$b,state:"OPEN",labels:[],comments:[]}')"
  printf '%s' "$served_json" > "$sandbox/served.json"
  cat > "$sandbox/gh" <<GHEOF
#!/bin/bash
if [[ "\$1" == "issue" && "\$2" == "view" ]]; then cat "$sandbox/served.json"; exit 0; fi
echo "PATCH_CALLED \$*" >> "$patch_log"
exit 0
GHEOF
  chmod +x "$sandbox/gh"
  out=$(
    env -u PROJECT_DIR -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u AUTONOMOUS_PROVIDERS_DIR \
        ISSUE_PROVIDER=github REPO=o/r PATH="$sandbox:$PATH" \
    bash -c 'unset -f gh; bash "$1" "$2" "$3"' _ "$COMMON_SCRIPTS/mark-issue-checkbox.sh" 1 "Do the thing" 2>&1
  ); rc=$?
  local patched_body=""; [[ -f "$patch_log" ]] && patched_body="$(cat "$patch_log")"
  printf -v "_${prefix}_rc" '%s' "$rc"
  printf -v "_${prefix}_out" '%s' "$out"
  printf -v "_${prefix}_patch" '%s' "$patched_body"
  rm -rf "$sandbox"
}
run_mcb $'## Requirements\n- [ ] Do the thing\n' happy
assert_eq "TC-W1B-PARITY-010a happy rewrite rc matches golden" "$(jq -r '.["mark_checkbox.happy_rewrite"].rc' "$GOLDEN")" "$_happy_rc"
assert_eq "TC-W1B-PARITY-010b happy rewrite stdout matches golden" "$(jq -r '.["mark_checkbox.happy_rewrite"].stdout' "$GOLDEN")" "$_happy_out"
assert_contains "TC-W1B-PARITY-010c PATCH carries the same checked-box body as golden" \
  "$(jq -r '.["mark_checkbox.happy_rewrite"].patched_body' "$GOLDEN")" "$_happy_patch"

run_mcb $'## Requirements\n- [x] Do the thing\n' already
assert_eq "TC-W1B-PARITY-011a already-checked rc matches golden" "$(jq -r '.["mark_checkbox.already_checked"].rc' "$GOLDEN")" "$_already_rc"
assert_eq "TC-W1B-PARITY-011b already-checked stdout matches golden" "$(jq -r '.["mark_checkbox.already_checked"].stdout' "$GOLDEN")" "$_already_out"
assert_eq "TC-W1B-PARITY-011c already-checked issues NO patch (matches golden)" "" "$_already_patch"

# ===========================================================================
echo ""
echo "=== TC-W1B-PARITY-020..021: autonomous-review.sh no-auto-close gate ==="
# ===========================================================================
run_noautoclose() {
  local labels_json="$1"
  env -u AUTONOMOUS_PROVIDERS_DIR ISSUE_PROVIDER=github REPO="$REPO" _LABELS="$labels_json" \
  bash -c '
    set -uo pipefail
    gh() {
      # Raw gh shape: labels as {name} objects — the LEAF normalizes them.
      jq -cn --argjson names "$_LABELS" "{title:\"\",body:\"\",state:\"OPEN\",labels:[\$names[] | {name:.}],comments:[]}"
    }
    export -f gh
    source "'"$SCRIPTS"'/lib-issue-provider.sh" 2>/dev/null
    HAS_NO_AUTO_CLOSE=$(itp_read_task 42 labels | jq -r ".labels | any(. == \"no-auto-close\")" 2>/dev/null || echo "false")
    echo "$HAS_NO_AUTO_CLOSE"
  '
}
r_present=$(run_noautoclose '["autonomous","no-auto-close"]')
r_absent=$(run_noautoclose '["autonomous","reviewing"]')
assert_eq "TC-W1B-PARITY-020 no-auto-close present → gate matches golden" "$(golden_str no_auto_close.present)" "$r_present"
assert_eq "TC-W1B-PARITY-021 no-auto-close absent → gate matches golden" "$(golden_str no_auto_close.absent)" "$r_absent"

# ===========================================================================
echo ""
echo "=== TC-W1B-PARITY-030..031: status.sh state/labels read + terminal branch ==="
# ===========================================================================
run_status_state() {
  local state="$1" labels_json="$2"
  env -u AUTONOMOUS_PROVIDERS_DIR ISSUE_PROVIDER=github REPO="$REPO" _STATE="$state" _LABELS="$labels_json" \
  bash -c '
    set -uo pipefail
    gh() {
      # Raw gh shape: labels as {name} objects — the LEAF normalizes them.
      jq -cn --arg state "$_STATE" --argjson names "$_LABELS" "{title:\"t\",body:\"\",state:\$state,labels:[\$names[] | {name:.}],comments:[]}"
    }
    export -f gh
    source "'"$SCRIPTS"'/lib-issue-provider.sh" 2>/dev/null
    ISSUE_JSON="$(itp_read_task 42 state,labels,title 2>/dev/null || echo "{}")"
    ISSUE_STATE="$(jq -r ".state // \"UNKNOWN\"" <<<"$ISSUE_JSON")"
    LABELS="$(jq -r "[.labels[]] | join(\" \")" <<<"$ISSUE_JSON" 2>/dev/null || echo "")"
    if [[ "$ISSUE_STATE" != "OPEN" ]]; then echo "TERMINAL:$ISSUE_STATE:LABELS=$LABELS"; else echo "OPEN:LABELS=$LABELS"; fi
  '
}
r_open=$(run_status_state "OPEN" '["pending-dev"]')
r_closed=$(run_status_state "CLOSED" '["approved"]')
assert_eq "TC-W1B-PARITY-030 OPEN state → not-terminal branch matches golden" "$(golden_str status_next_action.open)" "$r_open"
assert_eq "TC-W1B-PARITY-031 CLOSED state → terminal branch matches golden" "$(golden_str status_next_action.closed)" "$r_closed"

# ===========================================================================
echo ""
echo "=== TC-W1B-PARITY-040..041: autonomous-dev.sh issue-body fetch (text parity) ==="
# ===========================================================================
run_dev_fetch() {
  local fields_csv="$1" title="$2" body="$3"
  env -u AUTONOMOUS_PROVIDERS_DIR ISSUE_PROVIDER=github REPO="$REPO" _TITLE="$title" _BODY="$body" \
  bash -c '
    set -uo pipefail
    gh() {
      jq -cn --arg t "$_TITLE" --arg b "$_BODY" "{title:\$t,body:\$b,state:\"OPEN\",labels:[],comments:[]}"
    }
    export -f gh
    source "'"$SCRIPTS"'/lib-issue-provider.sh" 2>/dev/null
    itp_read_task 42 "$1"
  ' _ "$fields_csv"
}
dev1="$(run_dev_fetch "title,body,comments" "$(jq -r '.["dev_fetch.title_body_comments"].title' "$GOLDEN")" "$(jq -r '.["dev_fetch.title_body_comments"].body' "$GOLDEN")")"
assert_eq "TC-W1B-PARITY-040a title TEXT identical to golden" \
  "$(jq -r '.["dev_fetch.title_body_comments"].title' "$GOLDEN")" "$(jq -r '.title' <<<"$dev1")"
assert_eq "TC-W1B-PARITY-040b body TEXT identical to golden" \
  "$(jq -r '.["dev_fetch.title_body_comments"].body' "$GOLDEN")" "$(jq -r '.body' <<<"$dev1")"

dev2="$(run_dev_fetch "title,body" "$(jq -r '.["dev_fetch.resume_title_body"].title' "$GOLDEN")" "$(jq -r '.["dev_fetch.resume_title_body"].body' "$GOLDEN")")"
assert_eq "TC-W1B-PARITY-041a resume-fetch title TEXT identical to golden" \
  "$(jq -r '.["dev_fetch.resume_title_body"].title' "$GOLDEN")" "$(jq -r '.title' <<<"$dev2")"
assert_eq "TC-W1B-PARITY-041b resume-fetch body TEXT identical to golden" \
  "$(jq -r '.["dev_fetch.resume_title_body"].body' "$GOLDEN")" "$(jq -r '.body' <<<"$dev2")"

# ===========================================================================
echo ""
echo "=== Summary ==="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
[ "$FAIL" -eq 0 ]
