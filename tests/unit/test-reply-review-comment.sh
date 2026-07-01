#!/bin/bash
# test-reply-review-comment.sh — #327: mint chp_reply_review_comment + migrate
# the last raw `gh api …pulls/<n>/comments -X POST … in_reply_to=…` site
# (reply-to-comments.sh:41, an autonomous-common util) behind it.
#
# Proves the Code-Host-Provider (CHP) review-reply leaf contract
# (provider-spec.md §3.2, [INV-87]/[INV-91]; the deferred reply-to-comments.sh
# row, the #283-deferred CHP review-thread reply) is a zero-behavior-change
# GitHub refactor:
#
#   1. GOLDEN-TRACE (AC1) — chp_github_reply_review_comment emits BYTE-IDENTICAL
#      `gh api repos/$REPO/pulls/$PR/comments -X POST -f body=… -F in_reply_to=…
#      --jq '{id: .id, url: .html_url}'` argv after routing through the verb.
#   2. DISPATCH ROUTING — chp_reply_review_comment shim forwards "$@" to
#      chp_github_reply_review_comment.
#   3. SELF-SOURCE ISOLATION (AC2) — the migrated reply-to-comments.sh, run
#      STANDALONE via a symlink sandbox (no pre-sourced seam), self-sources the
#      seam via readlink -f and routes the POST through the verb; leaf-absent →
#      FAILs LOUD (no raw-`gh` fallback).
#   4. SOURCE-SHAPE (AC3) — zero raw `gh api …pulls/…/comments` in
#      reply-to-comments.sh; shim+leaf present; baseline −1 pinned mechanically.
#
# The body/comment-id values cross the hermetic `bash -c` subshells via the
# ENVIRONMENT or positional args, never string-interpolated into a single-quoted
# script body, so spaces/special chars survive verbatim.
#
# Run: bash tests/unit/test-reply-review-comment.sh
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
COMMON_SCRIPTS="$PROJECT_ROOT/skills/autonomous-common/scripts"
CHP_LIB="$SCRIPTS/lib-code-host.sh"
PROVIDERS="$SCRIPTS/providers"
REPLY_UTIL="$COMMON_SCRIPTS/reply-to-comments.sh"
BASELINE="$PROVIDERS/cutover-baseline.json"
INVARIANTS="$PROJECT_ROOT/docs/pipeline/invariants.md"
SPEC="$PROJECT_ROOT/docs/pipeline/provider-spec.md"

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
assert_not_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      unexpected needle: |$needle|"
    FAIL=$((FAIL + 1))
  fi
}

export REPO=o/r

# ===========================================================================
# 1. GOLDEN-TRACE (AC1) — byte-identical gh argv for the review-reply leaf.
# ===========================================================================
echo "=== GOLDEN-TRACE: chp_github_reply_review_comment byte-identical gh argv ==="
_GH_ARGV_FILE="$(mktemp)"
run_trace() {
  # run_trace <verb> <args...> — source the lib with a recording gh, invoke the
  # verb, echo the recorded argv (newline-joined into one space-separated line).
  local verb="$1"; shift
  env -u CODE_HOST -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      REPO="$REPO" _GH_ARGV_FILE="$_GH_ARGV_FILE" \
  bash -c '
    set -uo pipefail
    gh() { printf "%s\n" "$@" > "$_GH_ARGV_FILE"; return 0; }
    source "'"$CHP_LIB"'" 2>/dev/null
    "$@" >/dev/null 2>&1
  ' _ "$verb" "$@"
  tr "\n" " " < "$_GH_ARGV_FILE"
}

# TC-RRC-001 — full byte-identical argv for a normal reply.
argv=$(run_trace chp_github_reply_review_comment 5 2734892022 "Fixed in abc")
assert_eq "TC-RRC-001 chp_github_reply_review_comment byte-identical gh api argv" \
  "api repos/o/r/pulls/5/comments -X POST -f body=Fixed in abc -F in_reply_to=2734892022 --jq {id: .id, url: .html_url} " \
  "$argv"

# TC-RRC-002 — the endpoint path uses the caller-supplied $REPO slug.
assert_contains "TC-RRC-002 endpoint path repos/\$REPO/pulls/\$PR/comments (REPO threaded)" \
  "repos/o/r/pulls/5/comments" "$argv"

# TC-RRC-003 — the --jq projection is the fixed literal {id: .id, url: .html_url}.
assert_contains "TC-RRC-003 --jq projection is the fixed {id: .id, url: .html_url} literal" \
  "{id: .id, url: .html_url}" "$argv"

# TC-RRC-004 — body with spaces survives as one argv token (the -f body= field).
argv2=$(run_trace chp_github_reply_review_comment 9 42 "Addressed: the bug in foo bar")
assert_contains "TC-RRC-004 body with spaces survives the -f body= field verbatim" \
  "-f body=Addressed: the bug in foo bar -F" "$argv2"
rm -f "$_GH_ARGV_FILE"

# ===========================================================================
# 2. DISPATCH ROUTING — the shim forwards "$@" to the github leaf.
# ===========================================================================
echo "=== DISPATCH ROUTING: chp_reply_review_comment → chp_github_reply_review_comment ==="
routed=$(
  env -u CODE_HOST -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR REPO="$REPO" \
  bash -c '
    set -uo pipefail
    source "'"$CHP_LIB"'" 2>/dev/null
    chp_github_reply_review_comment() { echo "ROUTED:reply:$*"; }
    chp_reply_review_comment 7 99 BODYTEXT
  '
)
assert_contains "TC-RRC-010 chp_reply_review_comment → chp_github_reply_review_comment" \
  "ROUTED:reply:7 99 BODYTEXT" "$routed"

# ===========================================================================
# 3. SELF-SOURCE ISOLATION (AC2) — run the REAL reply-to-comments.sh as a
#    SUBPROCESS via a SYMLINK in a temp sandbox (NOT by calling the verb directly)
#    so the test exercises seam-sourcing + the verb-undefined guard end-to-end.
#
#    Sandbox trick (mirrors the #315 mark-issue-checkbox.sh precedent): the
#    script is invoked via a SYMLINK in a temp dir. `$0`/SCRIPT_DIR is the symlink
#    dir (no autonomous.conf there → the env REPO survives, no operator-conf
#    contamination), while `readlink -f "$BASH_SOURCE"` resolves to the REAL
#    skill-tree file so the provider seam still sources and chp_reply_review_comment
#    is defined.
# ===========================================================================
echo "=== SELF-SOURCE ISOLATION: reply-to-comments.sh resolves the verb standalone (AC2) ==="
_BE_SANDBOX="$(mktemp -d)"
ln -s "$REPLY_UTIL" "$_BE_SANDBOX/reply-to-comments.sh"

# (a) HAPPY — the binary gh stub records the POST argv; assert the POST routes
#     through the verb (byte-identical gh api shape) and the script exits 0.
_BE_POST_ARGV="$(mktemp)"
cat > "$_BE_SANDBOX/gh" <<GHEOF
#!/bin/bash
printf '%s\n' "\$@" > "$_BE_POST_ARGV"
printf '{"id":1,"url":"https://x"}\n'
exit 0
GHEOF
chmod +x "$_BE_SANDBOX/gh"
be_happy=$(
  env -u PROJECT_DIR -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u AUTONOMOUS_PROVIDERS_DIR \
      -u CODE_HOST PATH="$_BE_SANDBOX:$PATH" \
  bash -c 'unset -f gh; bash "$1" "$2" "$3" "$4" "$5" "$6"' _ \
      "$_BE_SANDBOX/reply-to-comments.sh" o r 5 2734892022 "Fixed in abc" 2>&1
); be_happy_rc=$?
be_post_argv="$(tr '\n' ' ' < "$_BE_POST_ARGV")"
[ "$be_happy_rc" -eq 0 ] && echo -e "  ${GREEN}PASS${NC}: TC-RRC-020 standalone reply-to-comments.sh exits 0 (verb-routed POST)" && PASS=$((PASS+1)) \
  || { echo -e "  ${RED}FAIL${NC}: TC-RRC-020 expected exit 0, got rc=$be_happy_rc (out: ${be_happy:0:300})"; FAIL=$((FAIL+1)); }
# TC-RRC-022 — the POST went through the verb → byte-identical gh api shape, with
# REPO composed as $OWNER/$REPO (o/r) so the endpoint path is byte-identical.
assert_eq "TC-RRC-022 standalone POST routes through the verb (byte-identical gh api argv)" \
  "api repos/o/r/pulls/5/comments -X POST -f body=Fixed in abc -F in_reply_to=2734892022 --jq {id: .id, url: .html_url} " \
  "$be_post_argv"

# (b) LEAF-ABSENT — point the seam at a providers dir whose chp-github.sh defines
#     NO reply leaf (the all-empty degraded shape) so chp_reply_review_comment's
#     leaf is undefined. The script must FAIL LOUD and never POST via raw gh.
_NOLEAF_PROV="$(mktemp -d)"
# Minimal provider file with NO chp_github_reply_review_comment leaf.
cat > "$_NOLEAF_PROV/chp-github.sh" <<'PEOF'
#!/bin/bash
# degraded provider for #327 leaf-absent test: defines NO reply leaf.
:
PEOF
_BE_TRIP_ARGV="$(mktemp)"
cat > "$_BE_SANDBOX/gh" <<GHEOF
#!/bin/bash
printf 'TRIPWIRE_GH_POST %s\n' "\$*" >> "$_BE_TRIP_ARGV"
exit 0
GHEOF
chmod +x "$_BE_SANDBOX/gh"
be_absent=$(
  env -u PROJECT_DIR -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR \
      -u CODE_HOST AUTONOMOUS_PROVIDERS_DIR="$_NOLEAF_PROV" PATH="$_BE_SANDBOX:$PATH" \
  bash -c 'unset -f gh; bash "$1" "$2" "$3" "$4" "$5" "$6"' _ \
      "$_BE_SANDBOX/reply-to-comments.sh" o r 5 2734892022 "Fixed in abc" 2>&1
); be_absent_rc=$?
[ "$be_absent_rc" -ne 0 ] && echo -e "  ${GREEN}PASS${NC}: TC-RRC-021 leaf-absent → non-zero exit (rc=$be_absent_rc)" && PASS=$((PASS+1)) \
  || { echo -e "  ${RED}FAIL${NC}: TC-RRC-021 expected non-zero exit on leaf-absent, got rc=$be_absent_rc"; FAIL=$((FAIL+1)); }
assert_contains "TC-RRC-021 leaf-absent fails LOUD naming chp_reply_review_comment" \
  "chp_reply_review_comment" "$be_absent"
assert_not_contains "TC-RRC-021 leaf-absent does NOT POST via raw gh (no silent GitHub fallback)" \
  "TRIPWIRE_GH_POST" "$(cat "$_BE_TRIP_ARGV")"

rm -rf "$_BE_SANDBOX" "$_NOLEAF_PROV"
rm -f "$_BE_POST_ARGV" "$_BE_TRIP_ARGV"

# ===========================================================================
# 4. SOURCE-SHAPE (AC3) — zero raw gh in reply-to-comments.sh; shim+leaf present;
#    baseline shrunk by exactly 1.
# ===========================================================================
echo "=== SOURCE-SHAPE (AC3): cutover + shim/leaf presence ==="

# TC-RRC-030 — zero raw `gh api …pulls/…/comments` in reply-to-comments.sh.
raw_count=$(grep -cE 'gh api .*pulls/.*/comments' "$REPLY_UTIL" 2>/dev/null || true)
assert_eq "TC-RRC-030 zero raw 'gh api …pulls/…/comments' in reply-to-comments.sh" "0" "$raw_count"

# TC-RRC-031 — reply-to-comments.sh calls the verb.
assert_contains "TC-RRC-031 reply-to-comments.sh calls chp_reply_review_comment" \
  "chp_reply_review_comment" "$(cat "$REPLY_UTIL")"

# TC-RRC-032 — shim in lib-code-host.sh + leaf in providers/chp-github.sh.
assert_contains "TC-RRC-032a lib-code-host.sh defines the chp_reply_review_comment shim" \
  "chp_reply_review_comment() { chp_\${CODE_HOST}_reply_review_comment" "$(cat "$CHP_LIB")"
assert_contains "TC-RRC-032b providers/chp-github.sh defines chp_github_reply_review_comment" \
  "chp_github_reply_review_comment()" "$(cat "$PROVIDERS/chp-github.sh")"

# TC-RRC-033 — baseline shrank: the migrated wire-string is GONE. #327 itself
# removed reply-to-comments.sh's signature (72→71 occ, 66→65 sigs at that time).
# The absolute totals then dropped further as sibling #296 second-tier migrations
# stacked onto main: #334 (auto-merge-marker read → itp_list_comments: 71→70 occ,
# 65→64 sigs), #328 (PR inline-comment read → chp_list_inline_comments: 70→69 occ,
# 64→63 sigs), and #343 (the #286-amendment structurally exempts the guard's own
# ALLOWLISTED_FILES array + primary matcher + _comment template lines: 69→66 occ,
# 63→60 sigs). The migration-robust invariant (TC-RRC-033a) is that NO
# reply-to-comments.sh signature survives; the absolute totals below are pinned to
# the current stacked value (66 occ / 60 sigs) and move with each sibling migration.
mig_in_baseline=$(jq '[.surviving_sites[] | select(.file=="reply-to-comments.sh")] | length' "$BASELINE")
assert_eq "TC-RRC-033a no reply-to-comments.sh signature remains in the cutover baseline" "0" "$mig_in_baseline"
total_occ=$(jq '[.surviving_sites[].count] | add' "$BASELINE")
assert_eq "TC-RRC-033b cutover baseline total occurrences == 66 (#327 71, then #334 −1, #328 −1, #343 −3)" "66" "$total_occ"
distinct_sigs=$(jq '.surviving_sites | length' "$BASELINE")
assert_eq "TC-RRC-033c cutover baseline distinct signatures == 60 (#327 65, then #334 −1, #328 −1, #343 −3)" "60" "$distinct_sigs"

# ===========================================================================
# 5. SPEC / INVARIANT (AC4) — the new INV heading + its triage marker; spec row.
# ===========================================================================
echo "=== SPEC / INVARIANT (AC4): new INV + triage marker + spec row ==="

# TC-RRC-040 — the new INV heading mentions chp_reply_review_comment AND carries a
# `_Triage (issue #236): [machine-checked: …test-reply-review-comment.sh]_` marker
# within 2 lines of the heading (the #236 is a FIXED marker, NOT this issue's #).
inv_block=$(awk '
  /^## INV-[0-9]+:.*chp_reply_review_comment/ { found=1; n=0 }
  found { print; n++; if (n>=3) found=0 }
' "$INVARIANTS")
assert_contains "TC-RRC-040a new INV heading mentions chp_reply_review_comment" \
  "chp_reply_review_comment" "$inv_block"
assert_contains "TC-RRC-040b new INV heading carries the _Triage (issue #236): machine-checked marker" \
  "_Triage (issue #236): [machine-checked: tests/unit/test-reply-review-comment.sh]_" "$inv_block"

# TC-RRC-041 — provider-spec.md §3.2: the deferred reply-to-comments row now names
# the migrated verb chp_reply_review_comment (no longer "NOT migrated in #283").
spec_reply_row=$(grep -nE 'reply-to-comments\.sh' "$SPEC" | grep -i 'chp_reply_review_comment' || true)
assert_contains "TC-RRC-041 provider-spec.md §3.2 row migrated to chp_reply_review_comment" \
  "chp_reply_review_comment" "$spec_reply_row"

# ===========================================================================
echo ""
echo "================================================="
echo -e "  Passed: ${GREEN}${PASS}${NC}   Failed: ${RED}${FAIL}${NC}"
echo "================================================="
[ "$FAIL" -eq 0 ] || exit 1
