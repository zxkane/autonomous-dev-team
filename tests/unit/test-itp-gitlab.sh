#!/bin/bash
# test-itp-gitlab.sh — issue #417 (W-B, phase-3 W-B slice of #414).
#
# LEAF-level coverage for providers/itp-gitlab.sh (14 verbs). Hermetic — no
# live GitLab, no _gl_api transport lib on this branch. Each test defines a
# local `_gl_api` / `_gl_urlencode` STUB that serves recorded fixture
# payloads and sets GL_API_STATUS in the calling shell (matches the FROZEN
# #416 P3-1 contract). `itp-gitlab.sh` is sourced AFTER the stubs.
#
# Test-case IDs match docs/test-cases/w-b-itp-gitlab.md.
#
# Run: env -u PROJECT_DIR bash tests/unit/test-itp-gitlab.sh
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ITP_GITLAB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/itp-gitlab.sh"
PAYLOADS="$PROJECT_ROOT/tests/provider-conformance/fixtures/payloads"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      expected: |$expected|"; echo "      actual:   |$actual|"
    FAIL=$((FAIL + 1))
  fi
}
assert_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      needle: |$needle|"; echo "      hay: |${hay:0:300}|"
    FAIL=$((FAIL + 1))
  fi
}
assert_not_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      forbidden needle: |$needle|"; echo "      hay: |${hay:0:300}|"
    FAIL=$((FAIL + 1))
  fi
}
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

[[ -f "$ITP_GITLAB" ]] || { echo "providers/itp-gitlab.sh not found at $ITP_GITLAB"; exit 1; }

# ---------------------------------------------------------------------------
# Stub `_gl_api` + `_gl_urlencode`. Test-local fixtures serve recorded
# payloads and set GL_API_STATUS on every return. Matches the FROZEN #416
# contract: caller passes flags, we honor --method / --tolerate-status /
# --paginate / --body / --max-items / --status-out as they appear.
# ---------------------------------------------------------------------------

# _GL_STUB_ARGV_FILE — every _gl_api invocation appends its argv here (one
# arg per line, blank line between invocations). The tests grep it for
# recorded call shape.
_GL_STUB_ARGV_FILE=""
# _GL_STUB_INV_FILE — file-based invocation counter. Load-bearing under
# nested command-substitution (`list_by_state` → `$(list_comments …)`) —
# a shell-variable counter is scoped to each subshell, so a nested $() call
# would reset the count and re-serve payload #1. The counter lives in a
# file so it survives every subshell boundary.
_GL_STUB_INV_FILE=""
# _GL_STUB_PAYLOAD — file path served on stdout for the next _gl_api call
# (single payload mode). Cleared by the caller between assertions.
_GL_STUB_PAYLOAD=""
# _GL_STUB_PAYLOAD_SEQ — colon-separated file paths, one per invocation
# (multi-page mode). Wins over _GL_STUB_PAYLOAD when set.
_GL_STUB_PAYLOAD_SEQ=""
# _GL_STUB_STATUS — status to set into GL_API_STATUS on next return.
_GL_STUB_STATUS=""
# _GL_STUB_STATUS_SEQ — colon-separated statuses, one per invocation.
_GL_STUB_STATUS_SEQ=""
# _GL_STUB_MODE — "ok" (default) or "fail".
_GL_STUB_MODE="ok"
# _GL_STUB_FAIL_AT — 1-indexed invocation to force-fail (rc≠0, empty stdout).
_GL_STUB_FAIL_AT=""

_gl_stub_reset() {
  _GL_STUB_PAYLOAD=""
  _GL_STUB_PAYLOAD_SEQ=""
  _GL_STUB_STATUS=""
  _GL_STUB_STATUS_SEQ=""
  _GL_STUB_MODE="ok"
  _GL_STUB_FAIL_AT=""
  _GL_STUB_ARGV_FILE="$(mktemp)"
  _GL_STUB_INV_FILE="$(mktemp)"
  printf '0' > "$_GL_STUB_INV_FILE"
  # Set GL_API_STATUS empty so no stale value bleeds across tests.
  GL_API_STATUS=""
}

_gl_api() {
  # File-based invocation counter (subshell-safe — see _GL_STUB_INV_FILE note).
  local _inv
  _inv=$(<"$_GL_STUB_INV_FILE")
  _inv=$((_inv + 1))
  printf '%d' "$_inv" > "$_GL_STUB_INV_FILE"
  # Record argv on its own block.
  if [[ -n "$_GL_STUB_ARGV_FILE" ]]; then
    {
      printf 'CALL %d\n' "$_inv"
      printf 'ARG:%s\n' "$@"
      printf '\n'
    } >> "$_GL_STUB_ARGV_FILE"
  fi
  # Parse --status-out FILE off argv so the stub can honor it (mimics the
  # transport's status-out contract).
  local status_out=""
  local prev=""
  local a
  for a in "$@"; do
    if [[ "$prev" == "--status-out" ]]; then status_out="$a"; break; fi
    prev="$a"
  done
  # Force-fail path.
  if [[ -n "$_GL_STUB_FAIL_AT" && "$_GL_STUB_FAIL_AT" == "$_inv" ]]; then
    GL_API_STATUS="500"
    [[ -n "$status_out" ]] && printf '500' > "$status_out"
    return 1
  fi
  if [[ "$_GL_STUB_MODE" == "fail" ]]; then
    GL_API_STATUS="500"
    [[ -n "$status_out" ]] && printf '500' > "$status_out"
    return 1
  fi
  # Pick this invocation's status.
  local this_status=""
  if [[ -n "$_GL_STUB_STATUS_SEQ" ]]; then
    local -a _seq
    IFS=':' read -r -a _seq <<< "$_GL_STUB_STATUS_SEQ"
    local n=${#_seq[@]}
    local idx=$((_inv - 1))
    (( idx >= n )) && idx=$((n - 1))
    this_status="${_seq[$idx]}"
  else
    this_status="${_GL_STUB_STATUS:-200}"
  fi
  GL_API_STATUS="$this_status"
  [[ -n "$status_out" ]] && printf '%s' "$this_status" > "$status_out"
  # Pick this invocation's payload.
  local this_payload=""
  if [[ -n "$_GL_STUB_PAYLOAD_SEQ" ]]; then
    local -a _pseq
    IFS=':' read -r -a _pseq <<< "$_GL_STUB_PAYLOAD_SEQ"
    local pn=${#_pseq[@]}
    local pidx=$((_inv - 1))
    (( pidx >= pn )) && pidx=$((pn - 1))
    this_payload="${_pseq[$pidx]}"
  else
    this_payload="$_GL_STUB_PAYLOAD"
  fi
  if [[ -n "$this_payload" && -f "$this_payload" ]]; then
    cat "$this_payload"
  fi
  return 0
}

_gl_urlencode() {
  # Faithful `@uri` fold using jq — matches what lib-gitlab-transport.sh's
  # implementation will do. Injection-safe.
  printf '%s' "$1" | jq -Rr '@uri'
}

# Export names used by the leaf.
export GITLAB_PROJECT="group%2Fproject"   # already URL-encoded per §3.4
export GITLAB_HOST="gitlab.com"
export GITLAB_TOKEN="stub-token"
export BOT_LOGIN="my-claw-bot"
export REPO="group/project"
export REPO_OWNER="group"
export REPO_NAME="project"

# Source the leaf AFTER the stubs.
# shellcheck source=../../skills/autonomous-dispatcher/scripts/providers/itp-gitlab.sh
source "$ITP_GITLAB"

set +e

echo "==================================================================="
echo "=== TC-WB-001..006: itp_gitlab_list_by_state shape / sort / project"
echo "==================================================================="

# TC-WB-001: single-page happy path — labels as name-strings, number ascending.
_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-issues-list.json"
out=$(itp_gitlab_list_by_state open autonomous 100 "number,title,labels"); rc=$?
assert_eq "TC-WB-001 rc 0 on happy path" "0" "$rc"
assert_eq "TC-WB-001 sorted ascending by number" "3 5" "$(jq -r '[.[].number] | join(" ")' <<<"$out")"
assert_eq "TC-WB-001 labels are name-strings (already strings in GitLab shape)" \
  '["autonomous"]' "$(jq -c '.[0].labels' <<<"$out")"
assert_eq "TC-WB-001 title is verbatim string" "first issue" "$(jq -r '.[0].title' <<<"$out")"
assert_eq "TC-WB-001 comments key absent when not requested (fields-subset)" \
  "0" "$(jq '[.[] | select(has("comments"))] | length' <<<"$out")"

# TC-WB-003: STATE mapping — assert the query string carries `state=opened`.
_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-issues-list.json"
_ignored=$(itp_gitlab_list_by_state open autonomous 100 "number") || true
argv=$(cat "$_GL_STUB_ARGV_FILE")
assert_contains "TC-WB-003 open → state=opened in URL" "state=opened" "$argv"
_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-issues-list.json"
_ignored=$(itp_gitlab_list_by_state closed autonomous 100 "number") || true
argv=$(cat "$_GL_STUB_ARGV_FILE")
assert_contains "TC-WB-003 closed → state=closed in URL" "state=closed" "$argv"
_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-issues-list.json"
_ignored=$(itp_gitlab_list_by_state all autonomous 100 "number") || true
argv=$(cat "$_GL_STUB_ARGV_FILE")
assert_contains "TC-WB-003 all → state=all in URL" "state=all" "$argv"
# Labels-and-CSV lands on the query string as native AND.
assert_contains "TC-WB-003 labels-and-CSV → labels= arm" "labels=autonomous" "$argv"
# --paginate present + --max-items honored.
assert_contains "TC-WB-003 --paginate present" "ARG:--paginate" "$argv"
assert_contains "TC-WB-003 --max-items honored" "ARG:--max-items" "$argv"

# TC-WB-006: FIELDS_CSV projects EXACTLY the requested keys.
_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-issues-list.json"
out=$(itp_gitlab_list_by_state open autonomous 100 "number") || true
assert_eq "TC-WB-006 FIELDS=number → single key" \
  "number" "$(jq -r '.[0] | keys_unsorted | join(",")' <<<"$out")"
_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-issues-list.json"
out=$(itp_gitlab_list_by_state open autonomous 100 "number,labels") || true
assert_eq "TC-WB-006 FIELDS=number,labels → exactly those two keys" \
  "number,labels" "$(jq -r '.[0] | keys_unsorted | join(",")' <<<"$out")"

# [#435] TC-WB-007: assignees field — array of username strings, [] when
# unassigned, absent when not requested (projection honesty).
_gl_stub_reset
assignees_pl=$(mktemp)
cat > "$assignees_pl" <<'JSON'
[
  {"iid": 5, "id": 500005, "title": "second issue", "description": "body five", "state": "opened", "labels": ["autonomous"], "assignees": [{"username": "alice"}, {"username": "bob"}]},
  {"iid": 3, "id": 500003, "title": "first issue", "description": "body three", "state": "opened", "labels": ["autonomous"], "assignees": []}
]
JSON
_GL_STUB_PAYLOAD="$assignees_pl"
out=$(itp_gitlab_list_by_state open autonomous 100 "number,assignees") || true
assert_eq "TC-WB-007 assignees requested → array of username strings" \
  '["alice","bob"]' "$(jq -c '.[1].assignees' <<<"$out")"
assert_eq "TC-WB-007 unassigned issue → assignees: [] (never null)" \
  '[]' "$(jq -c '.[0].assignees' <<<"$out")"
_gl_stub_reset
_GL_STUB_PAYLOAD="$assignees_pl"
out=$(itp_gitlab_list_by_state open autonomous 100 "number,labels") || true
assert_eq "TC-WB-007 assignees NOT requested → key absent from every row" \
  "0" "$(jq '[.[] | select(has("assignees"))] | length' <<<"$out")"
rm -f "$assignees_pl"

# TC-WB-004: multi-page merge — the transport is responsible for merging, so
# the leaf gets a MERGED array from the stub. Prove the leaf just consumes
# a longer merged array.
_gl_stub_reset
merged=$(mktemp)
jq -s 'add' "$PAYLOADS/gitlab-issues-list-p1.json" "$PAYLOADS/gitlab-issues-list-p2.json" > "$merged"
_GL_STUB_PAYLOAD="$merged"
out=$(itp_gitlab_list_by_state open autonomous 100 "number") || true
assert_eq "TC-WB-004 merged multi-page → length 4" "4" "$(jq 'length' <<<"$out")"
assert_eq "TC-WB-004 merged multi-page preserves ascending number sort" \
  "1 2 3 4" "$(jq -r '[.[].number] | join(" ")' <<<"$out")"
rm -f "$merged"

# TC-WB-005: mid-walk fail — _gl_api rc≠0 → leaf rc≠0, no partial stdout.
_gl_stub_reset
_GL_STUB_MODE="fail"
out=$(itp_gitlab_list_by_state open autonomous 100 "number" 2>/dev/null); rc=$?
assert_eq "TC-WB-005 mid-walk fail → non-zero rc" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert_eq "TC-WB-005 mid-walk fail → no partial stdout" "" "$out"

# Empty enumeration → [] (never null).
_gl_stub_reset
empty=$(mktemp); echo '[]' > "$empty"
_GL_STUB_PAYLOAD="$empty"
out=$(itp_gitlab_list_by_state open autonomous 100 "number") || true
assert_eq "empty enumeration → []" "[]" "$out"
rm -f "$empty"

# TC-WB-002: FIELDS includes comments → the leaf calls _gl_api again (once
# per issue) to fetch notes; those get folded in as the [INV-90] array.
_gl_stub_reset
# Build a 2-issue enumeration payload + a per-issue notes payload.
enum2=$(mktemp)
cat > "$enum2" <<'JSON'
[
  {"iid": 10, "id": 5000010, "title": "t10", "description": "", "state": "opened", "labels": ["autonomous"]},
  {"iid": 11, "id": 5000011, "title": "t11", "description": "", "state": "opened", "labels": ["autonomous"]}
]
JSON
notes=$(mktemp)
cat > "$notes" <<'JSON'
[
  {"id": 100, "body": "hi", "author": {"username": "alice"}, "system": false, "created_at": "2026-05-01T00:00:00.000Z"}
]
JSON
# 3 invocations: enum + 2 note lists.
_GL_STUB_PAYLOAD_SEQ="$enum2:$notes:$notes"
out=$(itp_gitlab_list_by_state open autonomous 100 "number,comments") || true
assert_eq "TC-WB-002 both issues carry comments arrays" "2" "$(jq '[.[].comments | length] | add' <<<"$out")"
assert_eq "TC-WB-002 comment shape has INV-90 author field" "alice" "$(jq -r '.[0].comments[0].author' <<<"$out")"
rm -f "$enum2" "$notes"

echo ""
echo "==================================================================="
echo "=== TC-WB-010..011: itp_gitlab_count_by_state (integer)"
echo "==================================================================="

_gl_stub_reset
# Fixture with 3 label sets — any-of=in-progress,reviewing picks 2 of 3.
pl=$(mktemp)
cat > "$pl" <<'JSON'
[
  {"iid": 1, "id": 1, "title": "", "description": "", "state": "opened", "labels": ["in-progress"]},
  {"iid": 2, "id": 2, "title": "", "description": "", "state": "opened", "labels": ["reviewing"]},
  {"iid": 3, "id": 3, "title": "", "description": "", "state": "opened", "labels": ["pending-review"]}
]
JSON
_GL_STUB_PAYLOAD="$pl"
out=$(itp_gitlab_count_by_state open autonomous 100 "in-progress,reviewing") || true
assert_eq "TC-WB-010 any-of matches 2 of 3" "2" "$out"
_gl_stub_reset
_GL_STUB_PAYLOAD="$pl"
out=$(itp_gitlab_count_by_state open autonomous 100 "") || true
assert_eq "TC-WB-010 empty any-of → count all matches" "3" "$out"
rm -f "$pl"

# TC-WB-011 fail-CLOSED.
_gl_stub_reset
_GL_STUB_MODE="fail"
out=$(itp_gitlab_count_by_state open autonomous 100 "" 2>/dev/null); rc=$?
assert_eq "TC-WB-011 fail-CLOSED → non-zero rc" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert_eq "TC-WB-011 fail-CLOSED → no partial stdout" "" "$out"

echo ""
echo "==================================================================="
echo "=== TC-WB-020..021: itp_gitlab_list_forbidden_combos"
echo "==================================================================="

_gl_stub_reset
pl=$(mktemp)
cat > "$pl" <<'JSON'
[
  {"iid": 1, "id": 1, "title": "", "description": "", "state": "opened", "labels": ["approved", "in-progress"], "assignees": [{"username": "alice"}]},
  {"iid": 2, "id": 2, "title": "", "description": "", "state": "opened", "labels": ["autonomous"], "assignees": []},
  {"iid": 3, "id": 3, "title": "", "description": "", "state": "opened", "labels": ["stalled", "pending-dev"], "assignees": []},
  {"iid": 4, "id": 4, "title": "", "description": "", "state": "opened", "labels": ["approved"], "assignees": []}
]
JSON
_GL_STUB_PAYLOAD="$pl"
out=$(itp_gitlab_list_forbidden_combos open autonomous 100) || true
assert_eq "TC-WB-020 filters to mixed-combo issues (1 and 3)" \
  "1 3" "$(jq -r '[.[].number] | join(" ")' <<<"$out")"
assert_eq "[#435] TC-WB-020 output fields are exactly number,labels,assignees" \
  "number,labels,assignees" "$(jq -r '.[0] | keys_unsorted | join(",")' <<<"$out")"
assert_eq "[#435] TC-WB-020 assignees normalized to username-string array" \
  '["alice"]' "$(jq -c '.[0].assignees' <<<"$out")"
assert_eq "[#435] TC-WB-020 unassigned combo row → assignees: [] (never null)" \
  '[]' "$(jq -c '.[1].assignees' <<<"$out")"
rm -f "$pl"

_gl_stub_reset
_GL_STUB_MODE="fail"
out=$(itp_gitlab_list_forbidden_combos open autonomous 100 2>/dev/null); rc=$?
assert_eq "TC-WB-021 fail-CLOSED → non-zero rc" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert_eq "TC-WB-021 fail-CLOSED → no partial stdout" "" "$out"

echo ""
echo "==================================================================="
echo "=== TC-WB-030..033: itp_gitlab_transition_state"
echo "==================================================================="

# TC-WB-030 single-label per side — one PUT with combined body.
_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-transition-put.json"
itp_gitlab_transition_state 42 "in-progress" "reviewing"; rc=$?
assert_eq "TC-WB-030 rc 0 on happy PUT" "0" "$rc"
argv=$(cat "$_GL_STUB_ARGV_FILE")
assert_contains "TC-WB-030 --method PUT" "ARG:PUT" "$argv"
assert_contains "TC-WB-030 target path issues/:iid" "ARG:/projects/${GITLAB_PROJECT}/issues/42" "$argv"
# Extract the --body arg (line after "ARG:--body") and check it carries both keys.
body_line=$(awk '/^ARG:--body$/{getline; print; exit}' "$_GL_STUB_ARGV_FILE")
body_json="${body_line#ARG:}"
assert_eq "TC-WB-030 body has add_labels=reviewing" "reviewing" "$(jq -r '.add_labels' <<<"$body_json")"
assert_eq "TC-WB-030 body has remove_labels=in-progress" "in-progress" "$(jq -r '.remove_labels' <<<"$body_json")"

# TC-WB-031 multi-label CSV — one PUT, both sides carry CSV verbatim.
_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-transition-put.json"
itp_gitlab_transition_state 42 "in-progress,pending-dev" "reviewing" || true
argv=$(cat "$_GL_STUB_ARGV_FILE")
# Exactly ONE call — grep for CALL count.
call_count=$(grep -c '^CALL ' "$_GL_STUB_ARGV_FILE")
assert_eq "TC-WB-031 exactly one PUT (atomic)" "1" "$call_count"
body_line=$(awk '/^ARG:--body$/{getline; print; exit}' "$_GL_STUB_ARGV_FILE")
body_json="${body_line#ARG:}"
assert_eq "TC-WB-031 CSV remove_labels passes through" \
  "in-progress,pending-dev" "$(jq -r '.remove_labels' <<<"$body_json")"

# TC-WB-032 empty side omits its key entirely.
_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-transition-put.json"
itp_gitlab_transition_state 42 "" "reviewing" || true
body_line=$(awk '/^ARG:--body$/{getline; print; exit}' "$_GL_STUB_ARGV_FILE")
body_json="${body_line#ARG:}"
assert_eq "TC-WB-032 empty REMOVE → no remove_labels key" \
  "0" "$(jq 'has("remove_labels") | if . then 1 else 0 end' <<<"$body_json")"
assert_eq "TC-WB-032 empty REMOVE → add_labels present" \
  "1" "$(jq 'has("add_labels") | if . then 1 else 0 end' <<<"$body_json")"

_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-transition-put.json"
itp_gitlab_transition_state 42 "in-progress" "" || true
body_line=$(awk '/^ARG:--body$/{getline; print; exit}' "$_GL_STUB_ARGV_FILE")
body_json="${body_line#ARG:}"
assert_eq "TC-WB-032 empty ADD → no add_labels key" \
  "0" "$(jq 'has("add_labels") | if . then 1 else 0 end' <<<"$body_json")"
assert_eq "TC-WB-032 empty ADD → remove_labels present" \
  "1" "$(jq 'has("remove_labels") | if . then 1 else 0 end' <<<"$body_json")"

# TC-WB-033 fail-CLOSED.
_gl_stub_reset
_GL_STUB_MODE="fail"
itp_gitlab_transition_state 42 "a" "b" 2>/dev/null; rc=$?
assert_eq "TC-WB-033 fail-CLOSED → non-zero rc" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"

echo ""
echo "==================================================================="
echo "=== TC-WB-040..044: itp_gitlab_read_task"
echo "==================================================================="

# TC-WB-040 basic normalization.
_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-issue-view.json"
out=$(itp_gitlab_read_task 42 "title,body,state,labels") || true
assert_eq "TC-WB-040 title verbatim" "example task" "$(jq -r '.title' <<<"$out")"
assert_eq "TC-WB-040 description→body rename" "task body here" "$(jq -r '.body' <<<"$out")"
assert_eq "TC-WB-040 state normalizes opened→OPEN" "OPEN" "$(jq -r '.state' <<<"$out")"
assert_eq "TC-WB-040 labels are name-strings" \
  '["autonomous","in-progress"]' "$(jq -c '.labels' <<<"$out")"

# TC-WB-041 absent body → "".
_gl_stub_reset
pl=$(mktemp); cat > "$pl" <<'JSON'
{"iid": 42, "title": "t", "state": "opened", "labels": []}
JSON
_GL_STUB_PAYLOAD="$pl"
out=$(itp_gitlab_read_task 42 "body") || true
assert_eq "TC-WB-041 absent body → empty string" "" "$(jq -r '.body' <<<"$out")"
rm -f "$pl"

# TC-WB-041b [INV-138] author → .author.username, absent → "".
_gl_stub_reset
pl=$(mktemp); cat > "$pl" <<'JSON'
{"iid": 42, "title": "t", "description": "b", "state": "opened", "labels": [], "author": {"username": "gl-filer"}}
JSON
_GL_STUB_PAYLOAD="$pl"
out=$(itp_gitlab_read_task 42 "author") || true
assert_eq "TC-WB-041b author → .author.username" "gl-filer" "$(jq -r '.author' <<<"$out")"
rm -f "$pl"
_gl_stub_reset
pl=$(mktemp); cat > "$pl" <<'JSON'
{"iid": 42, "title": "t", "state": "opened", "labels": []}
JSON
_GL_STUB_PAYLOAD="$pl"
out=$(itp_gitlab_read_task 42 "author") || true
assert_eq "TC-WB-041b absent author → empty string" "" "$(jq -r '.author' <<<"$out")"
rm -f "$pl"

# TC-WB-042 comments requested → same-tick list_comments folds INV-90 array.
_gl_stub_reset
notes=$(mktemp); cat > "$notes" <<'JSON'
[
  {"id": 100, "body": "hi", "author": {"username": "alice"}, "system": false, "created_at": "2026-05-01T00:00:00.000Z"}
]
JSON
_GL_STUB_PAYLOAD_SEQ="$PAYLOADS/gitlab-issue-view.json:$notes"
out=$(itp_gitlab_read_task 42 "title,comments") || true
assert_eq "TC-WB-042 comments folded from list_comments call" "alice" "$(jq -r '.comments[0].author' <<<"$out")"
assert_eq "TC-WB-042 comment has INV-90 body key" "hi" "$(jq -r '.comments[0].body' <<<"$out")"
rm -f "$notes"

# TC-WB-043 fields subset — body-only.
_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-issue-view.json"
out=$(itp_gitlab_read_task 42 "body") || true
assert_eq "TC-WB-043 body-only → exactly one key" \
  "body" "$(jq -r 'keys_unsorted | join(",")' <<<"$out")"

# TC-WB-044 fail-CLOSED (transport rc≠0 AND empty stdout).
_gl_stub_reset
_GL_STUB_MODE="fail"
out=$(itp_gitlab_read_task 42 "body" 2>/dev/null); rc=$?
assert_eq "TC-WB-044 transport fail → non-zero rc" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
_gl_stub_reset
empty=$(mktemp); : > "$empty"
_GL_STUB_PAYLOAD="$empty"
out=$(itp_gitlab_read_task 42 "body" 2>/dev/null); rc=$?
assert_eq "TC-WB-044 empty stdout → non-zero rc" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
rm -f "$empty"

echo ""
echo "==================================================================="
echo "=== TC-WB-050..052: itp_gitlab_post_comment"
echo "==================================================================="

_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-post-note.json"
itp_gitlab_post_comment 42 "hello world"; rc=$?
assert_eq "TC-WB-050 rc 0" "0" "$rc"
argv=$(cat "$_GL_STUB_ARGV_FILE")
assert_contains "TC-WB-050 --method POST" "ARG:POST" "$argv"
assert_contains "TC-WB-050 target path issues/:iid/notes" "ARG:/projects/${GITLAB_PROJECT}/issues/42/notes" "$argv"
body_line=$(awk '/^ARG:--body$/{getline; print; exit}' "$_GL_STUB_ARGV_FILE")
body_json="${body_line#ARG:}"
assert_eq "TC-WB-050 body has body=hello world" "hello world" "$(jq -r '.body' <<<"$body_json")"

# TC-WB-051 marker round-trip.
_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-post-note.json"
marker='<!-- dispatcher-token: abc-123 -->'
itp_gitlab_post_comment 42 "$marker" || true
body_line=$(awk '/^ARG:--body$/{getline; print; exit}' "$_GL_STUB_ARGV_FILE")
body_json="${body_line#ARG:}"
assert_eq "TC-WB-051 HTML marker survives jq --arg" "$marker" "$(jq -r '.body' <<<"$body_json")"

# TC-WB-052 fail-CLOSED.
_gl_stub_reset
_GL_STUB_MODE="fail"
itp_gitlab_post_comment 42 "hi" 2>/dev/null; rc=$?
assert_eq "TC-WB-052 fail-CLOSED → non-zero rc" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"

echo ""
echo "==================================================================="
echo "=== TC-WB-060..061: itp_gitlab_edit_comment"
echo "==================================================================="

_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-post-note.json"
itp_gitlab_edit_comment 42 1001 "revised body"; rc=$?
assert_eq "TC-WB-060 rc 0" "0" "$rc"
argv=$(cat "$_GL_STUB_ARGV_FILE")
assert_contains "TC-WB-060 --method PUT" "ARG:PUT" "$argv"
assert_contains "TC-WB-060 path issues/:iid/notes/:note_id" \
  "ARG:/projects/${GITLAB_PROJECT}/issues/42/notes/1001" "$argv"
body_line=$(awk '/^ARG:--body$/{getline; print; exit}' "$_GL_STUB_ARGV_FILE")
body_json="${body_line#ARG:}"
assert_eq "TC-WB-060 body payload has body=revised body" "revised body" "$(jq -r '.body' <<<"$body_json")"

# TC-WB-061 fail-CLOSED.
_gl_stub_reset
_GL_STUB_MODE="fail"
itp_gitlab_edit_comment 42 1001 "x" 2>/dev/null; rc=$?
assert_eq "TC-WB-061 fail-CLOSED → non-zero rc" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"

echo ""
echo "==================================================================="
echo "=== TC-WB-070..074: itp_gitlab_list_comments"
echo "==================================================================="

# TC-WB-070/071/072 — full fixture covers system-note filter + authorKind
# derivation for all three arms.
_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-notes-list.json"
out=$(itp_gitlab_list_comments 42) || true
argv=$(cat "$_GL_STUB_ARGV_FILE")
assert_contains "TC-WB-070 --paginate on notes list" "ARG:--paginate" "$argv"
assert_contains "TC-WB-070 sort=asc&order_by=created_at present" \
  "sort=asc&order_by=created_at" "$argv"
# TC-WB-071: system note (id 1002) is filtered out (3 kept of 4 total).
assert_eq "TC-WB-071 system-notes filtered → 3 comments" "3" "$(jq 'length' <<<"$out")"
assert_eq "TC-WB-071 the filtered id (1002) is absent" \
  "0" "$(jq '[.[] | select(.id == 1002)] | length' <<<"$out")"
# TC-WB-072 authorKind derivation.
assert_eq "TC-WB-072 human author → human" "human" "$(jq -r '.[] | select(.id == 1001).authorKind' <<<"$out")"
assert_eq "TC-WB-072 project bot author → bot" "bot" "$(jq -r '.[] | select(.id == 1003).authorKind' <<<"$out")"
assert_eq "TC-WB-072 BOT_LOGIN match → self" "self" "$(jq -r '.[] | select(.id == 1004).authorKind' <<<"$out")"
# Author verbatim.
assert_eq "TC-WB-072 author is .author.username verbatim" "project_42_bot_abc123" \
  "$(jq -r '.[] | select(.id == 1003).author' <<<"$out")"

# TC-WB-073 fail-CLOSED.
_gl_stub_reset
_GL_STUB_MODE="fail"
out=$(itp_gitlab_list_comments 42 2>/dev/null); rc=$?
assert_eq "TC-WB-073 fail-CLOSED → non-zero rc" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"

# TC-WB-074 sort tie-break — same createdAt, ascending id.
_gl_stub_reset
tie=$(mktemp); cat > "$tie" <<'JSON'
[
  {"id": 200, "body": "y", "author": {"username": "u"}, "system": false, "created_at": "2026-06-01T00:00:00.000Z"},
  {"id": 100, "body": "x", "author": {"username": "u"}, "system": false, "created_at": "2026-06-01T00:00:00.000Z"}
]
JSON
_GL_STUB_PAYLOAD="$tie"
out=$(itp_gitlab_list_comments 42) || true
assert_eq "TC-WB-074 tie-break by ascending id" "100 200" "$(jq -r '[.[].id] | join(" ")' <<<"$out")"
rm -f "$tie"

# TC-WB-075 fail-CLOSED on rc-0 EMPTY stdout — a bare `_gl_api | jq` pipe
# would let jq emit `[]` on empty input (real "no comments" and silent
# transport failure become indistinguishable). Leaf must capture-then-check.
_gl_stub_reset
empty=$(mktemp); : > "$empty"
_GL_STUB_PAYLOAD="$empty"
out=$(itp_gitlab_list_comments 42 2>/dev/null); rc=$?
assert_eq "TC-WB-075 rc-0 empty stdout → non-zero rc (fail-CLOSED, not silent [])" \
  "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert_eq "TC-WB-075 rc-0 empty stdout → no partial stdout" "" "$out"
rm -f "$empty"

# TC-WB-076 fail-CLOSED on rc-0 NON-ARRAY shape — a transport-hook oddity
# returning `{}` or an error-shaped object must not slip past jq's `.[]` as
# a silent `[]`. Matches the W1c2 online-review r2 discipline on the CHP
# side (chp_list_inline_comments non-array-page gate).
_gl_stub_reset
obj=$(mktemp); echo '{"message":"Not Found"}' > "$obj"
_GL_STUB_PAYLOAD="$obj"
out=$(itp_gitlab_list_comments 42 2>/dev/null); rc=$?
assert_eq "TC-WB-076 rc-0 object payload → non-zero rc" \
  "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert_eq "TC-WB-076 rc-0 object payload → no partial stdout" "" "$out"
rm -f "$obj"

# The literal empty-array `[]` payload is a LEGITIMATE "zero comments"
# response and MUST NOT trip fail-CLOSED — leaf returns `[]` rc 0.
_gl_stub_reset
empty_arr=$(mktemp); echo '[]' > "$empty_arr"
_GL_STUB_PAYLOAD="$empty_arr"
out=$(itp_gitlab_list_comments 42); rc=$?
assert_eq "TC-WB-076b legitimate empty-array → rc 0" "0" "$rc"
assert_eq "TC-WB-076b legitimate empty-array → []" "[]" "$out"
rm -f "$empty_arr"

echo ""
echo "==================================================================="
echo "=== TC-WB-080..082: itp_gitlab_resolve_dep"
echo "==================================================================="

# TC-WB-080 slash-bearing group path, closed state → CLOSED (uppercase).
# Out-var is the literal `state`, matching the real call site
# (lib-dispatch.sh's check_deps_resolved) — see #439 / itp-gitlab.sh's
# itp_gitlab_resolve_dep header comment for why that name matters here.
_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-issue-view-crossproj.json"
itp_gitlab_resolve_dep "group/subgroup/project" 99 state
assert_eq "TC-WB-080 slash-bearing path encoded via _gl_urlencode" \
  "CLOSED" "$state"
argv=$(cat "$_GL_STUB_ARGV_FILE")
# _gl_urlencode replaces / with %2F.
assert_contains "TC-WB-080 encoded path used in URL" \
  "ARG:/projects/group%2Fsubgroup%2Fproject/issues/99" "$argv"

# opened → OPEN.
_gl_stub_reset
pl=$(mktemp); cat > "$pl" <<'JSON'
{"iid": 99, "state": "opened"}
JSON
_GL_STUB_PAYLOAD="$pl"
itp_gitlab_resolve_dep "g/p" 99 state
assert_eq "TC-WB-080 opened → OPEN" "OPEN" "$state"
rm -f "$pl"

# TC-WB-081 fail-SOFT (rc 0 with empty out-var on transport failure).
_gl_stub_reset
_GL_STUB_MODE="fail"
state="preserved"
itp_gitlab_resolve_dep "g/p" 99 state; rc=$?
assert_eq "TC-WB-081 fail-SOFT rc 0" "0" "$rc"
assert_eq "TC-WB-081 fail-SOFT empty out-var" "" "$state"

# TC-WB-082 [INV-83] simplification — no `_DEP_TOKEN_CACHE` declaration or
# actual index access; no source of gh-app-token. (Doc-comment mentions of
# the identifier are fine — this is a code-behavior check, not a
# text-scrub.) Grep for real code shapes: `declare … _DEP_TOKEN_CACHE`,
# `_DEP_TOKEN_CACHE[…]`, `unset _DEP_TOKEN_CACHE`, `source … gh-app-token`,
# and a `get_gh_app_scoped_token …` call site (not the identifier alone).
if grep -qE 'declare[[:space:]]+-[gAaix]+[[:space:]]+_DEP_TOKEN_CACHE|_DEP_TOKEN_CACHE\[|unset[[:space:]]+_DEP_TOKEN_CACHE' "$ITP_GITLAB"; then
  bad "TC-WB-082 [INV-83] simplification: _DEP_TOKEN_CACHE code shape detected in itp-gitlab.sh"
else
  ok "TC-WB-082 [INV-83] simplification: no _DEP_TOKEN_CACHE code (declaration/index/unset) in itp-gitlab.sh"
fi
# get_gh_app_scoped_token is a bash function name — its use is either
# `declare -F get_gh_app_scoped_token …` (guard) or a bare-name call at
# start-of-word. Both are grep-visible; a doc comment naming the function
# would trip too, but the itp-gitlab.sh leaf has no legitimate reason to
# mention it at all (the [INV-83] simplification excludes even the
# reference), so a plain literal grep is honest here.
if grep -qE '\bget_gh_app_scoped_token\b' "$ITP_GITLAB"; then
  bad "TC-WB-082 no per-project token mint: unexpected get_gh_app_scoped_token reference in itp-gitlab.sh"
else
  ok "TC-WB-082 no per-project token mint (GitLab single-token spans all projects)"
fi

echo ""
echo "==================================================================="
echo "=== TC-WB-090..091: itp_gitlab_mark_checkbox"
echo "==================================================================="

_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-transition-put.json"
itp_gitlab_mark_checkbox 42 "- [x] done"; rc=$?
assert_eq "TC-WB-090 rc 0" "0" "$rc"
argv=$(cat "$_GL_STUB_ARGV_FILE")
assert_contains "TC-WB-090 --method PUT" "ARG:PUT" "$argv"
assert_contains "TC-WB-090 path /projects/…/issues/:iid" \
  "ARG:/projects/${GITLAB_PROJECT}/issues/42" "$argv"
body_line=$(awk '/^ARG:--body$/{getline; print; exit}' "$_GL_STUB_ARGV_FILE")
body_json="${body_line#ARG:}"
assert_eq "TC-WB-090 body has description key" "- [x] done" "$(jq -r '.description' <<<"$body_json")"

# TC-WB-091 fail-CLOSED.
_gl_stub_reset
_GL_STUB_MODE="fail"
itp_gitlab_mark_checkbox 42 "x" 2>/dev/null; rc=$?
assert_eq "TC-WB-091 fail-CLOSED → non-zero rc" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"

echo ""
echo "==================================================================="
echo "=== TC-WB-100..104: itp_gitlab_provision_states (idempotent probe/create)"
echo "==================================================================="

# TC-WB-100 existence probe hits GL_API_STATUS=200 → skip.
_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-labels-view.json"
_GL_STUB_STATUS="200"
out=$(itp_gitlab_provision_states "autonomous" "ededed" "d"); rc=$?
assert_eq "TC-WB-100 rc 0 on skip branch" "0" "$rc"
assert_contains "TC-WB-100 [skip] emitted" "[skip]" "$out"
# Assert exactly one call was made — no POST.
call_count=$(grep -c '^CALL ' "$_GL_STUB_ARGV_FILE")
assert_eq "TC-WB-100 exactly one call (probe only)" "1" "$call_count"

# TC-WB-101 probe 404 → create → GL_API_STATUS=201 → [created].
_gl_stub_reset
missing=$(mktemp); echo '{"message":"404 Label Not Found"}' > "$missing"
_GL_STUB_PAYLOAD_SEQ="$missing:$PAYLOADS/gitlab-labels-create.json"
_GL_STUB_STATUS_SEQ="404:201"
out=$(itp_gitlab_provision_states "new-label" "ededed" "d"); rc=$?
assert_eq "TC-WB-101 rc 0 on create branch" "0" "$rc"
assert_contains "TC-WB-101 [created] emitted" "[created]" "$out"
call_count=$(grep -c '^CALL ' "$_GL_STUB_ARGV_FILE")
assert_eq "TC-WB-101 exactly two calls (probe + create)" "2" "$call_count"
# Assert the CREATE call carried --tolerate-status 409 and POST.
argv=$(cat "$_GL_STUB_ARGV_FILE")
assert_contains "TC-WB-101 create is POST" "ARG:POST" "$argv"
assert_contains "TC-WB-101 create has --tolerate-status 409" "ARG:409" "$argv"
# Color-format normalization: `setup-labels.sh` passes bare 6-hex (`ededed`),
# but GitLab's /labels API rejects it with HTTP 400. The leaf normalizes to
# `#ededed` in the POSTED body. Assert the recorded --body arg carries the
# `#`-prefixed form (the second `ARG:--body` in the argv trace — the first
# is the probe which has NO --body).
create_body_line=$(awk '/^CALL 2$/,/^$/{ if (prev=="ARG:--body") { print; exit } prev=$0 }' "$_GL_STUB_ARGV_FILE")
create_body_json="${create_body_line#ARG:}"
assert_eq "TC-WB-101 posted color is #-prefixed (GitLab /labels requires #RRGGBB)" \
  "#ededed" "$(jq -r '.color' <<<"$create_body_json")"
rm -f "$missing"

# TC-WB-101b already-#-prefixed color passes through unchanged (idempotent
# normalizer — a caller that already conformed to GitLab's shape isn't
# mangled).
_gl_stub_reset
missing=$(mktemp); echo '{"message":"404 Label Not Found"}' > "$missing"
_GL_STUB_PAYLOAD_SEQ="$missing:$PAYLOADS/gitlab-labels-create.json"
_GL_STUB_STATUS_SEQ="404:201"
out=$(itp_gitlab_provision_states "new-label" "#0E8A16" "d"); rc=$?
create_body_line=$(awk '/^CALL 2$/,/^$/{ if (prev=="ARG:--body") { print; exit } prev=$0 }' "$_GL_STUB_ARGV_FILE")
create_body_json="${create_body_line#ARG:}"
assert_eq "TC-WB-101b already-#-prefixed color passes through" \
  "#0E8A16" "$(jq -r '.color' <<<"$create_body_json")"
rm -f "$missing"

# TC-WB-102 concurrent race — 404 probe, 409 create → downgrade to [skip].
_gl_stub_reset
missing=$(mktemp); echo '{"message":"404 Label Not Found"}' > "$missing"
race=$(mktemp); echo '{"message":"Label already exists"}' > "$race"
_GL_STUB_PAYLOAD_SEQ="$missing:$race"
_GL_STUB_STATUS_SEQ="404:409"
out=$(itp_gitlab_provision_states "raced" "ededed" "d"); rc=$?
assert_eq "TC-WB-102 rc 0 on race downgrade" "0" "$rc"
assert_contains "TC-WB-102 409 race → [skip]" "[skip]" "$out"
rm -f "$missing" "$race"

# TC-WB-103 transport rc≠0 (untolerated) → leaf rc≠0.
_gl_stub_reset
_GL_STUB_MODE="fail"
itp_gitlab_provision_states "x" "y" "z" 2>/dev/null; rc=$?
assert_eq "TC-WB-103 transport fail → non-zero rc" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"

# TC-WB-104 idempotency — two back-to-back invocations.
_gl_stub_reset
_GL_STUB_PAYLOAD_SEQ="$PAYLOADS/gitlab-labels-view.json:$PAYLOADS/gitlab-labels-view.json"
_GL_STUB_STATUS_SEQ="200:200"
out1=$(itp_gitlab_provision_states "autonomous" "ededed" "d")
out2=$(itp_gitlab_provision_states "autonomous" "ededed" "d")
assert_contains "TC-WB-104 invocation 1 → [skip]" "[skip]" "$out1"
assert_contains "TC-WB-104 invocation 2 → [skip]" "[skip]" "$out2"

echo ""
echo "==================================================================="
echo "=== TC-WB-110..113: itp_gitlab_label_event_ts"
echo "==================================================================="

# TC-WB-110 newest matching event.
_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-resource-label-events.json"
out=$(itp_gitlab_label_event_ts 42 "pending-review") || true
argv=$(cat "$_GL_STUB_ARGV_FILE")
assert_contains "TC-WB-110 --paginate present" "ARG:--paginate" "$argv"
assert_contains "TC-WB-110 endpoint issues/:iid/resource_label_events" \
  "ARG:/projects/${GITLAB_PROJECT}/issues/42/resource_label_events" "$argv"
# The fixture has TWO `add` events for pending-review (9003 @ 04-03, 9004 @ 04-05).
# Leaf's `sort_by(.created_at)` returns the NEWEST via .[-1]; but the impl uses .[0]
# after sort, which is OLDEST — the spec says "FIRST `labeled` event", so oldest.
assert_eq "TC-WB-110 emits the FIRST (earliest) matching created_at" \
  "2026-04-03T00:00:00.000Z" "$out"

removal_fixture=$(mktemp)
cat > "$removal_fixture" <<'JSON'
[
  {"id":9101,"action":"remove","label":{"name":"stalled"},"created_at":"2026-04-06T00:00:00.000Z"},
  {"id":9102,"action":"remove","label":{"name":"stalled"},"created_at":"2026-04-08T00:00:00.000Z"},
  {"id":9103,"action":"remove","label":{"name":"other"},"created_at":"2026-04-09T00:00:00.000Z"}
]
JSON
_gl_stub_reset
_GL_STUB_PAYLOAD="$removal_fixture"
out=$(itp_gitlab_label_event_ts 42 "stalled" latest-removed) || true
assert_eq "TC-WB-110b latest-removed emits newest matching removal" \
  "2026-04-08T00:00:00.000Z" "$out"
rm -f "$removal_fixture"

# TC-WB-111 no matching event → empty stdout, rc 0.
_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-resource-label-events.json"
out=$(itp_gitlab_label_event_ts 42 "nonexistent-label"); rc=$?
assert_eq "TC-WB-111 no match rc 0" "0" "$rc"
assert_eq "TC-WB-111 no match empty stdout" "" "$out"

# TC-WB-112 fail-SOFT on transport rc≠0.
_gl_stub_reset
_GL_STUB_MODE="fail"
out=$(itp_gitlab_label_event_ts 42 "anything"); rc=$?
assert_eq "TC-WB-112 fail-SOFT rc 0" "0" "$rc"
assert_eq "TC-WB-112 fail-SOFT empty stdout" "" "$out"

# TC-WB-113: multi-page — spec says "paginated"; transport merges pages so
# leaf sees a single merged array. Prove a match found on page 2 (i.e.
# further down the merged array) still surfaces correctly.
_gl_stub_reset
p1=$(mktemp); cat > "$p1" <<'JSON'
[{"id": 8001, "action": "add", "label": {"name": "other"}, "created_at": "2026-03-01T00:00:00.000Z"}]
JSON
p2=$(mktemp); cat > "$p2" <<'JSON'
[{"id": 8002, "action": "add", "label": {"name": "target"}, "created_at": "2026-03-05T00:00:00.000Z"}]
JSON
merged=$(mktemp)
jq -s 'add' "$p1" "$p2" > "$merged"
_GL_STUB_PAYLOAD="$merged"
out=$(itp_gitlab_label_event_ts 42 "target") || true
assert_eq "TC-WB-113 multi-page match on later page still surfaces" \
  "2026-03-05T00:00:00.000Z" "$out"
rm -f "$p1" "$p2" "$merged"

echo ""
echo "==================================================================="
echo "=== TC-WB-120: itp_gitlab_begin_tick (no-op)"
echo "==================================================================="

_gl_stub_reset
itp_gitlab_begin_tick; rc=$?
assert_eq "TC-WB-120 begin_tick returns rc 0" "0" "$rc"
# `grep -c` prints "0" and exits 1 on zero matches; capture stdout only
# (the || fallback appended a second "0", producing "0\n0" — spurious).
call_count=$(grep -c '^CALL ' "$_GL_STUB_ARGV_FILE" 2>/dev/null; true)
assert_eq "TC-WB-120 begin_tick makes zero API calls" "0" "$call_count"

echo ""
echo "==================================================================="
echo "=== CAPS: parse itp-gitlab.caps + read via public seam (spec §4)"
echo "==================================================================="

CAPS_FILE="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/itp-gitlab.caps"
[[ -f "$CAPS_FILE" ]] || { echo "MISSING $CAPS_FILE"; FAIL=$((FAIL+1)); }

# Sanity-parse: read each key as "key=value" with inline # stripped.
_caps_read() {
  local key="$1" line k v
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" != *=* ]] && continue
    k="${line%%=*}"
    v="${line#*=}"
    k="${k%"${k##*[![:space:]]}"}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    if [[ "$k" == "$key" ]]; then printf '%s' "$v"; return 0; fi
  done < "$CAPS_FILE"
  return 1
}

assert_eq "TC-WB-130 server_side_state_and=1"    "1"    "$(_caps_read server_side_state_and)"
assert_eq "TC-WB-131 server_side_state_negation=1" "1"  "$(_caps_read server_side_state_negation)"
assert_eq "TC-WB-132 marker_channel=html"        "html" "$(_caps_read marker_channel)"
assert_eq "TC-WB-133 distinct_bot_author=1"      "1"    "$(_caps_read distinct_bot_author)"
assert_eq "TC-WB-134 read_after_write_state=1"   "1"    "$(_caps_read read_after_write_state)"
assert_eq "TC-WB-135 cross_ref_shorthand=1"      "1"    "$(_caps_read cross_ref_shorthand)"
assert_eq "TC-WB-136 body_checkbox=1"            "1"    "$(_caps_read body_checkbox)"
assert_eq "TC-WB-137 edit_comment=1"             "1"    "$(_caps_read edit_comment)"
assert_eq "TC-WB-138 label_colors=1"             "1"    "$(_caps_read label_colors)"
assert_eq "TC-WB-139 [#435] assignees=1"         "1"    "$(_caps_read assignees)"

echo ""
echo "==================================================================="
echo "=== NO-SEAM-BLEED: jq -n --arg discipline on request bodies"
echo "==================================================================="

# Prove the leaf never string-interpolates label / body / description text
# into a JSON document. We seed the write verbs with strings containing
# jq/shell-hazardous characters and re-parse the recorded --body arg with
# jq — a broken quote or unescaped `"` would abort the parse.
_gl_stub_reset
_GL_STUB_PAYLOAD="$PAYLOADS/gitlab-post-note.json"
hazardous='body with "double quotes" and $variables and `backticks` and \n and \\'
itp_gitlab_post_comment 42 "$hazardous" || true
body_line=$(awk '/^ARG:--body$/{getline; print; exit}' "$_GL_STUB_ARGV_FILE")
body_json="${body_line#ARG:}"
if jq -e . <<<"$body_json" >/dev/null 2>&1; then
  ok "NO-SEAM-BLEED: post_comment body is well-formed JSON despite hazardous content"
  # And the value survives round-trip.
  round=$(jq -r '.body' <<<"$body_json")
  assert_eq "NO-SEAM-BLEED: hazardous body round-trips verbatim" "$hazardous" "$round"
else
  bad "NO-SEAM-BLEED: post_comment produced malformed JSON: ${body_json:0:200}"
fi

# ---------------------------------------------------------------------------
echo ""
echo "==================================================================="
echo "=== Summary ==="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
rm -f "$_GL_STUB_ARGV_FILE" 2>/dev/null || true
[ "$FAIL" -eq 0 ]
