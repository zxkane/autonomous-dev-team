#!/bin/bash
# test-pr-author-escalation-mention.sh — issue #495.
#
# Pins:
#   R1 — `author` joins the pr_view-only §3.2.1 vocabulary (15th member) on
#        BOTH providers; `chp_pr_list` / `chp_find_pr_for_issue` keep
#        rejecting it on both hosts (provider parity).
#   R2 — `resolve_pr_author_mention` (lib-review-resolve-author.sh): mandatory
#        bot-detection + `HUMAN_ESCALATION_LOGIN`/`REPO_OWNER` fallback chain,
#        always rc 0, exactly one `@<token>` on stdout.
#   R3 — call-site conversion source-shape pins: the 8 converted PR-scoped
#        sites, the 2 maintainer-target sites, the 6 operator-target sites,
#        and the 1 never-touch prompt-text site.
#
# See docs/test-cases/pr-author-escalation-mention.md for the TC-PAEM-*
# mapping.
#
# Run: bash tests/unit/test-pr-author-escalation-mention.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GH_LEAF="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/chp-github.sh"
GL_LEAF="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/chp-gitlab.sh"
RESOLVE_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-resolve-author.sh"
DISPATCH_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
DISPATCHER_TICK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$desc"
  else bad "$desc"; echo "      expected: |$expected|"; echo "      actual:   |$actual|"; fi
}
assert_rc_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$desc (rc=$actual)"
  else bad "$desc (expected rc=$expected, got rc=$actual)"; fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then ok "$desc"
  else bad "$desc"; echo "      needle: $needle"; echo "      haystack (300): ${haystack:0:300}"; fi
}
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then ok "$desc"
  else bad "$desc (unexpectedly found)"; echo "      needle: $needle"; fi
}
assert_file_exists() {
  local desc="$1" file="$2"
  if [ -f "$file" ]; then ok "$desc"
  else bad "$desc"; echo "      missing file: $file"; fi
}

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }
assert_file_exists "setup: chp-github.sh exists" "$GH_LEAF"
assert_file_exists "setup: chp-gitlab.sh exists" "$GL_LEAF"
assert_file_exists "setup: lib-review-resolve-author.sh exists" "$RESOLVE_LIB"
assert_file_exists "setup: lib-dispatch.sh exists" "$DISPATCH_LIB"
assert_file_exists "setup: autonomous-review.sh exists" "$WRAPPER"

# ============================================================================
# R1a — GitHub `chp_github_pr_view` accepts `author`; list/find reject it.
# ============================================================================
echo "=== R1a: GitHub provider — author vocabulary (pr_view-only) ==="

_run_gh() (
  # Subshell isolation: each invocation gets a fresh `gh` stub + fresh source
  # of the leaf (guarded readonly vocabulary constants tolerate re-source).
  set -uo pipefail
  export REPO="owner/repo"
  gh() {
    if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
      cat "$_STUB_PAYLOAD"
      return 0
    fi
    return 1
  }
  export -f gh
  # shellcheck source=../../skills/autonomous-dispatcher/scripts/providers/chp-github.sh
  source "$GH_LEAF"
  "$@"
)

TMPDIR_GH=$(mktemp -d)
trap 'rm -rf "$TMPDIR_GH"' EXIT

printf '%s' '{"author":{"login":"alice"}}' > "$TMPDIR_GH/author-alice.json"
printf '%s' '{"author":null}' > "$TMPDIR_GH/author-null.json"

_STUB_PAYLOAD="$TMPDIR_GH/author-alice.json"
out=$(_STUB_PAYLOAD="$_STUB_PAYLOAD" _run_gh chp_github_pr_view 42 "author"); rc=$?
assert_rc_eq "TC-PAEM-001 chp_github_pr_view author rc" "0" "$rc"
assert_eq "TC-PAEM-001 chp_github_pr_view author flattens login" '{"author":"alice"}' "$out"

_STUB_PAYLOAD="$TMPDIR_GH/author-null.json"
out=$(_STUB_PAYLOAD="$_STUB_PAYLOAD" _run_gh chp_github_pr_view 42 "author")
assert_eq "TC-PAEM-002 chp_github_pr_view null author normalizes to key-present null" '{"author":null}' "$out"

out=$(_run_gh chp_github_pr_list open "author" 2>&1); rc=$?
assert_rc_eq "TC-PAEM-003 chp_github_pr_list rejects author" "2" "$rc"
assert_contains "TC-PAEM-003 chp_github_pr_list rejection names 'author'" "$out" "author"

out=$(_run_gh chp_github_find_pr_for_issue 42 "author" 2>&1); rc=$?
assert_rc_eq "TC-PAEM-004 chp_github_find_pr_for_issue rejects author" "2" "$rc"
assert_contains "TC-PAEM-004 chp_github_find_pr_for_issue rejection names 'author'" "$out" "author"

out=$(_STUB_PAYLOAD="$TMPDIR_GH/author-null.json" _run_gh chp_github_pr_view 42 "bogusField" 2>&1); rc=$?
assert_rc_eq "TC-PAEM-008a chp_github_pr_view still rejects unknown field (no gate regression)" "2" "$rc"

printf '%s' '{"author":{"login":"alice"},"number":42}' > "$TMPDIR_GH/author-number.json"
out=$(_STUB_PAYLOAD="$TMPDIR_GH/author-number.json" _run_gh chp_github_pr_view 42 "author,number")
assert_eq "TC-PAEM-009a chp_github_pr_view author+number both present" '{"author":"alice","number":42}' "$out"

# ============================================================================
# R1b — GitLab `chp_gitlab_pr_view` accepts `author`; list/find reject it.
# ============================================================================
echo
echo "=== R1b: GitLab provider — author vocabulary (pr_view-only) ==="

_run_gl() (
  set -uo pipefail
  export GITLAB_PROJECT="group%2Fproj"
  _gl_api() { cat "$_STUB_PAYLOAD"; return 0; }
  export -f _gl_api
  # shellcheck source=../../skills/autonomous-dispatcher/scripts/providers/chp-gitlab.sh
  source "$GL_LEAF"
  "$@"
)

TMPDIR_GL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_GH" "$TMPDIR_GL"' EXIT

printf '%s' '{"iid":42,"state":"opened","author":{"username":"bob"}}' > "$TMPDIR_GL/author-bob.json"
printf '%s' '{"iid":42,"state":"opened","author":null}' > "$TMPDIR_GL/author-null.json"

out=$(_STUB_PAYLOAD="$TMPDIR_GL/author-bob.json" _run_gl chp_gitlab_pr_view 42 "author"); rc=$?
assert_rc_eq "TC-PAEM-005 chp_gitlab_pr_view author rc" "0" "$rc"
assert_eq "TC-PAEM-005 chp_gitlab_pr_view author flattens username" '{"author":"bob"}' "$(jq -c . <<<"$out")"

# TC-PAEM-005b (#495 review round 6): a degraded/unexpected MR payload with
# `"author": null` (the GitLab leaf's own comment documents this as the
# non-ordinary case, since a real MR view always has an author object) must
# still normalize to a key-present null, mirroring GitHub's TC-PAEM-002.
out=$(_STUB_PAYLOAD="$TMPDIR_GL/author-null.json" _run_gl chp_gitlab_pr_view 42 "author"); rc=$?
assert_rc_eq "TC-PAEM-005b chp_gitlab_pr_view null author rc" "0" "$rc"
assert_eq "TC-PAEM-005b chp_gitlab_pr_view null author normalizes to key-present null" '{"author":null}' "$(jq -c . <<<"$out")"

out=$(_STUB_PAYLOAD="$TMPDIR_GL/author-bob.json" _run_gl chp_gitlab_pr_list open "author" 2>&1); rc=$?
assert_rc_eq "TC-PAEM-006 chp_gitlab_pr_list rejects author" "2" "$rc"
assert_contains "TC-PAEM-006 chp_gitlab_pr_list rejection names 'author'" "$out" "author"

out=$(_STUB_PAYLOAD="$TMPDIR_GL/author-bob.json" _run_gl chp_gitlab_find_pr_for_issue 42 "author" 2>&1); rc=$?
assert_rc_eq "TC-PAEM-007 chp_gitlab_find_pr_for_issue rejects author" "2" "$rc"
assert_contains "TC-PAEM-007 chp_gitlab_find_pr_for_issue rejection names 'author'" "$out" "author"

out=$(_STUB_PAYLOAD="$TMPDIR_GL/author-bob.json" _run_gl chp_gitlab_pr_view 42 "bogusField" 2>&1); rc=$?
assert_rc_eq "TC-PAEM-008b chp_gitlab_pr_view still rejects unknown field (no gate regression)" "2" "$rc"

printf '%s' '{"iid":42,"state":"opened","author":{"username":"bob"}}' > "$TMPDIR_GL/author-number.json"
out=$(_STUB_PAYLOAD="$TMPDIR_GL/author-number.json" _run_gl chp_gitlab_pr_view 42 "author,number")
assert_eq "TC-PAEM-009b chp_gitlab_pr_view author+number both present" '{"author":"bob","number":42}' "$(jq -c . <<<"$out")"

# ============================================================================
# R2 — resolve_pr_author_mention: bot-detection + fallback chain
# ============================================================================
echo
echo "=== R2: resolve_pr_author_mention ==="

_run_resolver() (
  set -uo pipefail
  export REPO_OWNER="the-owner"
  chp_pr_view() {
    case "$_RPAM_MODE" in
      fail) return 1 ;;
      malformed) printf '%s' 'not-json' ;;
      *) printf '{"author": %s}' "$_RPAM_AUTHOR" ;;
    esac
  }
  export -f chp_pr_view
  # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-resolve-author.sh
  source "$RESOLVE_LIB"
  "$@"
)

_RPAM_MODE=ok _RPAM_AUTHOR='"alice"' out=$(_RPAM_MODE=ok _RPAM_AUTHOR='"alice"' _run_resolver resolve_pr_author_mention 42 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-010 human author rc" "0" "$rc"
assert_eq "TC-PAEM-010 human author mention" "@alice" "$out"

out=$(_RPAM_MODE=ok _RPAM_AUTHOR='"app/my-dev-bot"' _run_resolver resolve_pr_author_mention 42 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-011 app/ prefix rc" "0" "$rc"
assert_eq "TC-PAEM-011 app/ prefix falls back" "@the-owner" "$out"

out=$(_RPAM_MODE=ok _RPAM_AUTHOR='"my-claw[bot]"' _run_resolver resolve_pr_author_mention 42 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-012 [bot] suffix rc" "0" "$rc"
assert_eq "TC-PAEM-012 [bot] suffix falls back" "@the-owner" "$out"

out=$(_RPAM_MODE=ok _RPAM_AUTHOR='"project_123_bot_abc"' _run_resolver resolve_pr_author_mention 42 2>/dev/null)
assert_eq "TC-PAEM-013 gitlab service-account pattern falls back" "@the-owner" "$out"
out=$(_RPAM_MODE=ok _RPAM_AUTHOR='"group_9_bot"' _run_resolver resolve_pr_author_mention 42 2>/dev/null)
assert_eq "TC-PAEM-013b gitlab service-account pattern (no suffix) falls back" "@the-owner" "$out"

out=$(BOT_LOGIN="custom-app-name" _RPAM_MODE=ok _RPAM_AUTHOR='"custom-app-name"' _run_resolver resolve_pr_author_mention 42 2>/dev/null)
assert_eq "TC-PAEM-014 author==BOT_LOGIN falls back" "@the-owner" "$out"

# TC-PAEM-014b/c (#495 review finding #1): DEV_BOT_LOGIN is the dispatcher-
# side counterpart to BOT_LOGIN — BOT_LOGIN is only ever resolved inside
# autonomous-review.sh's own process (never in lib-dispatch.sh's), so a
# plain-login dev-agent identity (no app/ prefix, no [bot] suffix) needs its
# own operator-configured override to be recognized as a bot on the
# dispatcher call path.
out=$(DEV_BOT_LOGIN="my-org-ci-bot" _RPAM_MODE=ok _RPAM_AUTHOR='"my-org-ci-bot"' _run_resolver resolve_pr_author_mention 42 2>/dev/null)
assert_eq "TC-PAEM-014b author==DEV_BOT_LOGIN falls back" "@the-owner" "$out"

out=$(DEV_BOT_LOGIN="my-org-ci-bot" _RPAM_MODE=ok _RPAM_AUTHOR='"alice"' _run_resolver resolve_pr_author_mention 42 2>/dev/null)
assert_eq "TC-PAEM-014c DEV_BOT_LOGIN set but author differs → human still wins" "@alice" "$out"

out=$(_RPAM_MODE=ok _RPAM_AUTHOR='"my-org-ci-bot"' _run_resolver resolve_pr_author_mention 42 2>/dev/null)
assert_eq "TC-PAEM-014d DEV_BOT_LOGIN unset → a plain-login bot author is NOT caught (documented gap; operator must set DEV_BOT_LOGIN)" "@my-org-ci-bot" "$out"

out=$(_RPAM_MODE=ok _RPAM_AUTHOR='"abbot"' _run_resolver resolve_pr_author_mention 42 2>/dev/null)
assert_eq "TC-PAEM-015a human login containing 'bot' substring is NOT misclassified (abbot)" "@abbot" "$out"
out=$(_RPAM_MODE=ok _RPAM_AUTHOR='"robert"' _run_resolver resolve_pr_author_mention 42 2>/dev/null)
assert_eq "TC-PAEM-015b human login containing 'bot' substring is NOT misclassified (robert)" "@robert" "$out"

out=$(_RPAM_MODE=ok _RPAM_AUTHOR='null' _run_resolver resolve_pr_author_mention 42 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-016 null author rc" "0" "$rc"
assert_eq "TC-PAEM-016 null author falls back" "@the-owner" "$out"

out=$(_RPAM_MODE=ok _RPAM_AUTHOR='""' _run_resolver resolve_pr_author_mention 42 2>/dev/null)
assert_eq "TC-PAEM-017 empty-string author falls back" "@the-owner" "$out"

out=$(_RPAM_MODE=fail _run_resolver resolve_pr_author_mention 42 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-018 chp_pr_view failure rc" "0" "$rc"
assert_eq "TC-PAEM-018 chp_pr_view failure falls back" "@the-owner" "$out"

out=$(_RPAM_MODE=malformed _run_resolver resolve_pr_author_mention 42 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-019 malformed output rc" "0" "$rc"
assert_eq "TC-PAEM-019 malformed output falls back" "@the-owner" "$out"

# TC-PAEM-019b/c/d (#495 review round 3): a malformed `.author` SHAPE inside
# an otherwise well-formed JSON object must fall back, not be echoed verbatim
# into the mention token — an object/array shape or a whitespace-containing
# string would otherwise produce a multiline/multi-token comment body.
out=$(_RPAM_MODE=ok _RPAM_AUTHOR='{"login":"evil"}' _run_resolver resolve_pr_author_mention 42 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-019b object-shaped author rc" "0" "$rc"
assert_eq "TC-PAEM-019b object-shaped author falls back (not echoed verbatim)" "@the-owner" "$out"

out=$(_RPAM_MODE=ok _RPAM_AUTHOR='["evil","actor"]' _run_resolver resolve_pr_author_mention 42 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-019c array-shaped author rc" "0" "$rc"
assert_eq "TC-PAEM-019c array-shaped author falls back (not echoed verbatim)" "@the-owner" "$out"

out=$(_RPAM_MODE=ok _RPAM_AUTHOR='"evil actor"' _run_resolver resolve_pr_author_mention 42 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-019d whitespace-containing string author rc" "0" "$rc"
assert_eq "TC-PAEM-019d whitespace-containing string author falls back (not a multi-token mention)" "@the-owner" "$out"

out=$(_RPAM_MODE=ok _RPAM_AUTHOR='"evil\nactor"' _run_resolver resolve_pr_author_mention 42 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-019e newline-containing string author rc" "0" "$rc"
assert_eq "TC-PAEM-019e newline-containing string author falls back (not a multiline mention)" "@the-owner" "$out"

# TC-PAEM-019f (#495 review round 5): an author string containing an
# embedded `@` (e.g. `alice@evil`) must fall back rather than being echoed
# verbatim — `@alice@evil` is a second/malformed mention token, violating the
# exactly-one-token contract just like the whitespace cases above.
out=$(_RPAM_MODE=ok _RPAM_AUTHOR='"alice@evil"' _run_resolver resolve_pr_author_mention 42 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-019f at-sign-containing string author rc" "0" "$rc"
assert_eq "TC-PAEM-019f at-sign-containing string author falls back (not a multi-token mention)" "@the-owner" "$out"

out=$(_run_resolver resolve_pr_author_mention "abc" 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-020 non-numeric PR arg rc" "0" "$rc"
assert_eq "TC-PAEM-020 non-numeric PR arg falls back" "@the-owner" "$out"

out=$(_run_resolver resolve_pr_author_mention "" 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-021 empty PR arg rc" "0" "$rc"
assert_eq "TC-PAEM-021 empty PR arg falls back" "@the-owner" "$out"

out=$(HUMAN_ESCALATION_LOGIN="maintainer1" _RPAM_MODE=ok _RPAM_AUTHOR='"app/dev-bot"' _run_resolver resolve_pr_author_mention 42 2>/dev/null)
assert_eq "TC-PAEM-022 HUMAN_ESCALATION_LOGIN set + bot author → escalation login" "@maintainer1" "$out"

out=$(_RPAM_MODE=ok _RPAM_AUTHOR='"app/dev-bot"' _run_resolver resolve_pr_author_mention 42 2>/dev/null)
assert_eq "TC-PAEM-023 HUMAN_ESCALATION_LOGIN unset + bot author → REPO_OWNER" "@the-owner" "$out"

out=$(HUMAN_ESCALATION_LOGIN="maintainer1" _RPAM_MODE=ok _RPAM_AUTHOR='"alice"' _run_resolver resolve_pr_author_mention 42 2>/dev/null)
assert_eq "TC-PAEM-024 HUMAN_ESCALATION_LOGIN set + human author → human still wins" "@alice" "$out"

# TC-PAEM-024b-f (#495 review round 3 finding #2) — a malformed configured
# HUMAN_ESCALATION_LOGIN must never be echoed verbatim into the mention: it
# would break the "exactly one @<token>" contract (a second `@`, or a
# whitespace/newline-split value producing a multi-token/multiline comment
# body). Each row falls through to REPO_OWNER instead.
out=$(HUMAN_ESCALATION_LOGIN="two words" _RPAM_MODE=ok _RPAM_AUTHOR='"app/dev-bot"' _run_resolver resolve_pr_author_mention 42 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-024b whitespace-containing HUMAN_ESCALATION_LOGIN rc" "0" "$rc"
assert_eq "TC-PAEM-024b whitespace-containing HUMAN_ESCALATION_LOGIN falls back to REPO_OWNER" "@the-owner" "$out"

out=$(HUMAN_ESCALATION_LOGIN="@maintainer1" _RPAM_MODE=ok _RPAM_AUTHOR='"app/dev-bot"' _run_resolver resolve_pr_author_mention 42 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-024c leading-@ HUMAN_ESCALATION_LOGIN rc" "0" "$rc"
assert_eq "TC-PAEM-024c leading-@ HUMAN_ESCALATION_LOGIN falls back to REPO_OWNER (never @@maintainer1)" "@the-owner" "$out"

out=$(HUMAN_ESCALATION_LOGIN="alice@evil" _RPAM_MODE=ok _RPAM_AUTHOR='"app/dev-bot"' _run_resolver resolve_pr_author_mention 42 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-024d embedded-@ HUMAN_ESCALATION_LOGIN rc" "0" "$rc"
assert_eq "TC-PAEM-024d embedded-@ HUMAN_ESCALATION_LOGIN falls back to REPO_OWNER" "@the-owner" "$out"

out=$(HUMAN_ESCALATION_LOGIN=$'first\nsecond' _RPAM_MODE=ok _RPAM_AUTHOR='"app/dev-bot"' _run_resolver resolve_pr_author_mention 42 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-024e newline-containing HUMAN_ESCALATION_LOGIN rc" "0" "$rc"
assert_eq "TC-PAEM-024e newline-containing HUMAN_ESCALATION_LOGIN falls back to REPO_OWNER" "@the-owner" "$out"

out=$(HUMAN_ESCALATION_LOGIN="maintainer1" _RPAM_MODE=ok _RPAM_AUTHOR='"app/dev-bot"' _run_resolver resolve_pr_author_mention 42 2>/dev/null); rc=$?
assert_eq "TC-PAEM-024f well-formed HUMAN_ESCALATION_LOGIN is unaffected by the new validation" "@maintainer1" "$out"

# TC-PAEM-025 — exactly one token, no stray whitespace/newlines, across the
# fallback and success rows exercised above.
for row in \
  'ok|"alice"|' \
  'ok|"app/dev-bot"|' \
  'fail||' \
  'malformed||' \
  ; do
  IFS='|' read -r _m _a _extra <<<"$row"
  out=$(_RPAM_MODE="$_m" _RPAM_AUTHOR="${_a:-null}" _run_resolver resolve_pr_author_mention 42 2>/dev/null)
  n_tokens=$(printf '%s' "$out" | wc -w | tr -d ' ')
  n_lines=$(printf '%s' "$out" | wc -l | tr -d ' ')
  assert_eq "TC-PAEM-025 mode=$_m emits exactly one whitespace-token" "1" "$n_tokens"
  assert_eq "TC-PAEM-025 mode=$_m emits no embedded newline" "0" "$n_lines"
done

# TC-PAEM-026 — the function itself never aborts a strict-mode caller (every
# call above ran with `set -uo pipefail` active in the subshell; a `set -e`
# variant additionally proves no internal `return 1` path is reachable).
out=$(bash -c '
  set -euo pipefail
  export REPO_OWNER="the-owner"
  chp_pr_view() { return 1; }
  export -f chp_pr_view
  source "'"$RESOLVE_LIB"'"
  resolve_pr_author_mention 42
  echo "SURVIVED_SET_E"
' 2>/dev/null)
assert_contains "TC-PAEM-026 resolver never aborts a set -e caller on the failure path" "$out" "SURVIVED_SET_E"

# ============================================================================
# R3 — call-site conversion source-shape pins
# ============================================================================
echo
echo "=== R3: call-site conversion (source-shape) ==="

DISPATCH_SRC=$(cat "$DISPATCH_LIB")
WRAPPER_SRC=$(cat "$WRAPPER")

# --- Converted sites (lib-dispatch.sh) ---
assert_contains "TC-PAEM-030 INV-92 403-stall report calls resolve_escalation_mention" \
  "$DISPATCH_SRC" 'its scoped token hit \`Resource not accessible by integration\` on a PR-metadata edit, or the finding requires a maintainer / post-merge action. Marking stalled — no further \`dev-new\` will be dispatched. $(resolve_escalation_mention "$issue_num" "$_np_pr_number")'

assert_contains "TC-PAEM-031 INV-85 no-progress stall report calls resolve_escalation_mention" \
  "$DISPATCH_SRC" 'The finding appears un-actionable by the dev agent. Marking stalled — no further \`dev-new\` will be dispatched. $(resolve_escalation_mention "$issue_num" "$_np_pr_number")'

assert_contains "TC-PAEM-032 INV-92 non-actionable stall report calls resolve_escalation_mention" \
  "$DISPATCH_SRC" 'Marking stalled — no \`dev-new\` will be dispatched (\`reason=non_actionable_finding\`). $(resolve_escalation_mention "$issue_num" "$_np_pr_number")'

assert_contains "TC-PAEM-033 INV-105 convergence-breaker report calls resolve_escalation_mention" \
  "$DISPATCH_SRC" $'removal re-arms the pipeline and resets the retry counter, INV-05).**\n$(resolve_escalation_mention "$issue_num" "$_np_pr_number")'

assert_contains "TC-PAEM-034a _same_head_verdict_aware_recovery INV-92 branch calls resolve_escalation_mention(issue_num, pr_num)" \
  "$DISPATCH_SRC" 'Marking stalled — no \`dev-new\` will be dispatched. $(resolve_escalation_mention "$issue_num" "$pr_num") please apply the change manually.'

assert_contains "TC-PAEM-034b _same_head_verdict_aware_recovery non-substantive-budget-spent branch calls resolve_escalation_mention(issue_num, pr_num)" \
  "$DISPATCH_SRC" 'with no progress. Marking stalled rather than parking indefinitely. $(resolve_escalation_mention "$issue_num" "$pr_num") please investigate."
    mark_stalled "$issue_num"
    return 0
    ;;'

assert_contains "TC-PAEM-034c _same_head_verdict_aware_recovery self-heal/crash-budget-spent branch calls resolve_escalation_mention(issue_num, pr_num)" \
  "$DISPATCH_SRC" 'self-heal/crash-recovery \`dev-new\` for this HEAD with no progress. Marking stalled rather than parking indefinitely. $(resolve_escalation_mention "$issue_num" "$pr_num") please investigate."'

assert_contains "TC-PAEM-034d _same_head_verdict_aware_recovery signature carries pr_num as 5th positional" \
  "$DISPATCH_SRC" 'local issue_num="$1" pr_ref="$2" current_head="$3" cause="$4" pr_num="${5:-}"'

assert_contains "TC-PAEM-034e caller passes pr_num to _same_head_verdict_aware_recovery" \
  "$DISPATCH_SRC" $'_same_head_verdict_aware_recovery \\\n        "$issue_num" "$pr_ref" "$current_head" "$_recovery_cause" "$pr_num" \\\n        || _same_head_recovery_rc=$?'

# --- Converted site (autonomous-review.sh) ---
assert_contains "TC-PAEM-035 INV-127 round-cap report calls resolve_escalation_mention(ISSUE_NUMBER, PR_NUMBER)" \
  "$WRAPPER_SRC" $'removal re-arms the pipeline).\n$(resolve_escalation_mention "$ISSUE_NUMBER" "$PR_NUMBER")\nROUNDCAPREPORT'

assert_contains "TC-PAEM-036 [#453] same-HEAD E2E-gate breaker report calls resolve_escalation_mention(ISSUE_NUMBER, PR_NUMBER)" \
  "$WRAPPER_SRC" $'the pipeline).**\n$(resolve_escalation_mention "$ISSUE_NUMBER" "$PR_NUMBER")\nGATEBREAKREPORT'

# TC-PAEM-037/038 — end-to-end resolver behavior on the INV-85 no-progress
# path is covered functionally by TC-PAEM-010/011 above (same resolver, same
# fallback chain) — the source-shape pin (TC-PAEM-031) proves THIS call site
# is wired to it.

# --- Maintainer-target sites (never resolve_pr_author_mention; validated
# via resolve_operator_mention, not a raw HUMAN_ESCALATION_LOGIN:-REPO_OWNER
# interpolation — #495 review round 4 finding #1) ---
assert_contains "TC-PAEM-040 approval-failed fallback calls resolve_operator_mention" \
  "$WRAPPER_SRC" 'Review PASSED but formal PR approval failed (permission issue?). $(resolve_operator_mention) please approve and merge PR #${PR_NUMBER} manually.'
assert_not_contains "TC-PAEM-040b approval-failed fallback never calls resolve_escalation_mention" \
  "$WRAPPER_SRC" 'approval failed (permission issue?). $(resolve_pr_author_mention'

assert_contains "TC-PAEM-041 no-auto-close notice calls resolve_operator_mention" \
  "$WRAPPER_SRC" "Review PASSED — this issue has the 'no-auto-close' label. "'$(resolve_operator_mention) please review and merge PR #${PR_NUMBER} when ready.'
assert_not_contains "TC-PAEM-041b no-auto-close notice never calls resolve_escalation_mention" \
  "$WRAPPER_SRC" "no-auto-close' label. \$(resolve_pr_author_mention"

# --- Operator-target sites (validated via resolve_operator_mention, no
# resolve_pr_author_mention call — #495 review round 4 finding #1: the prior
# raw @${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER} interpolation bypassed the
# malformed-token validation _rpam_fallback already applies to the resolver's
# own fallback path) ---
for pair in \
  "TC-PAEM-050|Marking as stalled. "'$(resolve_operator_mention)'" please investigate manually." \
  "TC-PAEM-051|Marking stalled. "'$(resolve_operator_mention)'" please investigate the upstream review dependency" \
  "TC-PAEM-052|one-retry bound ([INV-85]) is degraded for this HEAD; the issue is still bounded by \\\`MAX_RETRIES\\\`. "'$(resolve_operator_mention)'" no action needed" \
  "TC-PAEM-053|please verify before removing the label. "'$(resolve_operator_mention)' \
  "TC-PAEM-054|"'$(resolve_operator_mention)'" this issue may need attention." \
  "TC-PAEM-055|"'$(resolve_operator_mention)'" please investigate — this is the class-level backstop" \
  ; do
  id="${pair%%|*}"
  needle="${pair#*|}"
  assert_contains "$id operator-target site calls resolve_operator_mention" "$DISPATCH_SRC" "$needle"
done

# None of the 8 direct-fallback sites should have been converted to
# resolve_pr_author_mention (the 6 operator sites can fire with zero PRs in
# scope; the 2 maintainer sites must never target the PR author).
assert_not_contains "TC-PAEM-050b MAX_RETRIES stall does not call resolve_pr_author_mention" \
  "$DISPATCH_SRC" 'Marking as stalled. $(resolve_pr_author_mention'

# --- Never-touch: the ONE remaining prompt-text @${REPO_OWNER} literal ---
bare_owner_count=$(grep -o '@\${REPO_OWNER}' "$WRAPPER" | wc -l | tr -d ' ')
assert_eq "TC-PAEM-060 exactly one byte-unchanged bare @\${REPO_OWNER} remains (the Step 0.5 prompt literal)" "1" "$bare_owner_count"
assert_contains "TC-PAEM-060b the remaining bare mention is the requirement-drift prompt line" \
  "$WRAPPER_SRC" 'Corrections or clarifications from the repo owner (@${REPO_OWNER})'

bare_owner_count_dispatch=$(grep -o '@\${REPO_OWNER}' "$DISPATCH_LIB" | wc -l | tr -d ' ')
assert_eq "TC-PAEM-060c lib-dispatch.sh has ZERO remaining bare @\${REPO_OWNER} literals" "0" "$bare_owner_count_dispatch"

# --- Zero remaining raw HUMAN_ESCALATION_LOGIN:-REPO_OWNER interpolations
# anywhere (#495 review round 4 finding #1: every one of the 8 direct sites
# must route through the validated resolve_operator_mention helper) ---
raw_direct_count_dispatch=$(grep -c '\${HUMAN_ESCALATION_LOGIN:-\$REPO_OWNER}' "$DISPATCH_LIB")
assert_eq "TC-PAEM-061 lib-dispatch.sh has ZERO raw HUMAN_ESCALATION_LOGIN:-REPO_OWNER interpolations" "0" "$raw_direct_count_dispatch"
raw_direct_count_wrapper=$(grep -c '\${HUMAN_ESCALATION_LOGIN:-\$REPO_OWNER}' "$WRAPPER")
assert_eq "TC-PAEM-062 autonomous-review.sh has ZERO raw HUMAN_ESCALATION_LOGIN:-REPO_OWNER interpolations" "0" "$raw_direct_count_wrapper"

# --- resolve_operator_mention itself: validated single-token contract,
# identical to resolve_pr_author_mention's own fallback chain ---
out=$(_run_resolver resolve_operator_mention 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-063 resolve_operator_mention (unset HUMAN_ESCALATION_LOGIN) rc" "0" "$rc"
assert_eq "TC-PAEM-063 resolve_operator_mention falls back to REPO_OWNER when unset" "@the-owner" "$out"

out=$(HUMAN_ESCALATION_LOGIN="maintainer1" _run_resolver resolve_operator_mention 2>/dev/null)
assert_eq "TC-PAEM-064 resolve_operator_mention honors a well-formed HUMAN_ESCALATION_LOGIN" "@maintainer1" "$out"

out=$(HUMAN_ESCALATION_LOGIN="two words" _run_resolver resolve_operator_mention 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-065 resolve_operator_mention (malformed HUMAN_ESCALATION_LOGIN) rc" "0" "$rc"
assert_eq "TC-PAEM-065 resolve_operator_mention rejects a whitespace-containing HUMAN_ESCALATION_LOGIN, falls back to REPO_OWNER" "@the-owner" "$out"

out=$(HUMAN_ESCALATION_LOGIN="alice@evil" _run_resolver resolve_operator_mention 2>/dev/null)
assert_eq "TC-PAEM-066 resolve_operator_mention rejects an embedded-@ HUMAN_ESCALATION_LOGIN, falls back to REPO_OWNER" "@the-owner" "$out"

# --- No occurrences in dispatcher-tick.sh ---
if [ -f "$DISPATCHER_TICK" ]; then
  dt_count=$(grep -c '@\${REPO_OWNER}' "$DISPATCHER_TICK")
  assert_eq "TC-PAEM-070 dispatcher-tick.sh has zero @\${REPO_OWNER} sites" "0" "$dt_count"
else
  bad "TC-PAEM-070 dispatcher-tick.sh not found at expected path"
fi

# --- lib-dispatch.sh / autonomous-review.sh source the new lib ---
assert_contains "TC-PAEM-090 lib-dispatch.sh sources lib-review-resolve-author.sh" \
  "$DISPATCH_SRC" 'lib-review-resolve-author.sh'
assert_contains "TC-PAEM-091 autonomous-review.sh sources lib-review-resolve-author.sh" \
  "$WRAPPER_SRC" 'source "${LIB_DIR}/lib-review-resolve-author.sh"'

echo

# ============================================================================
# R5 ([INV-138], #492 integration) — resolve_escalation_mention composed chain
# (issue author first, PR author second, operator target last) + the
# three-state HUMAN_ESCALATION_LOGIN semantics (unset / set / set-EMPTY=mute).
# ============================================================================
echo
echo "=== R5: resolve_escalation_mention composed chain + three-state mute ==="

_run_chain() (
  set -uo pipefail
  export REPO_OWNER="the-owner"
  chp_pr_view() {
    case "${_RPAM_MODE:-ok}" in
      fail) return 1 ;;
      *) printf '{"author": %s}' "${_RPAM_AUTHOR:-null}" ;;
    esac
  }
  issue_mention_login() { printf '%s' "${_REM_ISSUE_AUTHOR:-}"; }
  export -f chp_pr_view issue_mention_login
  # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-resolve-author.sh
  source "$RESOLVE_LIB"
  "$@"
)

# 1) human issue author wins over everything (the #492 primary signal)
out=$(_REM_ISSUE_AUTHOR="filer-jane" _RPAM_MODE=ok _RPAM_AUTHOR='"alice"' _run_chain resolve_escalation_mention 7 42 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-170 chain: human issue author rc" "0" "$rc"
assert_eq "TC-PAEM-170 chain: human issue author wins" "@filer-jane" "$out"

# 2) BOT issue author (dispatcher-filed follow-up) falls to the PR author
out=$(_REM_ISSUE_AUTHOR="my-claw[bot]" _RPAM_MODE=ok _RPAM_AUTHOR='"alice"' _run_chain resolve_escalation_mention 7 42 2>/dev/null)
assert_eq "TC-PAEM-171 chain: bot issue author falls to human PR author" "@alice" "$out"

# 3) bot issue author + bot PR author → operator fallback
out=$(_REM_ISSUE_AUTHOR="app/filer-bot" _RPAM_MODE=ok _RPAM_AUTHOR='"app/dev-bot"' _run_chain resolve_escalation_mention 7 42 2>/dev/null)
assert_eq "TC-PAEM-172 chain: both authors bots → REPO_OWNER" "@the-owner" "$out"

# 4) unresolved issue author (empty) + no PR arg → operator fallback
out=$(_REM_ISSUE_AUTHOR="" _run_chain resolve_escalation_mention 7 2>/dev/null)
assert_eq "TC-PAEM-173 chain: empty issue author, no PR → REPO_OWNER" "@the-owner" "$out"

# 5) malformed issue author (embedded @) is rejected, falls to PR author
out=$(_REM_ISSUE_AUTHOR="alice@evil" _RPAM_MODE=ok _RPAM_AUTHOR='"bob"' _run_chain resolve_escalation_mention 7 42 2>/dev/null)
assert_eq "TC-PAEM-174 chain: malformed issue author falls to PR author" "@bob" "$out"

# 6) non-numeric issue arg skips the issue step entirely
out=$(_REM_ISSUE_AUTHOR="filer-jane" _RPAM_MODE=ok _RPAM_AUTHOR='"alice"' _run_chain resolve_escalation_mention "" 42 2>/dev/null)
assert_eq "TC-PAEM-175 chain: empty issue arg skips to PR author" "@alice" "$out"

# --- three-state HUMAN_ESCALATION_LOGIN ([INV-138]) ---
# set EMPTY = explicit mute: NO mention at all, even on github
out=$(HUMAN_ESCALATION_LOGIN="" _run_chain resolve_operator_mention 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-180 mute: rc stays 0" "0" "$rc"
assert_eq "TC-PAEM-180 mute: set-EMPTY HUMAN_ESCALATION_LOGIN emits NOTHING" "" "$out"

# mute applies at the end of the full chain too (both authors bots)
out=$(HUMAN_ESCALATION_LOGIN="" _REM_ISSUE_AUTHOR="app/a" _RPAM_MODE=ok _RPAM_AUTHOR='"app/b"' _run_chain resolve_escalation_mention 7 42 2>/dev/null)
assert_eq "TC-PAEM-181 mute: chain terminal is silent under set-EMPTY" "" "$out"

# ...but a resolvable HUMAN target still wins over mute-position fallback
out=$(HUMAN_ESCALATION_LOGIN="" _REM_ISSUE_AUTHOR="filer-jane" _run_chain resolve_escalation_mention 7 42 2>/dev/null)
assert_eq "TC-PAEM-182 mute: does not suppress a resolved human author" "@filer-jane" "$out"

# unset on a NON-github provider: default chain emits nothing (no group blast)
out=$(ISSUE_PROVIDER=gitlab _run_chain resolve_operator_mention 2>/dev/null); rc=$?
assert_rc_eq "TC-PAEM-183 gitlab default: rc stays 0" "0" "$rc"
assert_eq "TC-PAEM-183 gitlab default: unset + gitlab emits NOTHING (no group blast)" "" "$out"

# unset on github: REPO_OWNER preserved (byte-compat with pre-change behavior)
out=$(ISSUE_PROVIDER=github _run_chain resolve_operator_mention 2>/dev/null)
assert_eq "TC-PAEM-184 github default: unset falls back to @REPO_OWNER" "@the-owner" "$out"

echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
