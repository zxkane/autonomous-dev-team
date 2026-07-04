#!/bin/bash
# test-w1b-read-task-contracts.sh — issue #396 (W1b, #347 phase-2).
#
# LEAF-level coverage for the ABSTRACT itp_read_task contract
# (docs/pipeline/provider-spec.md §3.1):
#
#   AC1 is covered by tests/unit/test-w1b-read-task-parity.sh (decision-level
#       parity for the six callers) — NOT this file.
#   AC2: zero gh flags / jq programs cross the seam. Primary proof — a
#       seam-trace fixture provider records the argv each verb RECEIVES; the
#       six real callers are run against it and every received argv is
#       asserted to be exactly `<issue> <fields-csv>` — no element matches
#       `^--`, none contains a jq-program fragment (`-q`, `select(`,
#       `.labels[`, `any(`). Secondary guard — the #296-style source grep (no
#       `itp_read_task.*-q` / `itp_read_task.*--json` token on caller lines
#       outside providers/).
#   AC2 (leaf): the leaf itself returns the normalized shape — labels an array
#       of NAME strings, comments the [INV-90] array, state passed through.
#   R2: fail-closed — gh rc≠0 → leaf rc≠0, no partial output; malformed gh
#       JSON → leaf rc≠0.
#   R1 (leaf): the field-projection contract — FIELDS_CSV controls EXACTLY
#       which keys are returned.
#
# Run: bash tests/unit/test-w1b-read-task-contracts.sh
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
LIB_DISPATCH="$SCRIPTS/lib-dispatch.sh"
ITP_GITHUB="$SCRIPTS/providers/itp-github.sh"
DEV_WRAPPER="$SCRIPTS/autonomous-dev.sh"
REVIEW_WRAPPER="$SCRIPTS/autonomous-review.sh"
STATUS_SH="$SCRIPTS/status.sh"
COMMON_SCRIPTS="$PROJECT_ROOT/skills/autonomous-common/scripts"
MCB="$COMMON_SCRIPTS/mark-issue-checkbox.sh"

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
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-w1b-contracts-$$
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# ===========================================================================
# AC2 PRIMARY PROOF — seam-trace: stub itp_github_read_task to RECORD the argv
# it receives from the six real callers, then assert no arg looks like a gh
# flag or a jq-program fragment.
# ===========================================================================
echo "=== AC2 seam-trace: no gh flags / jq programs cross the seam ==="

_SEAM_ARGV_FILE="$(mktemp)"
export _SEAM_ARGV_FILE

seam_out=$(
  env -u AUTONOMOUS_PROVIDERS_DIR ISSUE_PROVIDER=github bash -c '
    set -uo pipefail
    export REPO="'"$REPO"'" REPO_OWNER="'"$REPO_OWNER"'" PROJECT_ID="'"$PROJECT_ID"'"
    export _SEAM_ARGV_FILE="'"$_SEAM_ARGV_FILE"'"
    source "'"$SCRIPTS"'/lib-issue-provider.sh"
    itp_github_read_task() {
      { printf "VERB:read_task\n"; printf "ARG:%s\n" "$@"; } >> "$_SEAM_ARGV_FILE"
      echo "{}"
    }
    source "'"$LIB_DISPATCH"'"
    set +e
    check_deps_resolved 99 >/dev/null 2>&1
  '
)

if [[ -s "$_SEAM_ARGV_FILE" ]]; then
  ok "seam-trace fixture captured argv from check_deps_resolved"
else
  bad "seam-trace fixture captured NOTHING (harness broken): $seam_out"
fi

violation_found=0
while IFS= read -r line; do
  case "$line" in
    ARG:--*)
      bad "seam-trace: a received argument starts with '--' (gh flag leaked across the seam): ${line#ARG:}"
      violation_found=1
      ;;
    ARG:*'-q'*|ARG:*'select('*|ARG:*'.labels['*|ARG:*'any('*)
      bad "seam-trace: a received argument contains a jq-program fragment: ${line#ARG:}"
      violation_found=1
      ;;
  esac
done < "$_SEAM_ARGV_FILE"
[[ "$violation_found" -eq 0 ]] && ok "AC2: zero gh-flag-shaped or jq-program-shaped arguments received by check_deps_resolved"

recorded="$(cat "$_SEAM_ARGV_FILE")"
assert_contains "seam-trace recorded check_deps_resolved's abstract args (issue, fields-csv)" $'ARG:99\nARG:body' "$recorded"
rm -f "$_SEAM_ARGV_FILE"

# Repeat the same seam-trace for the remaining five callers, each in its own
# isolated subshell (a missing/wrong-shaped leaf would otherwise abort the
# whole file under set -e).
_seam_trace_one() {
  local label="$1" snippet="$2"
  local argv_file; argv_file="$(mktemp)"
  env -u AUTONOMOUS_PROVIDERS_DIR ISSUE_PROVIDER=github _ARGV_FILE="$argv_file" \
      REPO="$REPO" REPO_OWNER="$REPO_OWNER" PROJECT_ID="$PROJECT_ID" \
  bash -c '
    set -uo pipefail
    source "'"$SCRIPTS"'/lib-issue-provider.sh"
    itp_read_task() {
      { printf "ARG:%s\n" "$@"; } >> "$_ARGV_FILE"
      echo "{}"
    }
    '"$snippet"'
  ' >/dev/null 2>&1
  local recorded; recorded="$(cat "$argv_file" 2>/dev/null)"
  local ok_shape=1
  [[ -s "$argv_file" ]] || ok_shape=0
  while IFS= read -r line; do
    case "$line" in
      ARG:--*|ARG:*'-q'*|ARG:*'select('*|ARG:*'.labels['*|ARG:*'any('*) ok_shape=0 ;;
    esac
  done < "$argv_file"
  rm -f "$argv_file"
  if [[ "$ok_shape" -eq 1 ]]; then
    ok "seam-trace ($label): abstract argv only, no gh flags/jq fragments"
  else
    bad "seam-trace ($label): violation or no capture (recorded: ${recorded:0:200})"
  fi
}
_seam_trace_one "autonomous-review.sh no-auto-close gate" \
  'ISSUE_NUMBER=42; HAS_NO_AUTO_CLOSE=$(itp_read_task "$ISSUE_NUMBER" labels | jq -r ".labels | any(. == \"no-auto-close\")" 2>/dev/null || echo false)'
_seam_trace_one "status.sh state/labels/title read" \
  'ISSUE_NUMBER=42; ISSUE_JSON="$(itp_read_task "$ISSUE_NUMBER" state,labels,title 2>/dev/null || echo "{}")"'
_seam_trace_one "mark-issue-checkbox.sh body read" \
  'ISSUE_NUMBER=1; body=$(itp_read_task "$ISSUE_NUMBER" body | jq -r ".body" 2>/dev/null)'
_seam_trace_one "autonomous-dev.sh primary fetch" \
  'ISSUE_NUMBER=42; ISSUE_BODY=$(itp_read_task "$ISSUE_NUMBER" title,body,comments)'
_seam_trace_one "autonomous-dev.sh resume-fallback fetch" \
  'ISSUE_NUMBER=42; ISSUE_BODY=$(itp_read_task "$ISSUE_NUMBER" title,body)'

# ===========================================================================
# AC2 SECONDARY GUARD — source grep: no --json/-q token on the caller-layer
# itp_read_task call sites, outside providers/.
# ===========================================================================
echo ""
echo "=== AC2 secondary guard: source grep (caller-layer, outside providers/) ==="

_grep_caller_clean() {
  local file="$1" label="$2"
  local lines; lines="$(grep -n 'itp_read_task' "$file" | grep -v '^\s*[0-9]*:\s*#')"
  # NOTE: match per-LINE, and never with a `[^$]*` gap — every real call line
  # contains `"$ISSUE_NUMBER"` so a $-excluding gap can never span it (the
  # pre-fix regex was inert against all six shipped call sites, r3 finding).
  if grep -qE -- 'itp_read_task.*(--json| -q |--jq)' <<<"$lines"; then
    bad "AC2 secondary ($label): a caller-layer itp_read_task call site still carries a gh flag: $lines"
  else
    ok "AC2 secondary ($label): zero --json/-q tokens on itp_read_task call sites"
  fi
}
_grep_caller_clean "$LIB_DISPATCH" "lib-dispatch.sh"
_grep_caller_clean "$DEV_WRAPPER" "autonomous-dev.sh"
_grep_caller_clean "$REVIEW_WRAPPER" "autonomous-review.sh"
_grep_caller_clean "$STATUS_SH" "status.sh"
_grep_caller_clean "$MCB" "mark-issue-checkbox.sh"

# Sanity: the guard regex must actually FIRE on the pre-W1b call shapes —
# an inert guard is worse than none (this is the regression the r3 review
# caught: `[^$]*` cannot cross the literal `$` in `"$ISSUE_NUMBER"`).
_negcheck='HAS_NO_AUTO_CLOSE=$(itp_read_task "$ISSUE_NUMBER" labels -q '"'"'[.labels[].name]'"'"')'
if grep -qE -- 'itp_read_task.*(--json| -q |--jq)' <<<"$_negcheck"; then
  ok "AC2 secondary self-test: guard regex fires on a pre-W1b -q call shape"
else
  bad "AC2 secondary self-test: guard regex is INERT against the old -q call shape"
fi

# SOURCE PINS for the four wrapper call sites whose seam-trace runs snippet
# copies (r3 finding): pin the exact abstract call line so a revert to the
# old flag-tail form fails here even though the snippet trace can't see it.
grep -qF 'ISSUE_BODY=$(itp_read_task "$ISSUE_NUMBER" title,body,comments)' "$DEV_WRAPPER" \
  && ok "source-pin: autonomous-dev.sh primary fetch is abstract" \
  || bad "source-pin: autonomous-dev.sh primary fetch drifted from the abstract form"
grep -qF 'ISSUE_BODY=$(itp_read_task "$ISSUE_NUMBER" title,body)' "$DEV_WRAPPER" \
  && ok "source-pin: autonomous-dev.sh resume fetch is abstract" \
  || bad "source-pin: autonomous-dev.sh resume fetch drifted from the abstract form"
grep -qF 'HAS_NO_AUTO_CLOSE=$(itp_read_task "$ISSUE_NUMBER" labels \' "$REVIEW_WRAPPER" \
  && ok "source-pin: autonomous-review.sh no-auto-close read is abstract" \
  || bad "source-pin: autonomous-review.sh no-auto-close read drifted"
grep -qF 'ISSUE_JSON="$(itp_read_task "$ISSUE_NUMBER" state,labels,title 2>/dev/null || echo '"'"'{}'"'"')"' "$STATUS_SH" \
  && ok "source-pin: status.sh state/labels/title read is abstract" \
  || bad "source-pin: status.sh read drifted from the abstract form"

# ===========================================================================
# LEAF SHAPE: itp_github_read_task normalization.
# ===========================================================================
echo ""
echo "=== LEAF SHAPE: itp_github_read_task normalization ==="

# [#396 review r2] the leaf now issues TWO gh calls when `comments` is
# requested: `issue view --json title,body,state,labels` (GraphQL, unchanged
# fields) and, via itp_github_list_comments, `api --paginate --slurp
# .../comments` (REST, [INV-90]) — so the stub must switch on subcommand.
_GH_VIEW_PAYLOAD='{"title":"T","body":"B","state":"OPEN","labels":[{"name":"autonomous"},{"name":"no-auto-close"}]}'
_GH_COMMENTS_PAYLOAD='[[{"id":7,"user":{"login":"alice","type":"User"},"body":"hi","created_at":"2026-01-01T00:00:00Z"}]]'
gh() {
  if [[ "${1:-}" == "api" ]]; then printf '%s' "$_GH_COMMENTS_PAYLOAD"; else printf '%s' "$_GH_VIEW_PAYLOAD"; fi
}
export -f gh
export _GH_VIEW_PAYLOAD _GH_COMMENTS_PAYLOAD BOT_LOGIN=my-claw
# shellcheck source=../../skills/autonomous-dispatcher/scripts/providers/itp-github.sh
source "$ITP_GITHUB"
set +e

out="$(itp_github_read_task 42 "title,body,state,labels,comments")"
assert_eq "leaf normalizes labels to a name-string array (not {name} objects)" \
  '["autonomous","no-auto-close"]' "$(jq -c '.labels' <<<"$out")"
assert_eq "leaf sources comments via itp_github_list_comments (REST, INV-90)" \
  "alice" "$(jq -r '.comments[0].author' <<<"$out")"
assert_eq "leaf passes state through verbatim" "OPEN" "$(jq -r '.state' <<<"$out")"
assert_eq "leaf title/body as plain strings" "T B" "$(jq -r '.title + " " + .body' <<<"$out")"

_GH_VIEW_PAYLOAD='{"title":"T","state":"CLOSED","labels":[]}'
out="$(itp_github_read_task 42 body)"
assert_eq "absent body -> empty string (never null)" '{"body":""}' "$(jq -c . <<<"$out")"

echo ""
echo "=== LEAF FIELD PROJECTION: FIELDS_CSV controls exactly the returned keys ==="
_GH_VIEW_PAYLOAD='{"title":"t","body":"b","state":"OPEN","labels":[{"name":"autonomous"}]}'
out="$(itp_github_read_task 42 "state,labels,title")"
assert_eq "fields=state,labels,title -> exactly those three keys" "state,labels,title" "$(jq -r 'keys_unsorted | join(",")' <<<"$out")"
out="$(itp_github_read_task 42 body)"
assert_eq "fields=body -> exactly one key" "body" "$(jq -r 'keys_unsorted | join(",")' <<<"$out")"
out="$(itp_github_read_task 42 "")"
assert_eq "empty fields-csv -> {}" "{}" "$out"

# ===========================================================================
# R2 FAIL-CLOSED: gh rc≠0 → leaf rc≠0, no partial output.
# ===========================================================================
echo ""
echo "=== R2 fail-closed: gh rc≠0 propagates ==="
gh() { echo "stub-gh: simulated failure" >&2; return 1; }
export -f gh
out="$(itp_github_read_task 42 title 2>/dev/null)"; rc=$?
assert_eq "itp_github_read_task: gh failure -> non-zero rc" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert_eq "itp_github_read_task: gh failure -> no partial stdout" "" "$out"

# Malformed JSON from gh (rc 0, garbage body) must also fail rather than
# silently emit a bogus "successful-looking" object.
gh() { printf '{ not json'; return 0; }
export -f gh
out="$(itp_github_read_task 42 title 2>/dev/null)"; rc=$?
assert_eq "malformed gh JSON -> non-zero rc (fail-closed)" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"

# The comments-fetch (itp_github_list_comments, REST) failing must ALSO
# fail-closed even though the primary `issue view` call succeeded.
gh() { if [[ "${1:-}" == "api" ]]; then echo "stub-gh: simulated failure" >&2; return 1; else printf '{"title":"T","body":"B","state":"OPEN","labels":[]}'; fi; }
export -f gh
out="$(itp_github_read_task 42 "title,comments" 2>/dev/null)"; rc=$?
assert_eq "itp_github_read_task: comments-fetch gh failure -> non-zero rc" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert_eq "itp_github_read_task: comments-fetch gh failure -> no partial stdout" "" "$out"

# ===========================================================================
echo ""
echo "=== Summary ==="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
[ "$FAIL" -eq 0 ]
