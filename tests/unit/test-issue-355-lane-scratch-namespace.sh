#!/bin/bash
# test-issue-355-lane-scratch-namespace.sh — issue #355 (INV-100).
#
# Superset hardening of #353/#354: every review-lane scratch path is keyed by
# (PROJECT_ID, agent, PR/issue) via a wrapper-created lane dir (mktemp -d as
# the primary mechanism), agents receive concrete literal paths, and
# post-verdict.sh enforces the rendered path read-side when VERDICT_BODY_FILE
# is set. This file covers the parts NOT already covered by:
#   - test-issue-353-verdict-body-namespace.sh (D1 path-uniqueness + the
#     original #342 two-writer race, updated for the lane-dir shape)
#   - test-post-verdict.sh (D2 VERDICT_BODY_FILE enforcement, TC-PV-25..31)
#
# This file adds:
#   1. Two-writer matrix (D1): (a) cross-project same issue number,
#      (b) same-project same-PR different agent (fan-out), (c) same-project
#      same-PR different lane (retry) — each posts its own body verbatim.
#   2. D1 render-time literal-path test for an agent whose session id is
#      EMPTY at render time (the codex/opencode shape) — the rendered prompt
#      must contain the LITERAL lane path, no `$VAR` token.
#   3. D3 pre-clean idempotency — a pre-existing dir (crashed prior lane)
#      does not wedge the documented rebase flow.
#   4. R6 grep-pins — every legacy scratch-path form is ABSENT from `skills/`
#      (docs/designs/ history is exempt — asserted explicitly below).
#
# Run: bash tests/unit/test-issue-355-lane-scratch-namespace.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
HELPER_SRC="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/post-verdict.sh"
LIBCONFIG_SRC="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-config.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_true() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "true" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected [$expected] got [$actual])"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
echo "=== TC-LSN-MATRIX: two-writer matrix (D1) ==="
# ---------------------------------------------------------------------------
# Render build_review_prompt for each scenario, extract the resolved lane-dir
# body path, write a distinct body to each, then post via the real
# post-verdict.sh (with VERDICT_BODY_FILE pinned to each scenario's own
# rendered path, mirroring the wrapper's real export) and assert each posts
# its own body verbatim.
_FN_SLICE=$(mktemp)
awk '/^build_review_prompt\(\) \{/,/^}$/' "$WRAPPER" > "$_FN_SLICE"
_RESOLVE_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-resolve.sh"
_ARTIFACT_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-artifact.sh"

render() {
  local project="$1" agent="$2" issue="$3" sid="$4"
  (
    set +e
    render_bot_review_section() { :; }
    _revalidate_ac_coverage_file() { printf ''; }
    gh() { return 0; }
    PR_NUMBER=210; ISSUE_NUMBER="$issue"; REPO="owner/repo"; REPO_OWNER="owner"
    REPO_NAME="repo"; PR_BRANCH="feat/x"; REVIEW_BOTS_VALIDATED=""; E2E_ACTIVE="false"
    PROJECT_ID="$project"
    unset AGENT_REVIEW_MODEL AGENT_REVIEW_MODEL_CLAUDE AGENT_REVIEW_MODEL_CODEX AGENT_REVIEW_MODEL_AGY
    source "$_RESOLVE_LIB"
    # #355: _verdict_body_lane_dir (the D1 lane-dir provisioner) lives in
    # lib-review-artifact.sh, sourced by the real wrapper but not by this
    # function-slice sandbox.
    source "$_ARTIFACT_LIB"
    source "$_FN_SLICE"
    build_review_prompt "$agent" "$sid"
  )
}

resolve_path() {
  grep -oE '/tmp/review-[A-Za-z0-9._-]+/verdict\.md' <<<"$1" | head -1
}

# (a) cross-project, SAME issue number, same agent.
PROMPT_A1=$(render "proj-alpha" "codex" 500 "sid-a1")
PROMPT_A2=$(render "proj-beta"  "codex" 500 "sid-a2")
PATH_A1=$(resolve_path "$PROMPT_A1")
PATH_A2=$(resolve_path "$PROMPT_A2")
assert_true "TC-LSN-01a cross-project (same issue #500) resolves distinct paths" \
  "$([[ -n "$PATH_A1" && -n "$PATH_A2" && "$PATH_A1" != "$PATH_A2" ]] && echo true || echo false)"

# (b) SAME project, SAME PR/issue, DIFFERENT agent (fan-out).
PROMPT_B1=$(render "proj-gamma" "codex"  600 "sid-b1")
PROMPT_B2=$(render "proj-gamma" "claude" 600 "sid-b2")
PATH_B1=$(resolve_path "$PROMPT_B1")
PATH_B2=$(resolve_path "$PROMPT_B2")
assert_true "TC-LSN-01b same-project same-PR different-agent (fan-out) resolves distinct paths" \
  "$([[ -n "$PATH_B1" && -n "$PATH_B2" && "$PATH_B1" != "$PATH_B2" ]] && echo true || echo false)"

# (c) SAME project, SAME PR/issue, SAME agent, DIFFERENT lane (retry — e.g. a
# re-dispatched review round). Each render call self-provisions its OWN
# mktemp -d lane, so two independent renders for the identical (project,
# agent, issue) tuple must still resolve to two DIFFERENT directories.
PROMPT_C1=$(render "proj-delta" "agy" 700 "sid-c1")
PROMPT_C2=$(render "proj-delta" "agy" 700 "sid-c2")
PATH_C1=$(resolve_path "$PROMPT_C1")
PATH_C2=$(resolve_path "$PROMPT_C2")
assert_true "TC-LSN-01c same-project same-PR same-agent different-lane (retry) resolves distinct paths" \
  "$([[ -n "$PATH_C1" && -n "$PATH_C2" && "$PATH_C1" != "$PATH_C2" ]] && echo true || echo false)"
rm -f "$_FN_SLICE"

# --- Each scenario posts its own body verbatim (VERDICT_BODY_FILE pinned per
# scenario, mirroring the wrapper's real per-agent export) -------------------
post_and_capture() {
  local sb="$1" path="$2" sid="$3" body="$4"
  printf '%s' "$body" > "$path"
  VERDICT_BODY_FILE="$path" \
    bash "$sb/post-verdict.sh" 999 fail "$path" codex "$sid" sonnet >/dev/null 2>&1
  cat "$sb/gh-body.txt" 2>/dev/null || echo ""
}

make_matrix_sandbox() {
  local sb; sb="$(mktemp -d)"
  cat > "$sb/autonomous.conf" <<'CONF'
REPO="owner/repo"
REPO_OWNER="owner"
REPO_NAME="repo"
CONF
  cat > "$sb/gh" <<STUB
#!/bin/bash
prev=""
for a in "\$@"; do
  if [[ "\$prev" == "--body" ]]; then printf '%s' "\$a" > "$sb/gh-body.txt"; fi
  prev="\$a"
done
echo "https://github.com/owner/repo/issues/999#issuecomment-1"
exit 0
STUB
  chmod +x "$sb/gh"
  cp "$HELPER_SRC" "$sb/post-verdict.sh"
  chmod +x "$sb/post-verdict.sh"
  [[ -f "$LIBCONFIG_SRC" ]] && cp "$LIBCONFIG_SRC" "$sb/lib-config.sh"
  printf '%s' "$sb"
}

SB_A=$(make_matrix_sandbox)
BODY_A1=$(post_and_capture "$SB_A" "$PATH_A1" "sid-a1" "cross-project body ALPHA")
assert_true "TC-LSN-02a cross-project scenario posts its own body verbatim" \
  "$([[ "$BODY_A1" == *"cross-project body ALPHA"* ]] && echo true || echo false)"
rm -rf "$SB_A" "$(dirname "$PATH_A1")" "$(dirname "$PATH_A2")" 2>/dev/null

SB_B=$(make_matrix_sandbox)
BODY_B1=$(post_and_capture "$SB_B" "$PATH_B1" "sid-b1" "fan-out body CODEX")
assert_true "TC-LSN-02b fan-out scenario posts its own body verbatim" \
  "$([[ "$BODY_B1" == *"fan-out body CODEX"* ]] && echo true || echo false)"
rm -rf "$SB_B" "$(dirname "$PATH_B1")" "$(dirname "$PATH_B2")" 2>/dev/null

SB_C=$(make_matrix_sandbox)
BODY_C1=$(post_and_capture "$SB_C" "$PATH_C1" "sid-c1" "retry-lane body FIRST")
assert_true "TC-LSN-02c retry-lane scenario posts its own body verbatim" \
  "$([[ "$BODY_C1" == *"retry-lane body FIRST"* ]] && echo true || echo false)"
rm -rf "$SB_C" "$(dirname "$PATH_C1")" "$(dirname "$PATH_C2")" 2>/dev/null

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LSN-EMPTY-SID: D1 render-time literal path for an EMPTY session id (codex/opencode shape) ==="
# ---------------------------------------------------------------------------
_FN_SLICE2=$(mktemp)
awk '/^build_review_prompt\(\) \{/,/^}$/' "$WRAPPER" > "$_FN_SLICE2"
PROMPT_EMPTY_SID=$(
  set +e
  render_bot_review_section() { :; }
  _revalidate_ac_coverage_file() { printf ''; }
  gh() { return 0; }
  PR_NUMBER=210; ISSUE_NUMBER=800; REPO="owner/repo"; REPO_OWNER="owner"
  REPO_NAME="repo"; PR_BRANCH="feat/x"; REVIEW_BOTS_VALIDATED=""; E2E_ACTIVE="false"
  PROJECT_ID="proj-epsilon"
  unset AGENT_REVIEW_MODEL AGENT_REVIEW_MODEL_CLAUDE AGENT_REVIEW_MODEL_CODEX
  source "$_RESOLVE_LIB"
  source "$_ARTIFACT_LIB"
  source "$_FN_SLICE2"
  # EMPTY 2nd arg — codex/opencode mint their thread/session id AFTER launch,
  # so this is what the prompt render sees for those CLIs.
  build_review_prompt "codex" ""
)
rm -f "$_FN_SLICE2"

# The rendered prompt must contain a LITERAL lane path (mktemp -d resolved to
# a concrete string) with NO unexpanded `$` token anywhere in that path
# component — a template like `${LANE_DIR}/verdict.md` reaching the agent
# verbatim would recreate a shared literal across every agent that copies it.
EMPTY_SID_PATH=$(resolve_path "$PROMPT_EMPTY_SID")
assert_true "TC-LSN-03a empty-session-id (codex-shaped) render still resolves a concrete lane path" \
  "$([[ -n "$EMPTY_SID_PATH" ]] && echo true || echo false)"
if [[ -n "$EMPTY_SID_PATH" ]] && ! grep -qF '$' <<<"$EMPTY_SID_PATH"; then
  echo -e "  ${GREEN}PASS${NC}: TC-LSN-03b resolved path has no unexpanded \$ token"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-LSN-03b resolved path contains an unexpanded \$ token: '$EMPTY_SID_PATH'"
  FAIL=$((FAIL + 1))
fi
# The literal path (as it appears in the prompt body) must NOT contain the
# literal substring '${' anywhere on its own line — the whole point of D1 is
# that the agent gets a copy-pasteable concrete path, not a template.
if [[ -n "$EMPTY_SID_PATH" ]]; then
  _line_with_path=$(grep -F "$EMPTY_SID_PATH" <<<"$PROMPT_EMPTY_SID" | head -1)
  if ! grep -qF '${' <<<"$_line_with_path"; then
    echo -e "  ${GREEN}PASS${NC}: TC-LSN-03c the rendered line carrying the lane path has no \${...} template syntax"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-LSN-03c rendered line still carries \${...} template syntax: '$_line_with_path'"
    FAIL=$((FAIL + 1))
  fi
fi
rm -rf "$(dirname "$EMPTY_SID_PATH")" 2>/dev/null

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LSN-D3: rebase-dir idempotent pre-clean (crashed prior lane) ==="
# ---------------------------------------------------------------------------
# Extract the ACTUAL Step 0 pre-clean + worktree-add lines from the wrapper's
# prompt heredoc (source-of-truth, not a hand-copied literal), substitute the
# request-scoped tokens with concrete test values, and execute them against a
# real scratch repo whose target dir is PRE-POPULATED (simulating a crashed
# prior lane's leftover worktree) to prove the documented flow is idempotent.
STEP0_BLOCK=$(awk '/## Step 0: Merge Conflict Resolution/,/## Step 0.5/' "$WRAPPER")

D3_PROJECT="d3proj"
D3_AGENT="d3agent"
D3_PR="4242"
EXPECTED_DIR="/tmp/rebase-${D3_PROJECT}-${D3_AGENT}-pr-${D3_PR}"

# Source-of-truth: the exact dir token appears in the wrapper's Step 0 block.
if grep -qF '/tmp/rebase-${PROJECT_ID}-${_agent_name}-pr-${PR_NUMBER}' <<<"$STEP0_BLOCK"; then
  echo -e "  ${GREEN}PASS${NC}: TC-LSN-D3-01 wrapper Step 0 block renders the PROJECT_ID+agent+PR rebase dir"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-LSN-D3-01 wrapper Step 0 block does not render the expected rebase-dir token"
  FAIL=$((FAIL + 1))
fi

# Extract the pre-clean + worktree-add lines and substitute concrete values.
PRECLEAN_LINE=$(grep -F 'git worktree remove --force /tmp/rebase-' <<<"$STEP0_BLOCK" | head -1)
ADD_LINE=$(grep -F 'git worktree add /tmp/rebase-' <<<"$STEP0_BLOCK" | head -1)
assert_true "TC-LSN-D3-02 pre-clean line extracted from the wrapper's own prompt" \
  "$([[ -n "$PRECLEAN_LINE" ]] && echo true || echo false)"
assert_true "TC-LSN-D3-03 worktree-add line extracted from the wrapper's own prompt" \
  "$([[ -n "$ADD_LINE" ]] && echo true || echo false)"

subst_tokens() {
  local line="$1"
  line="${line//\$\{PROJECT_ID\}/$D3_PROJECT}"
  line="${line//\$\{_agent_name\}/$D3_AGENT}"
  line="${line//\$\{PR_NUMBER\}/$D3_PR}"
  line="${line//\$\{PR_BRANCH\}/feat-branch}"
  printf '%s' "$line"
}
PRECLEAN_CMD=$(subst_tokens "$PRECLEAN_LINE")
ADD_CMD=$(subst_tokens "$ADD_LINE")

# Build a scratch repo with a diverging feat-branch (mirrors the CI-hermetic
# pattern test-lib-review-codex.sh uses for its own worktree-prep fixture —
# all git init/commit calls live INSIDE this .sh file, not in the harness's
# own direct shell invocations).
D3_REPO=$(mktemp -d)
(
  cd "$D3_REPO"
  git init -q -b main
  git config user.email t@t; git config user.name t
  echo base > f.txt; git add f.txt; git commit -qm base
  git checkout -q -b feat-branch
  echo change >> f.txt; git add f.txt; git commit -qm change
  git checkout -q main
) >/dev/null 2>&1

# Simulate a crashed prior lane: pre-populate the EXACT target dir with a
# leftover worktree checkout BEFORE the rebase flow ever runs the pre-clean.
rm -rf "$EXPECTED_DIR" 2>/dev/null
(cd "$D3_REPO" && git worktree add -q "$EXPECTED_DIR" feat-branch) >/dev/null 2>&1
CRASHED_LANE_EXISTS=$([[ -d "$EXPECTED_DIR" ]] && echo true || echo false)
assert_true "TC-LSN-D3-04 crashed-prior-lane fixture pre-populated at the exact target dir" "$CRASHED_LANE_EXISTS"

# Run the documented flow AS-IS: pre-clean, then worktree add. If the
# pre-clean were absent, `git worktree add` on a dir git already tracks as an
# active worktree would fail (git refuses to add over a live worktree path).
D3_RESULT=$(
  cd "$D3_REPO"
  eval "$PRECLEAN_CMD" 2>&1
  eval "$ADD_CMD"; echo "ADD_RC=$?"
)
D3_ADD_RC=$(grep -oE 'ADD_RC=[0-9]+' <<<"$D3_RESULT" | cut -d= -f2)
assert_eq "TC-LSN-D3-05 pre-clean + worktree add succeeds against a pre-existing crashed-lane dir" "0" "${D3_ADD_RC:-1}"

# The resulting worktree must be checked out AT the feat-branch tip (proving
# it's a FRESH worktree from THIS run, not a stale leftover).
D3_HEAD_SUBJ=$(git -C "$EXPECTED_DIR" log -1 --format=%s 2>/dev/null || echo NONE)
assert_eq "TC-LSN-D3-06 fresh worktree HEAD is the feat-branch tip commit" "change" "$D3_HEAD_SUBJ"

# Cleanup.
(cd "$D3_REPO" && git worktree remove --force "$EXPECTED_DIR" 2>/dev/null) || rm -rf "$EXPECTED_DIR"
rm -rf "$D3_REPO" "$EXPECTED_DIR" 2>/dev/null

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LSN-R6: grep-pins — legacy scratch-path forms absent from skills/ ==="
# ---------------------------------------------------------------------------
# docs/designs/ HISTORY IS EXEMPT (explicit boundary, R6) — those documents
# describe the state of the world AT THE TIME they were authored and are not
# updated retroactively. Only `skills/` (the actually-consumed prompt/doc
# templates) is asserted clean.
SKILLS_DIR="$PROJECT_ROOT/skills"

check_absent() {
  local desc="$1" pattern="$2"
  if grep -rqE "$pattern" "$SKILLS_DIR" 2>/dev/null; then
    echo -e "  ${RED}FAIL${NC}: $desc — pattern still found in skills/"
    echo "      $(grep -rnE "$pattern" "$SKILLS_DIR" 2>/dev/null | head -3)"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  fi
}

check_absent "TC-LSN-R6-01 bare /tmp/verdict-\${_agent_name}.md form absent" \
  '/tmp/verdict-\$\{_agent_name\}\.md'
check_absent "TC-LSN-R6-02 bare /tmp/verdict.md (unnamespaced example) absent" \
  '/tmp/verdict\.md[^-]'
check_absent "TC-LSN-R6-03 /tmp/rebase-pr-\${PR_NUMBER} (PROJECT_ID/agent-less) form absent" \
  '/tmp/rebase-pr-\$\{PR_NUMBER\}'
check_absent "TC-LSN-R6-03b /tmp/rebase-pr-<PR_NUMBER> (doc placeholder) form absent" \
  '/tmp/rebase-pr-<PR_NUMBER>'
check_absent "TC-LSN-R6-04 /tmp/e2e-ac-coverage-\${PR_NUMBER}.json (PR-number-only) form absent" \
  '/tmp/e2e-ac-coverage-\$\{PR_NUMBER\}\.json'
check_absent "TC-LSN-R6-05 /tmp/e2e-\${PR_NUMBER}.log (PR-number-only) form absent" \
  '/tmp/e2e-\$\{PR_NUMBER\}\.log'
check_absent "TC-LSN-R6-05b /tmp/e2e-\${PR_NUMBER}.log in a doc-code-span (no PROJECT_ID) form absent" \
  '`/tmp/e2e-\$\{PR_NUMBER\}\.log`'

# Positive control: the NEW forms ARE present (proves the greps above aren't
# vacuously passing because the whole feature is missing). D1's lane-dir
# template lives once, in the shared _verdict_body_lane_dir helper
# (lib-review-artifact.sh) — both call sites route through it.
if grep -rqF 'mktemp -d "/tmp/review-${_project}-${_agent}-${_issue}-XXXXXX"' "$SKILLS_DIR" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-LSN-R6-06 positive control — D1 lane-dir mechanism IS present"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-LSN-R6-06 positive control failed — D1 lane-dir mechanism not found (grep pins would be vacuous)"
  FAIL=$((FAIL + 1))
fi
if grep -rqF 'rebase-${PROJECT_ID}-${_agent_name}-pr-${PR_NUMBER}' "$SKILLS_DIR" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-LSN-R6-07 positive control — D3 rebase-dir rename IS present"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-LSN-R6-07 positive control failed — D3 rebase-dir rename not found"
  FAIL=$((FAIL + 1))
fi
if grep -rqE 'e2e-ac-coverage-\$\{PROJECT_ID\}-\$\{PR_NUMBER\}' "$SKILLS_DIR" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-LSN-R6-08 positive control — D4 E2E sidecar re-keying IS present"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-LSN-R6-08 positive control failed — D4 E2E sidecar re-keying not found"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LSN-SYNTAX: modified scripts parse ==="
# ---------------------------------------------------------------------------
for f in "$WRAPPER" "$HELPER_SRC" \
  "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-e2e.sh"; do
  if bash -n "$f" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: TC-LSN-SYNTAX $(basename "$f") passes bash -n"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-LSN-SYNTAX $(basename "$f") has a syntax error"
    FAIL=$((FAIL + 1))
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
