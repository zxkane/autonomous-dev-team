#!/bin/bash
# test-issue-mention-login.sh — issue-author @-mention target ([INV-138]).
#
# The pipeline's "a human needs to act" comments (stalled / hand-off / manual-
# merge notices) historically @-mentioned `${REPO_OWNER}`. On GitHub a repo has
# ONE canonical owner login, but on GitLab `REPO_OWNER` is the group/namespace —
# often a TEAM, not a person — so `@${REPO_OWNER}` either fails to notify anyone
# or pings a whole group. The correct notify target is the ISSUE AUTHOR (the
# person who filed it). This file pins:
#
#   AC1 (leaf): itp_{github,gitlab}_read_task expose an `author` field
#       (github: .author.login; gitlab: .author.username; absent → "").
#   AC2 (helper): issue_mention_login ISSUE returns the resolved @-target login:
#       - author present  → the author login (both providers).
#       - author absent, ISSUE_PROVIDER=github → falls back to REPO_OWNER.
#       - author absent, ISSUE_PROVIDER=gitlab → EMPTY (no mention — never pings
#         the group namespace).
#
# Run: bash tests/unit/test-issue-mention-login.sh
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
ITP_GITHUB="$SCRIPTS/providers/itp-github.sh"
ITP_GITLAB="$SCRIPTS/providers/itp-gitlab.sh"
LIB_PROVIDER="$SCRIPTS/lib-issue-provider.sh"

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

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-mention-$$
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# ===========================================================================
# AC1 (github leaf): itp_github_read_task exposes `author` normalized from
# `.author.login`, absent → "".
# ===========================================================================
echo "=== AC1 github leaf: read_task author field ==="
(
  export BOT_LOGIN=my-claw
  _GH_VIEW_PAYLOAD='{"title":"T","body":"B","state":"OPEN","labels":[],"author":{"login":"filer-jane"}}'
  gh() { printf '%s' "$_GH_VIEW_PAYLOAD"; }
  export -f gh; export _GH_VIEW_PAYLOAD
  source "$ITP_GITHUB"
  out="$(itp_github_read_task 42 "title,author")"
  a="$(jq -r '.author' <<<"$out")"
  keys="$(jq -r 'keys_unsorted | join(",")' <<<"$out")"
  [[ "$a" == "filer-jane" ]] && echo "OKA" || echo "BADA:$a"
  [[ "$keys" == "title,author" ]] && echo "OKK" || echo "BADK:$keys"

  # absent author -> ""
  _GH_VIEW_PAYLOAD='{"title":"T","state":"OPEN","labels":[]}'
  out2="$(itp_github_read_task 42 "author")"
  a2="$(jq -r '.author' <<<"$out2")"
  [[ "$a2" == "" ]] && echo "OKE" || echo "BADE:$a2"
) > /tmp/mention_gh_$$ 2>&1
grep -q OKA /tmp/mention_gh_$$ && { echo -e "  ${GREEN}PASS${NC}: github author = .author.login"; PASS=$((PASS+1)); } || { echo -e "  ${RED}FAIL${NC}: github author"; cat /tmp/mention_gh_$$; FAIL=$((FAIL+1)); }
grep -q OKK /tmp/mention_gh_$$ && { echo -e "  ${GREEN}PASS${NC}: github author projects exactly requested keys"; PASS=$((PASS+1)); } || { echo -e "  ${RED}FAIL${NC}: github author projection"; FAIL=$((FAIL+1)); }
grep -q OKE /tmp/mention_gh_$$ && { echo -e "  ${GREEN}PASS${NC}: github absent author → empty string"; PASS=$((PASS+1)); } || { echo -e "  ${RED}FAIL${NC}: github absent author"; FAIL=$((FAIL+1)); }
rm -f /tmp/mention_gh_$$

# ---------------------------------------------------------------------------
# AC1b (github leaf, ARGV pin): the on-demand `--json …,author` append. An argv-
# RECORDING gh stub proves the POSITIVE direction — requesting `author` actually
# adds `author` to the `gh issue view --json` field set. Without this, a stub
# that returns the payload unconditionally would still pass the normalization
# asserts above even if the leaf never widened the real argv → against live gh
# `.author` would never come back and the whole feature silently degrades to the
# REPO_OWNER/empty fallback with no failing test. (The NEGATIVE direction — a
# non-author read staying byte-identical `title,body,state,labels` — is pinned by
# the unchanged test-itp-write-leaves.sh TC-MCB-EQUIV-READSHAPE.)
# ---------------------------------------------------------------------------
echo "=== AC1b github leaf: on-demand --json author append (argv pin) ==="
(
  export BOT_LOGIN=my-claw
  _ARGV_FILE="$(mktemp)"; export _ARGV_FILE
  gh() { printf '%s\n' "$@" > "$_ARGV_FILE"; printf '{"title":"T","state":"OPEN","labels":[],"author":{"login":"jane"}}'; }
  export -f gh
  source "$ITP_GITHUB"
  itp_github_read_task 42 "author" >/dev/null
  argv_author="$(paste -sd' ' "$_ARGV_FILE")"
  itp_github_read_task 42 "title,author" >/dev/null
  argv_title_author="$(paste -sd' ' "$_ARGV_FILE")"
  rm -f "$_ARGV_FILE"
  [[ "$argv_author" == "issue view 42 --repo $REPO --json title,body,state,labels,author" ]] && echo "OK1" || echo "BAD1:$argv_author"
  [[ "$argv_title_author" == "issue view 42 --repo $REPO --json title,body,state,labels,author" ]] && echo "OK2" || echo "BAD2:$argv_title_author"
) > /tmp/mention_argv_$$ 2>&1
grep -q OK1 /tmp/mention_argv_$$ && { echo -e "  ${GREEN}PASS${NC}: requesting author appends ,author to --json argv"; PASS=$((PASS+1)); } || { echo -e "  ${RED}FAIL${NC}: author argv append"; cat /tmp/mention_argv_$$; FAIL=$((FAIL+1)); }
grep -q OK2 /tmp/mention_argv_$$ && { echo -e "  ${GREEN}PASS${NC}: mixed title,author request still appends ,author"; PASS=$((PASS+1)); } || { echo -e "  ${RED}FAIL${NC}: mixed author argv append"; FAIL=$((FAIL+1)); }
rm -f /tmp/mention_argv_$$

# ===========================================================================
# AC1 (gitlab leaf): itp_gitlab_read_task exposes `author` from `.author.username`.
# ===========================================================================
echo "=== AC1 gitlab leaf: read_task author field ==="
(
  _GL_PAYLOAD='{"iid":42,"title":"t","description":"b","state":"opened","labels":[],"author":{"username":"gl-filer"}}'
  _gl_api() { printf '%s' "$_GL_PAYLOAD"; }
  _gl_urlencode() { printf '%s' "$1"; }
  export -f _gl_api _gl_urlencode; export _GL_PAYLOAD
  export GITLAB_PROJECT="group%2Fproject"
  source "$ITP_GITLAB"
  out="$(itp_gitlab_read_task 42 "title,author")"
  a="$(jq -r '.author' <<<"$out")"
  [[ "$a" == "gl-filer" ]] && echo "OKA" || echo "BADA:$a"
  # absent author -> ""
  _GL_PAYLOAD='{"iid":42,"title":"t","description":"b","state":"opened","labels":[]}'
  out2="$(itp_gitlab_read_task 42 "author")"
  a2="$(jq -r '.author' <<<"$out2")"
  [[ "$a2" == "" ]] && echo "OKE" || echo "BADE:$a2"
) > /tmp/mention_gl_$$ 2>&1
grep -q OKA /tmp/mention_gl_$$ && { echo -e "  ${GREEN}PASS${NC}: gitlab author = .author.username"; PASS=$((PASS+1)); } || { echo -e "  ${RED}FAIL${NC}: gitlab author"; cat /tmp/mention_gl_$$; FAIL=$((FAIL+1)); }
grep -q OKE /tmp/mention_gl_$$ && { echo -e "  ${GREEN}PASS${NC}: gitlab absent author → empty string"; PASS=$((PASS+1)); } || { echo -e "  ${RED}FAIL${NC}: gitlab absent author"; FAIL=$((FAIL+1)); }
rm -f /tmp/mention_gl_$$

# ===========================================================================
# AC2 (helper): issue_mention_login resolution + per-provider fallback.
# We stub itp_read_task directly so this exercises the helper's branch logic,
# not a provider leaf.
# ===========================================================================
echo "=== AC2 helper: issue_mention_login ==="

_mention_in_env() {
  # $1 = ISSUE_PROVIDER, $2 = author login ("" for none)
  env -u AUTONOMOUS_PROVIDERS_DIR ISSUE_PROVIDER="$1" \
      REPO="$REPO" REPO_OWNER="$REPO_OWNER" PROJECT_ID="$PROJECT_ID" \
      _AUTHOR="$2" \
  bash -c '
    set -uo pipefail
    source "'"$LIB_PROVIDER"'"
    itp_read_task() {
      if [[ -n "${_AUTHOR}" ]]; then printf "{\"author\":\"%s\"}" "$_AUTHOR"; else printf "{}"; fi
    }
    issue_mention_login 42
  '
}

out="$(_mention_in_env github filer-jane)"
assert_eq "helper: github + author present → author login" "filer-jane" "$out"

out="$(_mention_in_env gitlab gl-filer)"
assert_eq "helper: gitlab + author present → author login" "gl-filer" "$out"

out="$(_mention_in_env github "")"
assert_eq "helper: github + author absent → EMPTY (fallback policy lives in resolve_escalation_mention, INV-138)" "" "$out"

out="$(_mention_in_env gitlab "")"
assert_eq "helper: gitlab + author absent → EMPTY (no group ping)" "" "$out"

# read_task hard failure (rc≠0) must degrade like an absent author, not abort.
out="$(env -u AUTONOMOUS_PROVIDERS_DIR ISSUE_PROVIDER=github \
        REPO="$REPO" REPO_OWNER="$REPO_OWNER" PROJECT_ID="$PROJECT_ID" \
  bash -c '
    set -uo pipefail
    source "'"$LIB_PROVIDER"'"
    itp_read_task() { echo "boom" >&2; return 1; }
    issue_mention_login 42
  ')"
assert_eq "helper: github + read_task failure → EMPTY, no abort (fallback policy lives in resolve_escalation_mention, INV-138)" "" "$out"

out="$(env -u AUTONOMOUS_PROVIDERS_DIR ISSUE_PROVIDER=gitlab \
        REPO="$REPO" REPO_OWNER="$REPO_OWNER" PROJECT_ID="$PROJECT_ID" \
  bash -c '
    set -uo pipefail
    source "'"$LIB_PROVIDER"'"
    itp_read_task() { echo "boom" >&2; return 1; }
    issue_mention_login 42
  ')"
assert_eq "helper: gitlab + read_task failure → EMPTY (no abort, no group ping)" "" "$out"

# The empty-resolution breadcrumb MUST go to stderr — the codebase's `log()`
# writes to STDOUT, and callers capture this helper's stdout into `_mention`, so
# an un-redirected breadcrumb would land inside the mention and render into the
# comment body. Define a stdout-writing `log` (matching the real wrappers) and
# assert the captured value is still exactly empty, not the breadcrumb text.
out="$(env -u AUTONOMOUS_PROVIDERS_DIR ISSUE_PROVIDER=gitlab \
        REPO="$REPO" REPO_OWNER="$REPO_OWNER" PROJECT_ID="$PROJECT_ID" \
  bash -c '
    set -uo pipefail
    source "'"$LIB_PROVIDER"'"
    log() { echo "[test-log] $*"; }          # real codebase log() writes STDOUT
    itp_read_task() { return 1; }
    issue_mention_login 42                     # stderr NOT redirected here
  ' 2>/dev/null)"
assert_eq "helper: empty-resolution breadcrumb goes to stderr, never pollutes captured mention" "" "$out"

# ===========================================================================
# AC2 wiring: no @${REPO_OWNER} literal remains in the human-NOTIFICATION comment
# bodies of lib-dispatch.sh / autonomous-review.sh (the mention sites migrate to
# the helper's resolved login). Two deliberate exclusions:
#   - Auth/token-scoping ${REPO_OWNER} uses never carry a leading `@`, so the
#     `@`-anchored pattern already skips them.
#   - The review-agent PROMPT prose ("Corrections or clarifications from the repo
#     owner (@${REPO_OWNER})") is descriptive text fed to the review agent, NOT a
#     posted GitHub/GitLab comment — it never renders as an @-mention that pings
#     anyone, so it is out of scope for [INV-138] and left byte-unchanged.
# ===========================================================================
echo "=== AC2 wiring: no @\${REPO_OWNER} mention literal in NOTIFICATION bodies ==="
for f in "$SCRIPTS/lib-dispatch.sh" "$SCRIPTS/autonomous-review.sh"; do
  # Exclude the known prompt-prose bullet before matching.
  hits="$(grep -nE '@\$\{REPO_OWNER\}|@\$REPO_OWNER' "$f" | grep -vF 'Corrections or clarifications from the repo owner')"
  if [[ -n "$hits" ]]; then
    echo -e "  ${RED}FAIL${NC}: $(basename "$f") still contains an @\${REPO_OWNER} notification mention:"
    printf '%s\n' "$hits" | head
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${NC}: $(basename "$f") carries no @\${REPO_OWNER} notification mention"
    PASS=$((PASS + 1))
  fi
done

# ---------------------------------------------------------------------------
# AC2b render-idiom guard: every migrated site must use the EMPTY-SAFE
# `${_mention:+@}${_mention}` form, never a bare `@${_mention}` / `@$_mention`.
# A bare form emits a dangling `@` when the login is empty — exactly the
# gitlab-absent case the feature exists to serve — and would pass the "no
# @${REPO_OWNER}" guard above. Static scan: any `@`-prefixed `_mention` expansion
# NOT immediately preceded by the `:+@` guard is a defect.
# ---------------------------------------------------------------------------
echo "=== AC2b render-idiom: no bare @\${_mention} (dangling-@ on empty) ==="
for f in "$SCRIPTS/lib-dispatch.sh" "$SCRIPTS/autonomous-review.sh"; do
  bare="$(grep -nE '@\$\{_mention\}|@\$_mention' "$f")"
  if [[ -n "$bare" ]]; then
    echo -e "  ${RED}FAIL${NC}: $(basename "$f") uses a bare @\${_mention} (dangling @ when login empty):"
    printf '%s\n' "$bare" | head
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${NC}: $(basename "$f") uses only the empty-safe \${_mention:+@}\${_mention} form"
    PASS=$((PASS + 1))
  fi
done

# Behavior of the render idiom itself: empty → no `@`, non-empty → `@login`.
_m="jane"; out="X ${_m:+@}${_m} Y"; assert_eq "render idiom: non-empty login → @login" "X @jane Y" "$out"
_m="";     out="X ${_m:+@}${_m} Y"; assert_eq "render idiom: empty login → no @ token"  "X  Y" "$out"

echo ""
echo "=== Summary ==="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
[ "$FAIL" -eq 0 ]
