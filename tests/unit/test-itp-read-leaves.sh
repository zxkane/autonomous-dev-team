#!/bin/bash
# test-itp-read-leaves.sh — #281: ITP READ-leaf migration.
#
# Proves the READ half of the ITP contract (provider-spec.md §3.1/§3.3/§3.5,
# [INV-87]/[INV-88]/[INV-90]) is a zero-behavior-change GitHub refactor:
#
#   1. Golden-trace argv — the state-list / read_task leaves emit BYTE-IDENTICAL
#      `gh` argv (+ --json field list) after routing through the verb, and the
#      28 inline `gh issue view --json comments` scanners are consolidated to
#      exactly ZERO inline calls (the comment-fetch trace is anchored on the
#      28-site count, not per-site argv — they deliberately collapse to one verb).
#   2. Dispatch routing — each itp_<verb> dispatches to itp_github_<verb>.
#   3. .caps parse — server_side_state_and=1 / server_side_state_negation=0.
#   4. Normalized comment shape — [{id,author,authorKind,body,createdAt}] sorted
#      ascending by createdAt; INV-85 exact-eq + INV-05 cutoff behavior preserved.
#   5. Capability-branch via the named degraded fake provider (read-side caps=0).
#   6. Conformance fixture rule (INV-75) + function-mock-shim audit (§7.3 m3).
#
# Run: bash tests/unit/test-itp-read-leaves.sh
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
LIB="$SCRIPTS/lib-dispatch.sh"
PROVIDERS="$SCRIPTS/providers"
FAKE_PROVIDER="$SCRIPT_DIR/fixtures/provider-degraded"

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

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-itp-read-$$
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# ===========================================================================
# 1. GOLDEN-TRACE — record the exact `gh` argv the leaf emits, assert it
#    byte-identical to the pre-refactor call (the no-behavior-change proof).
# ===========================================================================
# A recording `gh` stub: it writes the full argv (one arg per line, NUL-free)
# to $_GH_ARGV_FILE and returns a canned payload so the caller's downstream jq
# (the INV-25 subtraction etc.) still runs without error.
_GH_ARGV_FILE="$(mktemp)"
_GH_VIEW_COMMENTS_JSON='{"comments":[]}'
gh() {
  # Record argv verbatim.
  printf '%s\n' "$@" > "$_GH_ARGV_FILE"
  # Serve a payload appropriate to the subcommand so callers don't error.
  if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
    # Apply the requested -q (if any) to an empty array so `| length` → 0 etc.
    local q="" i
    for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "-q" || "${!i}" == "--jq" ]]; then local j=$((i+1)); q="${!j}"; break; fi; done
    if [[ -n "$q" ]]; then jq -c "$q" <<<'[]'; else printf '[]'; fi
    return 0
  fi
  if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
    # read_task (no -q on comments path here): return canned object/value.
    local q="" json="" i
    for ((i=1;i<=$#;i++)); do
      [[ "${!i}" == "-q" || "${!i}" == "--jq" ]] && { local j=$((i+1)); q="${!j}"; }
      [[ "${!i}" == "--json" ]] && { local k=$((i+1)); json="${!k}"; }
    done
    if [[ "$json" == *comments* ]]; then
      local body; body="$_GH_VIEW_COMMENTS_JSON"
      if [[ -n "$q" ]]; then jq -r "$q" <<<"$body"; else printf '%s' "$body"; fi
    else
      # title/body/state object
      local obj='{"title":"T","body":"B","state":"OPEN","labels":[]}'
      if [[ -n "$q" ]]; then jq -r "$q" <<<"$obj"; else printf '%s' "$obj"; fi
    fi
    return 0
  fi
  printf ''
}
export -f gh
export _GH_ARGV_FILE _GH_VIEW_COMMENTS_JSON

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

# Helper: read back the recorded argv as a single space-joined line. `gh` wrote
# one arg per line; paste -sd' ' joins them with single spaces and DROPs the
# trailing newline (no trailing space artifact).
recorded_argv() { paste -sd' ' "$_GH_ARGV_FILE"; }

echo "=== GOLDEN-TRACE: state-list / count / forbidden-combos argv byte-identical ==="

count_active >/dev/null
assert_eq "TC-GT-COUNT count_active argv" \
  "issue list --repo $REPO --state open --limit 100 --label autonomous --json labels -q [.[] | select(.labels[].name | IN(\"in-progress\",\"reviewing\"))] | length" \
  "$(recorded_argv)"

list_new_issues >/dev/null
assert_contains "TC-GT-NEW list_new_issues --json number,labels,title" \
  "issue list --repo $REPO --state open --limit 100 --label autonomous --json number,labels,title -q" "$(recorded_argv)"

list_pending_review >/dev/null
assert_contains "TC-GT-PREV list_pending_review --label autonomous,pending-review --json number,labels" \
  "--label autonomous,pending-review --json number,labels -q" "$(recorded_argv)"

list_pending_dev >/dev/null
assert_contains "TC-GT-PDEV list_pending_dev --json number,labels,comments (incl. comments)" \
  "--label autonomous,pending-dev --json number,labels,comments -q" "$(recorded_argv)"

list_stale_candidates >/dev/null
assert_contains "TC-GT-STALE list_stale_candidates argv" \
  "--label autonomous --json number,labels -q" "$(recorded_argv)"

list_hygiene_residue >/dev/null
hyg_argv="$(recorded_argv)"
assert_contains "TC-GT-HYG list_hygiene_residue routes issue list --json number,labels" \
  "issue list --repo $REPO --state open --limit 100 --label autonomous --json number,labels -q" "$hyg_argv"
assert_contains "TC-GT-HYG forbidden-combo 2-axis predicate preserved (terminal AND transitional)" \
  'contains(["approved"]) or contains(["stalled"])' "$hyg_argv"

echo "=== GOLDEN-TRACE: itp_read_task argv byte-identical per field ==="
itp_read_task 42 title >/dev/null
assert_eq "TC-GT-READTASK title" "issue view 42 --repo $REPO --json title" "$(recorded_argv)"
itp_read_task 42 body -q '.body' >/dev/null
assert_eq "TC-GT-READTASK body -q .body" "issue view 42 --repo $REPO --json body -q .body" "$(recorded_argv)"
itp_read_task 42 state -q '.state' >/dev/null
assert_eq "TC-GT-READTASK state -q .state" "issue view 42 --repo $REPO --json state -q .state" "$(recorded_argv)"
itp_read_task 42 title,body -q '.' >/dev/null
assert_eq "TC-GT-READTASK title,body -q . (autonomous-dev.sh:1097)" "issue view 42 --repo $REPO --json title,body -q ." "$(recorded_argv)"
itp_read_task 42 state,labels,title >/dev/null
assert_eq "TC-GT-READTASK state,labels,title (status.sh:85)" "issue view 42 --repo $REPO --json state,labels,title" "$(recorded_argv)"

echo "=== GOLDEN-TRACE: itp_list_comments internal gh argv (fetch leaf preserved) ==="
itp_list_comments 42 >/dev/null
lc_argv="$(recorded_argv)"
assert_contains "TC-GT-COMMENTS itp_list_comments fetches gh issue view --json comments" \
  "issue view 42 --repo $REPO --json comments -q" "$lc_argv"

echo "=== GOLDEN-TRACE: comment-fetch 28-site count anchor — ZERO inline scanners remain ==="
inline_count=$(grep -cE 'issue view .*--json [a-zA-Z,]*comments' "$LIB")
assert_eq "TC-GT-COMMENTS-28 no inline 'gh issue view --json comments' in lib-dispatch.sh" "0" "$inline_count"
# The 28 sites all route through itp_list_comments now.
itp_calls=$(grep -cE 'itp_list_comments ' "$LIB")
[ "$itp_calls" -ge 28 ] && echo -e "  ${GREEN}PASS${NC}: TC-GT-COMMENTS-28 ≥28 itp_list_comments call sites ($itp_calls)" && PASS=$((PASS+1)) \
  || { echo -e "  ${RED}FAIL${NC}: TC-GT-COMMENTS-28 expected ≥28 itp_list_comments calls, got $itp_calls"; FAIL=$((FAIL+1)); }

# ===========================================================================
# 2. DISPATCH ROUTING — itp_<verb> → itp_github_<verb> (mirrors test-cli-adapters)
# ===========================================================================
echo "=== DISPATCH ROUTING: itp_<verb> → itp_github_<verb> under default github ==="
routed=$(
  env -u AUTONOMOUS_PROVIDERS_DIR ISSUE_PROVIDER=github bash -c '
    set -uo pipefail
    export REPO='"$REPO"' REPO_OWNER='"$REPO_OWNER"' PROJECT_ID='"$PROJECT_ID"'
    source "'"$SCRIPTS"'/lib-issue-provider.sh"
    # Stub the github leaves so we can observe which one each shim hits.
    itp_github_list_by_state()        { echo "ROUTED:list_by_state:$*"; }
    itp_github_count_by_state()       { echo "ROUTED:count_by_state:$*"; }
    itp_github_list_forbidden_combos(){ echo "ROUTED:list_forbidden_combos:$*"; }
    itp_github_read_task()            { echo "ROUTED:read_task:$*"; }
    itp_github_list_comments()        { echo "ROUTED:list_comments:$*"; }
    itp_list_by_state A
    itp_count_by_state B
    itp_list_forbidden_combos C
    itp_read_task 7 title
    itp_list_comments 7
  '
)
assert_contains "TC-RT-LIST itp_list_by_state → itp_github_list_by_state" "ROUTED:list_by_state:A" "$routed"
assert_contains "TC-RT-COUNT itp_count_by_state → itp_github_count_by_state" "ROUTED:count_by_state:B" "$routed"
assert_contains "TC-RT-FORBIDDEN itp_list_forbidden_combos → itp_github_list_forbidden_combos" "ROUTED:list_forbidden_combos:C" "$routed"
assert_contains "TC-RT-READTASK itp_read_task → itp_github_read_task" "ROUTED:read_task:7 title" "$routed"
assert_contains "TC-RT-COMMENTS itp_list_comments → itp_github_list_comments" "ROUTED:list_comments:7" "$routed"

# ===========================================================================
# 3. .caps PARSE — the no-behavior-change anchor (§4.3, [INV-88]).
# ===========================================================================
echo "=== .caps PARSE: itp-github.caps as consumed by the read verbs ==="
caps_out=$(
  env -u AUTONOMOUS_PROVIDERS_DIR ISSUE_PROVIDER=github bash -c '
    source "'"$SCRIPTS"'/lib-issue-provider.sh"
    echo "AND=$(itp_caps server_side_state_and)"
    echo "NEG=$(itp_caps server_side_state_negation)"
  '
)
assert_contains "TC-CAPS-AND server_side_state_and=1 (server-side label-AND)" "AND=1" "$caps_out"
assert_contains "TC-CAPS-NEG server_side_state_negation=0 (negation client-side jq — GitHub's path)" "NEG=0" "$caps_out"

# ===========================================================================
# 4. NORMALIZED COMMENT SHAPE (§3.3 / [INV-90]).
# ===========================================================================
echo "=== NORMALIZED COMMENT SHAPE via itp_github_list_comments ==="
# Out-of-order createdAt + [bot]/human/self authors + numeric id in url.
export BOT_LOGIN="my-claw"
_GH_VIEW_COMMENTS_JSON='{"comments":[
  {"id":"IC_z","url":"https://github.com/o/r/issues/1#issuecomment-300","author":{"login":"dev-bot[bot]"},"body":"newest bot","createdAt":"2026-06-26T12:00:00Z"},
  {"id":"IC_a","url":"https://github.com/o/r/issues/1#issuecomment-100","author":{"login":"my-claw"},"body":"oldest self","createdAt":"2026-06-26T10:00:00Z"},
  {"id":"IC_m","url":"https://github.com/o/r/issues/1#issuecomment-200","author":{"login":"alice"},"body":"middle human","createdAt":"2026-06-26T11:00:00Z"}
]}'
norm=$(itp_list_comments 1)

# TC-SHAPE-FIELDS — exactly the five keys.
keys=$(jq -r '.[0] | keys_unsorted | join(",")' <<<"$norm")
assert_eq "TC-SHAPE-FIELDS element has exactly id,author,authorKind,body,createdAt" "id,author,authorKind,body,createdAt" "$keys"

# TC-SHAPE-SORT — ascending by createdAt.
order=$(jq -r '[.[].createdAt] | join(" ")' <<<"$norm")
assert_eq "TC-SHAPE-SORT ascending by createdAt" "2026-06-26T10:00:00Z 2026-06-26T11:00:00Z 2026-06-26T12:00:00Z" "$order"

# TC-SHAPE-ID-NUM — id is REST numeric (from url), type number.
id0=$(jq -r '.[0].id' <<<"$norm"); id0t=$(jq -r '.[0].id | type' <<<"$norm")
assert_eq "TC-SHAPE-ID-NUM oldest comment numeric REST id" "100" "$id0"
assert_eq "TC-SHAPE-ID-NUM id is a number" "number" "$id0t"

# TC-SHAPE-AUTHOR — login incl [bot] verbatim.
botauthor=$(jq -r '.[] | select(.body=="newest bot") | .author' <<<"$norm")
assert_eq "TC-SHAPE-AUTHOR bot login incl [bot] verbatim" "dev-bot[bot]" "$botauthor"

# TC-SHAPE-KIND — self / bot / human.
kself=$(jq -r '.[] | select(.author=="my-claw") | .authorKind' <<<"$norm")
kbot=$(jq -r '.[] | select(.author=="dev-bot[bot]") | .authorKind' <<<"$norm")
khuman=$(jq -r '.[] | select(.author=="alice") | .authorKind' <<<"$norm")
assert_eq "TC-SHAPE-KIND author==BOT_LOGIN → self" "self" "$kself"
assert_eq "TC-SHAPE-KIND login ends [bot] → bot" "bot" "$kbot"
assert_eq "TC-SHAPE-KIND otherwise → human" "human" "$khuman"

# TC-SHAPE-INV85 — exact-eq select((.author)==$dev) over normalized == pre-refactor
# .author.login==$dev over raw. Build a raw fixture and compare selections.
echo "=== INV-85 exact-eq + INV-05 cutoff equivalence (pre vs post) ==="
raw='{"comments":[
  {"url":"https://github.com/o/r/issues/1#issuecomment-1","author":{"login":"dev-bot[bot]"},"body":"403 Resource not accessible by integration on gh pr edit","createdAt":"2026-06-26T11:00:00Z"},
  {"url":"https://github.com/o/r/issues/1#issuecomment-2","author":{"login":"maintainer"},"body":"quoting 403 Resource not accessible by integration","createdAt":"2026-06-26T11:30:00Z"}
]}'
# pre-refactor selection (raw .comments[].author.login):
pre=$(jq -r '[.comments[] | select((.author.login // "")=="dev-bot[bot]") | .body] | length' <<<"$raw")
# post-refactor: normalize then select over .author.
_GH_VIEW_COMMENTS_JSON="$raw"
post=$(itp_list_comments 1 | jq -r '[.[] | select((.author // "")=="dev-bot[bot]") | .body] | length')
assert_eq "TC-SHAPE-INV85 exact-eq selects the dev-bot comment identically (pre=$pre post=$post)" "$pre" "$post"

# TC-SHAPE-INV05 — `.createdAt > cutoff` + `sort_by(.createdAt)|last` identical.
cutoff="2026-06-26T11:15:00Z"
pre_after=$(jq -r "[.comments[] | select(.createdAt > \"$cutoff\")] | length" <<<"$raw")
post_after=$(itp_list_comments 1 | jq -r "[.[] | select(.createdAt > \"$cutoff\")] | length")
assert_eq "TC-SHAPE-INV05 createdAt>cutoff count identical (pre=$pre_after post=$post_after)" "$pre_after" "$post_after"
pre_last=$(jq -r '[.comments[]] | sort_by(.createdAt) | last | .body' <<<"$raw")
post_last=$(itp_list_comments 1 | jq -r 'sort_by(.createdAt) | last | .body')
assert_eq "TC-SHAPE-INV05 sort_by(.createdAt)|last identical" "$pre_last" "$post_last"
unset BOT_LOGIN

# ===========================================================================
# 5. CAPABILITY-BRANCH via the named degraded fake provider (§7.4) — the
#    read-side caps=0 branches that ship now (negation + AND done client-side).
# ===========================================================================
echo "=== CAPABILITY-BRANCH: degraded fake provider read-side caps=0 (public seam) ==="
if [[ -d "$FAKE_PROVIDER" ]]; then
  fake=$(
    env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
        ISSUE_PROVIDER=degraded AUTONOMOUS_PROVIDERS_DIR="$FAKE_PROVIDER" \
    bash -c '
      source "'"$SCRIPTS"'/lib-issue-provider.sh"
      echo "AND=$(itp_caps server_side_state_and)"
      echo "NEG=$(itp_caps server_side_state_negation)"
    '
  )
  assert_contains "TC-CAP-AND0 degraded: server_side_state_and=0 (list-all + client-side AND branch)" "AND=0" "$fake"
  assert_contains "TC-CAP-NEG0 degraded: server_side_state_negation=0 (client-side negation branch)" "NEG=0" "$fake"
else
  echo -e "  ${RED}FAIL${NC}: degraded fake provider fixture missing at $FAKE_PROVIDER (expected from #280)"
  FAIL=$((FAIL+1))
fi

# ===========================================================================
# 6. CONFORMANCE FIXTURE RULE (INV-75) + FUNCTION-MOCK SHIM AUDIT (§7.3 m3).
# ===========================================================================
echo "=== CONFORMANCE FIXTURE RULE + FUNCTION-MOCK SHIM AUDIT ==="
e2e_fixture="$SCRIPT_DIR/test-entry-point-startup-e2e.sh"
if grep -qE 'cp -r .*/providers' "$e2e_fixture"; then
  echo -e "  ${GREEN}PASS${NC}: TC-FIXTURE-CPR fake-skill-tree fixture carries cp -r providers/ (INV-75)"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-FIXTURE-CPR fixture missing cp -r providers/ (INV-75)"; FAIL=$((FAIL+1))
fi

# Audit: every moved READ function keeps its EXACT name (no rename) so existing
# FUNCTION-level mocks still bind. Assert the functions are defined under their
# original names after sourcing the lib.
audit_ok=1
for fn in count_active list_new_issues list_pending_review list_pending_dev \
          list_stale_candidates list_hygiene_residue count_agent_failures \
          count_dispatcher_crashes extract_dev_session_id last_reviewed_head \
          classify_recent_review_verdict dev_report_bot_unfixable \
          latest_review_verdict_age_seconds recent_error_envelope; do
  declare -F "$fn" >/dev/null 2>&1 || { echo "   missing: $fn"; audit_ok=0; }
done
assert_eq "TC-AUDIT-NORENAME all moved read functions keep their names (shim=same name)" "1" "$audit_ok"

rm -f "$_GH_ARGV_FILE"

# ===========================================================================
echo ""
echo "=== Summary ==="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
[ "$FAIL" -eq 0 ]
