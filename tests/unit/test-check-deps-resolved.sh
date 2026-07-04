#!/bin/bash
# test-check-deps-resolved.sh — Regression tests for `check_deps_resolved`
# in lib-dispatch.sh, covering:
#   - #61: MERGED PR dependencies count as resolved
#   - #73: portable (non-GNU) dep extraction
#   - #157: cross-repo `owner/repo#N` deps + list-only extraction
#   - #269/INV-83: per-dep-repo scoped-token cross-repo lookup (TC-CRDEP-001..012)
#   - #284/INV-83: the leaf + mint + cache moved behind itp_resolve_dep /
#     itp_begin_tick (providers/itp-github.sh). These tests run against the VERB
#     SEAM: sourcing lib-dispatch.sh self-sources lib-issue-provider.sh →
#     itp-github.sh (default ISSUE_PROVIDER=github), so resolve_dep_state forwards
#     to itp_github_resolve_dep and the tick-boundary reset is itp_begin_tick.
#
# `check_deps_resolved` makes multiple gh calls in sequence:
#   1. `gh issue view N --repo $REPO --json title,body,state,labels`
#      ([W1b] #396 ABSTRACT itp_read_task contract — this caller requests only
#      `body`, so the leaf's [review r2] separate REST comments-fetch never
#      fires; the leaf still reads the full title/body/state/labels set and
#      normalizes, and the caller-side `| jq -r '.body'` projects down to the
#      body string it needs, byte-identical result to the pre-#396 `-q .body`
#      passthrough for THIS caller since it only ever consumed `.body`).
#   2. for each dep: `gh issue view M --repo <repo> --json state -q .state`
#      — this leaf now lives in providers/itp-github.sh::itp_github_resolve_dep,
#      but it emits the SAME argv, so the gh BINARY mock below applies unchanged.
#
# FUNCTION-MOCK SHIM AUDIT (#284, §7.3 m3 — shim-vs-rename policy):
#   - The gh BINARY mock (the `gh()` function) stubs the leaf I/O. The migration
#     keeps the emitted `gh issue view … --json state` argv byte-identical
#     (golden-trace pinned in test-itp-resolve-dep-golden-trace.sh), so this
#     binary mock is unaffected by where the leaf lives.
#   - `get_gh_app_scoped_token` is stubbed as a SHELL FUNCTION and `export -f`'d
#     BEFORE sourcing the lib (see lines ~76/84). The provider's
#     itp_github_resolve_dep lazy-sources gh-app-token.sh only when the function
#     is NOT already defined (`declare -F` guard), so the stub WINS — the mint
#     primitive stays resolvable from the provider's lazy-source path. This is a
#     function-level SHIM, NOT a rename: the production function name is
#     unchanged, so the provider resolves the real mint in production and the
#     stub in tests.
#
# Run: bash tests/unit/test-check-deps-resolved.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-proj
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# State: which JSON field was requested + what to return.
# _MOCK_BODY: text the body lookup returns
# _MOCK_STATES: associative array, "<repo>:<num>" → "CLOSED"/"MERGED"/"OPEN"
_MOCK_BODY=""
declare -A _MOCK_STATES

# ---------------------------------------------------------------------------
# [INV-83, #269] $GH_TOKEN-aware scope enforcement.
#
# The #269 bug is that the ambient dispatcher token is scoped to the DISPATCHING
# repo only, so a cross-repo lookup 404s. To make the regression test meaningful
# (fail-WITHOUT-fix / pass-WITH-fix), the mock must SIMULATE that scope: when
# `_SCOPE_ENFORCE=1`, a state lookup against a repo OTHER than $REPO returns
# empty (the 404) UNLESS the in-scope `$GH_TOKEN` equals the per-repo sentinel
# that the (stubbed) scoped mint produces. A lookup against $REPO succeeds with
# any token (that IS the dispatching repo the ambient token covers).
#
# Off by default (`_SCOPE_ENFORCE` unset) so every pre-#269 test in this file —
# which runs in token mode with no scope sentinels — is byte-for-byte unchanged.
# ---------------------------------------------------------------------------
_SCOPE_ENFORCE=0
# resolve_dep_state mints via `_minted=$(get_gh_app_scoped_token ...)` — a
# command-substitution subshell, so a shell-variable mint counter would die with
# it. Record mints + posted comments to FILES (the codebase's standard
# subshell-safe tally pattern). _MINT_LOG / _COMMENT_LOG_FILE hold paths.
_MINT_LOG=$(mktemp)
_COMMENT_LOG_FILE=$(mktemp)
# Mint-failure registry must also survive the subshell read, so back it with a
# directory of marker files rather than an associative array.
_MINT_FAIL_DIR=$(mktemp -d)
trap 'rm -f "$_MINT_LOG" "$_COMMENT_LOG_FILE"; rm -rf "$_MINT_FAIL_DIR"' EXIT

# The per-repo sentinel token the stubbed mint returns for a given dep repo.
_scoped_sentinel_for() { printf 'scoped-token-for-%s' "$1"; }

# Stub the scoped-token mint that resolve_dep_state calls in app mode. Records
# each mint to the _MINT_LOG file (so the cache-dedup + routing tests can count
# mints) and echoes the per-repo sentinel — unless the repo is registered as a
# mint-failure, in which case it fails (rc 1, empty) so resolve_dep_state
# negative-caches it. Both the log and the failure registry are FILES so the
# command-substitution subshell's writes/reads survive.
get_gh_app_scoped_token() {
  local owner_repo="$3/$4"
  printf '%s\n' "$owner_repo" >> "$_MINT_LOG"
  if [[ -f "$_MINT_FAIL_DIR/$(printf '%s' "$owner_repo" | tr '/' '_')" ]]; then
    return 1
  fi
  _scoped_sentinel_for "$owner_repo"
}
export -f get_gh_app_scoped_token _scoped_sentinel_for

gh() {
  # [#393] itp_list_comments reads REST (gh api --paginate --slurp .../comments).
  # THIS test synthesizes per-issue comments from _EXISTING_COMMENTS_COUNT
  # (keyed repo:issue) — mirror that here, in REST page shape. The issue
  # number comes from the REST path (arg 4: repos/<owner>/<name>/issues/N/comments).
  if [[ "${1:-}" == "api" && "${2:-}" == "--paginate" ]]; then
    local _rest_path="${4:-}" _rest_issue
    _rest_issue=$(sed -nE 's|.*/issues/([0-9]+)/comments$|\1|p' <<<"$_rest_path")
    local _rest_key="${REPO}:${_rest_issue}"
    local _rn="${_EXISTING_COMMENTS_COUNT[$_rest_key]:-0}"; [[ "$_rn" =~ ^[0-9]+$ ]] || _rn=0
    jq -cn --argjson n "$_rn" --arg body "${_MOCK_DEP_BLOCK_BODY:-}"       '[[range($n) | {id: (.+1), user:{login:"my-claw[bot]", type:"Bot"}, body:$body, created_at:"2026-06-12T00:00:0\(.)Z"}]]'
    return 0
  fi
  local mode="" issue_num="" repo="" body="" q=""
  # gh issue comment <num> --repo R --body "..."  (block-visibility post, #269 T5)
  if [[ "$1" == "issue" && "$2" == "comment" ]]; then
    shift 2
    issue_num="$1"; shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --body) body="$2"; shift 2 ;;
        --repo) shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$body" >> "$_COMMENT_LOG_FILE"
    return 0
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      view) issue_num="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --json)
        case "$2" in
          title,body,state,labels) mode="read_task" ;;
          body) mode="body" ;;
          state) mode="state" ;;
          comments) mode="comments" ;;
        esac
        shift 2
        ;;
      -q|--jq) q="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$mode" in
    # [W1b] #396 — itp_github_read_task requests title/body/state/labels and
    # normalizes; this caller's `| jq -r '.body'` then projects down to the
    # body string, so serving _MOCK_BODY here (with the other fields defaulted)
    # reproduces the same captured body this test asserts on.
    read_task) jq -cn --arg body "$_MOCK_BODY" '{title:"",body:$body,state:"OPEN",labels:[]}' ;;
    body)  printf '%s' "$_MOCK_BODY" ;;
    state)
      local s="${_MOCK_STATES[${repo}:${issue_num}]:-OPEN}"
      # Sentinel: __FAIL__ simulates a real `gh issue view` failure
      # (404 / network / unauthorized) — non-zero exit, empty stdout.
      if [[ "$s" == "__FAIL__" ]]; then
        return 1
      fi
      # [INV-83, #269] Scope enforcement: a cross-repo lookup (repo != $REPO)
      # 404s unless GH_TOKEN is the per-repo scoped sentinel.
      if [[ "$_SCOPE_ENFORCE" == "1" && "$repo" != "$REPO" ]]; then
        if [[ "${GH_TOKEN:-}" != "$(_scoped_sentinel_for "$repo")" ]]; then
          return 1
        fi
      fi
      printf '%s' "$s"
      ;;
    comments)
      # Dedup probe for _dep_block_comment. Post the ITP read-leaf refactor
      # (#281) the lib runs `itp_list_comments | jq '[.[].body|select(contains(
      # MARKER))]|length' | grep -q '^0$'`, where itp_list_comments calls one
      # `gh issue view … --json comments -q '<normalize>'`. So this stub applies
      # the requested `-q` to a synthesized `{comments:[…]}` of
      # _EXISTING_COMMENTS_COUNT comments whose body carries _MOCK_DEP_BLOCK_BODY
      # (the exact `dep-block:<ref>` marker the present-case test sets). Default
      # count 0 → empty array → length 0 → the lib posts.
      local key="${repo}:${issue_num}"
      local _n="${_EXISTING_COMMENTS_COUNT[$key]:-0}"; [[ "$_n" =~ ^[0-9]+$ ]] || _n=0
      local _arr; _arr=$(jq -cn --argjson n "$_n" --arg body "${_MOCK_DEP_BLOCK_BODY:-}" \
        '{comments: [range($n) | {url:"https://x/issues/1#issuecomment-\(.+1)", author:{login:"my-claw"}, body:$body, createdAt:"2026-06-12T00:00:0\(.)Z"}]}')
      # _dep_block_comment passes the normalize via -q; apply it to the array.
      if [[ -n "$q" ]]; then jq -r "$q" <<<"$_arr"; else printf '%s' "$_arr"; fi
      ;;
  esac
}
export -f gh
declare -A _EXISTING_COMMENTS_COUNT

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected='$expected', actual='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

# Reset _MOCK_STATES between tests. `unset` + `declare -A` is the only way
# to clear an associative array reliably across bash 4/5 — assigning `()`
# leaves stale keys on some versions.
_reset_states() {
  unset _MOCK_STATES
  declare -gA _MOCK_STATES
  # [INV-83, #269] Reset the scope-enforcement scaffolding too.
  _SCOPE_ENFORCE=0
  unset _EXISTING_COMMENTS_COUNT; declare -gA _EXISTING_COMMENTS_COUNT
  _MOCK_DEP_BLOCK_BODY=""   # #281: body of synthesized existing block comments
  : > "$_MINT_LOG"
  : > "$_COMMENT_LOG_FILE"
  rm -f "$_MINT_FAIL_DIR"/*
  # Each scope-aware test runs in app mode with creds present; default to that
  # and let token-mode tests override GH_AUTH_MODE explicitly. Pre-#269 tests
  # never touch these and stay in token mode (GH_AUTH_MODE unset).
  unset GH_TOKEN GH_AUTH_MODE DISPATCHER_APP_ID DISPATCHER_APP_PEM
  # [INV-83, #269/#284] Clear the dep-lookup token cache between INDEPENDENT
  # cases. The cache is TICK-scoped (persists across check_deps_resolved calls in
  # a tick), so check_deps_resolved no longer self-resets — each test case must
  # start from the tick boundary. Since #284 the cache + reset are provider-owned
  # (providers/itp-github.sh) and the boundary reset is the `itp_begin_tick` verb
  # (dispatcher-tick.sh calls it once before Step 2), NOT a direct
  # `_reset_dep_token_cache` call. We reset through the verb here, proving the
  # cache is cleared by the verb. (The cross-TICK-dedup test below deliberately
  # does NOT call _reset_states between its two check_deps_resolved calls.)
  itp_begin_tick
}

# Register a scoped-mint failure for owner/repo (file-backed, subshell-safe).
_set_mint_fail() {
  : > "$_MINT_FAIL_DIR/$(printf '%s' "$1" | tr '/' '_')"
}

# Count how many times the scoped mint was invoked for a given owner/repo.
# `grep -c` prints 0 AND exits 1 on no match, so a `|| echo 0` would double-print
# — count lines explicitly with awk instead.
_mint_count_for() {
  awk -v want="$1" 'index($0, want) == 1 && $0 == want { n++ } END { print n + 0 }' "$_MINT_LOG"
}

# Register state for an arbitrary repo:issue pair.
_set_repo_state() {
  local repo="$1" num="$2" state="$3"
  _MOCK_STATES["${repo}:${num}"]="$state"
}

# Convenience: register state for the default same-repo $REPO.
_set_same_repo_state() {
  _set_repo_state "$REPO" "$1" "$2"
}

# ---------------------------------------------------------------------------
echo "=== check_deps_resolved: no deps section ==="
# ---------------------------------------------------------------------------
_MOCK_BODY="## Summary
Some text without a Dependencies section."
_reset_states
check_deps_resolved 99
assert_eq "no deps section → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: single CLOSED dep ==="
# ---------------------------------------------------------------------------
_MOCK_BODY="## Summary
foo

## Dependencies
- #42

## Other"
_reset_states
_set_same_repo_state 42 CLOSED
check_deps_resolved 99
assert_eq "one CLOSED dep → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: single MERGED dep [INV-11, #61 fix] ==="
# ---------------------------------------------------------------------------
_reset_states
_set_same_repo_state 42 MERGED
check_deps_resolved 99
assert_eq "one MERGED dep → resolved (rc=0) — was rc=1 before #61 fix" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: single OPEN dep blocks ==="
# ---------------------------------------------------------------------------
_reset_states
_set_same_repo_state 42 OPEN
check_deps_resolved 99
assert_eq "one OPEN dep → blocked (rc=1)" "1" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: multiple deps mixed states ==="
# ---------------------------------------------------------------------------
_MOCK_BODY="## Dependencies
- #1 something
- #2 something
- #3 something
"
_reset_states
_set_same_repo_state 1 CLOSED
_set_same_repo_state 2 MERGED
_set_same_repo_state 3 CLOSED
check_deps_resolved 99
assert_eq "all CLOSED+MERGED → resolved (rc=0) [#73 grep portability + #61 MERGED]" "0" "$?"

_reset_states
_set_same_repo_state 1 CLOSED
_set_same_repo_state 2 MERGED
_set_same_repo_state 3 OPEN
check_deps_resolved 99
assert_eq "any one OPEN among three → blocked (rc=1)" "1" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: dep numbers extracted with portable regex (#73) ==="
# ---------------------------------------------------------------------------
# Regression guard: dep extraction must strip the leading `#` and pass bare
# numbers to `gh issue view`. If the # is not stripped, our mock returns
# the default "OPEN" → blocked, so a passing test here proves stripping works.

_MOCK_BODY="## Dependencies
- depends on #100 and #200
- and also #300
"
_reset_states
_set_same_repo_state 100 CLOSED
_set_same_repo_state 200 CLOSED
_set_same_repo_state 300 CLOSED
check_deps_resolved 99
assert_eq "portable extraction strips '#' prefix from dep numbers (#73)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: cross-repo dep, CLOSED in remote (#157) ==="
# ---------------------------------------------------------------------------
_MOCK_BODY="## Dependencies
- other-owner/other-repo#7
"
_reset_states
_set_repo_state other-owner/other-repo 7 CLOSED
check_deps_resolved 99
assert_eq "cross-repo CLOSED dep → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: cross-repo dep, MERGED in remote (#157) ==="
# ---------------------------------------------------------------------------
_reset_states
_set_repo_state other-owner/other-repo 7 MERGED
check_deps_resolved 99
assert_eq "cross-repo MERGED dep → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: cross-repo dep, OPEN in remote (#157) ==="
# ---------------------------------------------------------------------------
_reset_states
_set_repo_state other-owner/other-repo 7 OPEN
check_deps_resolved 99
assert_eq "cross-repo OPEN dep → blocked (rc=1)" "1" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: cross-repo same number resolves to different state (#157) ==="
# ---------------------------------------------------------------------------
# Same number in two repos must NOT collide. #42 is OPEN in $REPO but
# CLOSED in `other-owner/other-repo` — only the cross-repo ref is listed,
# so the result must be unblocked.
_MOCK_BODY="## Dependencies
- other-owner/other-repo#42
"
_reset_states
_set_same_repo_state 42 OPEN
_set_repo_state other-owner/other-repo 42 CLOSED
check_deps_resolved 99
assert_eq "same number, different repos: cross-repo CLOSED wins → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: mixed same-repo + cross-repo (#157) ==="
# ---------------------------------------------------------------------------
_MOCK_BODY="## Dependencies
- #42
- other-owner/other-repo#7
"
_reset_states
_set_same_repo_state 42 CLOSED
_set_repo_state other-owner/other-repo 7 OPEN
check_deps_resolved 99
assert_eq "same-repo CLOSED + cross-repo OPEN → blocked (rc=1)" "1" "$?"

_reset_states
_set_same_repo_state 42 CLOSED
_set_repo_state other-owner/other-repo 7 MERGED
check_deps_resolved 99
assert_eq "same-repo CLOSED + cross-repo MERGED → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: prose between headings does NOT block (#157) ==="
# ---------------------------------------------------------------------------
# Pre-#157, a prose line `requires #4470` between `## Dependencies` and the
# next `## ` heading was greedy-extracted. If 4470 doesn't exist in $REPO,
# `gh issue view` returns empty state and the dep was treated as unresolved
# — silent permanent block. After #157, prose is ignored entirely.
_MOCK_BODY="## Dependencies

This issue does not directly depend on anything, but is related to
the work happening in #4470 — see that PR for context.

## Acceptance Criteria
"
_reset_states
# 4470 is intentionally NOT registered — pre-#157 this would have caused
# a silent block. Post-fix, the prose line is ignored.
check_deps_resolved 99
assert_eq "prose-embedded #N reference (no list marker) → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: blockquote does NOT block (#157) ==="
# ---------------------------------------------------------------------------
_MOCK_BODY="## Dependencies

> Note: requires other-owner/other-repo#4470 to be merged first.

## Other
"
_reset_states
check_deps_resolved 99
assert_eq "blockquote-embedded cross-repo ref → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: numbered list items are extracted (#157) ==="
# ---------------------------------------------------------------------------
_MOCK_BODY="## Dependencies

1. #1
2. other-owner/other-repo#2

## Other
"
_reset_states
_set_same_repo_state 1 CLOSED
_set_repo_state other-owner/other-repo 2 CLOSED
check_deps_resolved 99
assert_eq "numbered list (1./2.) → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: 'None' marker → resolved (#157 acceptance) ==="
# ---------------------------------------------------------------------------
_MOCK_BODY="## Dependencies

None.

## Other
"
_reset_states
check_deps_resolved 99
assert_eq "'None' (no list items, no refs) → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: URL-form ref in prose does NOT block (#157) ==="
# ---------------------------------------------------------------------------
# A literal GitHub URL on a prose line — including the trailing `#NNN`
# fragment — must NOT be parsed as a dep. URL refs aren't supported syntax.
_MOCK_BODY="## Dependencies

See https://github.com/other-owner/other-repo/issues/123 for related context.

## Other
"
_reset_states
check_deps_resolved 99
assert_eq "URL fragment in prose → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: URL-form ref ON A LIST-ITEM does NOT block (#157, INV-39) ==="
# ---------------------------------------------------------------------------
# Even when a list-item line contains a GitHub URL with a numeric `#NNN`
# fragment (e.g., `#456`), the left-boundary anchor must reject it: in
# `repo/issues/123#456`, the `#` is preceded by digits, not whitespace
# / `(` / start-of-line, AND `issues/123` is preceded by `/`, not a
# left-boundary character. This test exercises Stage 2's boundary
# logic directly — the prose-only test above is filtered out at Stage 1.
# If `_MOCK_STATES` is unset and the regex did match, the lookup would
# return default OPEN (or, here, the registered CLOSED) — so we register
# CLOSED for the would-be-extracted numbers; if any of them were
# extracted it would still resolve, but the better signal is to register
# OPEN and confirm rc=0 anyway (proving they were filtered out).
_MOCK_BODY="## Dependencies
- See https://github.com/other-owner/other-repo/issues/123#456 for context
"
_reset_states
# Pre-fix, the greedy old parser could have extracted 123 or 456 against
# $REPO. Register both as OPEN so a regression that re-introduces
# greedy extraction would block (rc=1). Post-fix, the line is filtered
# at Stage 1 anyway (it's a list item, but the URL fragment fails Stage
# 2's left-boundary check).
_set_same_repo_state 123 OPEN
_set_same_repo_state 456 OPEN
_set_repo_state other-owner/other-repo 123 OPEN
_set_repo_state other-owner/other-repo 456 OPEN
check_deps_resolved 99
assert_eq "URL fragment on list item → resolved (rc=0); fragment ignored, repo path ignored" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: parenthesized refs are recognized (INV-39) ==="
# ---------------------------------------------------------------------------
# `- (owner/repo#42)` and `- (#42)` should still match — the spec permits
# `(` as a left boundary so common Markdown phrasings like
# `- waiting on (owner/repo#42)` parse correctly.
_MOCK_BODY="## Dependencies
- waiting on (other-owner/other-repo#42)
- and also (#7)
"
_reset_states
_set_repo_state other-owner/other-repo 42 CLOSED
_set_same_repo_state 7 CLOSED
check_deps_resolved 99
assert_eq "parenthesized cross-repo + same-repo, both CLOSED → resolved (rc=0)" "0" "$?"

_reset_states
_set_repo_state other-owner/other-repo 42 OPEN
_set_same_repo_state 7 CLOSED
check_deps_resolved 99
assert_eq "parenthesized cross-repo OPEN → blocked (rc=1)" "1" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: failed lookup blocks AND warns (INV-39) ==="
# ---------------------------------------------------------------------------
# Cross-repo ref to a non-existent / unauthorized repo: the real `gh issue
# view` exits non-zero with empty stdout. The dispatcher MUST fail-safe
# (return 1) AND emit a stderr warning naming the failed ref. Without the
# warning, a typo silently recreates the #157 bug class.
_MOCK_BODY="## Dependencies
- typo-owner/nonexistent#456
"
_reset_states
_set_repo_state typo-owner/nonexistent 456 __FAIL__
err=$(check_deps_resolved 99 2>&1 >/dev/null)
rc=$?
assert_eq "failed cross-repo lookup → blocked (rc=1)" "1" "$rc"
# [INV-83, #269] The cross-repo empty-state WARNING is SHARPENED to name the
# scope/installation cause FIRST. It must still name the failed ref AND now
# carry the "App may not be installed" phrasing.
if [[ "$err" == *"cross-repo lookup failed for typo-owner/nonexistent#456"* \
   && "$err" == *"App may not be installed on typo-owner/nonexistent"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: failed lookup emits sharpened stderr warning naming the ref + scope cause"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: missing/old stderr warning (got: ${err})"
  FAIL=$((FAIL + 1))
fi

# ===========================================================================
# [INV-83, #269] cross-repo dependency lookup uses a per-dep-repo scoped token
# ===========================================================================
# These cases run under `_SCOPE_ENFORCE=1` + app mode, simulating the #269 bug:
# the ambient dispatcher token is scoped to $REPO only, so a cross-repo lookup
# 404s UNLESS resolve_dep_state mints a token scoped to the TARGET repo.

# Common app-mode arming for the scope-aware cases.
_arm_app_mode() {
  _SCOPE_ENFORCE=1
  export GH_AUTH_MODE=app
  export DISPATCHER_APP_ID=12345
  export DISPATCHER_APP_PEM=/nonexistent.pem   # mint is stubbed; file never read
  export GH_TOKEN=ambient-repoA-scoped-token   # the #269 narrow token
}

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRDEP-001: app mode, cross-repo CLOSED dep → resolved via scoped mint (AC #1) ==="
# ---------------------------------------------------------------------------
# Fails WITHOUT the fix (ambient repo-A token 404s on repo-B); passes WITH it.
_MOCK_BODY="## Dependencies
- other-owner/other-repo#7
"
_reset_states
_arm_app_mode
_set_repo_state other-owner/other-repo 7 CLOSED
check_deps_resolved 99
assert_eq "cross-repo CLOSED dep resolves via target-scoped mint → rc 0" "0" "$?"
assert_eq "scoped mint invoked exactly once for the dep repo" "1" "$(_mint_count_for other-owner/other-repo)"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRDEP-002: app mode, cross-repo MERGED dep → resolved ==="
# ---------------------------------------------------------------------------
_reset_states
_arm_app_mode
_set_repo_state other-owner/other-repo 7 MERGED
check_deps_resolved 99
assert_eq "cross-repo MERGED dep → rc 0" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRDEP-003: app mode, cross-repo OPEN dep → blocked ==="
# ---------------------------------------------------------------------------
_reset_states
_arm_app_mode
_set_repo_state other-owner/other-repo 7 OPEN
check_deps_resolved 99
assert_eq "cross-repo OPEN dep → rc 1 (blocked)" "1" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRDEP-004: app mode, App-not-installed (empty state) → block + sharpened WARN + comment ==="
# ---------------------------------------------------------------------------
# Mint succeeds but the dep repo is unreachable (state __FAIL__) — models a repo
# the App cannot see. The block must be observable: sharpened WARN + once-per-ref
# comment.
_MOCK_BODY="## Dependencies
- unreachable-owner/unreachable#42
"
_reset_states
_arm_app_mode
_set_repo_state unreachable-owner/unreachable 42 __FAIL__
err=$(check_deps_resolved 99 2>&1 >/dev/null)
rc=$?
assert_eq "App-not-installed cross-repo dep → rc 1 (blocked)" "1" "$rc"
if [[ "$err" == *"App may not be installed on unreachable-owner/unreachable"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: sharpened WARNING names the scope/installation cause"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: sharpened WARNING missing (got: ${err})"
  FAIL=$((FAIL + 1))
fi
# The block-visibility comment is posted (current-shell call, so _COMMENT_LOG
# persists when check_deps_resolved runs NOT in a subshell). Re-run in-shell to
# capture the comment side-effect.
_reset_states
_arm_app_mode
_set_repo_state unreachable-owner/unreachable 42 __FAIL__
check_deps_resolved 99 >/dev/null 2>&1
if grep -qF 'dep-block:unreachable-owner/unreachable#42' "$_COMMENT_LOG_FILE"; then
  echo -e "  ${GREEN}PASS${NC}: once-per-ref block-visibility comment posted with the dedup marker"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: block-visibility comment missing (log: $(cat "$_COMMENT_LOG_FILE"))"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRDEP-005: token routing — same-repo uses ambient, cross-repo uses scoped ==="
# ---------------------------------------------------------------------------
# A same-repo #N (resolved against $REPO with the ambient token) AND a cross-repo
# ref in one body: same-repo resolves with the ambient token (scope enforce only
# bites repo != $REPO), cross-repo resolves only because the scoped mint fired.
_MOCK_BODY="## Dependencies
- #42
- other-owner/other-repo#7
"
_reset_states
_arm_app_mode
_set_same_repo_state 42 CLOSED          # same-repo: ambient token OK
_set_repo_state other-owner/other-repo 7 CLOSED
check_deps_resolved 99
assert_eq "same-repo (ambient) + cross-repo (scoped) both CLOSED → rc 0" "0" "$?"
assert_eq "scoped mint fired only for the cross-repo dep (not same-repo)" "1" "$(_mint_count_for other-owner/other-repo)"
assert_eq "no scoped mint for the dispatching repo" "0" "$(_mint_count_for "$REPO")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRDEP-006: per-repo mint FAILURE degrades to fail-safe block, does NOT exit ==="
# ---------------------------------------------------------------------------
# The mint fails (App lacks the dep repo's installation). resolve_dep_state must
# fall back to the ambient token (which 404s under scope enforce → empty state →
# fail-safe block), return 1, and NOT exit — so check_deps_resolved returns and
# control flows on. We prove "did not exit" by observing the function returned a
# value the test can read (an `exit 1` would have killed the whole test process).
_MOCK_BODY="## Dependencies
- mintfail-owner/mintfail#9
"
_reset_states
_arm_app_mode
_set_mint_fail "mintfail-owner/mintfail"
_set_repo_state mintfail-owner/mintfail 9 CLOSED   # would resolve IF token were scoped
check_deps_resolved 99
assert_eq "mint failure → fail-safe block (rc 1), function returned (no exit)" "1" "$?"
echo -e "  ${GREEN}PASS${NC}: test process still alive after mint-failure path (no exit 1)"
PASS=$((PASS + 1))

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRDEP-007: PAT mode — no mint, ambient fallback, no behavior change ==="
# ---------------------------------------------------------------------------
# In token mode resolve_dep_state never mints; the ambient token is used. With
# scope enforce OFF (token-mode default), the cross-repo CLOSED dep resolves
# exactly as the legacy path did.
_MOCK_BODY="## Dependencies
- other-owner/other-repo#7
"
_reset_states
# token mode: leave GH_AUTH_MODE unset, _SCOPE_ENFORCE=0 (a PAT spans repos, so
# the mock does not 404 cross-repo).
_set_repo_state other-owner/other-repo 7 CLOSED
check_deps_resolved 99
assert_eq "PAT mode cross-repo CLOSED → rc 0 (ambient token)" "0" "$?"
assert_eq "PAT mode: NO scoped mint happened" "0" "$(_mint_count_for other-owner/other-repo)"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRDEP-008: PR-number cross-repo dep (MERGED) resolves ==="
# ---------------------------------------------------------------------------
# `gh issue view --json state` on a PR returns MERGED; the dep is a PR ref.
_MOCK_BODY="## Dependencies
- other-owner/other-repo#1234
"
_reset_states
_arm_app_mode
_set_repo_state other-owner/other-repo 1234 MERGED
check_deps_resolved 99
assert_eq "cross-repo MERGED PR ref → rc 0" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRDEP-009: cache — two deps in the SAME cross-repo are minted ONCE ==="
# ---------------------------------------------------------------------------
_MOCK_BODY="## Dependencies
- other-owner/other-repo#7
- other-owner/other-repo#8
"
_reset_states
_arm_app_mode
_set_repo_state other-owner/other-repo 7 CLOSED
_set_repo_state other-owner/other-repo 8 MERGED
check_deps_resolved 99
assert_eq "two deps same repo, both resolved → rc 0" "0" "$?"
assert_eq "scoped mint invoked ONCE for the shared dep repo (cache dedup)" "1" "$(_mint_count_for other-owner/other-repo)"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRDEP-010: block-visibility comment is once-per-ref (dedup marker) ==="
# ---------------------------------------------------------------------------
# An already-posted block (existing-comment count = 1) must NOT post again.
_MOCK_BODY="## Dependencies
- unreachable-owner/unreachable#42
"
_reset_states
_arm_app_mode
_set_repo_state unreachable-owner/unreachable 42 __FAIL__
_EXISTING_COMMENTS_COUNT["${REPO}:99"]=1   # a prior block comment already exists
# The existing comment carries the exact once-per-ref marker the dedup probe
# searches for (#281: itp_list_comments returns the normalized body; the
# `contains(marker)` count stays caller-side).
_MOCK_DEP_BLOCK_BODY='Dependency could not be resolved <!-- dep-block:unreachable-owner/unreachable#42 -->'
check_deps_resolved 99 >/dev/null 2>&1
if [[ ! -s "$_COMMENT_LOG_FILE" ]]; then
  echo -e "  ${GREEN}PASS${NC}: block already surfaced → no duplicate comment (once-per-ref dedup)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: duplicate block comment posted (log: $(cat "$_COMMENT_LOG_FILE"))"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRDEP-011: cache spans the TICK — two ISSUES on the same dep repo mint ONCE (AC #2) ==="
# ---------------------------------------------------------------------------
# THE #269 review [P1] regression: AC #2 requires caching by `owner/repo`
# *within the tick*, not per-issue. Two different issues processed in the same
# tick (the cache is NOT reset between their check_deps_resolved calls — only at
# the tick boundary) that both depend on the same external repo MUST reuse the
# first issue's minted token → exactly ONE mint. With the pre-fix per-call reset
# this minted twice; this assertion fails without the fix.
_reset_states                      # tick boundary (clears the cache once)
_arm_app_mode
# Two issues' bodies. The mock `gh --json body` returns _MOCK_BODY for ANY issue
# number, so we set the shared body and call check_deps_resolved for two issue
# numbers WITHOUT _reset_states between them (mid-tick).
_MOCK_BODY="## Dependencies
- shared-owner/shared-repo#7
"
_set_repo_state shared-owner/shared-repo 7 CLOSED
check_deps_resolved 101            # issue #101 (first in the tick) — mints once
rc1=$?
check_deps_resolved 102           # issue #102 (same tick, same dep repo) — reuses
rc2=$?
assert_eq "issue #101 cross-repo CLOSED dep → rc 0" "0" "$rc1"
assert_eq "issue #102 cross-repo CLOSED dep → rc 0" "0" "$rc2"
assert_eq "TICK-scoped cache: same dep repo across TWO issues minted ONCE (AC #2)" "1" "$(_mint_count_for shared-owner/shared-repo)"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRDEP-012: the tick-boundary reset clears the cache (a new tick re-mints) ==="
# ---------------------------------------------------------------------------
# After a tick boundary (itp_begin_tick, what dispatcher-tick.sh calls once per
# tick before Step 2 — #284 relocated the reset body into the provider's
# itp_github_begin_tick), a fresh tick processing the same dep repo mints again —
# the cache does NOT leak across ticks. This proves the cache is cleared by the
# verb, not by check_deps_resolved.
_reset_states
_arm_app_mode
_MOCK_BODY="## Dependencies
- shared-owner/shared-repo#7
"
_set_repo_state shared-owner/shared-repo 7 CLOSED
check_deps_resolved 201            # tick A: one mint
mints_after_tick_a=$(_mint_count_for shared-owner/shared-repo)
itp_begin_tick                     # <-- tick boundary (dispatcher-tick.sh does this)
check_deps_resolved 202            # tick B: must mint AGAIN (cache cleared)
assert_eq "tick A minted once" "1" "$mints_after_tick_a"
assert_eq "after itp_begin_tick (tick-boundary reset), tick B re-mints (no cross-tick leak) → 2 total" "2" "$(_mint_count_for shared-owner/shared-repo)"

# ---------------------------------------------------------------------------
echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
