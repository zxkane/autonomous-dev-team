#!/bin/bash
# test-provider-prompts-gitlab-render.sh — issue #421 R5/AC3.
#
# Renders every fragment key in providers/prompts-gitlab.sh with a fixed args
# seed and asserts:
#   - zero bare `gh ` word-boundary tokens (R5 default), matching the SAME
#     RE2-safe consuming-boundary regex check-provider-cutover.sh's gh_lines_in
#     uses ((^|[^A-Za-z_-])gh );
#   - at most K explicitly-listed `glab ` tokens (default K=0, the same
#     boundary regex glab_lines_in uses).
# Also covers: every FRAGMENT_AXIS key has a matching gitlab fragment + argc
# (parity with the github file — a call site must render on EITHER provider);
# unknown key/provider still fails LOUD on the gitlab axis (AC1, mirrors the
# github-golden test's TC-P36-002/003 but selecting CODE_HOST=gitlab).
#
# Run: bash tests/unit/test-provider-prompts-gitlab-render.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
LIB="$SCRIPTS/lib-provider-prompts.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

[ -f "$LIB" ] || { echo "missing $LIB"; exit 1; }

# Default K (max tolerated `glab ` tokens) — 0 per R5. Override via env for a
# deliberate, documented, review-approved exception (issue #421 R5 wording).
K="${PP_GITLAB_MAX_GLAB_TOKENS:-0}"

render_all() {
  # shellcheck disable=SC1090
  source "$LIB"
  CODE_HOST=gitlab
  ISSUE_PROVIDER=gitlab
  _pp_load_provider gitlab
  local -a SEED=(SEED0 SEED1 SEED2)
  local key argc args
  for key in $(printf '%s\n' "${!FRAGMENT_AXIS[@]}" | sort); do
    argc="${_PP_GITLAB_ARGC[$key]:-0}"
    args=()
    for ((i = 0; i < argc; i++)); do args+=("${SEED[$i]}"); done
    CODE_HOST=gitlab ISSUE_PROVIDER=gitlab provider_prompt_fragment "$key" "${args[@]}"
    echo ""
  done
}

RENDERED="$(render_all)"
RENDERED_FILE="$(mktemp)"
printf '%s\n' "$RENDERED" > "$RENDERED_FILE"
trap 'rm -f "$RENDERED_FILE"' EXIT

# ---------------------------------------------------------------------------
echo "=== TC-P36-010: zero bare \`gh\` word-boundary tokens in gitlab fragments ==="
# ---------------------------------------------------------------------------
# Same RE2-safe consuming boundary as check-provider-cutover.sh's gh_lines_in:
# `(^|[^A-Za-z_-])gh ` — matches start-of-line/non-word-char + "gh ", so
# `github`/`gh-as-user`/`agh ` do NOT match.
gh_hits="$(grep -naE '(^|[^A-Za-z_-])gh ' "$RENDERED_FILE" || true)"
if [ -z "$gh_hits" ]; then
  ok "TC-P36-010 zero bare 'gh ' tokens found in rendered gitlab fragments"
else
  bad "TC-P36-010 found bare 'gh ' token(s) in gitlab fragments:"
  echo "$gh_hits"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-P36-011: at most K=${K} \`glab\` tokens in gitlab fragments (default K=0) ==="
# ---------------------------------------------------------------------------
glab_hits="$(grep -naE '(^|[^A-Za-z_-])glab[[:space:]]' "$RENDERED_FILE" || true)"
glab_count=0
[ -n "$glab_hits" ] && glab_count=$(printf '%s\n' "$glab_hits" | grep -c .)
if [ "$glab_count" -le "$K" ]; then
  ok "TC-P36-011 glab token count ($glab_count) <= K ($K)"
else
  bad "TC-P36-011 glab token count ($glab_count) exceeds K ($K):"
  echo "$glab_hits"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-P36-012: every FRAGMENT_AXIS key has BOTH a gitlab fragment and matching argc ==="
# ---------------------------------------------------------------------------
missing=0
bash -c "
  source '$LIB'
  _pp_load_provider gitlab
  for key in \"\${!FRAGMENT_AXIS[@]}\"; do
    [[ -n \"\${_PP_GITLAB_FRAGMENT[\$key]:-}\" ]] || { echo \"MISSING FRAGMENT: \$key\"; exit 1; }
    [[ -n \"\${_PP_GITLAB_ARGC[\$key]+set}\" ]] || { echo \"MISSING ARGC: \$key\"; exit 1; }
  done
" 2>/tmp/pp-missing-gl.$$ || missing=1
if [[ $missing -eq 0 ]]; then
  ok "TC-P36-012 every FRAGMENT_AXIS key resolves to a gitlab fragment + argc"
else
  bad "TC-P36-012 a FRAGMENT_AXIS key is missing from prompts-gitlab.sh: $(cat /tmp/pp-missing-gl.$$)"
fi
rm -f /tmp/pp-missing-gl.$$

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-P36-013: github and gitlab declare IDENTICAL argc per key (a call site fixes one positional-arg list) ==="
# ---------------------------------------------------------------------------
mismatch=0
bash -c "
  source '$LIB'
  _pp_load_provider github
  _pp_load_provider gitlab
  for key in \"\${!FRAGMENT_AXIS[@]}\"; do
    gh_argc=\"\${_PP_GITHUB_ARGC[\$key]:-0}\"
    gl_argc=\"\${_PP_GITLAB_ARGC[\$key]:-0}\"
    if [[ \"\$gh_argc\" != \"\$gl_argc\" ]]; then
      echo \"ARGC MISMATCH: \$key github=\$gh_argc gitlab=\$gl_argc\"
      exit 1
    fi
  done
" 2>/tmp/pp-argc-mismatch.$$ || mismatch=1
if [[ $mismatch -eq 0 ]]; then
  ok "TC-P36-013 github/gitlab argc match for every key"
else
  bad "TC-P36-013 argc mismatch between providers: $(cat /tmp/pp-argc-mismatch.$$)"
fi
rm -f /tmp/pp-argc-mismatch.$$

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-P36-014: unknown key/provider fails LOUD on the gitlab axis too ==="
# ---------------------------------------------------------------------------
out=$(bash -c "source '$LIB'; CODE_HOST=gitlab; provider_prompt_fragment nonexistent.key" 2>&1); rc=$?
if [[ $rc -ne 0 ]] && [[ "$out" == *"unknown fragment key"* ]]; then
  ok "TC-P36-014a unknown key fails loud on gitlab axis: rc=$rc"
else
  bad "TC-P36-014a unknown key did not fail loud on gitlab axis (rc=$rc, out='$out')"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-P36-015/016/017: fixed fragments extract to syntactically valid shell ==="
# ---------------------------------------------------------------------------
# Review-round regression pins (PR #428 codex rounds 2-4): render each key with
# a realistic seed, extract the fenced (or bare, for watch_ci_checks) code, and
# syntax-check it with `bash -n`. A prose-only render (English sentence spliced
# where a command is expected) or a mismatched-vocabulary render (case arms
# that don't match chp_gitlab_mergeable's tokens) would not necessarily trip
# the K=0 gh/glab greps above, so this is a distinct check.
_extract_code() {
  # Strip markdown fences (```bash / ```) if present; otherwise the whole
  # render IS the code (review.watch_ci_checks renders bare, spliced directly
  # into the wrapper's own heredoc).
  local rendered="$1"
  if printf '%s\n' "$rendered" | grep -qE '^[[:space:]]*```'; then
    printf '%s\n' "$rendered" | awk '{ t=$0; sub(/^[ \t]*/,"",t); if (t ~ /^```/) { f=!f; next } if (f) print }'
  else
    printf '%s\n' "$rendered"
  fi
}

_syntax_check_key() {
  local key="$1"; shift
  local rendered code err
  rendered="$(bash -c "source '$LIB'; CODE_HOST=gitlab; ISSUE_PROVIDER=gitlab; provider_prompt_fragment '$key' $(printf "'%s' " "$@")" 2>&1)"
  code="$(_extract_code "$rendered")"
  if err="$(bash -n <(printf '%s\n' "$code") 2>&1)"; then
    ok "TC-P36-015/016/017 $key extracts to syntactically valid shell"
  else
    bad "TC-P36-015/016/017 $key does NOT extract to valid shell: $err"
    echo "$code"
  fi
}

_syntax_check_key "review.check_mergeable" "42" "group/proj"
_syntax_check_key "review.requirement_drift_gh_issue_view" "421" "421" "group/proj"
_syntax_check_key "review.e2e_fetch_comment" "42" "group/proj"
_syntax_check_key "review.watch_ci_checks" "42"

# TC-P36-018 (review r5): `none` is NOT terminal in watch_ci_checks — a
# force-push rebase attaches the replacement pipeline with a delay, so the
# poll loop must ride through `none` for a grace window instead of breaking
# on the first no-pipeline read.
wcc_render="$(bash -c "source '$LIB'; CODE_HOST=gitlab; ISSUE_PROVIDER=gitlab; provider_prompt_fragment review.watch_ci_checks 42")"
if grep -q 'NONE_GRACE' <<<"$wcc_render" && ! grep -qE 'success\|failed\|canceled\|skipped\|none\)' <<<"$wcc_render"; then
  ok "TC-P36-018: none rides a grace window, not instant-terminal"
else
  bad "TC-P36-018: watch_ci_checks treats none as instantly terminal"
fi
_syntax_check_key "bots.review_count_check" "group/proj" "42" "codex-bot"
_syntax_check_key "bots.review_count_check_bare" "group/proj" "42" "codex-bot"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-P36-015: review.check_mergeable normalizes to chp_gitlab_mergeable's vocabulary ==="
# ---------------------------------------------------------------------------
_MERGEABLE_RENDER="$(bash -c "source '$LIB'; CODE_HOST=gitlab; provider_prompt_fragment review.check_mergeable 42 group/proj" 2>&1)"
if printf '%s\n' "$_MERGEABLE_RENDER" | grep -q 'STATUS=MERGEABLE' \
  && printf '%s\n' "$_MERGEABLE_RENDER" | grep -q 'STATUS=CONFLICTING' \
  && printf '%s\n' "$_MERGEABLE_RENDER" | grep -q 'STATUS=UNKNOWN'; then
  ok "TC-P36-015 review.check_mergeable renders all three MERGEABLE/CONFLICTING/UNKNOWN tokens"
else
  bad "TC-P36-015 review.check_mergeable is missing one or more of MERGEABLE/CONFLICTING/UNKNOWN"
  echo "$_MERGEABLE_RENDER"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-P36-016: note-reading fragments actually paginate (x-next-page walk, not just mentioned) ==="
# ---------------------------------------------------------------------------
for _key in review.requirement_drift_gh_issue_view review.e2e_fetch_comment; do
  _RENDER="$(bash -c "
    source '$LIB'
    _pp_load_provider gitlab
    CODE_HOST=gitlab ISSUE_PROVIDER=gitlab
    _argc=\"\${_PP_GITLAB_ARGC[$_key]:-0}\"
    _seed=(SEED0 SEED1 SEED2)
    _args=()
    for ((i = 0; i < _argc; i++)); do _args+=(\"\${_seed[\$i]}\"); done
    provider_prompt_fragment '$_key' \"\${_args[@]}\"
  " 2>&1)"
  if printf '%s\n' "$_RENDER" | grep -q 'x-next-page' && printf '%s\n' "$_RENDER" | grep -q 'page=' && printf '%s\n' "$_RENDER" | grep -qE 'while|for'; then
    ok "TC-P36-016 $_key renders an actual pagination loop (x-next-page + page= + a loop construct)"
  else
    bad "TC-P36-016 $_key does not render an actual pagination loop"
    echo "$_RENDER"
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-P36-018: bot-review-count fragments use /approvals, not /notes ==="
# ---------------------------------------------------------------------------
for _key in bots.review_count_check bots.review_count_check_bare; do
  _RENDER="$(bash -c "source '$LIB'; CODE_HOST=gitlab; provider_prompt_fragment '$_key' 'group/proj' '42' 'codex-bot'" 2>&1)"
  if printf '%s\n' "$_RENDER" | grep -q '/approvals' && ! printf '%s\n' "$_RENDER" | grep -q '/notes'; then
    ok "TC-P36-018 $_key counts via /approvals (not /notes)"
  else
    bad "TC-P36-018 $_key does not count via /approvals only"
    echo "$_RENDER"
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
