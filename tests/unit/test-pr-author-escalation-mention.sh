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

out=$(_STUB_PAYLOAD="$TMPDIR_GL/author-bob.json" _run_gl chp_gitlab_pr_view 42 "author"); rc=$?
assert_rc_eq "TC-PAEM-005 chp_gitlab_pr_view author rc" "0" "$rc"
assert_eq "TC-PAEM-005 chp_gitlab_pr_view author flattens username" '{"author":"bob"}' "$(jq -c . <<<"$out")"

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
assert_contains "TC-PAEM-030 INV-92 403-stall report calls resolve_pr_author_mention" \
  "$DISPATCH_SRC" 'its scoped token hit \`Resource not accessible by integration\` on a PR-metadata edit, or the finding requires a maintainer / post-merge action. Marking stalled — no further \`dev-new\` will be dispatched. $(resolve_pr_author_mention "$_np_pr_number")'

assert_contains "TC-PAEM-031 INV-85 no-progress stall report calls resolve_pr_author_mention" \
  "$DISPATCH_SRC" 'The finding appears un-actionable by the dev agent. Marking stalled — no further \`dev-new\` will be dispatched. $(resolve_pr_author_mention "$_np_pr_number")'

assert_contains "TC-PAEM-032 INV-92 non-actionable stall report calls resolve_pr_author_mention" \
  "$DISPATCH_SRC" 'Marking stalled — no \`dev-new\` will be dispatched (\`reason=non_actionable_finding\`). $(resolve_pr_author_mention "$_np_pr_number")'

assert_contains "TC-PAEM-033 INV-105 convergence-breaker report calls resolve_pr_author_mention" \
  "$DISPATCH_SRC" $'removal re-arms the pipeline and resets the retry counter, INV-05).**\n$(resolve_pr_author_mention "$_np_pr_number")'

assert_contains "TC-PAEM-034a _same_head_verdict_aware_recovery INV-92 branch calls resolve_pr_author_mention(pr_num)" \
  "$DISPATCH_SRC" 'Marking stalled — no \`dev-new\` will be dispatched. $(resolve_pr_author_mention "$pr_num") please apply the change manually.'

assert_contains "TC-PAEM-034b _same_head_verdict_aware_recovery non-substantive-budget-spent branch calls resolve_pr_author_mention(pr_num)" \
  "$DISPATCH_SRC" 'with no progress. Marking stalled rather than parking indefinitely. $(resolve_pr_author_mention "$pr_num") please investigate."
    mark_stalled "$issue_num"
    return 0
    ;;'

assert_contains "TC-PAEM-034c _same_head_verdict_aware_recovery self-heal/crash-budget-spent branch calls resolve_pr_author_mention(pr_num)" \
  "$DISPATCH_SRC" 'self-heal/crash-recovery \`dev-new\` for this HEAD with no progress. Marking stalled rather than parking indefinitely. $(resolve_pr_author_mention "$pr_num") please investigate."'

assert_contains "TC-PAEM-034d _same_head_verdict_aware_recovery signature carries pr_num as 5th positional" \
  "$DISPATCH_SRC" 'local issue_num="$1" pr_ref="$2" current_head="$3" cause="$4" pr_num="${5:-}"'

assert_contains "TC-PAEM-034e caller passes pr_num to _same_head_verdict_aware_recovery" \
  "$DISPATCH_SRC" '_same_head_verdict_aware_recovery "$issue_num" "$pr_ref" "$current_head" "$_recovery_cause" "$pr_num" && return 0'

# --- Converted site (autonomous-review.sh) ---
assert_contains "TC-PAEM-035 INV-127 round-cap report calls resolve_pr_author_mention(PR_NUMBER)" \
  "$WRAPPER_SRC" $'removal re-arms the pipeline).\n$(resolve_pr_author_mention "$PR_NUMBER")\nROUNDCAPREPORT'

assert_contains "TC-PAEM-036 [#453] same-HEAD E2E-gate breaker report calls resolve_pr_author_mention(PR_NUMBER)" \
  "$WRAPPER_SRC" $'the pipeline).**\n$(resolve_pr_author_mention "$PR_NUMBER")\nGATEBREAKREPORT'

# TC-PAEM-037/038 — end-to-end resolver behavior on the INV-85 no-progress
# path is covered functionally by TC-PAEM-010/011 above (same resolver, same
# fallback chain) — the source-shape pin (TC-PAEM-031) proves THIS call site
# is wired to it.

# --- Maintainer-target sites (never resolve_pr_author_mention) ---
assert_contains "TC-PAEM-040 approval-failed fallback mentions HUMAN_ESCALATION_LOGIN:-REPO_OWNER" \
  "$WRAPPER_SRC" 'Review PASSED but formal PR approval failed (permission issue?). @${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER} please approve and merge PR #${PR_NUMBER} manually.'
assert_not_contains "TC-PAEM-040b approval-failed fallback never calls resolve_pr_author_mention" \
  "$WRAPPER_SRC" 'approval failed (permission issue?). $(resolve_pr_author_mention'

assert_contains "TC-PAEM-041 no-auto-close notice mentions HUMAN_ESCALATION_LOGIN:-REPO_OWNER" \
  "$WRAPPER_SRC" "Review PASSED — this issue has the 'no-auto-close' label. @"'${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER} please review and merge PR #${PR_NUMBER} when ready.'
assert_not_contains "TC-PAEM-041b no-auto-close notice never calls resolve_pr_author_mention" \
  "$WRAPPER_SRC" "no-auto-close' label. \$(resolve_pr_author_mention"

# --- Operator-target sites (pure variable substitution, no resolver call) ---
for pair in \
  "TC-PAEM-050|Marking as stalled. @"'${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER}'" please investigate manually." \
  "TC-PAEM-051|Marking stalled. @"'${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER}'" please investigate the upstream review dependency" \
  "TC-PAEM-052|one-retry bound ([INV-85]) is degraded for this HEAD; the issue is still bounded by \\\`MAX_RETRIES\\\`. @"'${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER}'" no action needed" \
  "TC-PAEM-053|please verify before removing the label. @"'${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER}' \
  "TC-PAEM-054|@"'${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER}'" this issue may need attention." \
  "TC-PAEM-055|@"'${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER}'" please investigate — this is the class-level backstop" \
  ; do
  id="${pair%%|*}"
  needle="${pair#*|}"
  assert_contains "$id operator-target site uses HUMAN_ESCALATION_LOGIN:-REPO_OWNER" "$DISPATCH_SRC" "$needle"
done

# None of the 6 operator sites should have been converted to a resolver call
# (they can fire with zero PRs in scope).
assert_not_contains "TC-PAEM-050b MAX_RETRIES stall does not call resolve_pr_author_mention" \
  "$DISPATCH_SRC" 'Marking as stalled. $(resolve_pr_author_mention'

# --- Never-touch: the ONE remaining prompt-text @${REPO_OWNER} literal ---
bare_owner_count=$(grep -o '@\${REPO_OWNER}' "$WRAPPER" | wc -l | tr -d ' ')
assert_eq "TC-PAEM-060 exactly one byte-unchanged bare @\${REPO_OWNER} remains (the Step 0.5 prompt literal)" "1" "$bare_owner_count"
assert_contains "TC-PAEM-060b the remaining bare mention is the requirement-drift prompt line" \
  "$WRAPPER_SRC" 'Corrections or clarifications from the repo owner (@${REPO_OWNER})'

bare_owner_count_dispatch=$(grep -o '@\${REPO_OWNER}' "$DISPATCH_LIB" | wc -l | tr -d ' ')
assert_eq "TC-PAEM-060c lib-dispatch.sh has ZERO remaining bare @\${REPO_OWNER} literals" "0" "$bare_owner_count_dispatch"

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
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
