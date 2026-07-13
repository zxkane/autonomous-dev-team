#!/bin/bash
# test-base-branch-conf.sh — issue #478 ([INV-131]).
#
# Pins the BASE_BRANCH resolution-chain + validation pure helper
# (lib-config.sh::resolve_base_branch), source-of-truth wiring greps against
# both wrappers (they're too heavy to run end-to-end, mirroring
# test-review-convergence-rules.sh's two-pronged style), the provider
# PR-create leaves' argv, and hook fixture behavior (mirrors
# test-block-push-regex.sh's throwaway-repo pattern).
#
# See docs/test-cases/base-branch-conf.md for the TC-BASEBR-* mapping.
#
# Run: bash tests/unit/test-base-branch-conf.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_CONFIG="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-config.sh"
DEV_WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
REVIEW_WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
GH_LEAF="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/chp-github.sh"
GL_LEAF="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/chp-gitlab.sh"
REBASE_HOOK="$PROJECT_ROOT/skills/autonomous-common/hooks/check-rebase-before-push.sh"
VERIFY_HOOK="$PROJECT_ROOT/skills/autonomous-common/hooks/verify-completion.sh"
BLOCK_HOOK="$PROJECT_ROOT/skills/autonomous-common/hooks/block-push-to-main.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Single cleanup registry (a later `trap ... EXIT` in this file would
# otherwise silently overwrite an earlier one, leaking that section's temp
# dir/file) — every section appends its own path via `register_cleanup`.
declare -a CLEANUP_PATHS=()
register_cleanup() { CLEANUP_PATHS+=("$1"); }
cleanup_all() { local p; for p in "${CLEANUP_PATHS[@]:-}"; do [[ -n "$p" ]] && rm -rf "$p"; done; }
trap cleanup_all EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected=[$expected]"
    echo "      actual=  [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle: $needle"
    echo "      hay:    ${haystack:0:300}"
    FAIL=$((FAIL + 1))
  fi
}

assert_no_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc — should NOT contain: $needle"
    FAIL=$((FAIL + 1))
  fi
}

assert_empty() {
  local desc="$1" actual="$2"
  if [[ -z "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc — expected empty, got: |${actual:0:200}|"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected exit=$expected, actual exit=$actual)"
    FAIL=$((FAIL + 1))
  fi
}

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-config.sh
source "$LIB_CONFIG"

# ===========================================================================
echo "=== TC-BASEBR-001..008: resolve_base_branch resolution chain + validation ==="
# ===========================================================================

# resolve_base_branch is a shell function (sourced above), so each case runs
# it in a subshell with the relevant env vars set/unset — `env <fn>` cannot
# invoke a shell function. STDERR_CAP holds the last call's stderr (no /tmp
# file — a subshell-local fd-3 redirect avoids any cross-invocation leak).
BASEBR_ERR_FILE=$(mktemp)
register_cleanup "$BASEBR_ERR_FILE"

call_resolve() {
  # call_resolve <BASE_BRANCH-or-empty> <DEFAULT_BRANCH-or-empty> — echoes
  # stdout on fd1; stderr is captured into $BASEBR_ERR_FILE for the caller
  # to inspect via $(cat "$BASEBR_ERR_FILE").
  local base="$1" default="$2"
  : > "$BASEBR_ERR_FILE"
  (unset BASE_BRANCH DEFAULT_BRANCH
   [[ -n "$base" ]] && export BASE_BRANCH="$base"
   [[ -n "$default" ]] && export DEFAULT_BRANCH="$default"
   resolve_base_branch) 2>"$BASEBR_ERR_FILE"
}

out=$(call_resolve "develop" "release")
err=$(cat "$BASEBR_ERR_FILE")
assert_eq "TC-BASEBR-001 BASE_BRANCH wins over DEFAULT_BRANCH" "develop" "$out"
assert_empty "TC-BASEBR-001 no stderr when BASE_BRANCH is set" "$err"

out=$(call_resolve "" "release")
err=$(cat "$BASEBR_ERR_FILE")
assert_eq "TC-BASEBR-002 only DEFAULT_BRANCH set → used" "release" "$out"
assert_contains "TC-BASEBR-002 deprecation warning present" "$err" "WARNING: DEFAULT_BRANCH is deprecated"

out=$(call_resolve "" "")
err=$(cat "$BASEBR_ERR_FILE")
assert_eq "TC-BASEBR-003 neither set → main" "main" "$out"
assert_empty "TC-BASEBR-003 no stderr (byte-identical-default)" "$err"

out=$(call_resolve "feat branch" "")
err=$(cat "$BASEBR_ERR_FILE")
assert_eq "TC-BASEBR-004 value with space → falls back to main" "main" "$out"
assert_contains "TC-BASEBR-004 warning present" "$err" "WARNING"

out=$(call_resolve 'dev"branch' "")
err=$(cat "$BASEBR_ERR_FILE")
assert_eq "TC-BASEBR-005 value with quote → falls back to main" "main" "$out"
assert_contains "TC-BASEBR-005 warning present" "$err" "WARNING"

out=$(call_resolve "-x" "")
err=$(cat "$BASEBR_ERR_FILE")
assert_eq "TC-BASEBR-006 leading '-' → falls back to main" "main" "$out"
assert_contains "TC-BASEBR-006 warning present" "$err" "WARNING"

out=$(call_resolve "release/v2" "")
err=$(cat "$BASEBR_ERR_FILE")
assert_eq "TC-BASEBR-007 value with '/' is valid" "release/v2" "$out"
assert_empty "TC-BASEBR-007 no warning for a valid value" "$err"

out=$(call_resolve "" "bad branch")
err=$(cat "$BASEBR_ERR_FILE")
assert_eq "TC-BASEBR-008 invalid DEFAULT_BRANCH → falls back to main" "main" "$out"
assert_contains "TC-BASEBR-008 deprecation warning present" "$err" "WARNING: DEFAULT_BRANCH is deprecated"
assert_contains "TC-BASEBR-008 invalid-value warning ALSO present" "$err" "is not a valid branch name"

# ===========================================================================
echo ""
echo "=== TC-BASEBR-009..010: dev wrapper prompt rendering ==="
# ===========================================================================
# The wrapper is too heavy to run end-to-end (needs gh/jq/network/session
# state). Render the two rebase-instruction blocks directly by feeding the
# SAME heredoc shape the wrapper uses, driven by BASH_REMATCH-free extraction
# via a minimal harness: source the literal block text out of the wrapper
# file and eval it as a template with BASE_BRANCH bound, mirroring
# test-autonomous-dev-rebase-marker.sh's "wrapper too heavy, grep instead"
# posture but going one step further (actual rendering) since the block is a
# self-contained heredoc with only BASE_BRANCH/PR_NUM/AUTO_MERGE_FAILURE_MARKER
# interpolation.

render_dev_rebase_block() {
  # render_dev_rebase_block <base_branch> <delimiter> — extract the heredoc
  # body between <<DELIM and the standalone DELIM line, then render it with
  # bash's own $(...) / ${...} interpolation under a controlled environment.
  local base_branch="$1" delim="$2"
  local body
  body=$(awk -v delim="$delim" '
    $0 ~ ("<<" delim "$") { capture=1; next }
    capture && $0 == delim { exit }
    capture { print }
  ' "$DEV_WRAPPER")
  env -i PATH="$PATH" BASE_BRANCH="$base_branch" PR_NUM="99" \
    AUTO_MERGE_FAILURE_MARKER="Auto-merge failed: test marker" \
    bash -c '
      provider_prompt_fragment() { echo "[stub: $1]"; }
      cat <<INNEREOF
'"$body"'
INNEREOF
    '
}

rendered_main=$(render_dev_rebase_block "main" "REBASE_BLOCK")
assert_contains "TC-BASEBR-009 BASE_BRANCH=main renders git rebase origin/main" \
  "$rendered_main" "git rebase origin/main"
assert_contains "TC-BASEBR-009 BASE_BRANCH=main renders git fetch origin main" \
  "$rendered_main" "git fetch origin main"

rendered_develop=$(render_dev_rebase_block "develop" "REBASE_BLOCK")
assert_contains "TC-BASEBR-010 BASE_BRANCH=develop renders git rebase origin/develop" \
  "$rendered_develop" "git rebase origin/develop"
assert_contains "TC-BASEBR-010 BASE_BRANCH=develop renders git fetch origin develop" \
  "$rendered_develop" "git fetch origin develop"
if [[ "$rendered_develop" != *"origin/main"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-BASEBR-010 zero origin/main occurrences with BASE_BRANCH=develop"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-BASEBR-010 origin/main leaked into the rendered block"
  FAIL=$((FAIL + 1))
fi

rendered_develop2=$(render_dev_rebase_block "develop" "REBASE_BLOCK2")
assert_contains "TC-BASEBR-010b resume-fallback block: BASE_BRANCH=develop renders origin/develop" \
  "$rendered_develop2" "origin/develop"
if [[ "$rendered_develop2" != *"origin/main"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-BASEBR-010b resume-fallback block: zero origin/main occurrences"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-BASEBR-010b origin/main leaked into resume-fallback block"
  FAIL=$((FAIL + 1))
fi

# ===========================================================================
echo ""
echo "=== TC-BASEBR-011..012: review wrapper prompt/comment text wiring ==="
# ===========================================================================
# Same "wrapper too heavy" posture as test-review-convergence-rules.sh —
# source-of-truth greps against the interpolation sites rather than a full
# render (the review wrapper's Step-0 block and INV-44 gate branches are not
# isolated heredocs the way the dev wrapper's rebase blocks are).

assert_grep "TC-BASEBR-011 Step 0 block interpolates \${BASE_BRANCH} in 'rebase the PR branch onto'" \
  'rebase the PR branch onto \$\{BASE_BRANCH\}' "$REVIEW_WRAPPER"
assert_grep "TC-BASEBR-011 Step 0 block fetches \$BASE_BRANCH (not a literal main)" \
  'git fetch origin \$\{BASE_BRANCH\}' "$REVIEW_WRAPPER"
assert_grep "TC-BASEBR-011 Step 0 block rebases onto origin/\$BASE_BRANCH" \
  'git rebase origin/\$\{BASE_BRANCH\}' "$REVIEW_WRAPPER"

assert_grep "TC-BASEBR-012 INV-44 finding names \${BASE_BRANCH} in the BLOCKING heading" \
  '\[BLOCKING\] Merge conflict with \$\{BASE_BRANCH\}' "$REVIEW_WRAPPER"
assert_grep "TC-BASEBR-012 INV-44 finding's rebase instructions use \${BASE_BRANCH}" \
  'git fetch origin \$\{BASE_BRANCH\}' "$REVIEW_WRAPPER"
assert_grep "TC-BASEBR-012 Auto-merge failed marker names \${BASE_BRANCH}" \
  'CONFLICTING with \$\{BASE_BRANCH\}' "$REVIEW_WRAPPER"
assert_grep "TC-BASEBR-012 submit_request_changes body names \${BASE_BRANCH}" \
  'Merge conflict with \$\{BASE_BRANCH\}' "$REVIEW_WRAPPER"

# ===========================================================================
echo ""
echo "=== TC-BASEBR-013: needs_open_pr_only reads the BASE_BRANCH->DEFAULT_BRANCH->main chain ==="
# ===========================================================================
assert_grep "TC-BASEBR-013 needs_open_pr_only reads \${BASE_BRANCH:-\${DEFAULT_BRANCH:-main}}" \
  'local base="\$\{BASE_BRANCH:-\$\{DEFAULT_BRANCH:-main\}\}"' "$DEV_WRAPPER"

# ===========================================================================
echo ""
echo "=== TC-BASEBR-014..015: chp_github_create_pr --base argv ==="
# ===========================================================================
_GH_ARGV_FILE="$(mktemp)"
run_gh_trace() {
  local base_env="${1:-}"
  env -u CODE_HOST -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      REPO="acme/widget" BASE_BRANCH="$base_env" _GH_ARGV_FILE="$_GH_ARGV_FILE" \
  bash -c '
    set -uo pipefail
    gh() { printf "%s\n" "$@" > "$_GH_ARGV_FILE"; return 0; }
    source "'"$GH_LEAF"'" 2>/dev/null
    chp_github_create_pr feat/x T B >/dev/null 2>&1
  '
  tr "\n" " " < "$_GH_ARGV_FILE"
}

argv=$(run_gh_trace "develop")
assert_eq "TC-BASEBR-014 chp_github_create_pr argv includes --base develop under override" \
  "pr create --repo acme/widget --head feat/x --title T --body B --base develop " "$argv"

argv=$(run_gh_trace "")
assert_eq "TC-BASEBR-015 chp_github_create_pr argv includes --base main by default" \
  "pr create --repo acme/widget --head feat/x --title T --body B --base main " "$argv"
rm -f "$_GH_ARGV_FILE"

# ===========================================================================
echo ""
echo "=== TC-BASEBR-016..017: chp_gitlab_create_pr target-branch resolution ==="
# ===========================================================================
GL_TMPDIR=$(mktemp -d)
register_cleanup "$GL_TMPDIR"

run_gl_trace() {
  # run_gl_trace <base_branch_env> <default_branch_fixture> — source the
  # gitlab leaf with a recording _gl_api stub; echo "<call_count>|<post_body_or_empty>".
  # `_gl_api` is invoked from `chp_gitlab_create_pr` via `$(...)` command
  # substitution, which forks a subshell — a plain variable increment inside
  # the stub would NOT be visible to the parent shell, so the stub records
  # to a FILE (mirrors test-chp-gitlab-writes.sh's `_GL_API_CALL_LOG` pattern)
  # instead of an in-memory counter.
  local base_env="${1:-}" default_branch="${2:-main}"
  local call_log="$GL_TMPDIR/call.log"
  : > "$call_log"
  env BASE_BRANCH="$base_env" GITLAB_PROJECT="grp%2Fproj" DEFAULT_BRANCH_FIXTURE="$default_branch" \
      _GL_CALL_LOG="$call_log" \
  bash -c '
    set -uo pipefail
    _gl_api() {
      if [[ "$1" == "--method" ]]; then
        # POST /merge_requests call: args are --method POST --body <json> <path>
        printf "POST|%s\n" "$4" >> "$_GL_CALL_LOG"
        printf "%s" "{\"web_url\":\"https://example.test/mr/1\"}"
      else
        printf "GET|\n" >> "$_GL_CALL_LOG"
        printf "{\"default_branch\":\"%s\"}" "$DEFAULT_BRANCH_FIXTURE"
      fi
    }
    source "'"$GL_LEAF"'" 2>/dev/null
    chp_gitlab_create_pr feat/x title body >/dev/null 2>&1
  '
  local calls post_body
  calls=$(wc -l < "$call_log" | tr -d '[:space:]')
  post_body=$(grep '^POST|' "$call_log" | head -1 | sed 's/^POST|//')
  printf '%s|%s' "$calls" "$post_body"
}

result=$(run_gl_trace "develop" "main")
calls="${result%%|*}"
post_body="${result#*|}"
assert_eq "TC-BASEBR-016 BASE_BRANCH set → exactly 1 _gl_api call (probe skipped)" "1" "$calls"
assert_contains "TC-BASEBR-016 POST body targets develop" "$post_body" '"target_branch":"develop"'

result=$(run_gl_trace "" "main")
calls="${result%%|*}"
post_body="${result#*|}"
assert_eq "TC-BASEBR-017 BASE_BRANCH unset → exactly 2 _gl_api calls (probe + POST, regression pin)" "2" "$calls"
assert_contains "TC-BASEBR-017 POST body targets the probed default_branch" "$post_body" '"target_branch":"main"'

# ===========================================================================
echo ""
echo "=== TC-BASEBR-018..020: check-rebase-before-push.sh hook fixture ==="
# ===========================================================================
HOOK_TMPDIR=$(mktemp -d)
register_cleanup "$HOOK_TMPDIR"

setup_hook_repo() {
  local trunk="$1" behind_commits="${2:-0}"
  rm -rf "$HOOK_TMPDIR/repo" "$HOOK_TMPDIR/origin"
  mkdir -p "$HOOK_TMPDIR/origin"
  git -C "$HOOK_TMPDIR/origin" init --quiet --bare
  mkdir -p "$HOOK_TMPDIR/repo"
  git -C "$HOOK_TMPDIR/repo" init --quiet --initial-branch="$trunk"
  git -C "$HOOK_TMPDIR/repo" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m init
  git -C "$HOOK_TMPDIR/repo" remote add origin "$HOOK_TMPDIR/origin"
  git -C "$HOOK_TMPDIR/repo" push --quiet -u origin "$trunk"
  git -C "$HOOK_TMPDIR/repo" checkout --quiet -b feat/x
  # Advance the trunk on origin by $behind_commits, from a second clone, so
  # the feature branch (still at the original trunk tip) is genuinely behind.
  if [[ "$behind_commits" -gt 0 ]]; then
    rm -rf "$HOOK_TMPDIR/advance"
    git clone --quiet "$HOOK_TMPDIR/origin" "$HOOK_TMPDIR/advance"
    git -C "$HOOK_TMPDIR/advance" checkout --quiet "$trunk"
    for i in $(seq 1 "$behind_commits"); do
      git -C "$HOOK_TMPDIR/advance" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m "advance $i"
    done
    git -C "$HOOK_TMPDIR/advance" push --quiet origin "$trunk"
  fi
}

run_rebase_hook() {
  local base_branch_env="${1:-}"
  local input='{"tool_input":{"command":"git push"}}'
  local out_file="$HOOK_TMPDIR/hook_out.log"
  (cd "$HOOK_TMPDIR/repo" && env ${base_branch_env:+BASE_BRANCH="$base_branch_env"} bash "$REBASE_HOOK" <<<"$input" >"$out_file" 2>&1)
  local rc=$?
  echo "$rc"
}

setup_hook_repo "develop" 2
rc=$(run_rebase_hook "develop")
out=$(cat "$HOOK_TMPDIR/hook_out.log" 2>/dev/null)
assert_exit "TC-BASEBR-018 BASE_BRANCH=develop, 2 commits behind → blocked (rc=2)" "2" "$rc"
assert_contains "TC-BASEBR-018 message names develop/origin/develop" "$out" "origin/develop"

setup_hook_repo "main" 1
rc=$(run_rebase_hook "")
out=$(cat "$HOOK_TMPDIR/hook_out.log" 2>/dev/null)
assert_exit "TC-BASEBR-019 BASE_BRANCH unset, trunk=main, 1 commit behind → blocked (rc=2, regression pin)" "2" "$rc"
assert_contains "TC-BASEBR-019 message names main/origin/main" "$out" "origin/main"

setup_hook_repo "develop" 0
(cd "$HOOK_TMPDIR/repo" && git checkout --quiet develop)
rc=$(run_rebase_hook "develop")
assert_exit "TC-BASEBR-020 already on the resolved BASE_BRANCH → exits 0 (self-skip)" "0" "$rc"

rm -rf "$HOOK_TMPDIR"

# ===========================================================================
echo ""
echo "=== TC-BASEBR-021: verify-completion.sh reads the BASE_BRANCH chain ==="
# ===========================================================================
assert_grep "TC-BASEBR-021 verify-completion.sh resolves \${BASE_BRANCH:-\${TRUNK_BRANCH:-main}}" \
  'base_branch="\$\{BASE_BRANCH:-\$\{TRUNK_BRANCH:-main\}\}"' "$VERIFY_HOOK"
assert_grep "TC-BASEBR-021 verify-completion.sh skip-check compares against \$base_branch" \
  '"\$current_branch" == "\$base_branch"' "$VERIFY_HOOK"

# ---------------------------------------------------------------------------
# TC-BASEBR-021b: with BASE_BRANCH configured to a non-master value, a
# checkout literally named `master` must NOT get the unconditional trunk-skip
# bypass — it's an ordinary branch and must go through the full CI/E2E/
# review-thread gate, same as any other feature branch. Legacy behavior
# (neither BASE_BRANCH nor TRUNK_BRANCH set) must still skip `master`
# unconditionally (regression pin).
# ---------------------------------------------------------------------------
VC_TMPDIR=$(mktemp -d)
register_cleanup "$VC_TMPDIR"
git -C "$VC_TMPDIR" init --quiet --initial-branch=master
git -C "$VC_TMPDIR" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m init

# Stub `gh`/`jq` on PATH: the hook gates on `command -v jq` then `command -v
# gh` (silently exit 0 if either is missing) before making any gh call, so
# `jq` must resolve to the REAL binary; `gh` is a fake that just records that
# it was invoked — proving the hook proceeded PAST the trunk-skip early-exit
# rather than actually driving real network calls.
VC_STUB_DIR="$VC_TMPDIR/bin"
mkdir -p "$VC_STUB_DIR"
REAL_JQ="$(command -v jq)"
ln -sf "$REAL_JQ" "$VC_STUB_DIR/jq"
VC_GH_LOG="$VC_TMPDIR/gh-invoked.log"
cat > "$VC_STUB_DIR/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$VC_GH_LOG"
echo "[]"
exit 1
EOF
chmod +x "$VC_STUB_DIR/gh"

run_verify_hook() {
  local base_branch_env="${1:-}"
  rm -f "$VC_GH_LOG"
  (cd "$VC_TMPDIR" && env PATH="$VC_STUB_DIR:$PATH" ${base_branch_env:+BASE_BRANCH="$base_branch_env"} bash "$VERIFY_HOOK" <<<'{}' >/dev/null 2>&1)
}

run_verify_hook ""
gh_called_legacy="no"; [[ -s "$VC_GH_LOG" ]] && gh_called_legacy="yes"
assert_eq "TC-BASEBR-021b legacy (no BASE_BRANCH/TRUNK_BRANCH): master unconditionally skips (gh never called)" "no" "$gh_called_legacy"

run_verify_hook "develop"
gh_called_configured="no"; [[ -s "$VC_GH_LOG" ]] && gh_called_configured="yes"
assert_eq "TC-BASEBR-021b BASE_BRANCH=develop: master is NOT the trunk, hook proceeds (gh called)" "yes" "$gh_called_configured"

# ===========================================================================
echo ""
echo "=== TC-BASEBR-022..024: block-push-to-main.sh BASE_BRANCH precedence ==="
# ===========================================================================
BP_TMPDIR=$(mktemp -d)
register_cleanup "$BP_TMPDIR"

setup_bp_repo() {
  local branch="$1"
  rm -rf "$BP_TMPDIR/repo"
  mkdir -p "$BP_TMPDIR/repo"
  git -C "$BP_TMPDIR/repo" init --quiet --initial-branch=main
  git -C "$BP_TMPDIR/repo" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m init
  if [[ "$branch" != "main" ]]; then
    git -C "$BP_TMPDIR/repo" checkout --quiet -b "$branch"
  fi
}

# Build the hook's PreToolUse JSON payload for a `git push` command.
bp_hook_input() { printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')"; }

run_block_hook() {
  local cmd="$1"; shift
  (cd "$BP_TMPDIR/repo" && CLAUDE_PROJECT_DIR="$BP_TMPDIR/repo" env "$@" bash "$BLOCK_HOOK" <<<"$(bp_hook_input "$cmd")")
  echo $?
}

setup_bp_repo "main"
out=$(run_block_hook "git push -u origin develop" BASE_BRANCH=develop)
assert_exit "TC-BASEBR-022 BASE_BRANCH=develop blocks a push to refs/heads/develop" "2" "$out"

out=$(run_block_hook "git push -u origin main" BASE_BRANCH=develop)
assert_exit "TC-BASEBR-022 BASE_BRANCH=develop ALLOWS a push to refs/heads/main" "0" "$out"

out=$(run_block_hook "git push -u origin develop" BASE_BRANCH=develop TRUNK_BRANCH=master)
assert_exit "TC-BASEBR-023 BASE_BRANCH wins over TRUNK_BRANCH (develop protected)" "2" "$out"

out=$(run_block_hook "git push -u origin master" BASE_BRANCH=develop TRUNK_BRANCH=master)
assert_exit "TC-BASEBR-023 BASE_BRANCH wins over TRUNK_BRANCH (master NOT protected)" "0" "$out"

out=$(run_block_hook "git push -u origin master" TRUNK_BRANCH=master)
assert_exit "TC-BASEBR-024 only TRUNK_BRANCH set → unchanged pre-#478 behavior (master protected)" "2" "$out"

# ---------------------------------------------------------------------------
# TC-BASEBR-024b: the BLOCKED message text names the resolved trunk branch,
# not a hardcoded "main" — otherwise a BASE_BRANCH=develop deployment shows
# a misleading "Direct Push to Main" / "Pushing directly to main" message
# while actually blocking a push to develop.
# ---------------------------------------------------------------------------
# Same invocation as run_block_hook, but capture stderr (the BLOCKED message)
# instead of the exit code.
run_block_hook_stderr() {
  local cmd="$1"; shift
  (cd "$BP_TMPDIR/repo" && CLAUDE_PROJECT_DIR="$BP_TMPDIR/repo" env "$@" bash "$BLOCK_HOOK" <<<"$(bp_hook_input "$cmd")" 2>&1 1>/dev/null)
}

setup_bp_repo "main"
msg=$(run_block_hook_stderr "git push -u origin develop" BASE_BRANCH=develop)
assert_contains "TC-BASEBR-024b BASE_BRANCH=develop block message names 'develop', not 'main'" "$msg" '`develop`'
assert_no_contains "TC-BASEBR-024b BASE_BRANCH=develop block message has no 'Direct Push to Main'" "$msg" "Direct Push to Main"
assert_no_contains "TC-BASEBR-024b BASE_BRANCH=develop block message has no 'directly to \`main\`'" "$msg" 'directly to `main`'

msg=$(run_block_hook_stderr "git push -u origin main")
assert_contains "TC-BASEBR-024b BASE_BRANCH unset block message still names 'main' (regression pin)" "$msg" '`main`'

# ===========================================================================
echo ""
echo "=== TC-BASEBR-025: wiring pins — resolve+export placement ==="
# ===========================================================================
assert_grep "TC-BASEBR-025 autonomous-dev.sh resolves BASE_BRANCH via resolve_base_branch" \
  'BASE_BRANCH="\$\(resolve_base_branch\)"' "$DEV_WRAPPER"
assert_grep "TC-BASEBR-025 autonomous-dev.sh exports BASE_BRANCH" \
  '^export BASE_BRANCH$' "$DEV_WRAPPER"
assert_grep "TC-BASEBR-025 autonomous-review.sh resolves BASE_BRANCH via resolve_base_branch" \
  'BASE_BRANCH="\$\(resolve_base_branch\)"' "$REVIEW_WRAPPER"
assert_grep "TC-BASEBR-025 autonomous-review.sh exports BASE_BRANCH" \
  '^export BASE_BRANCH$' "$REVIEW_WRAPPER"

# ===========================================================================
echo ""
echo "=== TC-BASEBR-026: no hardcoded origin/main or 'onto main' remains ==="
# ===========================================================================
dev_hits=$(grep -nE 'origin/main|onto main' "$DEV_WRAPPER" | grep -v '^\s*[0-9]*:\s*#' || true)
review_hits=$(grep -nE 'origin/main|onto main' "$REVIEW_WRAPPER" | grep -v '^\s*[0-9]*:\s*#' || true)
assert_empty "TC-BASEBR-026 no live origin/main or 'onto main' in autonomous-dev.sh" "$dev_hits"
assert_empty "TC-BASEBR-026 no live origin/main or 'onto main' in autonomous-review.sh" "$review_hits"

# ===========================================================================
echo ""
echo "=== TC-BASEBR-027: bash -n on every modified script ==="
# ===========================================================================
for f in "$LIB_CONFIG" "$DEV_WRAPPER" "$REVIEW_WRAPPER" "$GH_LEAF" "$GL_LEAF" "$REBASE_HOOK" "$VERIFY_HOOK" "$BLOCK_HOOK"; do
  if bash -n "$f" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: TC-BASEBR-027 bash -n $(basename "$f")"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-BASEBR-027 bash -n failed for $(basename "$f")"
    FAIL=$((FAIL + 1))
  fi
done

# ===========================================================================
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
