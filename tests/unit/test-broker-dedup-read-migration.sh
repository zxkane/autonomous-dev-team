#!/bin/bash
# test-broker-dedup-read-migration.sh — issue #333 (#296 second-tier).
#
# `lib-review-e2e.sh::_post_brokered_e2e_report` (the [INV-79] E2E-report broker)
# dedups before posting: it counts the `## E2E Verification Report` comments already
# in the review window (bounded by WRAPPER_START_TS) so it does not double-post when
# the agent's direct-write fallback already landed one.
#
# This issue migrates that COUNT read from a raw
#   gh api "repos/${REPO_OWNER}/${REPO_NAME}/issues/${PR_NUMBER}/comments" --paginate
# call to the SHIPPED `itp_list_comments` verb — no new verb, shape-equivalent
# (#332 / #315 precedent):
#
#   _existing=$(itp_list_comments "$PR_NUMBER" 2>/dev/null \
#     | jq -r "[.[] | select((.createdAt >= \"${WRAPPER_START_TS}\") and (.body | contains(\"## E2E Verification Report\")))] | length" \
#     2>/dev/null | tail -n1 || true)
#
# Three strategies:
#   (i)  selector parity — extract the LIVE `jq -r '<EXPR>'` count selector from
#        _post_brokered_e2e_report and run it against synthetic NORMALIZED [INV-90]
#        array fixtures; prove it reproduces the raw-`gh-api` count (incl. the
#        .created_at->.createdAt rename + the WRAPPER_START_TS window-boundary
#        lexical-format equivalence, P1) for every golden case;
#   (ii) broker behavior — source _post_brokered_e2e_report in ISOLATION with a
#        STUBBED itp_list_comments / log / gh and assert SKIP-vs-PROCEED end-to-end
#        (incl. the P2 verb-error rc!=0 + empty-stdout failure mode);
#   (iii) source-shape — the raw `:571` gh-api read is gone (function-scoped), the
#        verb form is present, `| tail -n1` is KEPT (folded P2), baseline -1, cutover
#        guard green. The :486/:498 INV-46 reads in the OTHER function
#        (_stamp_browser_evidence_marker) were out of #333's scope at the time this
#        test was written ("STILL raw") — #345 (#296 deferred) later retired that
#        carve-out, so this file's negative-scope assertion now checks the reads are
#        GONE, not present (see TC-333-SRC-04/05b).
#
# Run: env -u PROJECT_DIR bash tests/unit/test-broker-dedup-read-migration.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
E2E_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-e2e.sh"
BASELINE="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/cutover-baseline.json"
CHECK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/check-provider-cutover.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad()  { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

# The window anchor used across all selector fixtures (matches the wrapper's
# WRAPPER_START_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ") lexical format).
WRAPPER_START_TS="2026-06-30T15:38:36Z"
export WRAPPER_START_TS

# ---------------------------------------------------------------------------
# Extract the broker function body (between `_post_brokered_e2e_report() {` and the
# next top-level `}`) so source-shape greps are FUNCTION-SCOPED — the INV-46 reads
# in the SEPARATE _stamp_browser_evidence_marker function must not false-green/red.
extract_broker_body() {
  awk '/^_post_brokered_e2e_report\(\) \{/{c=1} c{print} /^\}/{if(c){exit}}' "$E2E_LIB"
}
extract_stamp_body() {
  awk '/^_stamp_browser_evidence_marker\(\) \{/{c=1} c{print} /^\}/{if(c){exit}}' "$E2E_LIB"
}
BROKER_BODY="$(extract_broker_body)"
STAMP_BODY="$(extract_stamp_body)"

# Extract the LIVE jq count selector from the broker body (the single-quoted /
# double-quoted jq -r expression following the migrated itp_list_comments pipe,
# anchored on the `## E2E Verification Report` contains literal). The migrated form
# uses a double-quoted jq string (so ${WRAPPER_START_TS} interpolates), so we pull
# the text between `jq -r "` and the line's trailing `"`.
extract_selector() {
  printf '%s\n' "$BROKER_BODY" | awk '
    /jq -r .*contains\(.*E2E Verification Report/ {
      # strip everything up to and including `jq -r "`
      line=$0
      sub(/^.*jq -r "/, "", line)
      # strip the trailing `" \` (continuation) or `"`
      sub(/" *\\?[[:space:]]*$/, "", line)
      print line
      exit
    }
  '
}
JQ_SELECTOR="$(extract_selector)"

# Run the live selector over a NORMALIZED-array fixture. The selector was captured
# from the source VERBATIM — i.e. it still carries the `\"` shell-escapes and the
# unexpanded `${WRAPPER_START_TS}` reference, exactly as it sits inside the wrapper's
# double-quoted `jq -r "…"` argument. We reproduce bash's own expansion of that
# double-quoted string (un-escape `\"`→`"`, expand `${WRAPPER_START_TS}`) so the jq
# program the test runs is byte-identical to the one the wrapper runs at runtime.
run_selector() {
  local fixture_json="$1" prog
  eval "prog=\"$JQ_SELECTOR\""
  jq -r "$prog" <<<"$fixture_json" 2>/dev/null
}

# mk_comment "<iso-createdAt>" "<body>" — one normalized [INV-90] array element.
mk_comment() {
  local ts="$1" body="$2"
  jq -nc --arg ts "$ts" --arg body "$body" \
    '{id: 1, author: "kane-review-agent", authorKind: "bot", body: $body, createdAt: $ts}'
}
as_array() { jq -nc --argjson a "[$(printf '%s' "$1")]" '$a'; }

REPORT='## E2E Verification Report'
CHATTER='<!-- dispatcher-token: abc at 2026-06-30T16:00:00Z mode=review -->
Dispatching autonomous review...'

# ===================================================================
echo "=== Selector extraction sanity ==="
if [[ -z "$JQ_SELECTOR" ]]; then
  bad "could not extract the broker count selector from _post_brokered_e2e_report (migration not applied yet?)"
  echo "      (expected the migrated 'itp_list_comments \"\$PR_NUMBER\" … | jq -r \"…contains(\\\"## E2E Verification Report\\\")…|length\"' form)"
else
  ok "extracted live count selector: $JQ_SELECTOR"
fi

# ===================================================================
echo
echo "=== TC-333-SEL-01..06: migrated selector reproduces the raw-gh-api count (AC1/AC2) ==="

assert_count() { local d="$1" exp="$2" got="$3"; [[ "$got" == "$exp" ]] && ok "$d" || bad "$d (expected '$exp' got '$got')"; }

# TC-333-SEL-01 — one in-window report → count 1. (case a)
fx=$(as_array "$(mk_comment '2026-06-30T16:00:00Z' "$REPORT — run green")")
assert_count "TC-333-SEL-01 one in-window report → count 1" "1" "$(run_selector "$fx")"

# TC-333-SEL-02 — only a before-window report → count 0. (case b)
fx=$(as_array "$(mk_comment '2026-06-30T15:00:00Z' "$REPORT — stale")")
assert_count "TC-333-SEL-02 before-window-only report → count 0" "0" "$(run_selector "$fx")"

# TC-333-SEL-03 — in-window comment WITHOUT the marker → count 0. (case c)
fx=$(as_array "$(mk_comment '2026-06-30T16:00:00Z' "$CHATTER")")
assert_count "TC-333-SEL-03 in-window non-report → count 0" "0" "$(run_selector "$fx")"

# TC-333-SEL-04 (P1 lexical-format golden) — real createdAt strings straddling
# WRAPPER_START_TS: equal-ts → IN (>= inclusive), 1s earlier → OUT, 1s later → IN.
# Pins .created_at->.createdAt + the Z-suffix second-precision lexical >= boundary.
fx=$(as_array "$(mk_comment '2026-06-30T15:38:35Z' "$REPORT — 1s before"),$(mk_comment '2026-06-30T15:38:36Z' "$REPORT — exactly at start"),$(mk_comment '2026-06-30T15:38:37Z' "$REPORT — 1s after")")
assert_count "TC-333-SEL-04 P1 lexical boundary: at-start + after counted, before excluded → 2" "2" "$(run_selector "$fx")"

# TC-333-SEL-05 (contains substring) — marker MID-body still counts (literal
# contains, NOT startswith — guards against an accidental anchor swap; #332 used
# startswith for a DIFFERENT marker, this broker uses contains).
fx=$(as_array "$(mk_comment '2026-06-30T16:00:00Z' "preamble x $REPORT y trailer")")
assert_count "TC-333-SEL-05 marker mid-body counted (contains, not startswith)" "1" "$(run_selector "$fx")"

# TC-333-SEL-06 (engine parity) — non-ASCII + a test()-style metachar body is matched
# purely by literal contains; a test()-based selector could fold under Oniguruma.
fx=$(as_array "$(mk_comment '2026-06-30T16:00:00Z' "$REPORT 中 \\b(?i) [P1] literal")")
assert_count "TC-333-SEL-06 non-ASCII + metachar body counted literally (no Oniguruma fold)" "1" "$(run_selector "$fx")"

# TC-333-SEL-07 — empty array → count 0. (case d-empty, selector level)
assert_count "TC-333-SEL-07 empty array → count 0" "0" "$(run_selector '[]')"

# ===================================================================
echo
echo "=== TC-333-PARITY: selector is contains/>=, never test(); uses .createdAt (AC2) ==="
if [[ "$JQ_SELECTOR" == *'contains('* && "$JQ_SELECTOR" == *'>='* && "$JQ_SELECTOR" != *'test('* ]]; then
  ok "TC-333-PARITY-001 selector is contains + >=, no test()/regex — no engine divergence"
else
  bad "TC-333-PARITY-001 selector regressed (must be contains + >=, never test()): $JQ_SELECTOR"
fi
if [[ "$JQ_SELECTOR" == *'.createdAt'* && "$JQ_SELECTOR" != *'.created_at'* ]]; then
  ok "TC-333-PARITY-002 selector uses normalized .createdAt (not .created_at)"
else
  bad "TC-333-PARITY-002 selector must reference .createdAt (normalized), not .created_at: $JQ_SELECTOR"
fi

# ===================================================================
echo
echo "=== TC-333-FN-01..07: INV-79 broker dedup behavior unchanged (AC4, end-to-end) ==="

# Harness: source _post_brokered_e2e_report in isolation in a subshell, stub the
# dedup-read verb + log + the POST verb, and report whether the brokered POST
# fired and whether the dedup-read verb was invoked. Stub itp_list_comments AND
# chp_pr_comment DIRECTLY (not gh) — the broker posts via `chp_pr_comment` (#329,
# [INV-102]), not a raw `gh pr comment`, so a `gh` stub alone never sees the call
# in this isolated `eval "$BROKER_BODY"` harness (no lib-code-host.sh self-source
# runs here, so the real `chp_pr_comment` shim is never defined either — #329
# review [P1]). The lib self-source guard keys on `declare -F itp_edit_comment`,
# so test-defined itp_list_comments/chp_pr_comment shadow the seam cleanly and
# avoid the `gh issue view -q` fidelity trap.
#
# Args: <fixture> <start_ts(UNSET|<ts>)> <report_file_state(set|empty|unset)>
# <fixture> is one of:
#   - a NORMALIZED-array JSON string  → the verb echoes it on stdout, rc 0
#   - the sentinel __ERROR__          → the verb exits rc 3 with EMPTY stdout (P2)
# The fixture is written to a FILE the stub `cat`s, so arbitrary JSON (with its `"`)
# round-trips byte-exact — no nested-shell-quote corruption. The stub marks its own
# invocation via `: > "$VERB_FLAG"` as its first action (so the marker fires only
# when the verb is actually called). POST is recorded by the `gh pr comment` stub.
broker_harness() {
  local fixture="$1" start_ts="$2" report_file_state="$3"
  local tmp; tmp=$(mktemp -d)
  local POST_FLAG="$tmp/post" VERB_FLAG="$tmp/verb" FIXTURE_FILE="$tmp/fixture.json"
  local verb_mode="emit"
  if [[ "$fixture" == "__ERROR__" ]]; then verb_mode="error"; else printf '%s' "$fixture" > "$FIXTURE_FILE"; fi
  (
    set +e
    export VERB_FLAG FIXTURE_FILE
    # Minimal env the broker reads.
    PR_NUMBER=4242
    REPO="zxkane/autonomous-dev-team"
    if [[ "$report_file_state" == "set" ]]; then
      E2E_REPORT_FILE="$tmp/report.md"; printf '%s\n' "$REPORT body" > "$E2E_REPORT_FILE"
    elif [[ "$report_file_state" == "empty" ]]; then
      E2E_REPORT_FILE="$tmp/report.md"; : > "$E2E_REPORT_FILE"
    fi
    [[ "$start_ts" == "UNSET" ]] && unset WRAPPER_START_TS || WRAPPER_START_TS="$start_ts"
    # Stubs.
    log() { :; }
    if [[ "$verb_mode" == "error" ]]; then
      itp_list_comments() { : > "$VERB_FLAG"; return 3; }   # rc!=0, EMPTY stdout (P2)
    else
      itp_list_comments() { : > "$VERB_FLAG"; cat "$FIXTURE_FILE"; }
    fi
    # chp_pr_comment stub: the broker's POST verb (#329, [INV-102]) — flag ONLY on
    # the exact expected argv ("$PR_NUMBER" --body "$body"), mirroring the old
    # `gh` stub's `$1=="pr" && $2=="comment"` argv check, so a future argv
    # mis-order/drop in the broker still fails this test instead of passing
    # silently. No `gh` stub needed: the isolated broker body never shells out to
    # `gh` directly for the POST.
    chp_pr_comment() {
      [[ "${1:-}" == "$PR_NUMBER" && "${2:-}" == "--body" ]] && echo fired > "$POST_FLAG"
      return 0
    }
    # Define ONLY the broker function (avoid running the whole lib) — the subshell
    # inherits $BROKER_BODY (already extracted above), so the self-source seam never
    # runs.
    eval "$BROKER_BODY"
    _post_brokered_e2e_report
  ) >/dev/null 2>&1
  local posted=no verbran=no
  [[ -f "$POST_FLAG" ]] && posted=yes
  [[ -f "$VERB_FLAG" ]] && verbran=yes
  rm -rf "$tmp"
  echo "$posted $verbran"
}

# TC-333-FN-01 (skip) — in-window report → count>=1 → SKIP (no post), verb invoked.
res=$(broker_harness "$(as_array "$(mk_comment '2026-06-30T16:00:00Z' "$REPORT")")" "$WRAPPER_START_TS" set)
[[ "$res" == "no yes" ]] && ok "TC-333-FN-01 in-window report → SKIP (no post), verb invoked [$res]" || bad "TC-333-FN-01 expected 'no yes' got '$res'"

# TC-333-FN-02 (proceed, count 0) — before-window-only report → POST.
res=$(broker_harness "$(as_array "$(mk_comment '2026-06-30T15:00:00Z' "$REPORT")")" "$WRAPPER_START_TS" set)
[[ "$res" == "yes yes" ]] && ok "TC-333-FN-02 before-window-only report → POST [$res]" || bad "TC-333-FN-02 expected 'yes yes' got '$res'"

# TC-333-FN-03 (proceed, in-window non-marker) — POST.
res=$(broker_harness "$(as_array "$(mk_comment '2026-06-30T16:00:00Z' "just chatter")")" "$WRAPPER_START_TS" set)
[[ "$res" == "yes yes" ]] && ok "TC-333-FN-03 in-window non-marker → POST [$res]" || bad "TC-333-FN-03 expected 'yes yes' got '$res'"

# TC-333-FN-04 (proceed, empty array) — count 0 → POST.
res=$(broker_harness "[]" "$WRAPPER_START_TS" set)
[[ "$res" == "yes yes" ]] && ok "TC-333-FN-04 empty array → POST [$res]" || bad "TC-333-FN-04 expected 'yes yes' got '$res'"

# TC-333-FN-05 (proceed, verb ERROR rc!=0 + EMPTY stdout) — the P2 failure mode.
# _existing="" → ^[0-9]+$ guard fails → POST (best-effort preserved).
res=$(broker_harness "__ERROR__" "$WRAPPER_START_TS" set)
[[ "$res" == "yes yes" ]] && ok "TC-333-FN-05 verb error (rc!=0, empty stdout) → POST (P2 best-effort) [$res]" || bad "TC-333-FN-05 expected 'yes yes' got '$res'"

# TC-333-FN-06 (WRAPPER_START_TS unset → dedup block skipped) — verb NOT invoked, POST.
# The outer `[[ -n WRAPPER_START_TS ]]` guard means the dedup block (and thus the
# verb) is never entered, so VERB_FLAG stays unwritten.
res=$(broker_harness "[]" UNSET set)
[[ "$res" == "yes no" ]] && ok "TC-333-FN-06 WRAPPER_START_TS unset → dedup skipped, verb not invoked, POST [$res]" || bad "TC-333-FN-06 expected 'yes no' got '$res'"

# TC-333-FN-07 (early return: E2E_REPORT_FILE empty) — verb NOT invoked, NO post.
res=$(broker_harness "[]" "$WRAPPER_START_TS" empty)
[[ "$res" == "no no" ]] && ok "TC-333-FN-07 empty E2E_REPORT_FILE → early return, verb not invoked, no post [$res]" || bad "TC-333-FN-07 expected 'no no' got '$res'"

# ===================================================================
echo
echo "=== TC-333-SRC-01..05: source-shape — raw :571 gone, verb form present, baseline -1 (AC3) ==="

# Strip comment lines from the broker body for raw-token scans.
broker_code() { printf '%s\n' "$BROKER_BODY" | grep -vE '^[[:space:]]*#'; }

# TC-333-SRC-01 — raw `gh api …/issues/${PR_NUMBER}/comments` GONE from the broker.
if broker_code | grep -qE 'gh api "repos/\$\{REPO_OWNER\}/\$\{REPO_NAME\}/issues/\$\{PR_NUMBER\}/comments"'; then
  bad "TC-333-SRC-01 raw 'gh api …/issues/\${PR_NUMBER}/comments' survives in _post_brokered_e2e_report"
else
  ok "TC-333-SRC-01 raw 'gh api …/issues/\${PR_NUMBER}/comments' removed from _post_brokered_e2e_report"
fi

# TC-333-SRC-02 — migrated `itp_list_comments "$PR_NUMBER" … | jq -r` present in the broker.
if broker_code | grep -qE '_existing=\$\(itp_list_comments "\$PR_NUMBER"' && broker_code | grep -qE 'jq -r'; then
  ok "TC-333-SRC-02 migrated 'itp_list_comments \"\$PR_NUMBER\" … | jq -r' present in broker"
else
  bad "TC-333-SRC-02 migrated itp_list_comments|jq form absent from broker"
fi

# TC-333-SRC-03 — `| tail -n1` KEPT in the broker's _existing= assignment (folded P2).
if broker_code | grep -qE 'tail -n1'; then
  ok "TC-333-SRC-03 '| tail -n1' KEPT in broker (folded P2 defensive net)"
else
  bad "TC-333-SRC-03 '| tail -n1' was dropped — folded P2 finding says KEEP it"
fi

# TC-333-SRC-04 (scope updated by #345) — the TWO INV-46 reads formerly in
# _stamp_browser_evidence_marker (:486 GET-id, :498 GET-body) were OUT of #333's
# scope at the time this test was written ("STILL present + raw"). #345 (#296
# deferred) retired that carve-out: both raw `gh api` reads are now GONE, replaced
# by a single itp_list_comments call. Assert the raw forms are absent (the #345
# migration this test previously excluded is now the expected state).
stamp_code() { printf '%s\n' "$STAMP_BODY" | grep -vE '^[[:space:]]*#'; }
if stamp_code | grep -qE '_comment_id=\$\(gh api "repos/\$\{REPO_OWNER\}/\$\{REPO_NAME\}/issues/\$\{PR_NUMBER\}/comments"' \
   || stamp_code | grep -qE '_body=\$\(gh api "repos/\$\{REPO_OWNER\}/\$\{REPO_NAME\}/issues/comments/\$\{_comment_id\}"'; then
  bad "TC-333-SRC-04 an INV-46 raw gh-api read survives in _stamp_browser_evidence_marker (#345 should have migrated it behind itp_list_comments)"
else
  ok "TC-333-SRC-04 the :486/:498 INV-46 raw gh-api reads are GONE from _stamp_browser_evidence_marker (#345 migration)"
fi
if stamp_code | grep -qE 'itp_list_comments "\$PR_NUMBER"'; then
  ok "TC-333-SRC-04b _stamp_browser_evidence_marker now routes through itp_list_comments (#345)"
else
  bad "TC-333-SRC-04b _stamp_browser_evidence_marker does not call itp_list_comments"
fi

# TC-333-SRC-05 — baseline shrank by 1 (the broker entry gone) and cutover guard green.
if grep -Fq '_existing=$(gh api \"repos/${REPO_OWNER}/${REPO_NAME}/issues/${PR_NUMBER}/comments\" --paginate' "$BASELINE"; then
  bad "TC-333-SRC-05a cutover-baseline.json still carries the broker '_existing=\$(gh api …' entry (must shrink -1)"
else
  ok "TC-333-SRC-05a cutover-baseline.json no longer carries the broker '_existing=\$(gh api …' entry (baseline -1)"
fi
# The :486 (_comment_id) + :498 (_body) entries were retired from the baseline by #345.
if grep -Fq '_comment_id=$(gh api \"repos/${REPO_OWNER}/${REPO_NAME}/issues/${PR_NUMBER}/comments\" --paginate' "$BASELINE" \
   || grep -Fq '_body=$(gh api \"repos/${REPO_OWNER}/${REPO_NAME}/issues/comments/${_comment_id}\"' "$BASELINE"; then
  bad "TC-333-SRC-05b cutover-baseline.json still carries a :486/:498 INV-46 entry (#345 should have removed it)"
else
  ok "TC-333-SRC-05b cutover-baseline.json no longer carries the :486/:498 INV-46 entries (#345 migration)"
fi
if bash "$CHECK" >/dev/null 2>&1; then
  ok "TC-333-SRC-05c check-provider-cutover.sh ([INV-91]) PASSES (baseline reconciles with HEAD)"
else
  bad "TC-333-SRC-05c check-provider-cutover.sh ([INV-91]) FAILS — baseline/HEAD reconciliation broken"
  bash "$CHECK" 2>&1 | tail -8 | sed 's/^/      /'
fi

# ===================================================================
echo
echo "=== TC-333-SYNTAX: lib passes bash -n ==="
if bash -n "$E2E_LIB" 2>/dev/null; then
  ok "lib-review-e2e.sh passes bash -n"
else
  bad "lib-review-e2e.sh has syntax errors"
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
