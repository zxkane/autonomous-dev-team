#!/bin/bash
# test-chp-gitlab-writes.sh — #419 P3-4.
#
# Proves the 10 GitLab CHP WRITE leaves + `chp_gitlab_file_url` in
# skills/autonomous-dispatcher/scripts/providers/chp-gitlab.sh + the
# `chp_github_file_url` sibling + the `chp_file_url` shim + the
# upload-screenshot.sh:114 rewrite. Cases follow docs/test-cases/p3-4-chp-gitlab-writes.md
# (TC-P34-NNN).
#
# HERMETIC: this test defines a test-local `_gl_api` stub BEFORE sourcing the
# leaf. Every case configures the stub's per-invocation payload, invokes a
# leaf, and asserts (a) stdout, (b) rc, and (c) the recorded `_gl_api` argv
# trace.
#
# Run: env -u PROJECT_DIR bash tests/unit/test-chp-gitlab-writes.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LEAF="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/chp-gitlab.sh"
GH_LEAF="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/chp-github.sh"
CHP_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-code-host.sh"
UPLOAD_SH="$PROJECT_ROOT/skills/autonomous-review/scripts/upload-screenshot.sh"
PAYLOADS="$PROJECT_ROOT/tests/provider-conformance/fixtures/payloads"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

assert_eq()  { local d="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then ok "$d"; else bad "$d"; echo "      expected: |$e|"; echo "      actual:   |$a|"; fi; }
assert_rc()  { local d="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then ok "$d (rc=$a)"; else bad "$d (expected rc=$e, got rc=$a)"; fi; }
assert_rc_nz() { local d="$1" a="$2"; if [ "$a" != "0" ]; then ok "$d (rc=$a)"; else bad "$d (rc=0, expected non-zero)"; fi; }
assert_empty() { local d="$1" a="$2"; if [ -z "$a" ]; then ok "$d (empty)"; else bad "$d — expected empty, got: |${a:0:200}|"; fi; }
assert_json_eq() { local d="$1" filter="$2" expected="$3" json="$4"; local got; got=$(jq -c "$filter" <<<"$json" 2>/dev/null); if [ "$got" = "$expected" ]; then ok "$d"; else bad "$d — expected: |$expected| got: |$got|"; fi; }
assert_contains() { local d="$1" needle="$2" haystack="$3"; case "$haystack" in *"$needle"*) ok "$d" ;; *) bad "$d — needle '$needle' not in |${haystack:0:200}|" ;; esac; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }
[ -f "$LEAF" ]      || { echo "FATAL: chp-gitlab.sh missing at $LEAF"; exit 2; }
[ -f "$GH_LEAF" ]   || { echo "FATAL: chp-github.sh missing at $GH_LEAF"; exit 2; }
[ -f "$CHP_LIB" ]   || { echo "FATAL: lib-code-host.sh missing at $CHP_LIB"; exit 2; }

# ============================================================================
# Test-local `_gl_api` stub — models the FROZEN #416 signature. Same shape
# as test-chp-gitlab-reads.sh's stub with additions for --tolerate-status /
# --status-out / GL_API_STATUS discipline.
#
# Configuration (env vars, all optional):
#   _GL_API_PAYLOAD          single canned payload (default mode)
#   _GL_API_PAYLOAD_SEQ      colon-separated list of payload files served in
#                            invocation order (last cycled on overflow)
#   _GL_API_STATUS_SEQ       colon-separated status codes served in order
#                            (default '200' per call)
#   _GL_API_FAIL_AT          N — force this invocation (1-indexed) to fail rc≠0
#   _GL_API_CALL_LOG         file — every invocation appends one line
#                            "<argv pipe-joined>"
#   _GL_API_INV_STATE        file — invocation-count state
# ============================================================================
_reset_stub() {
  export _GL_API_PAYLOAD=""
  export _GL_API_PAYLOAD_SEQ=""
  export _GL_API_STATUS_SEQ=""
  export _GL_API_FAIL_AT=""
  export _GL_API_CALL_LOG="$RUNDIR/call.log"
  export _GL_API_INV_STATE="$RUNDIR/inv.state"
  : > "$_GL_API_CALL_LOG"
  : > "$_GL_API_INV_STATE"
}

_gl_api() {
  local IFS='|'; printf '%s\n' "$*" >> "$_GL_API_CALL_LOG"; IFS=' '
  local inv
  inv=$(<"$_GL_API_INV_STATE")
  inv=$((inv + 1))
  printf '%s' "$inv" > "$_GL_API_INV_STATE"

  # Status-code channel: pick from --status-out flag or _GL_API_STATUS_SEQ.
  local status_out_file="" status_code="200" a next=""
  local args=("$@")
  local i=0
  while [ $i -lt $# ]; do
    a="${args[$i]}"
    case "$a" in
      --status-out) i=$((i + 1)); status_out_file="${args[$i]}"; ;;
      --status-out=*) status_out_file="${a#*=}" ;;
    esac
    i=$((i + 1))
  done
  if [ -n "$_GL_API_STATUS_SEQ" ]; then
    local IFS_SAVE=$IFS; IFS=':'
    # shellcheck disable=SC2206
    local -a seq_status=($_GL_API_STATUS_SEQ)
    IFS="$IFS_SAVE"
    local idx=$((inv - 1))
    (( idx >= ${#seq_status[@]} )) && idx=$(( ${#seq_status[@]} - 1 ))
    status_code="${seq_status[$idx]}"
  fi
  GL_API_STATUS="$status_code"
  [ -n "$status_out_file" ] && printf '%s' "$status_code" > "$status_out_file"

  # Forced-failure hook.
  if [ -n "$_GL_API_FAIL_AT" ] && [ "$_GL_API_FAIL_AT" = "$inv" ]; then
    return 1
  fi

  # Choose payload.
  local payload="$_GL_API_PAYLOAD"
  if [ -z "$payload" ] && [ -n "$_GL_API_PAYLOAD_SEQ" ]; then
    local IFS_SAVE=$IFS; IFS=':'
    # shellcheck disable=SC2206
    local -a seq=($_GL_API_PAYLOAD_SEQ)
    IFS="$IFS_SAVE"
    local idx=$((inv - 1))
    (( idx >= ${#seq[@]} )) && idx=$(( ${#seq[@]} - 1 ))
    payload="${seq[$idx]}"
  fi
  [ -n "$payload" ] && [ -f "$payload" ] || { printf ''; return 0; }
  cat "$payload"
}

_gl_urlencode() { jq -rn --arg s "$1" '$s | @uri'; }
export -f _gl_api _gl_urlencode

RUNDIR=$(mktemp -d)
trap 'rm -rf "$RUNDIR"' EXIT

export GITLAB_PROJECT="myGroup%2FmyProject"
export GITLAB_HOST="gitlab.example.test"
export GITLAB_TOKEN="not-a-real-token"

# Source the leaf under test.
# shellcheck source=../../skills/autonomous-dispatcher/scripts/providers/chp-gitlab.sh
source "$LEAF"

# Helper: return the Nth _gl_api call recorded (1-indexed).
_call_n() { sed -n "${1}p" "$_GL_API_CALL_LOG"; }
_call_count() { wc -l < "$_GL_API_CALL_LOG" | tr -d '[:space:]'; }

# ============================================================================
# R2 — chp_gitlab_create_pr
# ============================================================================
echo "=== R2: chp_gitlab_create_pr ==="

# TC-P34-001 — happy path
_reset_stub
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-write-create-pr-project.json:$PAYLOADS/gitlab-chp-write-create-pr-response.json"
out=$(chp_gitlab_create_pr "feat/x" "sample title" "sample body"); rc=$?
assert_rc "TC-P34-001 rc" "0" "$rc"
assert_eq "TC-P34-001 stdout is web_url" "https://gitlab.example.test/myGroup/myProject/-/merge_requests/99" "$out"
assert_eq "TC-P34-001 exactly 2 _gl_api calls" "2" "$(_call_count)"
assert_contains "TC-P34-001 call #1 = GET /projects/…" "/projects/myGroup%2FmyProject" "$(_call_n 1)"
assert_contains "TC-P34-001 call #2 = --method POST /merge_requests" "--method|POST" "$(_call_n 2)"
assert_contains "TC-P34-001 POST body has target_branch=\"main\"" '"target_branch":"main"' "$(_call_n 2)"
assert_contains "TC-P34-001 POST body has squash:true" '"squash":true' "$(_call_n 2)"
assert_contains "TC-P34-001 POST body has remove_source_branch:true" '"remove_source_branch":true' "$(_call_n 2)"

# TC-P34-002 — empty BODY is legitimate
_reset_stub
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-write-create-pr-project.json:$PAYLOADS/gitlab-chp-write-create-pr-response.json"
out=$(chp_gitlab_create_pr "feat/x" "title" ""); rc=$?
assert_rc "TC-P34-002 rc (empty BODY legitimate)" "0" "$rc"
assert_contains "TC-P34-002 POST body has empty description" '"description":""' "$(_call_n 2)"

# TC-P34-003 — default-branch fetch fails → fail-CLOSED
_reset_stub
export _GL_API_FAIL_AT="1"
out=$(chp_gitlab_create_pr "feat/x" "t" "b" 2>/dev/null); rc=$?
assert_rc_nz "TC-P34-003 default-branch fetch fails → fail-CLOSED" "$rc"
assert_empty "TC-P34-003 empty stdout" "$out"
assert_eq "TC-P34-003 exactly 1 _gl_api call (no POST)" "1" "$(_call_count)"

# TC-P34-004 — POST create fails
_reset_stub
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-write-create-pr-project.json:$PAYLOADS/gitlab-chp-write-create-pr-response.json"
export _GL_API_FAIL_AT="2"
out=$(chp_gitlab_create_pr "feat/x" "t" "b" 2>/dev/null); rc=$?
assert_rc_nz "TC-P34-004 POST rc≠0 → fail-CLOSED" "$rc"
assert_empty "TC-P34-004 empty stdout" "$out"
assert_eq "TC-P34-004 exactly 2 calls" "2" "$(_call_count)"

# TC-P34-005 — HEAD_BRANCH empty → rc 2 NO HTTP
_reset_stub
out=$(chp_gitlab_create_pr "" "t" "b" 2>/dev/null); rc=$?
assert_rc "TC-P34-005 empty HEAD_BRANCH → rc 2" "2" "$rc"
assert_empty "TC-P34-005 empty stdout" "$out"
assert_eq "TC-P34-005 0 _gl_api calls" "0" "$(_call_count)"

# TC-P34-006 — TITLE empty → rc 2 NO HTTP
_reset_stub
out=$(chp_gitlab_create_pr "feat/x" "" "b" 2>/dev/null); rc=$?
assert_rc "TC-P34-006 empty TITLE → rc 2" "2" "$rc"
assert_eq "TC-P34-006 0 _gl_api calls" "0" "$(_call_count)"

# ============================================================================
# R3 — chp_gitlab_approve
# ============================================================================
echo "=== R3: chp_gitlab_approve ==="

# TC-P34-007 — both OK (approve first, then note)
_reset_stub
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-write-approve-approve-ok.json:$PAYLOADS/gitlab-chp-write-approve-note-ok.json"
chp_gitlab_approve 42 "sample approval note" >/dev/null 2>&1; rc=$?
assert_rc "TC-P34-007 rc" "0" "$rc"
assert_eq "TC-P34-007 exactly 2 _gl_api calls" "2" "$(_call_count)"
assert_contains "TC-P34-007 call #1 = POST /approve" "--method|POST" "$(_call_n 1)"
assert_contains "TC-P34-007 call #1 path = …/approve" "/approve" "$(_call_n 1)"
assert_contains "TC-P34-007 call #2 path = …/notes" "/notes" "$(_call_n 2)"

# TC-P34-008 — approve OK, note FAILS → rc 0 + WARN
_reset_stub
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-write-approve-approve-ok.json:$PAYLOADS/gitlab-chp-write-approve-note-ok.json"
export _GL_API_FAIL_AT="2"
warn_out=$(chp_gitlab_approve 42 "note body" 2>&1 >/dev/null); rc=$?
assert_rc "TC-P34-008 rc 0 (note-only failure tolerated)" "0" "$rc"
assert_contains "TC-P34-008 WARN on stderr" "WARN: chp_gitlab_approve" "$warn_out"

# TC-P34-009 — approve FAILS → rc≠0, note NOT attempted
_reset_stub
export _GL_API_FAIL_AT="1"
out=$(chp_gitlab_approve 42 "body" 2>/dev/null); rc=$?
assert_rc_nz "TC-P34-009 approve FAILS → rc≠0" "$rc"
assert_eq "TC-P34-009 exactly 1 call (no note POST)" "1" "$(_call_count)"

# TC-P34-010 — PR="" → rc 2 NO HTTP
_reset_stub
out=$(chp_gitlab_approve "" "body" 2>/dev/null); rc=$?
assert_rc "TC-P34-010 PR='' → rc 2" "2" "$rc"
assert_eq "TC-P34-010 0 calls" "0" "$(_call_count)"

# TC-P34-011 — PR="abc" → rc 2 NO HTTP
_reset_stub
out=$(chp_gitlab_approve "abc" "body" 2>/dev/null); rc=$?
assert_rc "TC-P34-011 PR='abc' non-numeric → rc 2" "2" "$rc"
assert_eq "TC-P34-011 0 calls" "0" "$(_call_count)"

# TC-P34-012 — BODY="" → rc 2 NO HTTP
_reset_stub
out=$(chp_gitlab_approve 42 "" 2>/dev/null); rc=$?
assert_rc "TC-P34-012 BODY='' → rc 2" "2" "$rc"
assert_eq "TC-P34-012 0 calls" "0" "$(_call_count)"

# ============================================================================
# R4 — chp_gitlab_merge
# ============================================================================
echo "=== R4: chp_gitlab_merge ==="

# TC-P34-013 — happy merge
_reset_stub
export _GL_API_PAYLOAD="$PAYLOADS/gitlab-chp-write-merge-response.json"
out=$(chp_gitlab_merge 42); rc=$?
assert_rc "TC-P34-013 rc" "0" "$rc"
assert_contains "TC-P34-013 stdout contains merged state" "merged" "$out"
assert_eq "TC-P34-013 exactly 1 call" "1" "$(_call_count)"
assert_contains "TC-P34-013 call = --method PUT" "--method|PUT" "$(_call_n 1)"
assert_contains "TC-P34-013 body has squash:true" '"squash":true' "$(_call_n 1)"
assert_contains "TC-P34-013 body has should_remove_source_branch:true" '"should_remove_source_branch":true' "$(_call_n 1)"
assert_contains "TC-P34-013 path = …/merge_requests/42/merge" "/merge_requests/42/merge" "$(_call_n 1)"

# TC-P34-014 — 405 not-mergeable → surface (_gl_api rc≠0 pass-through)
_reset_stub
export _GL_API_FAIL_AT="1"
export _GL_API_STATUS_SEQ="405"
out=$(chp_gitlab_merge 42 2>/dev/null); rc=$?
assert_rc_nz "TC-P34-014 405 → rc≠0" "$rc"

# TC-P34-015 — 409 conflict → surface
_reset_stub
export _GL_API_FAIL_AT="1"
export _GL_API_STATUS_SEQ="409"
out=$(chp_gitlab_merge 42 2>/dev/null); rc=$?
assert_rc_nz "TC-P34-015 409 → rc≠0" "$rc"

# TC-P34-016 — PR="" → rc 2 NO HTTP
_reset_stub
out=$(chp_gitlab_merge "" 2>/dev/null); rc=$?
assert_rc "TC-P34-016 PR='' → rc 2" "2" "$rc"
assert_eq "TC-P34-016 0 calls" "0" "$(_call_count)"

# TC-P34-017 — PR="abc" → rc 2 NO HTTP
_reset_stub
out=$(chp_gitlab_merge "abc" 2>/dev/null); rc=$?
assert_rc "TC-P34-017 PR='abc' → rc 2" "2" "$rc"
assert_eq "TC-P34-017 0 calls" "0" "$(_call_count)"

# ============================================================================
# R5 — chp_gitlab_pr_comment (--body <string> audited shape)
# ============================================================================
echo "=== R5: chp_gitlab_pr_comment ==="

# TC-P34-018 — happy comment
_reset_stub
export _GL_API_PAYLOAD="$PAYLOADS/gitlab-chp-write-pr-comment-response.json"
chp_gitlab_pr_comment 42 --body "hello world" >/dev/null 2>&1; rc=$?
assert_rc "TC-P34-018 rc" "0" "$rc"
assert_eq "TC-P34-018 exactly 1 call" "1" "$(_call_count)"
assert_contains "TC-P34-018 call = --method POST" "--method|POST" "$(_call_n 1)"
assert_contains "TC-P34-018 body = {\"body\":\"hello world\"}" '"body":"hello world"' "$(_call_n 1)"
assert_contains "TC-P34-018 path = …/merge_requests/42/notes" "/merge_requests/42/notes" "$(_call_n 1)"

# TC-P34-019 — body with special chars (JSON encoded via jq)
_reset_stub
export _GL_API_PAYLOAD="$PAYLOADS/gitlab-chp-write-pr-comment-response.json"
chp_gitlab_pr_comment 42 --body $'line1\nline2\"q\"' >/dev/null 2>&1; rc=$?
assert_rc "TC-P34-019 special-chars rc" "0" "$rc"
# Extract the body arg and verify it parses as JSON.
body_arg=$(_call_n 1 | awk -F'|' '{for(i=1;i<=NF;i++) if($i=="--body"){print $(i+1); exit}}')
assert_json_eq "TC-P34-019 body JSON round-trip" '.body' '"line1\nline2\"q\""' "$body_arg"

# TC-P34-020 — _gl_api fails
_reset_stub
export _GL_API_FAIL_AT="1"
chp_gitlab_pr_comment 42 --body "x" 2>/dev/null; rc=$?
assert_rc_nz "TC-P34-020 _gl_api rc≠0 → rc≠0" "$rc"

# TC-P34-021 — PR="" → rc 2 NO HTTP
_reset_stub
chp_gitlab_pr_comment "" --body "x" 2>/dev/null; rc=$?
assert_rc "TC-P34-021 PR='' → rc 2" "2" "$rc"
assert_eq "TC-P34-021 0 calls" "0" "$(_call_count)"

# TC-P34-022 — missing --body → rc 2 NO HTTP
_reset_stub
chp_gitlab_pr_comment 42 2>/dev/null; rc=$?
assert_rc "TC-P34-022 missing --body → rc 2" "2" "$rc"
assert_eq "TC-P34-022 0 calls" "0" "$(_call_count)"

# ============================================================================
# R6 — chp_gitlab_reply_review_comment (discussions walk + synthesized URL)
# ============================================================================
echo "=== R6: chp_gitlab_reply_review_comment ==="

# TC-P34-023 — happy walk — target on page 2 (comment id 200002 → discussion d099)
_reset_stub
# `_gl_api --paginate` returns the MERGED array in ONE call (transport walks
# internally). The stub returns the merged fixture.
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-write-reply-discussions-merged.json:$PAYLOADS/gitlab-chp-write-reply-note-response.json"
out=$(chp_gitlab_reply_review_comment 42 200002 "reply body"); rc=$?
assert_rc "TC-P34-023 rc" "0" "$rc"
assert_eq "TC-P34-023 exactly 2 calls (walk + POST)" "2" "$(_call_count)"
assert_contains "TC-P34-023 call #1 --paginate" "--paginate" "$(_call_n 1)"
assert_contains "TC-P34-023 call #2 = --method POST" "--method|POST" "$(_call_n 2)"
assert_contains "TC-P34-023 POST path = …/discussions/d099/notes" "/discussions/d099/notes" "$(_call_n 2)"
assert_json_eq "TC-P34-023 stdout {id}" '.id' '5678' "$out"
assert_json_eq "TC-P34-023 stdout {url}" '.url' '"https://gitlab.example.test/myGroup/myProject/-/merge_requests/42#note_5678"' "$out"

# TC-P34-024 — comment id NOT found → rc≠0
_reset_stub
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-write-reply-discussions-merged.json"
out=$(chp_gitlab_reply_review_comment 42 999999 "reply" 2>/dev/null); rc=$?
assert_rc_nz "TC-P34-024 comment id not in any discussion → rc≠0" "$rc"
assert_empty "TC-P34-024 empty stdout" "$out"

# TC-P34-025 — mid-walk failure → rc≠0 (MANDATORY fixture)
_reset_stub
export _GL_API_FAIL_AT="1"
out=$(chp_gitlab_reply_review_comment 42 200002 "reply" 2>/dev/null); rc=$?
assert_rc_nz "TC-P34-025 --paginate fails → rc≠0" "$rc"
assert_empty "TC-P34-025 empty stdout" "$out"

# TC-P34-026 — encoded project decodes for the synthesized URL
_reset_stub
export GITLAB_PROJECT="my%2Egroup%2Fnested%2Fproj"
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-write-reply-discussions-merged.json:$PAYLOADS/gitlab-chp-write-reply-note-response.json"
out=$(chp_gitlab_reply_review_comment 42 200002 "r"); rc=$?
assert_rc "TC-P34-026 rc" "0" "$rc"
assert_json_eq "TC-P34-026 decoded URL" '.url' '"https://gitlab.example.test/my.group/nested/proj/-/merge_requests/42#note_5678"' "$out"
# Restore GITLAB_PROJECT for the rest of the suite.
export GITLAB_PROJECT="myGroup%2FmyProject"

# ============================================================================
# R7 — chp_gitlab_resolve_thread (compound-id decode)
# ============================================================================
echo "=== R7: chp_gitlab_resolve_thread ==="

# TC-P34-027 — happy decode + PUT
_reset_stub
export _GL_API_PAYLOAD="$PAYLOADS/gitlab-chp-write-resolve-thread-response.json"
out=$(chp_gitlab_resolve_thread "42:8f1e2d3c"); rc=$?
assert_rc "TC-P34-027 rc" "0" "$rc"
assert_eq "TC-P34-027 stdout = true" "true" "$out"
assert_eq "TC-P34-027 exactly 1 call" "1" "$(_call_count)"
assert_contains "TC-P34-027 --method PUT" "--method|PUT" "$(_call_n 1)"
assert_contains "TC-P34-027 body = {\"resolved\":true}" '{"resolved":true}' "$(_call_n 1)"
assert_contains "TC-P34-027 path = …/merge_requests/42/discussions/8f1e2d3c" "/merge_requests/42/discussions/8f1e2d3c" "$(_call_n 1)"

# TC-P34-028 — PUT fails
_reset_stub
export _GL_API_FAIL_AT="1"
out=$(chp_gitlab_resolve_thread "42:d99" 2>/dev/null); rc=$?
assert_rc_nz "TC-P34-028 PUT fails → rc≠0" "$rc"

# TC-P34-029 — malformed no colon → rc 2 NO HTTP
_reset_stub
out=$(chp_gitlab_resolve_thread "42d99" 2>/dev/null); rc=$?
assert_rc "TC-P34-029 no colon → rc 2" "2" "$rc"
assert_eq "TC-P34-029 0 calls" "0" "$(_call_count)"

# TC-P34-030 — malformed non-numeric iid
_reset_stub
out=$(chp_gitlab_resolve_thread "abc:d99" 2>/dev/null); rc=$?
assert_rc "TC-P34-030 non-numeric iid → rc 2" "2" "$rc"
assert_eq "TC-P34-030 0 calls" "0" "$(_call_count)"

# TC-P34-031 — malformed empty discussion
_reset_stub
out=$(chp_gitlab_resolve_thread "42:" 2>/dev/null); rc=$?
assert_rc "TC-P34-031 empty disc → rc 2" "2" "$rc"
assert_eq "TC-P34-031 0 calls" "0" "$(_call_count)"

# TC-P34-032 — malformed empty
_reset_stub
out=$(chp_gitlab_resolve_thread "" 2>/dev/null); rc=$?
assert_rc "TC-P34-032 empty → rc 2" "2" "$rc"
assert_eq "TC-P34-032 0 calls" "0" "$(_call_count)"

# ============================================================================
# R8 — chp_gitlab_request_changes DELIBERATELY ABSENT
# ============================================================================
echo "=== R8: chp_gitlab_request_changes leaf-absent ==="

# TC-P34-033 — leaf ABSENT
declare -F chp_gitlab_request_changes >/dev/null 2>&1; rc=$?
assert_rc "TC-P34-033 leaf ABSENT (rc≠0)" "1" "$rc"

# TC-P34-034 — shim `chp_has_leaf request_changes` returns rc≠0
# The shim is defined in lib-code-host.sh; source it and check.
(
  export CODE_HOST=gitlab
  # shellcheck source=/dev/null
  source "$CHP_LIB"
  chp_has_leaf request_changes
) >/dev/null 2>&1
rc=$?
assert_rc_nz "TC-P34-034 chp_has_leaf request_changes rc≠0 under CODE_HOST=gitlab" "$rc"

# TC-P34-035 — caps declaration
CAPS_FILE="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/chp-gitlab.caps"
[ -f "$CAPS_FILE" ] && grep -qE '^\s*rest_request_changes\s*=\s*0' "$CAPS_FILE"
assert_rc "TC-P34-035 chp-gitlab.caps has rest_request_changes=0" "0" "$?"

# ============================================================================
# R9 — chp_gitlab_close_keyword
# ============================================================================
echo "=== R9: chp_gitlab_close_keyword ==="

# TC-P34-036/037 — render tests
_reset_stub
assert_eq "TC-P34-036 close_keyword 42" "Closes #42" "$(chp_gitlab_close_keyword 42)"
assert_eq "TC-P34-037 close_keyword 1"  "Closes #1"  "$(chp_gitlab_close_keyword 1)"
assert_eq "TC-P34-036/037 no HTTP" "0" "$(_call_count)"

# ============================================================================
# R10 — chp_gitlab_commit_file
# ============================================================================
echo "=== R10: chp_gitlab_commit_file ==="

# TC-P34-038 — branch exists + file new → POST create
_reset_stub
# Call sequence: (1) branch preflight 200, (2) file preflight 404, (3) POST create, (4) commits GET
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-write-commit-file-branch-exists.json:$PAYLOADS/gitlab-chp-write-commit-file-create-response.json:$PAYLOADS/gitlab-chp-write-commit-file-create-response.json:$PAYLOADS/gitlab-chp-write-commit-file-commits.json"
export _GL_API_STATUS_SEQ="200:404:201:200"
out=$(chp_gitlab_commit_file "myGroup%2FmyProject" "screenshots" "pr-42/TC-1.png" "$(printf 'imgdata' | base64 -w0)" "screenshot: PR #42 TC-1"); rc=$?
assert_rc "TC-P34-038 rc" "0" "$rc"
assert_eq "TC-P34-038 stdout = commit SHA" "abcdef1234567890abcdef1234567890abcdef12" "$out"
assert_eq "TC-P34-038 exactly 4 calls" "4" "$(_call_count)"
assert_contains "TC-P34-038 call #1 branch preflight (--tolerate-status 404)" "--tolerate-status|404" "$(_call_n 1)"
assert_contains "TC-P34-038 call #3 = --method POST" "--method|POST" "$(_call_n 3)"

# TC-P34-039 — branch exists + file exists → PUT update
_reset_stub
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-write-commit-file-branch-exists.json:$PAYLOADS/gitlab-chp-write-commit-file-file-exists.json:$PAYLOADS/gitlab-chp-write-commit-file-create-response.json:$PAYLOADS/gitlab-chp-write-commit-file-commits.json"
export _GL_API_STATUS_SEQ="200:200:200:200"
out=$(chp_gitlab_commit_file "myGroup%2FmyProject" "screenshots" "pr-42/TC-1.png" "$(printf 'imgdata' | base64 -w0)" "screenshot: update"); rc=$?
assert_rc "TC-P34-039 rc" "0" "$rc"
assert_contains "TC-P34-039 call #3 = --method PUT (file exists)" "--method|PUT" "$(_call_n 3)"

# TC-P34-040 — branch absent → bootstrap → POST create
_reset_stub
# (1) branch preflight 404, (2) project GET default, (3) POST create branch,
# (4) file preflight 404, (5) POST create file, (6) commits GET
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-write-commit-file-branch-exists.json:$PAYLOADS/gitlab-chp-write-commit-file-project-default.json:$PAYLOADS/gitlab-chp-write-commit-file-branch-create.json:$PAYLOADS/gitlab-chp-write-commit-file-file-exists.json:$PAYLOADS/gitlab-chp-write-commit-file-create-response.json:$PAYLOADS/gitlab-chp-write-commit-file-commits.json"
export _GL_API_STATUS_SEQ="404:200:201:404:201:200"
out=$(chp_gitlab_commit_file "myGroup%2FmyProject" "screenshots" "pr-42/TC-1.png" "$(printf 'imgdata' | base64 -w0)" "m"); rc=$?
assert_rc "TC-P34-040 rc (bootstrap branch)" "0" "$rc"
assert_eq "TC-P34-040 exactly 6 calls" "6" "$(_call_count)"
assert_contains "TC-P34-040 call #3 creates branch (--method POST on /repository/branches)" "/repository/branches" "$(_call_n 3)"
assert_contains "TC-P34-040 call #3 has ref= (default branch)" "ref=" "$(_call_n 3)"

# TC-P34-041 — INV-99 RETURN-trap self-disarm across 2 consecutive invocations
_reset_stub
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-write-commit-file-branch-exists.json:$PAYLOADS/gitlab-chp-write-commit-file-file-exists.json:$PAYLOADS/gitlab-chp-write-commit-file-create-response.json:$PAYLOADS/gitlab-chp-write-commit-file-commits.json"
export _GL_API_STATUS_SEQ="200:200:200:200:200:200:200:200"
# Invoke twice — set -u ensures the second call would blow up if the RETURN
# trap persisted and referenced now-out-of-scope locals.
set -u
chp_gitlab_commit_file "myGroup%2FmyProject" "screenshots" "pr-42/TC-1.png" "$(printf 'x' | base64 -w0)" "m" >/dev/null 2>&1
r1=$?
chp_gitlab_commit_file "myGroup%2FmyProject" "screenshots" "pr-42/TC-2.png" "$(printf 'y' | base64 -w0)" "m" >/dev/null 2>&1
r2=$?
set +u
assert_rc "TC-P34-041 invocation #1" "0" "$r1"
assert_rc "TC-P34-041 invocation #2 (no set -u unbound-variable crash)" "0" "$r2"

# TC-P34-042 — commit_file POST fails
_reset_stub
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-write-commit-file-branch-exists.json:$PAYLOADS/gitlab-chp-write-commit-file-file-exists.json"
export _GL_API_STATUS_SEQ="200:404"
export _GL_API_FAIL_AT="3"
out=$(chp_gitlab_commit_file "repo" "b" "p" "$(printf 'x' | base64 -w0)" "m" 2>/dev/null); rc=$?
assert_rc_nz "TC-P34-042 POST fails → rc≠0" "$rc"

# TC-P34-043 — slash-bearing branch percent-encoded
_reset_stub
export _GL_API_PAYLOAD_SEQ="$PAYLOADS/gitlab-chp-write-commit-file-branch-exists.json:$PAYLOADS/gitlab-chp-write-commit-file-file-exists.json:$PAYLOADS/gitlab-chp-write-commit-file-create-response.json:$PAYLOADS/gitlab-chp-write-commit-file-commits.json"
export _GL_API_STATUS_SEQ="200:200:200:200"
chp_gitlab_commit_file "myGroup%2FmyProject" "feat/x" "pr-42/TC-1.png" "$(printf 'x' | base64 -w0)" "m" >/dev/null 2>&1
assert_contains "TC-P34-043 slash-bearing branch percent-encoded (feat%2Fx)" "feat%2Fx" "$(_call_n 1)"

# TC-P34-044 — slash-bearing file path percent-encoded
assert_contains "TC-P34-044 file-path slash percent-encoded (path%2Fto%2Ff)" "pr-42%2FTC-1.png" "$(_call_n 2)"

# ============================================================================
# R11 — chp_file_url (github + gitlab + shim + upload-screenshot.sh rewrite)
# ============================================================================
echo "=== R11: chp_file_url (both leaves + shim + upload-screenshot rewrite) ==="

# We must source chp-github.sh for its file_url leaf. Guard against readonly-collision.
# The lib-code-host.sh source below establishes CODE_HOST=github default and
# also sources chp-github.sh from the skill tree.
(
  # Fresh shell to avoid readonly/global pollution.
  export _GL_API_CALL_LOG _GL_API_INV_STATE _GL_API_PAYLOAD _GL_API_PAYLOAD_SEQ _GL_API_FAIL_AT _GL_API_STATUS_SEQ
  # shellcheck source=../../skills/autonomous-dispatcher/scripts/providers/chp-github.sh
  source "$GH_LEAF"

  gh1="$(chp_github_file_url "owner/repo" "screenshots" "pr-42/TC-1.png")"
  gh2="$(chp_github_file_url "zxkane/foo-bar" "feat/x" "docs/a.md")"
  printf 'GH1=%s\nGH2=%s\n' "$gh1" "$gh2"
) > "$RUNDIR/github-out" 2>&1
gh1=$(sed -n 's/^GH1=//p' "$RUNDIR/github-out")
gh2=$(sed -n 's/^GH2=//p' "$RUNDIR/github-out")
assert_eq "TC-P34-045 github render" "https://github.com/owner/repo/blob/screenshots/pr-42/TC-1.png" "$gh1"
assert_eq "TC-P34-046 github render byte-identical to hardcode" "https://github.com/zxkane/foo-bar/blob/feat/x/docs/a.md" "$gh2"

# TC-P34-047/048/049 — gitlab renders
assert_eq "TC-P34-047 gitlab render (ambient GITLAB_PROJECT)" \
  "https://gitlab.example.test/myGroup/myProject/-/blob/screenshots/pr-42/TC-1.png" \
  "$(chp_gitlab_file_url "" screenshots pr-42/TC-1.png)"
assert_eq "TC-P34-048 gitlab render (explicit REPO override)" \
  "https://gitlab.example.test/otherGroup/other/-/blob/main/README.md" \
  "$(chp_gitlab_file_url "otherGroup%2Fother" main README.md)"
# Nested slash-project scenario
_saved_gp="$GITLAB_PROJECT"
export GITLAB_PROJECT="myGroup%2Fnested%2Fproj"
assert_eq "TC-P34-049 gitlab render (raw slash path, NOT URL-encoded)" \
  "https://gitlab.example.test/myGroup/nested/proj/-/blob/feat/x/path/to/f.png" \
  "$(chp_gitlab_file_url "" feat/x path/to/f.png)"
export GITLAB_PROJECT="$_saved_gp"

# TC-P34-050 — shim dispatch under both CODE_HOSTs
# Run each in a fresh subshell so we can source lib-code-host.sh (which sources
# the enabled provider's leaf file) without contaminating THIS shell.
(
  export CODE_HOST=github
  # shellcheck source=/dev/null
  source "$CHP_LIB"
  chp_file_url "owner/r" "b" "f.md"
) > "$RUNDIR/shim-gh" 2>&1
(
  export CODE_HOST=gitlab
  export GITLAB_PROJECT="myGroup%2FmyProject"
  export GITLAB_HOST="gitlab.example.test"
  # shellcheck source=/dev/null
  source "$CHP_LIB"
  chp_file_url "" "b" "f.md"
) > "$RUNDIR/shim-gl" 2>&1
assert_eq "TC-P34-050 shim dispatch → github leaf" "https://github.com/owner/r/blob/b/f.md" "$(cat "$RUNDIR/shim-gh")"
assert_eq "TC-P34-050 shim dispatch → gitlab leaf" "https://gitlab.example.test/myGroup/myProject/-/blob/b/f.md" "$(cat "$RUNDIR/shim-gl")"

# TC-P34-051 — upload-screenshot.sh:114 rewrite grep-anchor
grep -qE '^chp_file_url "\$REPO" "\$BRANCH" "\$FILE_PATH"' "$UPLOAD_SH"
assert_rc "TC-P34-051 upload-screenshot.sh calls chp_file_url" "0" "$?"
# Negative anchor — the pre-#419 hardcoded `echo "https://github.com/…"` line
# must be GONE.
! grep -qE '^echo "https://github\.com/\$\{REPO\}/blob/' "$UPLOAD_SH"
assert_rc "TC-P34-051 hardcode line removed" "0" "$?"

# ============================================================================
# R12 — chp_gitlab_trigger_bot no-op
# ============================================================================
echo "=== R12: chp_gitlab_trigger_bot ==="

# TC-P34-052 — no-op, no HTTP, rc 0
_reset_stub
chp_gitlab_trigger_bot 42 "/codex review" >/dev/null 2>&1; rc=$?
assert_rc "TC-P34-052 rc 0" "0" "$rc"
assert_eq "TC-P34-052 0 _gl_api calls" "0" "$(_call_count)"

# ============================================================================
# R13 — chp_gitlab_count_reviews_by_login (INV-94)
# ============================================================================
echo "=== R13: chp_gitlab_count_reviews_by_login ==="

# TC-P34-054 — 2 approvers, matching login "bot-a" → count 1
_reset_stub
export _GL_API_PAYLOAD="$PAYLOADS/gitlab-chp-write-count-reviews-two.json"
assert_eq "TC-P34-054 count(bot-a)=1" "1" "$(chp_gitlab_count_reviews_by_login "myGroup%2FmyProject" 42 bot-a)"

# TC-P34-055 — 0 matches
_reset_stub
export _GL_API_PAYLOAD="$PAYLOADS/gitlab-chp-write-count-reviews-two.json"
assert_eq "TC-P34-055 count(nobody)=0" "0" "$(chp_gitlab_count_reviews_by_login "repo" 42 nobody)"

# TC-P34-056 — github-actions[bot]-style login
_reset_stub
export _GL_API_PAYLOAD="$PAYLOADS/gitlab-chp-write-count-reviews-injection.json"
assert_eq "TC-P34-056 count(github-actions[bot])=1" "1" "$(chp_gitlab_count_reviews_by_login "repo" 42 "github-actions[bot]")"

# TC-P34-057 — injection-safe: login containing `"` finds NO widen-match
_reset_stub
export _GL_API_PAYLOAD="$PAYLOADS/gitlab-chp-write-count-reviews-injection.json"
count=$(chp_gitlab_count_reviews_by_login "repo" 42 'evil"; injection')
# The literal `evil"; injection` username in the fixture is a REAL match — verify it's counted as 1.
assert_eq "TC-P34-057 injection-safe: literal login counted 1, no widen" "1" "$count"

# TC-P34-058 — _gl_api rc≠0 → echo 0 rc 0 (fail-SAFE)
_reset_stub
export _GL_API_FAIL_AT="1"
count=$(chp_gitlab_count_reviews_by_login "repo" 42 bot-a); rc=$?
assert_rc "TC-P34-058 rc 0 (fail-SAFE)" "0" "$rc"
assert_eq "TC-P34-058 count=0 on failure" "0" "$count"

# TC-P34-059 — malformed JSON → echo 0 rc 0
_reset_stub
malformed="$RUNDIR/malformed.json"
printf '{ not json' > "$malformed"
export _GL_API_PAYLOAD="$malformed"
count=$(chp_gitlab_count_reviews_by_login "repo" 42 bot-a); rc=$?
assert_rc "TC-P34-059 rc 0 on malformed JSON" "0" "$rc"
assert_eq "TC-P34-059 count=0 on malformed" "0" "$count"

# TC-P34-060 — empty approved_by
_reset_stub
export _GL_API_PAYLOAD="$PAYLOADS/gitlab-chp-write-count-reviews-empty.json"
assert_eq "TC-P34-060 count(empty approved_by)=0" "0" "$(chp_gitlab_count_reviews_by_login "repo" 42 bot-a)"

# ============================================================================
# Report
# ============================================================================
echo ""
echo "=============================================="
echo "TOTAL: PASS=$PASS  FAIL=$FAIL"
echo "=============================================="
[ "$FAIL" -eq 0 ]
