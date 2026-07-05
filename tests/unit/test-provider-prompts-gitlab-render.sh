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
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
