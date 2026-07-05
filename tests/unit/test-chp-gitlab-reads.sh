#!/bin/bash
# test-chp-gitlab-reads.sh — #418 P3-3.
#
# Proves the 7 GitLab CHP READ leaves in
# skills/autonomous-dispatcher/scripts/providers/chp-gitlab.sh against the
# TC-P33-NNN row set (docs/test-cases/p3-3-chp-gitlab-reads.md).
#
# HERMETIC: this test defines a test-local `_gl_api` stub BEFORE sourcing the
# leaf. `lib-gitlab-transport.sh` does NOT exist on this branch yet (#416 is
# a concurrent PR); the leaf's contract is against the FROZEN #416 signature
# only. Every case configures the stub's behavior via a small in-scope state
# object (_GL_API_PAYLOAD_FILE, _GL_API_PAYLOAD_SEQ, _GL_API_FAIL_AT, ...)
# then invokes a leaf and asserts.
#
# Run: env -u PROJECT_DIR bash tests/unit/test-chp-gitlab-reads.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LEAF="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/chp-gitlab.sh"
CAPS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/chp-gitlab.caps"
PAYLOADS="$PROJECT_ROOT/tests/provider-conformance/fixtures/payloads"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad()  { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$desc"
  else bad "$desc"; echo "      expected: |$expected|"; echo "      actual:   |$actual|"; fi
}
assert_rc_nz() {
  local desc="$1" rc="$2"
  if [ "$rc" != "0" ]; then ok "$desc (rc=$rc)"
  else bad "$desc (rc=0, expected non-zero)"; fi
}
assert_rc_2() {
  local desc="$1" rc="$2"
  if [ "$rc" = "2" ]; then ok "$desc (rc=2)"
  else bad "$desc (rc=$rc, expected 2)"; fi
}
assert_jq_true() {
  local desc="$1" filter="$2" json="$3"
  if jq -e "$filter" >/dev/null 2>&1 <<<"$json"; then ok "$desc"
  else bad "$desc"; echo "      filter: $filter"; echo "      json (200 chars): ${json:0:200}"; fi
}
assert_empty() {
  local desc="$1" actual="$2"
  if [ -z "$actual" ]; then ok "$desc (empty)"
  else bad "$desc"; echo "      expected empty, got: |${actual:0:200}|"; fi
}

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }
[ -f "$LEAF" ] || { echo "FATAL: chp-gitlab.sh missing at $LEAF"; exit 2; }
[ -f "$CAPS" ] || { echo "FATAL: chp-gitlab.caps missing at $CAPS"; exit 2; }

# ============================================================================
# Test-local `_gl_api` stub — models the FROZEN #416 signature.
#
# Configuration (env vars, all optional):
#   _GL_API_PAYLOAD          single canned payload file (default mode)
#   _GL_API_PAYLOAD_SEQ      colon-separated list of payload files served
#                            in invocation order (last one cycled on overflow)
#   _GL_API_FAIL_AT          N — force this invocation (1-indexed) to fail rc≠0
#   _GL_API_STATUS           set GL_API_STATUS to this value on every return
#   _GL_API_CALL_LOG         file — every invocation appends one line
#                            "<argv joined by |>"; the test asserts against it.
#   _GL_API_INV_STATE        file — invocation-count state (auto-managed)
# ============================================================================
_reset_stub() {
  export _GL_API_PAYLOAD=""
  export _GL_API_PAYLOAD_SEQ=""
  export _GL_API_FAIL_AT=""
  export _GL_API_STATUS="200"
  export _GL_API_CALL_LOG="$RUNDIR/call.log"
  export _GL_API_INV_STATE="$RUNDIR/inv.state"
  : > "$_GL_API_CALL_LOG"
  : > "$_GL_API_INV_STATE"
}

_gl_api() {
  # Record every argv line as a pipe-joined single line.
  local IFS='|'; printf '%s\n' "$*" >> "$_GL_API_CALL_LOG"; IFS=' '
  local inv
  inv=$(<"$_GL_API_INV_STATE")
  inv=$((inv + 1))
  printf '%s' "$inv" > "$_GL_API_INV_STATE"
  # Simulate the transport-status channel.
  GL_API_STATUS="$_GL_API_STATUS"
  # Forced-failure hook.
  if [ -n "$_GL_API_FAIL_AT" ] && [ "$_GL_API_FAIL_AT" = "$inv" ]; then
    return 1
  fi
  # Choose the payload for this invocation.
  local payload="$_GL_API_PAYLOAD"
  if [ -z "$payload" ] && [ -n "$_GL_API_PAYLOAD_SEQ" ]; then
    local IFS_SAVE=$IFS; IFS=':'
    # shellcheck disable=SC2206
    local -a seq=($_GL_API_PAYLOAD_SEQ)
    IFS="$IFS_SAVE"
    local idx=$(( inv - 1 ))
    (( idx >= ${#seq[@]} )) && idx=$(( ${#seq[@]} - 1 ))
    payload="${seq[$idx]}"
  fi
  [ -n "$payload" ] && [ -f "$payload" ] || { printf ''; return 0; }
  cat "$payload"
}

# `_gl_urlencode <string>` is not called by any read leaf in P3-3 (leaves use
# the pre-encoded ${GITLAB_PROJECT}), but stub it anyway so a future refactor
# does not have to touch this file.
_gl_urlencode() { jq -rn --arg s "$1" '$s | @uri'; }

# Export the stubs so a subshell (if any) sees them.
export -f _gl_api _gl_urlencode

RUNDIR=$(mktemp -d)
trap 'rm -rf "$RUNDIR"' EXIT

# Config env vars the leaves read.
export GITLAB_PROJECT="myGroup%2FmyProject"
export GITLAB_HOST="gitlab.example.test"
export GITLAB_TOKEN="not-a-real-token"

# Source the leaf under test.
# shellcheck source=../../skills/autonomous-dispatcher/scripts/providers/chp-gitlab.sh
source "$LEAF"

# Convenience: build an MR-view JSON with a specific field value.
_mr_json() {
  # $1 = jq patch expression, $2 = optional base (default: pr-view fixture)
  local patch="$1" base="${2:-$PAYLOADS/gitlab-chp-pr-view.json}"
  jq -c "$patch" < "$base"
}
_write_json() {
  local path="$1"; shift
  printf '%s' "$1" > "$path"
  printf '%s' "$path"
}

# ============================================================================
# R2 — chp_gitlab_ci_status bucket table
# ============================================================================
echo "=== R2: chp_gitlab_ci_status bucket table ==="

# TC-P33-001 — null head_pipeline → none
_reset_stub
export _GL_API_PAYLOAD; _GL_API_PAYLOAD="$(_write_json "$RUNDIR/mr-null.json" "$(_mr_json '.head_pipeline = null')")"
out=$(chp_gitlab_ci_status 42); rc=$?
assert_eq "TC-P33-001 head_pipeline=null → none" "none" "$out"
assert_eq "TC-P33-001 rc=0" "0" "$rc"

# Each bucket row uses the same fixture with .head_pipeline.status rewritten.
_bucket() {
  local id="$1" status="$2" expected="$3"
  _reset_stub
  export _GL_API_PAYLOAD; _GL_API_PAYLOAD="$(_write_json "$RUNDIR/mr-${status}.json" "$(_mr_json ".head_pipeline.status = \"$status\"")")"
  local out rc
  out=$(chp_gitlab_ci_status 42); rc=$?
  assert_eq "$id head_pipeline.status=$status → $expected" "$expected" "$out"
  assert_eq "$id rc=0" "0" "$rc"
}
_bucket "TC-P33-002" "success"              "green"
_bucket "TC-P33-003" "failed"               "failed"
_bucket "TC-P33-004" "canceled"             "failed"
_bucket "TC-P33-005" "skipped"              "pending"
_bucket "TC-P33-006" "manual"               "pending"
_bucket "TC-P33-007" "created"              "pending"
_bucket "TC-P33-008" "waiting_for_resource" "pending"
_bucket "TC-P33-009" "preparing"            "pending"
_bucket "TC-P33-010" "pending"              "pending"
_bucket "TC-P33-011" "running"              "pending"
_bucket "TC-P33-012" "scheduled"            "pending"
_bucket "TC-P33-013" "quantum_pending"      "pending"   # unknown-future token

# TC-P33-014 — _gl_api rc≠0 → leaf rc≠0
_reset_stub
_GL_API_FAIL_AT=1
out=$(chp_gitlab_ci_status 42 2>/dev/null); rc=$?
assert_rc_nz "TC-P33-014 _gl_api rc≠0 → leaf rc≠0" "$rc"
assert_empty "TC-P33-014 no partial stdout" "$out"

# TC-P33-015 — rc-0 payload missing head_pipeline key → rc≠0
_reset_stub
export _GL_API_PAYLOAD; _GL_API_PAYLOAD="$(_write_json "$RUNDIR/mr-nohp.json" '{"iid":42,"state":"opened"}')"
out=$(chp_gitlab_ci_status 42 2>/dev/null); rc=$?
assert_rc_nz "TC-P33-015 missing head_pipeline key → leaf rc≠0" "$rc"
assert_empty "TC-P33-015 no partial stdout" "$out"

# TC-P33-016 — rc-0 non-object payload (array) → rc≠0
_reset_stub
export _GL_API_PAYLOAD; _GL_API_PAYLOAD="$(_write_json "$RUNDIR/mr-arr.json" '[1,2,3]')"
out=$(chp_gitlab_ci_status 42 2>/dev/null); rc=$?
assert_rc_nz "TC-P33-016 non-object payload → leaf rc≠0" "$rc"
assert_empty "TC-P33-016 no partial stdout" "$out"

# ============================================================================
# R3 — chp_gitlab_mergeable bucket table
# ============================================================================
echo "=== R3: chp_gitlab_mergeable bucket table ==="

_mergeable_case() {
  local id="$1" dms="$2" expected="$3"
  _reset_stub
  export _GL_API_PAYLOAD; _GL_API_PAYLOAD="$(_write_json "$RUNDIR/mr-dms-${dms}.json" "$(_mr_json ".detailed_merge_status = \"$dms\"")")"
  local out rc
  out=$(chp_gitlab_mergeable 42); rc=$?
  assert_eq "$id dms=$dms → $expected" "$expected" "$out"
  assert_eq "$id rc=0" "0" "$rc"
}
_mergeable_case "TC-P33-020" "mergeable"                          "MERGEABLE"
_mergeable_case "TC-P33-021" "conflict"                           "CONFLICTING"
_mergeable_case "TC-P33-022" "need_rebase"                        "CONFLICTING"
_mergeable_case "TC-P33-023" "commits_status"                     "CONFLICTING"
_mergeable_case "TC-P33-024" "broken_status"                      "CONFLICTING"
_mergeable_case "TC-P33-025" "checking"                           "UNKNOWN"
_mergeable_case "TC-P33-026" "unchecked"                          "UNKNOWN"
_mergeable_case "TC-P33-027" "preparing"                          "UNKNOWN"
_mergeable_case "TC-P33-028" "approvals_syncing"                  "UNKNOWN"
_mergeable_case "TC-P33-029" "not_open"                           "UNKNOWN"
_mergeable_case "TC-P33-030" "ci_must_pass"                       "UNKNOWN"
_mergeable_case "TC-P33-031" "ci_still_running"                   "UNKNOWN"
_mergeable_case "TC-P33-032" "not_approved"                       "UNKNOWN"
_mergeable_case "TC-P33-033" "requested_changes"                  "UNKNOWN"
_mergeable_case "TC-P33-034" "merge_request_blocked"              "UNKNOWN"
_mergeable_case "TC-P33-035" "discussions_not_resolved"           "UNKNOWN"
_mergeable_case "TC-P33-036" "draft_status"                       "UNKNOWN"
_mergeable_case "TC-P33-037" "status_checks_must_pass"            "UNKNOWN"
_mergeable_case "TC-P33-038" "jira_association_missing"           "UNKNOWN"
_mergeable_case "TC-P33-039" "merge_time"                         "UNKNOWN"
_mergeable_case "TC-P33-040" "security_policy_violations"         "UNKNOWN"
_mergeable_case "TC-P33-041" "security_policy_pipeline_check"     "UNKNOWN"
_mergeable_case "TC-P33-042" "locked_paths"                       "UNKNOWN"
_mergeable_case "TC-P33-043" "locked_lfs_files"                   "UNKNOWN"
_mergeable_case "TC-P33-044" "title_regex"                        "UNKNOWN"
_mergeable_case "TC-P33-045" "some_future_token"                  "UNKNOWN"

# TC-P33-046 — _gl_api rc≠0 → leaf rc≠0
_reset_stub
_GL_API_FAIL_AT=1
out=$(chp_gitlab_mergeable 42 2>/dev/null); rc=$?
assert_rc_nz "TC-P33-046 _gl_api rc≠0 → leaf rc≠0" "$rc"
assert_empty "TC-P33-046 no partial stdout" "$out"

# ============================================================================
# R4 — chp_gitlab_pr_view
# ============================================================================
echo "=== R4: chp_gitlab_pr_view ==="

# TC-P33-050 — full vocabulary read.
_reset_stub
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-pr-view.json:$PAYLOADS/gitlab-chp-pr-view-closes.json:$PAYLOADS/gitlab-chp-pr-view-notes.json:$PAYLOADS/gitlab-chp-pr-view-approvals.json"
out=$(chp_gitlab_pr_view 42 "number,state,title,body,createdAt,updatedAt,mergedAt,headRefName,headRefOid,reviewDecision,mergeable,closingIssueNumbers,comments,reviews"); rc=$?
assert_eq "TC-P33-050 rc=0" "0" "$rc"
assert_jq_true "TC-P33-050 exact 14 keys" '((keys | sort) == ["body","closingIssueNumbers","comments","createdAt","headRefName","headRefOid","mergeable","mergedAt","number","reviewDecision","reviews","state","title","updatedAt"])' "$out"
assert_jq_true "TC-P33-050 number=42" '.number == 42' "$out"
assert_jq_true "TC-P33-050 state=OPEN" '.state == "OPEN"' "$out"
assert_jq_true "TC-P33-050 body=Merge request body text" '.body == "Merge request body text"' "$out"
assert_jq_true "TC-P33-050 reviewDecision=\"\"" '.reviewDecision == ""' "$out"
assert_jq_true "TC-P33-050 mergeable=MERGEABLE" '.mergeable == "MERGEABLE"' "$out"
assert_jq_true "TC-P33-050 closingIssueNumbers=[7]" '.closingIssueNumbers == [7]' "$out"
assert_jq_true "TC-P33-050 reviews synthesized (2 APPROVED)" '(.reviews | length == 2) and all(.reviews[]; .state == "APPROVED")' "$out"
assert_jq_true "TC-P33-050 reviews submittedAt = /approvals top-level approved_at" 'all(.reviews[]; .submittedAt == "2026-01-03T09:00:00Z")' "$out"

# TC-P33-051..055 — state mapping matrix.
_state_case() {
  local id="$1" gl_state="$2" normalized="$3"
  _reset_stub
  export _GL_API_PAYLOAD; _GL_API_PAYLOAD="$(_write_json "$RUNDIR/mr-state-${gl_state}.json" "$(_mr_json ".state = \"$gl_state\"")")"
  local out
  out=$(chp_gitlab_pr_view 42 "state")
  assert_jq_true "$id state=$gl_state → $normalized" ".state == \"$normalized\"" "$out"
}
_state_case "TC-P33-053" "opened"  "OPEN"
_state_case "TC-P33-054" "closed"  "CLOSED"
_state_case "TC-P33-052" "merged"  "MERGED"
_state_case "TC-P33-051" "locked"  "CLOSED"
_state_case "TC-P33-055" "quantum" ""

# TC-P33-056 — body null → ""
_reset_stub
export _GL_API_PAYLOAD; _GL_API_PAYLOAD="$(_write_json "$RUNDIR/mr-null-desc.json" "$(_mr_json '.description = null')")"
out=$(chp_gitlab_pr_view 42 "body")
assert_jq_true "TC-P33-056 body null → \"\"" '.body == ""' "$out"

# TC-P33-057 — reviewDecision unconditional ""
_reset_stub
export _GL_API_PAYLOAD; _GL_API_PAYLOAD="$PAYLOADS/gitlab-chp-pr-view.json"
out=$(chp_gitlab_pr_view 42 "reviewDecision")
assert_jq_true "TC-P33-057 reviewDecision=\"\"" '.reviewDecision == ""' "$out"

# TC-P33-058 — closingIssueNumbers empty from empty /closes_issues
_reset_stub
empty_closes="$RUNDIR/closes-empty.json"; printf '[]' > "$empty_closes"
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-pr-view.json:$empty_closes"
out=$(chp_gitlab_pr_view 42 "closingIssueNumbers")
assert_jq_true "TC-P33-058 empty /closes_issues → []" '.closingIssueNumbers == []' "$out"

# TC-P33-059 — fetch-cost gate: single-field `number` does NOT trigger /closes_issues
_reset_stub
export _GL_API_PAYLOAD="$PAYLOADS/gitlab-chp-pr-view.json"
out=$(chp_gitlab_pr_view 42 "number")
call_count=$(wc -l < "$_GL_API_CALL_LOG" | tr -d ' ')
assert_eq "TC-P33-059 fetch-cost gate number-only: 1 _gl_api call (base MR only)" "1" "$call_count"

# TC-P33-060 — fetch-cost gate: comments not requested → no /notes fetch
_reset_stub
export _GL_API_PAYLOAD="$PAYLOADS/gitlab-chp-pr-view.json"
out=$(chp_gitlab_pr_view 42 "number,state,title")
if grep -q '/notes' "$_GL_API_CALL_LOG"; then
  bad "TC-P33-060 /notes fetched despite comments not requested"
else
  ok "TC-P33-060 fetch-cost gate: no /notes call when comments not requested"
fi

# TC-P33-061 — fetch-cost gate: reviews not requested → no /approvals fetch
_reset_stub
export _GL_API_PAYLOAD="$PAYLOADS/gitlab-chp-pr-view.json"
out=$(chp_gitlab_pr_view 42 "number")
if grep -q '/approvals' "$_GL_API_CALL_LOG"; then
  bad "TC-P33-061 /approvals fetched despite reviews not requested"
else
  ok "TC-P33-061 fetch-cost gate: no /approvals call when reviews not requested"
fi

# TC-P33-062 — comments system-note filter
_reset_stub
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-pr-view.json:$PAYLOADS/gitlab-chp-pr-view-notes.json"
out=$(chp_gitlab_pr_view 42 "comments")
assert_jq_true "TC-P33-062 comments filters .system==true" '(.comments | length) == 2 and all(.comments[]; .body != "assigned to @alice")' "$out"

# TC-P33-063 — comments normalized shape + ascending
assert_jq_true "TC-P33-063 comments element keys={id,author,body,createdAt}" 'all(.comments[]; (keys | sort) == ["author","body","createdAt","id"])' "$out"
assert_jq_true "TC-P33-063 comments ascending by createdAt" '[.comments[].createdAt] as $t | ($t == ($t | sort))' "$out"
assert_jq_true "TC-P33-063 comments.author=username (alice/bob)" '.comments[0].author == "alice" and .comments[1].author == "bob"' "$out"

# TC-P33-064 — reviews element shape
_reset_stub
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-pr-view.json:$PAYLOADS/gitlab-chp-pr-view-approvals.json"
out=$(chp_gitlab_pr_view 42 "reviews")
assert_jq_true "TC-P33-064 reviews element keys={author,state,submittedAt}" 'all(.reviews[]; (keys | sort) == ["author","state","submittedAt"])' "$out"

# TC-P33-065 — /closes_issues rc≠0 on REQUESTED closingIssueNumbers → leaf rc≠0
_reset_stub
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-pr-view.json:$PAYLOADS/gitlab-chp-pr-view-closes.json"
_GL_API_FAIL_AT=2
out=$(chp_gitlab_pr_view 42 "closingIssueNumbers" 2>/dev/null); rc=$?
assert_rc_nz "TC-P33-065 /closes_issues rc≠0 on requested closingIssueNumbers → leaf rc≠0" "$rc"
assert_empty "TC-P33-065 no partial stdout" "$out"

# TC-P33-066 — /notes rc≠0 on REQUESTED comments → leaf rc≠0
_reset_stub
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-pr-view.json:$PAYLOADS/gitlab-chp-pr-view-notes.json"
_GL_API_FAIL_AT=2
out=$(chp_gitlab_pr_view 42 "comments" 2>/dev/null); rc=$?
assert_rc_nz "TC-P33-066 /notes rc≠0 on requested comments → leaf rc≠0" "$rc"
assert_empty "TC-P33-066 no partial stdout" "$out"

# TC-P33-067 — /approvals rc≠0 on REQUESTED reviews → leaf rc≠0
_reset_stub
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-pr-view.json:$PAYLOADS/gitlab-chp-pr-view-approvals.json"
_GL_API_FAIL_AT=2
out=$(chp_gitlab_pr_view 42 "reviews" 2>/dev/null); rc=$?
assert_rc_nz "TC-P33-067 /approvals rc≠0 on requested reviews → leaf rc≠0" "$rc"
assert_empty "TC-P33-067 no partial stdout" "$out"

# TC-P33-068..072 — vocabulary rejection (rc 2, ZERO _gl_api calls)
_vocab_reject() {
  local id="$1" fld="$2"
  _reset_stub
  local out rc
  out=$(chp_gitlab_pr_view 42 "$fld" 2>/dev/null); rc=$?
  assert_rc_2 "$id vocabulary rejection: '$fld' → rc 2" "$rc"
  local calls; calls=$(wc -l < "$_GL_API_CALL_LOG" | tr -d ' ')
  assert_eq "$id ZERO _gl_api calls on rejection" "0" "$calls"
}
_vocab_reject "TC-P33-068" "iid"
_vocab_reject "TC-P33-069" "description"
_vocab_reject "TC-P33-070" "notes"
_vocab_reject "TC-P33-071" "source_branch"
_vocab_reject "TC-P33-072" "bogus_field"

# TC-P33-073 — missing FIELDS-CSV → rc 2, no _gl_api call
_reset_stub
out=$(chp_gitlab_pr_view 42 2>/dev/null); rc=$?
assert_rc_2 "TC-P33-073 missing FIELDS-CSV → rc 2" "$rc"
calls=$(wc -l < "$_GL_API_CALL_LOG" | tr -d ' ')
assert_eq "TC-P33-073 ZERO _gl_api calls on missing FIELDS-CSV" "0" "$calls"

# TC-P33-074 — MR fetch rc≠0 → leaf rc≠0 no partial stdout
_reset_stub
_GL_API_FAIL_AT=1
out=$(chp_gitlab_pr_view 42 "number" 2>/dev/null); rc=$?
assert_rc_nz "TC-P33-074 MR fetch rc≠0 → leaf rc≠0" "$rc"
assert_empty "TC-P33-074 no partial stdout" "$out"

# TC-P33-075 — MR fetch rc 0 empty stdout → leaf rc≠0
_reset_stub
empty_pl="$RUNDIR/empty.json"; : > "$empty_pl"
export _GL_API_PAYLOAD="$empty_pl"
out=$(chp_gitlab_pr_view 42 "number" 2>/dev/null); rc=$?
assert_rc_nz "TC-P33-075 rc-0 empty MR-view stdout → leaf rc≠0" "$rc"
assert_empty "TC-P33-075 no partial stdout" "$out"

# TC-P33-076 — MR fetch rc 0 non-object payload → leaf rc≠0
_reset_stub
export _GL_API_PAYLOAD; _GL_API_PAYLOAD="$(_write_json "$RUNDIR/mr-arr.json" '[1,2,3]')"
out=$(chp_gitlab_pr_view 42 "number" 2>/dev/null); rc=$?
assert_rc_nz "TC-P33-076 non-object MR-view payload → leaf rc≠0" "$rc"
assert_empty "TC-P33-076 no partial stdout" "$out"

# ============================================================================
# R5 — chp_gitlab_pr_list
# ============================================================================
echo "=== R5: chp_gitlab_pr_list ==="

# TC-P33-080 — state=open → opened, 2 opened MRs
_reset_stub
export _GL_API_PAYLOAD="$PAYLOADS/gitlab-chp-pr-list-p1.json"
out=$(chp_gitlab_pr_list open "number,state")
assert_jq_true "TC-P33-080 state=open → 2 opened MRs" 'length == 2 and all(.[]; .state == "OPEN")' "$out"

# TC-P33-081 — state=closed excludes merged (leaf post-filter)
_reset_stub
# Fixture with 2 closed + 1 merged; leaf post-filter drops the merged.
mixed="$RUNDIR/mixed-closed.json"
printf '%s' '[
  {"iid":1,"state":"closed","description":"a"},
  {"iid":2,"state":"closed","description":"b"},
  {"iid":3,"state":"merged","description":"c"}
]' > "$mixed"
export _GL_API_PAYLOAD="$mixed"
out=$(chp_gitlab_pr_list closed "number,state")
assert_jq_true "TC-P33-081 state=closed excludes merged (2 closed)" 'length == 2 and all(.[]; .state == "CLOSED")' "$out"

# TC-P33-082 — state=merged
_reset_stub
merged="$RUNDIR/merged.json"
printf '%s' '[
  {"iid":11,"state":"merged","description":"m1"},
  {"iid":12,"state":"merged","description":"m2"}
]' > "$merged"
export _GL_API_PAYLOAD="$merged"
out=$(chp_gitlab_pr_list merged "number,state")
assert_jq_true "TC-P33-082 state=merged → 2 MERGED" 'length == 2 and all(.[]; .state == "MERGED")' "$out"

# TC-P33-083 — state=all → no post-filter narrows; length includes all shapes
_reset_stub
allpl="$RUNDIR/all.json"
printf '%s' '[
  {"iid":21,"state":"opened","description":"o"},
  {"iid":22,"state":"closed","description":"c"},
  {"iid":23,"state":"merged","description":"m"},
  {"iid":24,"state":"locked","description":"l"}
]' > "$allpl"
export _GL_API_PAYLOAD="$allpl"
out=$(chp_gitlab_pr_list all "number,state")
assert_jq_true "TC-P33-083 state=all → length 4 (opened+closed+merged+locked)" 'length == 4' "$out"

# TC-P33-084 — invalid STATE → rc 2, no _gl_api call
_reset_stub
out=$(chp_gitlab_pr_list foo "number" 2>/dev/null); rc=$?
assert_rc_2 "TC-P33-084 invalid STATE=foo → rc 2" "$rc"
calls=$(wc -l < "$_GL_API_CALL_LOG" | tr -d ' ')
assert_eq "TC-P33-084 zero _gl_api calls on invalid STATE" "0" "$calls"

# TC-P33-085 — missing STATE → rc 2
_reset_stub
out=$(chp_gitlab_pr_list 2>/dev/null); rc=$?
assert_rc_2 "TC-P33-085 missing STATE → rc 2" "$rc"

# TC-P33-086 — missing FIELDS-CSV → rc 2
_reset_stub
out=$(chp_gitlab_pr_list open 2>/dev/null); rc=$?
assert_rc_2 "TC-P33-086 missing FIELDS-CSV → rc 2" "$rc"

# TC-P33-087 — reject `comments` in FIELDS-CSV (rc 2 loud, no _gl_api call)
_reset_stub
out=$(chp_gitlab_pr_list open "number,comments" 2>/dev/null); rc=$?
assert_rc_2 "TC-P33-087 pr_list REJECTS 'comments' field → rc 2" "$rc"
calls=$(wc -l < "$_GL_API_CALL_LOG" | tr -d ' ')
assert_eq "TC-P33-087 zero _gl_api calls on comments-rejection" "0" "$calls"

# TC-P33-088 — reviews supported (per-MR /approvals synthesized)
_reset_stub
# 1 base MR list call + N per-MR /approvals calls (N=2 opened MRs).
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-pr-list-p1.json:$PAYLOADS/gitlab-chp-pr-view-approvals.json:$PAYLOADS/gitlab-chp-pr-view-approvals.json"
out=$(chp_gitlab_pr_list open "number,reviews"); rc=$?
assert_eq "TC-P33-088 pr_list reviews rc=0" "0" "$rc"
assert_jq_true "TC-P33-088 pr_list reviews element shape" 'all(.[]; (.reviews | type == "array") and all(.reviews[]; .state == "APPROVED"))' "$out"

# TC-P33-089 — 2-page walk simulated by stub (each _gl_api --paginate call would
# be a single call in the real transport, so we simulate a merged page — the
# concatenated array in one payload).
_reset_stub
concat="$RUNDIR/pr-list-concat.json"
jq -s -c 'add' "$PAYLOADS/gitlab-chp-pr-list-p1.json" "$PAYLOADS/gitlab-chp-pr-list-p2.json" > "$concat"
export _GL_API_PAYLOAD="$concat"
out=$(chp_gitlab_pr_list open "number,body"); rc=$?
assert_eq "TC-P33-089 2-page walk rc=0" "0" "$rc"
assert_jq_true "TC-P33-089 merged length == 4 (p1 + p2)" 'length == 4' "$out"

# TC-P33-090 — mid-walk failure → leaf rc≠0 EMPTY stdout
_reset_stub
_GL_API_FAIL_AT=1
out=$(chp_gitlab_pr_list open "number,body" 2>/dev/null); rc=$?
assert_rc_nz "TC-P33-090 mid-walk _gl_api rc≠0 → leaf rc≠0" "$rc"
assert_empty "TC-P33-090 no partial stdout" "$out"

# TC-P33-091 — page-cap (documented deferral):
# CHP_GITLAB_PR_LIST_PAGE_CAP is forwarded to `_gl_api --max-items` as a
# transport-side bound. The frozen #416 contract makes the transport itself
# fail-CLOSED on cap-hit with rc≠0 empty stdout — the leaf just passes rc≠0
# through. Our test-local stub does not model the transport's page-cap, so we
# simulate it by making the stub fail rc≠0 (which is what the transport
# would emit on a cap-hit).
_reset_stub
_GL_API_FAIL_AT=1
CHP_GITLAB_PR_LIST_PAGE_CAP=2 out=$(chp_gitlab_pr_list open "number,body" 2>/dev/null); rc=$?
assert_rc_nz "TC-P33-091 page-cap-hit (simulated as transport rc≠0) → leaf rc≠0" "$rc"
assert_empty "TC-P33-091 no partial stdout" "$out"

# TC-P33-092 — empty match → []
_reset_stub
empty="$RUNDIR/list-empty.json"; printf '[]' > "$empty"
export _GL_API_PAYLOAD="$empty"
out=$(chp_gitlab_pr_list open "number,body"); rc=$?
assert_eq "TC-P33-092 empty match rc=0" "0" "$rc"
assert_eq "TC-P33-092 empty match → []" "[]" "$out"

# TC-P33-093 — projection-only: fields=body,number → only those keys
_reset_stub
export _GL_API_PAYLOAD="$PAYLOADS/gitlab-chp-pr-list-p1.json"
out=$(chp_gitlab_pr_list open "body,number")
assert_jq_true "TC-P33-093 projection-only: no unrequested fields" 'all(.[]; (keys | sort) == ["body","number"])' "$out"

# TC-P33-094 — body null → "" across every element
assert_jq_true "TC-P33-094 body null → \"\" across every element" 'all(.[]; (.body | type == "string"))' "$out"
assert_jq_true "TC-P33-094 fixture has one null body normalized" 'any(.[]; .body == "" and .number == 8)' "$out"

# ============================================================================
# R6 — chp_gitlab_find_pr_for_issue
# ============================================================================
echo "=== R6: chp_gitlab_find_pr_for_issue ==="

# TC-P33-100 — narrowing via /closed_by + per-MR /closes_issues.
_reset_stub
# Only 2 candidates in /closed_by; one (MR#8) is merged and post-filtered
# out — so we expect ONE surviving candidate + ONE /closes_issues follow-up.
opened_only="$RUNDIR/closed-by-opened.json"
printf '%s' '[
  {"iid":7,"state":"opened","description":"Closes #42","source_branch":"feat/x","sha":"aa"}
]' > "$opened_only"
export _GL_API_PAYLOAD_SEQ="$opened_only:$PAYLOADS/gitlab-chp-find-pr-closes-mr7.json"
out=$(chp_gitlab_find_pr_for_issue 42 "body")
assert_jq_true "TC-P33-100 narrowing: 1 opened MR with closingIssueNumbers=[42]" 'length == 1 and .[0].number == 7 and .[0].closingIssueNumbers == [42]' "$out"

# TC-P33-101 — state post-filter drops merged MRs
_reset_stub
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-find-pr-closed-by.json:$PAYLOADS/gitlab-chp-find-pr-closes-mr7.json"
out=$(chp_gitlab_find_pr_for_issue 42 "body")
assert_jq_true "TC-P33-101 state post-filter: only opened survives" 'length == 1 and .[0].number == 7' "$out"

# TC-P33-102 — empty candidate set → []
_reset_stub
empty="$RUNDIR/empty-cb.json"; printf '[]' > "$empty"
export _GL_API_PAYLOAD="$empty"
out=$(chp_gitlab_find_pr_for_issue 42 "body")
assert_eq "TC-P33-102 empty candidate set → []" "[]" "$out"

# TC-P33-103 — reject `comments` in FIELDS-CSV
_reset_stub
out=$(chp_gitlab_find_pr_for_issue 42 "body,comments" 2>/dev/null); rc=$?
assert_rc_2 "TC-P33-103 find_pr_for_issue REJECTS 'comments' field" "$rc"
calls=$(wc -l < "$_GL_API_CALL_LOG" | tr -d ' ')
assert_eq "TC-P33-103 zero _gl_api calls on comments-rejection" "0" "$calls"

# TC-P33-104 — FIELDS-CSV ∪ resolution keys projection
_reset_stub
export _GL_API_PAYLOAD_SEQ="$opened_only:$PAYLOADS/gitlab-chp-find-pr-closes-mr7.json"
out=$(chp_gitlab_find_pr_for_issue 42 "body")
assert_jq_true "TC-P33-104 projection ∪ {number, closingIssueNumbers, headRefName}" 'all(.[]; has("body") and has("number") and has("closingIssueNumbers") and has("headRefName"))' "$out"

# TC-P33-105 — body null across each element normalizes to ""
_reset_stub
opened_null_body="$RUNDIR/opened-null-body.json"
printf '%s' '[
  {"iid":7,"state":"opened","description":null,"source_branch":"feat/x"}
]' > "$opened_null_body"
export _GL_API_PAYLOAD_SEQ="$opened_null_body:$PAYLOADS/gitlab-chp-find-pr-closes-mr7.json"
out=$(chp_gitlab_find_pr_for_issue 42 "body")
assert_jq_true "TC-P33-105 body null → \"\"" '.[0].body == ""' "$out"

# TC-P33-106 — /closed_by rc≠0 → leaf rc≠0
_reset_stub
_GL_API_FAIL_AT=1
out=$(chp_gitlab_find_pr_for_issue 42 "body" 2>/dev/null); rc=$?
assert_rc_nz "TC-P33-106 /closed_by rc≠0 → leaf rc≠0" "$rc"
assert_empty "TC-P33-106 no partial stdout" "$out"

# TC-P33-107 — per-MR /closes_issues mid-walk rc≠0 → leaf rc≠0
_reset_stub
export _GL_API_PAYLOAD_SEQ="$opened_only:$PAYLOADS/gitlab-chp-find-pr-closes-mr7.json"
_GL_API_FAIL_AT=2
out=$(chp_gitlab_find_pr_for_issue 42 "body" 2>/dev/null); rc=$?
assert_rc_nz "TC-P33-107 per-MR /closes_issues rc≠0 → leaf rc≠0" "$rc"
assert_empty "TC-P33-107 no partial stdout" "$out"

# ============================================================================
# R7 — chp_gitlab_list_inline_comments
# ============================================================================
echo "=== R7: chp_gitlab_list_inline_comments ==="

# TC-P33-120 — mixed inline/non-inline/system, only inline survive
_reset_stub
export _GL_API_PAYLOAD="$PAYLOADS/gitlab-chp-inline-comments-p1.json"
out=$(chp_gitlab_list_inline_comments 42)
assert_jq_true "TC-P33-120 exactly 1 inline note (non-inline + system filtered)" 'length == 1 and .[0].id == 6000001' "$out"

# TC-P33-121 — .line = new_line
assert_jq_true "TC-P33-121 line = new_line=5" '.[0].line == 5' "$out"

# TC-P33-122/123 — page 2: new_line null → old_line fold; new_path null → old_path fold
_reset_stub
export _GL_API_PAYLOAD="$PAYLOADS/gitlab-chp-inline-comments-p2.json"
out=$(chp_gitlab_list_inline_comments 42)
assert_jq_true "TC-P33-122 line = old_line=7 when new_line null" 'any(.[]; .id == 6000010 and .line == 7)' "$out"
assert_jq_true "TC-P33-123 path = old_path when new_path null" 'any(.[]; .id == 6000010 and .path == "src/legacy.py")' "$out"

# TC-P33-124 — both position fields null → line null
assert_jq_true "TC-P33-124 both null → line null" 'any(.[]; .id == 6000011 and .line == null)' "$out"

# TC-P33-125 — body null → ""
_reset_stub
null_body_disc="$RUNDIR/disc-null-body.json"
printf '%s' '[{"id":"d1","notes":[{"id":1,"body":null,"author":{"username":"a"},"created_at":"2026-01-01T00:00:00Z","system":false,"resolvable":true,"resolved":false,"position":{"new_path":"x","new_line":1}}]}]' > "$null_body_disc"
export _GL_API_PAYLOAD="$null_body_disc"
out=$(chp_gitlab_list_inline_comments 42)
assert_jq_true "TC-P33-125 body null → \"\"" 'all(.[]; .body == "")' "$out"

# TC-P33-126 — ascending by createdAt (id tie-break)
_reset_stub
seq_test="$RUNDIR/inline-sort.json"
printf '%s' '[
  {"id":"d","notes":[
    {"id":3,"body":"c","author":{"username":"a"},"created_at":"2026-01-01T03:00:00Z","system":false,"position":{"new_path":"x","new_line":1}},
    {"id":1,"body":"a","author":{"username":"a"},"created_at":"2026-01-01T01:00:00Z","system":false,"position":{"new_path":"x","new_line":1}},
    {"id":2,"body":"b","author":{"username":"a"},"created_at":"2026-01-01T02:00:00Z","system":false,"position":{"new_path":"x","new_line":1}}
  ]}
]' > "$seq_test"
export _GL_API_PAYLOAD="$seq_test"
out=$(chp_gitlab_list_inline_comments 42)
assert_jq_true "TC-P33-126 ascending by createdAt" '[.[].createdAt] as $t | $t == ($t | sort)' "$out"

# TC-P33-127 — multi-page merge (concat as single payload the stub returns —
# `_gl_api --paginate` in the real transport merges pages internally).
_reset_stub
merged="$RUNDIR/inline-merged.json"
jq -s -c 'add' "$PAYLOADS/gitlab-chp-inline-comments-p1.json" "$PAYLOADS/gitlab-chp-inline-comments-p2.json" > "$merged"
export _GL_API_PAYLOAD="$merged"
out=$(chp_gitlab_list_inline_comments 42)
assert_jq_true "TC-P33-127 multi-page merged: 3 inline notes (p1=1 + p2=2)" 'length == 3' "$out"

# TC-P33-128 — mid-walk failure
_reset_stub
_GL_API_FAIL_AT=1
out=$(chp_gitlab_list_inline_comments 42 2>/dev/null); rc=$?
assert_rc_nz "TC-P33-128 mid-walk _gl_api rc≠0 → leaf rc≠0" "$rc"
assert_empty "TC-P33-128 no partial stdout" "$out"

# TC-P33-129 — empty
_reset_stub
empty="$RUNDIR/inline-empty.json"; printf '[]' > "$empty"
export _GL_API_PAYLOAD="$empty"
out=$(chp_gitlab_list_inline_comments 42)
assert_eq "TC-P33-129 empty discussions → []" "[]" "$out"

# ============================================================================
# R8 — chp_gitlab_review_threads
# ============================================================================
echo "=== R8: chp_gitlab_review_threads ==="

# TC-P33-140 — compound thread_id "<mr-iid>:<discussion.id>"
_reset_stub
export _GL_API_PAYLOAD="$PAYLOADS/gitlab-chp-review-threads-p1.json"
out=$(chp_gitlab_review_threads 42)
assert_jq_true "TC-P33-140 thread_id encodes 42:disc-abc" 'any(.[]; .thread_id == "42:disc-abc")' "$out"

# TC-P33-141 — resolvable-only filter (3 in fixture → 2 in output)
assert_jq_true "TC-P33-141 resolvable-only filter: 2 threads" 'length == 2' "$out"
assert_jq_true "TC-P33-141 non-resolvable general excluded" 'all(.[]; .thread_id != "42:disc-general")' "$out"

# TC-P33-142 — resolved=true derived from first note resolved
assert_jq_true "TC-P33-142 disc-def resolved=true" 'any(.[]; .thread_id == "42:disc-def" and .resolved == true)' "$out"
# TC-P33-143 — resolved=false
assert_jq_true "TC-P33-143 disc-abc resolved=false" 'any(.[]; .thread_id == "42:disc-abc" and .resolved == false)' "$out"

# TC-P33-144 — comments element shape (R7 mapping applies)
assert_jq_true "TC-P33-144 comments element keys" 'all(.[]; all(.comments[]; (keys | sort) == ["author","body","createdAt","id","line","path"]))' "$out"

# TC-P33-145 — multi-page walk (concat)
_reset_stub
merged="$RUNDIR/threads-merged.json"
jq -s -c 'add' "$PAYLOADS/gitlab-chp-review-threads-p1.json" "$PAYLOADS/gitlab-chp-review-threads-p2.json" > "$merged"
export _GL_API_PAYLOAD="$merged"
out=$(chp_gitlab_review_threads 42)
# p1 contributes 2 resolvable (abc unresolved, def resolved), p2 contributes 1
# (xyz unresolved) — total 3.
assert_jq_true "TC-P33-145 merged length == 3 (p1: 2 resolvable + p2: 1 resolvable)" 'length == 3' "$out"

# TC-P33-146 — page-cap simulated via _gl_api rc≠0 (transport owns cap)
_reset_stub
_GL_API_FAIL_AT=1
CHP_GITLAB_REVIEW_THREADS_PAGE_CAP=1 out=$(chp_gitlab_review_threads 42 2>/dev/null); rc=$?
assert_rc_nz "TC-P33-146 page-cap hit (simulated) → leaf rc≠0" "$rc"
assert_empty "TC-P33-146 no partial stdout" "$out"

# TC-P33-147 — mid-walk failure (the MANDATORY R8/R12 failure fixture)
_reset_stub
_GL_API_FAIL_AT=1
out=$(chp_gitlab_review_threads 42 2>/dev/null); rc=$?
assert_rc_nz "TC-P33-147 mid-walk failure → rc≠0 EMPTY stdout (fail-CLOSED)" "$rc"
assert_empty "TC-P33-147 no partial stdout" "$out"

# TC-P33-148 — empty
_reset_stub
empty="$RUNDIR/threads-empty.json"; printf '[]' > "$empty"
export _GL_API_PAYLOAD="$empty"
out=$(chp_gitlab_review_threads 42)
assert_eq "TC-P33-148 empty discussions → []" "[]" "$out"

# ============================================================================
# Positional-validation gates (rc 2 + zero _gl_api calls)
# ============================================================================
echo "=== positional-validation gates ==="

_pos_reject() {
  local id="$1" invocation="$2"
  _reset_stub
  local out rc
  out=$(eval "$invocation" 2>/dev/null); rc=$?
  assert_rc_2 "$id '$invocation' → rc 2" "$rc"
  local calls; calls=$(wc -l < "$_GL_API_CALL_LOG" | tr -d ' ')
  assert_eq "$id ZERO _gl_api calls" "0" "$calls"
}
_pos_reject "TC-P33-160" 'chp_gitlab_ci_status ""'
_pos_reject "TC-P33-161" 'chp_gitlab_ci_status abc'
_pos_reject "TC-P33-162a" 'chp_gitlab_mergeable ""'
_pos_reject "TC-P33-162b" 'chp_gitlab_mergeable abc'
_pos_reject "TC-P33-163a" 'chp_gitlab_review_threads ""'
_pos_reject "TC-P33-163b" 'chp_gitlab_review_threads abc'
_pos_reject "TC-P33-164a" 'chp_gitlab_list_inline_comments ""'
_pos_reject "TC-P33-164b" 'chp_gitlab_list_inline_comments abc'
_pos_reject "TC-P33-165a" 'chp_gitlab_pr_view ""'
_pos_reject "TC-P33-165b" 'chp_gitlab_pr_view abc'
_pos_reject "TC-P33-166a" 'chp_gitlab_find_pr_for_issue ""'
_pos_reject "TC-P33-166b" 'chp_gitlab_find_pr_for_issue abc'

# ============================================================================
# Caps manifest (R11)
# ============================================================================
echo "=== R11: chp-gitlab.caps evidence ==="

_caps() { grep -E "^${1}=" "$CAPS" 2>/dev/null | head -1; }

assert_eq "TC-P33-180 chp-gitlab.caps exists as sibling of chp-gitlab.sh" \
  "1" "$(test -f "$CAPS" && echo 1 || echo 0)"
assert_eq "TC-P33-181 native_issue_pr_link=1" "native_issue_pr_link=1" "$(_caps native_issue_pr_link)"
assert_eq "TC-P33-182 rest_request_changes=0" "rest_request_changes=0"   "$(_caps rest_request_changes)"
assert_eq "TC-P33-183 review_bots=0"          "review_bots=0"            "$(_caps review_bots)"
assert_eq "TC-P33-184 merge_closes_issue=1"   "merge_closes_issue=1"     "$(_caps merge_closes_issue)"
assert_eq "TC-P33-185 marker_channel=html"    "marker_channel=html"      "$(_caps marker_channel)"

# Evidence-comment presence (the default-branch-only caveat MUST appear
# verbatim in the caps comment near merge_closes_issue).
if grep -qi -F "default branch" "$CAPS"; then
  ok "TC-P33-184 default-branch-only caveat present verbatim in caps comment"
else
  bad "TC-P33-184 default-branch-only caveat missing from caps comment"
fi

# ============================================================================
# Cutover-guard sanity (no glab / no /api/v4 outside providers/)
# ============================================================================
echo "=== [INV-91]: guard-neutral verification ==="

# The leaf itself lives under providers/ so raw /api/v4 curls in it would be
# EXEMPT by the check-provider-cutover.sh rule. This assert only confirms the
# leaf never accidentally calls `glab` or a raw `curl` — both are guaranteed
# forbidden by the transport contract (_gl_api is the ONLY hook) and would
# indicate a rewrite in the wrong direction. Comment lines (leading `#`) are
# exempted — they can legitimately name `glab`/`curl` when describing what
# the leaf deliberately does NOT do (choke-point discipline commentary).
_noncomment_leaf() { grep -vE '^\s*#' "$LEAF" 2>/dev/null; }
if _noncomment_leaf | grep -qE '(^|[^A-Za-z_-])glab([^A-Za-z_-]|$)'; then
  bad "TC-P33-203 leaf contains executable raw 'glab' (must use _gl_api only)"
else
  ok "TC-P33-203 leaf carries no executable raw 'glab' reference"
fi
if _noncomment_leaf | grep -qE '(^|[^A-Za-z_-])curl([^A-Za-z_-]|$)'; then
  bad "TC-P33-203 leaf contains executable raw 'curl' (must use _gl_api only)"
else
  ok "TC-P33-203 leaf carries no executable raw 'curl' reference"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "======================================================"
echo "  chp-gitlab reads: PASS=$PASS  FAIL=$FAIL"
echo "======================================================"

[ "$FAIL" -eq 0 ]
