#!/bin/bash
# test-itp-read-task-b5b7.sh — #296 B5+B7: live-wrapper issue READ migration.
#
# Proves the two byte-identical `gh issue view` READ sites in the live wrappers
# (autonomous-dev.sh:887 issue-body, autonomous-review.sh:3439 no-auto-close
# label gate) are zero-behavior-change call-site swaps behind the shipped
# `itp_read_task` verb (provider-spec.md §3.1, [INV-87]/[INV-91]):
#
#   1. GOLDEN-TRACE (argument-boundary-preserving) — argv recorded NUL-delimited
#      (NOT space-joined; the `-q` selectors carry spaces/pipes), asserting argc
#      + each exact arg incl. the verbatim `-q` selector for both sites. A
#      word-split / re-escaped selector FAILS. (AC2)
#   2. SEAM + OBSERVED-CALL — source the real lib-issue-provider.sh (which sources
#      providers/itp-github.sh) and assert the gh-stub OBSERVED the verb's argv —
#      proving the path was EXERCISED, not merely reachable (an undefined verb
#      would fail-soft; these reads wrap in 2>/dev/null/capture). (AC4)
#   3. BEHAVIOR-EQUIVALENCE — a gh stub returning a canned payload yields the
#      identical captured ISSUE_BODY / HAS_NO_AUTO_CLOSE the old raw call did.
#   4. SOURCE-OF-TRUTH — the wrappers call the verb (not raw gh) at both sites,
#      and carry NO raw `gh issue view` at the migrated lines (AC1 backstop).
#   5. SPEC-GATE — the exact INV-91 Migration-log bullet is present (AC5).
#
# Argv/selector values are passed to the hermetic `bash -c` subshells via the
# ENVIRONMENT (never string-interpolated into the single-quoted script body), so
# the B7 selector's embedded spaces, pipe, and double-quotes survive verbatim.
#
# Run: bash tests/unit/test-itp-read-task-b5b7.sh
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
ITP_LIB="$SCRIPTS/lib-issue-provider.sh"
DEV_WRAPPER="$SCRIPTS/autonomous-dev.sh"
REVIEW_WRAPPER="$SCRIPTS/autonomous-review.sh"
INVARIANTS="$PROJECT_ROOT/docs/pipeline/invariants.md"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected: |$expected|"
    echo "      actual:   |$actual|"
    FAIL=$((FAIL + 1))
  fi
}
assert_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      needle: |$needle|"; echo "      hay:    |$hay|"
    FAIL=$((FAIL + 1))
  fi
}
ok()   { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad()  { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane

# The two migrated selectors, recorded verbatim so the test fails on any byte
# drift (re-escape / word-split / quote change) at the migrated sites. Exported
# so subshells reference them by name (never interpolate into the script body).
export B5_SEL='.'
export B7_SEL='[.labels[].name] | any(. == "no-auto-close")'

# ===========================================================================
# 1. GOLDEN-TRACE — argument-boundary-preserving (NUL-delimited argv). (AC2)
# ===========================================================================
echo "=== GOLDEN-TRACE: itp_read_task argv byte-identical AND boundary-preserving ==="
# A recording `gh` stub writes argc then each arg NUL-delimited, so spaces/pipes
# inside an arg do NOT merge with neighbours. The args to itp_read_task are passed
# positionally ("$@") so their boundaries are preserved across the env -u + bash -c.
_ARGV_FILE="$(mktemp)"

run_argv() {
  env -u ISSUE_PROVIDER -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      REPO="$REPO" _ARGV_FILE="$_ARGV_FILE" ITP_LIB="$ITP_LIB" \
  bash -c '
    set -uo pipefail
    gh() { printf "%s\0" "$#" "$@" > "$_ARGV_FILE"; return 0; }
    source "$ITP_LIB" 2>/dev/null
    itp_read_task "$@" >/dev/null 2>&1
  ' _ "$@"
}

# Read back: argc (first NUL field) then "[i]=<arg>" lines (order- + boundary-exact).
argv_dump() {
  awk 'BEGIN{RS="\0"} NR==1{print "argc=" $0; next} {print "[" (NR-2) "]=" $0}' "$_ARGV_FILE"
}

# --- B5: itp_read_task <N> title,body,comments -q '.' ---
run_argv 310 title,body,comments -q "$B5_SEL"
b5=$(argv_dump)
b5_expected="argc=9
[0]=issue
[1]=view
[2]=310
[3]=--repo
[4]=$REPO
[5]=--json
[6]=title,body,comments
[7]=-q
[8]=$B5_SEL"
assert_eq "TC-RT-B5-ARGV B5 argv byte-identical, boundary-preserving (issue-body read)" \
  "$b5_expected" "$b5"

# --- B7: itp_read_task <N> labels -q '[.labels[].name] | any(. == "no-auto-close")' ---
run_argv 310 labels -q "$B7_SEL"
b7=$(argv_dump)
b7_expected="argc=9
[0]=issue
[1]=view
[2]=310
[3]=--repo
[4]=$REPO
[5]=--json
[6]=labels
[7]=-q
[8]=$B7_SEL"
assert_eq "TC-RT-B7-ARGV B7 argv byte-identical, boundary-preserving (no-auto-close gate)" \
  "$b7_expected" "$b7"

# Negative: the B7 selector MUST be ONE argv element — assert argc + the selector arg.
b7_argc=$(awk 'BEGIN{RS="\0"} NR==1{print; exit}' "$_ARGV_FILE")
b7_sel_arg=$(awk 'BEGIN{RS="\0"} NR==10{print; exit}' "$_ARGV_FILE")   # field 10 == arg index 8
if [[ "$b7_argc" == "9" && "$b7_sel_arg" == "$B7_SEL" ]]; then
  ok "TC-RT-B7-SELECTOR-ONEARG -q selector is a single argv element (space+pipe+quotes survive the boundary)"
else
  bad "TC-RT-B7-SELECTOR-ONEARG selector word-split or re-escaped (argc=$b7_argc, sel=|$b7_sel_arg|)"
fi

rm -f "$_ARGV_FILE"

# ===========================================================================
# 2. SEAM + OBSERVED-CALL — the github leaf actually RAN (not just reachable). (AC4)
# ===========================================================================
echo "=== SEAM + OBSERVED-CALL: real lib-issue-provider.sh routes itp_read_task → github leaf ==="
seam=$(
  env -u ISSUE_PROVIDER -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      REPO="$REPO" ITP_LIB="$ITP_LIB" \
  bash -c '
    set -uo pipefail
    source "$ITP_LIB" 2>/dev/null
    declare -F itp_read_task >/dev/null 2>&1 && echo "VERB_DEFINED"
    declare -F itp_github_read_task >/dev/null 2>&1 && echo "LEAF_DEFINED"
  '
)
assert_contains "TC-RT-SEAM-SOURCED real lib defines itp_read_task" "VERB_DEFINED" "$seam"
assert_contains "TC-RT-SEAM-SOURCED real lib defines the github leaf (ISSUE_PROVIDER=github default)" "LEAF_DEFINED" "$seam"

# OBSERVED through the real seam — gh records its argv NUL-delimited; we read it
# back and compare exactly (selectors passed positionally, boundary-preserved).
observe_argv() {
  local obs; obs="$(mktemp)"
  env -u ISSUE_PROVIDER -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      REPO="$REPO" ITP_LIB="$ITP_LIB" _OBS="$obs" \
  bash -c '
    set -uo pipefail
    gh() { printf "%s\0" "$@" > "$_OBS"; }
    source "$ITP_LIB" 2>/dev/null
    itp_read_task "$@" >/dev/null 2>&1
  ' _ "$@"
  awk 'BEGIN{RS="\0"; ORS="\t"} {print}' "$obs"   # tab-joined so spaces in a field stay intact
  rm -f "$obs"
}
b5_obs=$(observe_argv 310 title,body,comments -q "$B5_SEL")
assert_eq "TC-RT-B5-OBSERVED B5 verb-call exercised the github leaf (observed argv)" \
  "issue	view	310	--repo	$REPO	--json	title,body,comments	-q	$B5_SEL	" "$b5_obs"
b7_obs=$(observe_argv 310 labels -q "$B7_SEL")
assert_eq "TC-RT-B7-OBSERVED B7 verb-call exercised the github leaf (observed argv)" \
  "issue	view	310	--repo	$REPO	--json	labels	-q	$B7_SEL	" "$b7_obs"

# ===========================================================================
# 3. BEHAVIOR-EQUIVALENCE — same ISSUE_BODY / HAS_NO_AUTO_CLOSE before & after.
# ===========================================================================
echo "=== BEHAVIOR-EQUIVALENCE: captured value identical to the old raw gh call ==="
# The gh stub applies the verb's forwarded -q selector (read from argv) to a
# canned payload passed via env, so the captured value is exactly what the old
# raw `gh issue view --json … -q <sel>` produced.
equiv() {
  # equiv <PAYLOAD> <itp_read_task-args...> — prints the captured value.
  local payload="$1"; shift
  env -u ISSUE_PROVIDER -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      REPO="$REPO" ITP_LIB="$ITP_LIB" _PAYLOAD="$payload" \
  bash -c '
    set -uo pipefail
    gh() {
      local sel="" i j; for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "-q" ]]; then j=$((i+1)); sel="${!j}"; fi; done
      jq -c "$sel" <<<"$_PAYLOAD"
    }
    source "$ITP_LIB" 2>/dev/null
    printf "%s" "$(itp_read_task "$@" 2>/dev/null || echo "false")"
  ' _ "$@"
}
b5_body=$(equiv '{"title":"T","body":"B","comments":[]}' 310 title,body,comments -q "$B5_SEL")
assert_eq "TC-RT-B5-EQUIV ISSUE_BODY identical to old raw -q '.' read" \
  '{"title":"T","body":"B","comments":[]}' "$b5_body"
b7_true=$(equiv '{"labels":[{"name":"autonomous"},{"name":"no-auto-close"}]}' 310 labels -q "$B7_SEL")
assert_eq "TC-RT-B7-EQUIV-TRUE no-auto-close present → HAS_NO_AUTO_CLOSE=true" "true" "$b7_true"
b7_false=$(equiv '{"labels":[{"name":"autonomous"},{"name":"reviewing"}]}' 310 labels -q "$B7_SEL")
assert_eq "TC-RT-B7-EQUIV-FALSE no-auto-close absent → HAS_NO_AUTO_CLOSE=false" "false" "$b7_false"

# ===========================================================================
# 4. SOURCE-OF-TRUTH — wrappers call the verb, not raw gh, at the migrated sites. (AC1 backstop)
# ===========================================================================
echo "=== SOURCE-OF-TRUTH: migrated call-sites use itp_read_task, no raw gh issue view ==="
if grep -qE 'ISSUE_BODY=\$\(itp_read_task "\$ISSUE_NUMBER" title,body,comments -q' "$DEV_WRAPPER"; then
  ok "TC-RT-B5-SRC autonomous-dev.sh issue-body read routes through itp_read_task"
else
  bad "TC-RT-B5-SRC autonomous-dev.sh issue-body read NOT migrated to itp_read_task"
fi
dev_code=$(grep -vE '^[[:space:]]*#' "$DEV_WRAPPER")
if grep -qE 'gh issue view "\$ISSUE_NUMBER" --repo "\$REPO" --json title,body,comments' <<<"$dev_code"; then
  bad "TC-RT-B5-SRC raw gh issue view … title,body,comments still executable in autonomous-dev.sh"
else
  ok "TC-RT-B5-SRC no raw gh issue view … title,body,comments executable in autonomous-dev.sh"
fi
if grep -qE 'HAS_NO_AUTO_CLOSE=\$\(itp_read_task "\$ISSUE_NUMBER" labels' "$REVIEW_WRAPPER"; then
  ok "TC-RT-B7-SRC autonomous-review.sh no-auto-close gate routes through itp_read_task"
else
  bad "TC-RT-B7-SRC autonomous-review.sh no-auto-close gate NOT migrated to itp_read_task"
fi
review_code=$(grep -vE '^[[:space:]]*#' "$REVIEW_WRAPPER")
if grep -qE 'HAS_NO_AUTO_CLOSE=\$\(gh issue view' <<<"$review_code"; then
  bad "TC-RT-B7-SRC raw gh issue view --json labels still executable at the no-auto-close gate"
else
  ok "TC-RT-B7-SRC no raw gh issue view --json labels at the no-auto-close gate"
fi

# ===========================================================================
# 5. SPEC-GATE — the exact INV-91 Migration-log bullet is present. (AC5)
# ===========================================================================
echo "=== TC-SPEC-GATE-310: INV-91 Migration-log bullet present ==="
_AC5_BULLET='- #296 B5+B7 (#310): live-wrapper issue READS — autonomous-dev.sh issue-body (1× itp_read_task), autonomous-review.sh no-auto-close label gate (1× itp_read_task) — byte-identical; baseline shrank by 2 sigs.'
if grep -qF -- "$_AC5_BULLET" "$INVARIANTS"; then
  ok "TC-SPEC-GATE-310 exact INV-91 Migration-log bullet present in invariants.md"
else
  bad "TC-SPEC-GATE-310 INV-91 Migration-log bullet MISSING/altered in invariants.md"
fi

# ===========================================================================
echo ""
echo "=== Summary ==="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
[ "$FAIL" -eq 0 ]
