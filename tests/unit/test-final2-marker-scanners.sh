#!/bin/bash
# test-final2-marker-scanners.sh — issue #321 (#296 "final-2-marker-scanners").
#
# Migrate the last two raw-`gh issue view --json comments` comment-scanner leaves
# behind the `itp_list_comments` provider verb:
#   S1  dispatcher-tick.sh  — the INV-12 PTL idempotency marker-count scanner.
#   S2  lib-review-poll.sh  — _fetch_agent_verdict_body (the verdict choke-point).
#
# S2 moves the comment `select` from gh's embedded engine (Go RE2, ASCII-only
# case folding) to system jq (Oniguruma, Unicode folding). That is a real
# regex-engine boundary, NOT a byte-identical swap, so the migrated helper carries
# four behavior-preservation fixes (LC_ALL=C ascii-fold, `// empty`, empty-RE
# fail-closed, same-second `.id` tiebreak). This suite is the load-bearing proof of
# RE2-fold parity + fail-CLOSED on every degenerate input.
#
# Four-pronged (the wrappers are too heavy to run end-to-end):
#   1. S2 golden-parity matrix — drives the REAL _fetch_agent_verdict_body with
#      `itp_list_comments` stubbed to emit the [INV-90] normalized array;
#   2. S1 idempotency — drives the migrated marker-count guard logic;
#   3. source-shape pins (the choke-point has two entry paths) + the four fix tokens;
#   4. cutover-baseline pins (DURABLE absence/presence — the two #321 wire-forms gone,
#      dispatcher-tick.sh terminally raw-gh-free; #323 flipped TC-FINAL2-042 once the
#      timeline survivor migrated behind itp_label_event_ts).
#
# Run: env -u PROJECT_DIR bash tests/unit/test-final2-marker-scanners.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISP="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
POLL_LIB="$DISP/lib-review-poll.sh"
TICK="$DISP/dispatcher-tick.sh"
BASELINE="$DISP/providers/cutover-baseline.json"

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

# A normalized [INV-90] comment record builder for fixtures.
# rec <id> <author> <body> <createdAt>  → one JSON object line.
rec() {
  jq -cn --arg id "$1" --arg author "$2" --arg body "$3" --arg createdAt "$4" \
    '{id: ($id|tonumber), author: $author, authorKind: "bot", body: $body, createdAt: $createdAt}'
}

# Assemble a JSON array (ascending createdAt, as the verb contract guarantees)
# from the rec lines passed on stdin.
as_array() { jq -cs '.'; }

# --------------------------------------------------------------------------
# Prong 1 — S2 golden-parity matrix. Drive the REAL _fetch_agent_verdict_body.
# --------------------------------------------------------------------------
echo "=== Prong 1: S2 golden parity (REAL _fetch_agent_verdict_body, itp_list_comments stubbed) ==="

# fetch_with <array-json> <agent> <sid> [bot_login] [verdict_re] [start_ts] [locale]
# Runs the real helper in a subshell with itp_list_comments stubbed to echo the array.
fetch_with() {
  local arr="$1" agent="$2" sid="$3" bot="${4-}" vre="${5-}" start="${6:-2026-01-01T00:00:00Z}" loc="${7-}"
  (
    set -uo pipefail
    # shellcheck source=/dev/null
    source "$POLL_LIB"
    itp_list_comments() { printf '%s' "$arr"; }
    ISSUE_NUMBER=1; REPO="o/r"
    BOT_LOGIN="$bot"
    WRAPPER_START_TS="$start"
    if [[ "$vre" == "__UNSET__" ]]; then unset _VERDICT_RE; else _VERDICT_RE="$vre"; fi
    [[ -n "$loc" ]] && export LC_ALL="$loc"
    _fetch_agent_verdict_body "$agent" "$sid"
  )
}

VRE='Review PASSED|Review APPROVED|APPROVED FOR MERGE|LGTM|Review PASS|Review findings:|Review FAILED|Review REJECTED|Changes requested'
BOT='kane-review-agent[bot]'

# (a) matching verdict, newest-wins. (BOT_LOGIN-set path requires a `Review Session`
#     line — the INV-20 case-sensitive auth predicate — exactly as a real verdict
#     comment carries; the production comment template always emits it.)
arr="$( { rec 100 "$BOT" "Review PASSED first
Review Session
Review Agent: agy" "2026-02-01T00:00:00Z"
         rec 200 "$BOT" "Review PASSED second
Review Session
Review Agent: agy" "2026-02-01T00:05:00Z"; } | as_array )"
out="$(fetch_with "$arr" "agy" "sid-a" "$BOT" "$VRE")"
assert_eq "TC-FINAL2-001 (a) newest matching verdict wins" "Review PASSED second
Review Session
Review Agent: agy" "$out"

# (b) wrong-agent excluded.
arr="$( rec 100 "$BOT" "Review PASSED
Review Agent: other" "2026-02-01T00:00:00Z" | as_array )"
out="$(fetch_with "$arr" "agy" "sid-b" "$BOT" "$VRE")"
assert_eq "TC-FINAL2-002 (b) wrong-agent excluded → EMPTY" "" "$out"

# (c) before-window excluded.
arr="$( rec 100 "$BOT" "Review PASSED
Review Agent: agy" "2025-12-31T23:59:59Z" | as_array )"
out="$(fetch_with "$arr" "agy" "sid-c" "$BOT" "$VRE" "2026-01-01T00:00:00Z")"
assert_eq "TC-FINAL2-003 (c) before-window excluded → EMPTY" "" "$out"

# (d) wrong-author excluded (BOT_LOGIN set).
arr="$( rec 100 "someone-else" "Review PASSED
Review Session
Review Agent: agy" "2026-02-01T00:00:00Z" | as_array )"
out="$(fetch_with "$arr" "agy" "sid-d" "$BOT" "$VRE")"
assert_eq "TC-FINAL2-004 (d) wrong-author excluded (BOT_LOGIN set) → EMPTY" "" "$out"

# (e) BOT_LOGIN-empty session-id fallback path.
arr="$( { rec 100 "anyone" "Review PASSED
Review Session: sid-MATCH
Review Agent: agy" "2026-02-01T00:00:00Z"
          rec 101 "anyone" "Review PASSED
Review Session: sid-OTHER
Review Agent: agy" "2026-02-01T00:01:00Z"; } | as_array )"
out="$(fetch_with "$arr" "agy" "sid-MATCH" "" "$VRE")"
assert_eq "TC-FINAL2-005 (e) BOT_LOGIN-empty sid fallback selects the matching sid" "Review PASSED
Review Session: sid-MATCH
Review Agent: agy" "$out"

# (f) Unicode-fold counterexample — long-s (U+017F) MUST NOT match (RE2 parity);
#     a sibling lowercase-ASCII body MUST match. Both carry the auth `Review Session`
#     line, so ONLY the ascii-fold predicate decides selection.
arr="$( { rec 100 "$BOT" "Review PAſSED
Review Session
Review Agent: agy" "2026-02-01T00:00:00Z"
          rec 200 "$BOT" "review passed
Review Session
Review Agent: agy" "2026-02-01T00:05:00Z"; } | as_array )"
out="$(fetch_with "$arr" "agy" "sid-f" "$BOT" "$VRE")"
assert_eq "TC-FINAL2-006 (f) long-s NOT selected; lowercase-ASCII IS (RE2 fold parity)" "review passed
Review Session
Review Agent: agy" "$out"

# (f2) long-s ALONE → no match at all (EMPTY), proving the widening is gone.
arr="$( rec 100 "$BOT" "Review PAſSED
Review Session
Review Agent: agy" "2026-02-01T00:00:00Z" | as_array )"
out="$(fetch_with "$arr" "agy" "sid-f2" "$BOT" "$VRE")"
assert_eq "TC-FINAL2-006b (f) long-s-only → EMPTY (no Oniguruma i-fold widening)" "" "$out"

# (g) no-match returns EMPTY (zero bytes, NOT the literal string `null`). The comment
#     is auth+agent-matching but carries NO verdict keyword.
arr="$( rec 100 "$BOT" "just a chat comment
Review Session
Review Agent: agy" "2026-02-01T00:00:00Z" | as_array )"
out="$(fetch_with "$arr" "agy" "sid-g" "$BOT" "$VRE")"
assert_eq "TC-FINAL2-007 (g) no-match → EMPTY (not literal 'null')" "" "$out"

# (h) same-second .id tiebreak — higher .id wins.
arr="$( { rec 100 "$BOT" "Review FAILED
Review Session
Review Agent: agy" "2026-02-01T00:00:00Z"
          rec 200 "$BOT" "Review PASSED
Review Session
Review Agent: agy" "2026-02-01T00:00:00Z"; } | as_array )"
out="$(fetch_with "$arr" "agy" "sid-h" "$BOT" "$VRE")"
assert_eq "TC-FINAL2-008 (h) same-second tie → higher .id (newest) body wins" "Review PASSED
Review Session
Review Agent: agy" "$out"

# (i) C-locale fold — Review FAILED still matches under a Turkish locale (the `I`
#     regression). If tr_TR.UTF-8 is not installed on the box (the common case in
#     hermetic CI), run the match under whatever locale IS active AND assert the
#     helper hard-codes `LC_ALL=C tr` (the static guard, per the issue's "or assert
#     the helper uses LC_ALL=C") — so the dotless-ı regression is pinned either way.
arr="$( rec 100 "$BOT" "Review FAILED
Review Session
Review Agent: agy" "2026-02-01T00:00:00Z" | as_array )"
exp="Review FAILED
Review Session
Review Agent: agy"
if locale -a 2>/dev/null | grep -qiE '^tr_TR\.utf-?8$'; then
  out="$(fetch_with "$arr" "agy" "sid-i" "$BOT" "$VRE" "2026-01-01T00:00:00Z" "tr_TR.UTF-8")"
  assert_eq "TC-FINAL2-009 (i) Review FAILED matches under tr_TR.UTF-8 (LC_ALL=C tr guards dotless-ı)" "$exp" "$out"
else
  out="$(fetch_with "$arr" "agy" "sid-i" "$BOT" "$VRE")"
  assert_eq "TC-FINAL2-009 (i) Review FAILED matches (tr_TR.UTF-8 absent — run under active locale)" "$exp" "$out"
  assert_grep "TC-FINAL2-009b (i) helper hard-codes LC_ALL=C tr (static dotless-ı guard)" \
    "LC_ALL=C[[:space:]]+tr[[:space:]]" "$POLL_LIB"
fi

# (j) empty _VERDICT_RE fail-CLOSED — unset RE + an auth+agent-matching NON-verdict comment → EMPTY.
arr="$( rec 100 "$BOT" "not a verdict at all
Review Session
Review Agent: agy" "2026-02-01T00:00:00Z" | as_array )"
out="$(fetch_with "$arr" "agy" "sid-j" "$BOT" "__UNSET__")"
assert_eq "TC-FINAL2-010 (j) empty _VERDICT_RE → EMPTY (fail-CLOSED, not test(\"\") match-all)" "" "$out"

# --------------------------------------------------------------------------
# Prong 2 — S1 idempotency (dispatcher-tick.sh INV-12 PTL marker-count guard).
# --------------------------------------------------------------------------
echo "=== Prong 2: S1 idempotency (migrated marker-count guard logic) ==="

# Drive the migrated guard shape directly (the tick wrapper is too heavy to source).
# This mirrors the exact post-migration logic in dispatcher-tick.sh.
s1_guard() {
  local marker="$1"; shift
  local arr="$1"
  local posted=0
  itp_list_comments() { printf '%s' "$arr"; }
  itp_post_comment() { posted=1; }
  local _count
  _count="$(itp_list_comments 0 2>/dev/null \
    | jq -r "[.[].body | select(contains(\"${marker}\"))] | length" 2>/dev/null)"
  if [ "${_count:-}" = "0" ]; then
    itp_post_comment 0 "notice (${marker})"
  fi
  echo "$posted"
}

MARK="INV-12-prompt-too-long:sid-123"
arr="$( { rec 1 "$BOT" "old comment" "2026-02-01T00:00:00Z"
          rec 2 "$BOT" "Session exhausted … (${MARK})" "2026-02-01T00:01:00Z"; } | as_array )"
assert_eq "TC-FINAL2-020 marker already present → NOT posted" "0" "$(s1_guard "$MARK" "$arr")"

arr="$( rec 1 "$BOT" "unrelated comment" "2026-02-01T00:00:00Z" | as_array )"
assert_eq "TC-FINAL2-021 marker absent → posted once" "1" "$(s1_guard "$MARK" "$arr")"

# fetch error / empty → fail-closed (NOT posted).
assert_eq "TC-FINAL2-022 fetch empty/error → NOT posted (fail-closed)" "0" "$(s1_guard "$MARK" "")"

# --------------------------------------------------------------------------
# Prong 3 — source-shape pins + the four fix tokens.
# --------------------------------------------------------------------------
echo "=== Prong 3: source-shape pins (anti-drift) ==="

# Count raw `gh issue view --json comments` CALL SITES (non-comment lines only) —
# the same #-line exclusion check-provider-cutover.sh's detector applies, so a
# doc-comment that quotes the old wire form (these files now carry one) is not
# miscounted as a surviving call.
count_gh_comments_sites() {
  grep -nE 'gh issue view .*--json comments' "$1" 2>/dev/null \
    | awk -F: '{ s=$0; sub(/^[0-9]+:/, "", s); sub(/^[[:space:]]+/, "", s); if (substr(s,1,1) != "#") print }' \
    | wc -l | tr -d ' '
}

# TC-FINAL2-030: zero raw gh issue view --json comments CALL SITES in lib-review-poll.sh.
assert_eq "TC-FINAL2-030 lib-review-poll.sh raw gh-issue-view-comments call sites == 0" \
  "0" "$(count_gh_comments_sites "$POLL_LIB")"

# TC-FINAL2-031: dispatcher-tick.sh dropped its ONLY --json comments scanner call site.
assert_eq "TC-FINAL2-031 dispatcher-tick.sh raw gh-issue-view-comments call sites == 0 (timeline gh api stays)" \
  "0" "$(count_gh_comments_sites "$TICK")"

# TC-FINAL2-032/033: the migrated itp_list_comments form is present.
c="$(grep -c 'itp_list_comments' "$POLL_LIB" || true)"
assert_grep "TC-FINAL2-032 lib-review-poll.sh uses itp_list_comments" 'itp_list_comments' "$POLL_LIB"
c="$(grep -c 'itp_list_comments' "$TICK" || true)"
assert_grep "TC-FINAL2-033 dispatcher-tick.sh uses itp_list_comments (S1)" 'itp_list_comments' "$TICK"

# TC-FINAL2-034: the lazy self-source guard token.
assert_grep "TC-FINAL2-034 lazy self-source guard (declare -F itp_list_comments)" \
  'declare -F itp_list_comments' "$POLL_LIB"

# TC-FINAL2-035: the four S2 fix tokens.
assert_grep "TC-FINAL2-035a LC_ALL=C fold token" 'LC_ALL=C' "$POLL_LIB"
assert_grep "TC-FINAL2-035b ascii_downcase token" 'ascii_downcase' "$POLL_LIB"
assert_grep "TC-FINAL2-035c // empty guard token" '// empty' "$POLL_LIB"
assert_grep "TC-FINAL2-035d empty-_VERDICT_RE fail-closed guard" \
  '\[\[ -z "\$_vre_lc" \]\] && return 0' "$POLL_LIB"

# TC-FINAL2-036: the stable-sort .id tiebreak. The jq lives inside a bash
# double-quoted string, so the on-disk form carries backslash-escaped quotes
# (`sort_by(.createdAt // \"\", .id // 0)`) — match it as a FIXED string.
if grep -qF 'sort_by(.createdAt // \"\", .id // 0)' "$POLL_LIB"; then
  echo -e "  ${GREEN}PASS${NC}: TC-FINAL2-036 same-second .id tiebreak sort_by present"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-FINAL2-036 same-second .id tiebreak sort_by missing"
  FAIL=$((FAIL + 1))
fi

# --------------------------------------------------------------------------
# Prong 4 — cutover-baseline delta pinned DURABLY (absence/presence, not a
# fragile prior−N delta-vs-origin/main arithmetic).
# --------------------------------------------------------------------------
# #321 originally pinned its own −2 delta with `cur_total == origin/main − 2`.
# That arithmetic is only valid in the PR that introduces the delta — once #321
# merged, origin/main carries the −2 already, so the pin went STALE (it asserts
# `origin/main − 2` against an origin/main that now equals the post-#321 total).
# #323 (this PR) removes the LAST survivor in dispatcher-tick.sh (the timeline
# read), shrinking the baseline by 1 more — which would make a `−2` pin fail
# `72 == 73−2 = 71`. So Prong 4 is rewritten to the DURABLE idiom #308/#310 use:
# assert the specific migrated wire-forms are ABSENT from the baseline + the
# terminal property (dispatcher-tick.sh has ZERO baseline survivors). The total
# reconciliation is the cutover guard's own job (TC-CUTOVER-001 / Check 1/4), so
# no PR-relative delta arithmetic is duplicated here where it can rot.
echo "=== Prong 4: cutover-baseline (durable absence/presence pins) ==="

S1_WIRE='if gh issue view "$issue_num" --repo "$REPO" --json comments \'
S2_WIRE='gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json comments \'
TIMELINE_WIRE='gh api "repos/${REPO}/issues/${issue_num}/timeline"'

# #321's two migrated wire-forms are ABSENT from the working-tree baseline.
n_s1="$(jq --arg c "$S1_WIRE" '[.surviving_sites[] | select(.content == $c)] | length' "$BASELINE")"
n_s2="$(jq --arg c "$S2_WIRE" '[.surviving_sites[] | select(.content == $c)] | length' "$BASELINE")"
assert_eq "TC-FINAL2-040a S1 wire-form absent from baseline" "0" "$n_s1"
assert_eq "TC-FINAL2-040b S2 wire-form absent from baseline" "0" "$n_s2"

# TC-FINAL2-041 (rewritten, durable): dispatcher-tick.sh is TERMINALLY raw-gh-free —
# ZERO entries in the cutover baseline. (#323 removed the last one, the timeline
# read.) This is the standing property the #296 second-tier batch establishes; it
# does not rot across future PRs the way a prior−N delta does.
n_tick="$(jq '[.surviving_sites[] | select(.file == "dispatcher-tick.sh")] | length' "$BASELINE")"
assert_eq "TC-FINAL2-041 dispatcher-tick.sh has ZERO cutover-baseline survivors (terminally raw-gh-free, #323)" \
  "0" "$n_tick"

# TC-FINAL2-042 (FLIPPED, #323): the dispatcher-tick timeline gh api survivor is now
# GONE — #321 left it as out-of-scope; #323 migrated it behind itp_label_event_ts.
# Co-require ALL THREE pins in one block so a vacuous-green (one pin satisfied while
# another regressed) cannot pass:
#   (i)   `gh api …/timeline` is ABSENT from dispatcher-tick.sh (executable, non-comment);
#   (ii)  `itp_label_event_ts "$issue_num" "autonomous"` is PRESENT in dispatcher-tick.sh;
#   (iii) the specific timeline WIRE-STRING is the baseline entry that was removed.
n_tl_src="$(grep -aE '(^|[^A-Za-z_-])gh ' "$TICK" \
  | awk '{s=$0;sub(/^[[:space:]]+/,"",s); if(substr(s,1,1)=="#")next; print s}' \
  | grep -c 'gh api .*timeline' || true)"
has_verb_call="$(grep -cF 'itp_label_event_ts "$issue_num" "autonomous"' "$TICK" || true)"
n_tl_base="$(jq --arg c "$TIMELINE_WIRE" '[.surviving_sites[] | select(.content | contains($c))] | length' "$BASELINE")"
if [[ "$n_tl_src" -eq 0 && "$has_verb_call" -ge 1 && "$n_tl_base" -eq 0 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-FINAL2-042 timeline gh api survivor MIGRATED (src absent + verb call present + baseline entry removed)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-FINAL2-042 timeline migration incomplete (src_gh=$n_tl_src verb_call=$has_verb_call base_entry=$n_tl_base — all 3 pins co-required)"
  FAIL=$((FAIL + 1))
fi

# --------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
