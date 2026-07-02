#!/bin/bash
# test-issue-353-verdict-body-namespace.sh — issue #353 (updated by #355, NOT
# deleted — R1 requires keeping this regression test current with the new
# path shape rather than dropping it).
#
# Background. The review-agent prompt template (`build_review_prompt` in
# autonomous-review.sh) told every review agent to write its comment-fallback
# verdict BODY to `/tmp/verdict-<agent-name>.md` — a path keyed ONLY on the
# agent name. That path is GLOBAL across every concurrent review on the host
# (every project, every issue, every session). Two overlapping reviews in
# different projects (or even the same project, different issues) race on the
# same file: the later writer's findings land in the earlier issue's verdict
# comment, under the earlier issue's session trailer — passing every
# INV-20/INV-40 attribution check (observed twice against #342 on 2026-07-01).
#
# #353/#354 fix: namespace the path by agent name + issue number + the agent's
# OWN session id — `/tmp/verdict-<agent>-<issue>-<session>.md`.
#
# #355 (INV-100) supersedes that literal with a wrapper-created per-lane
# `mktemp -d` scratch DIR (`/tmp/review-<project>-<agent>-<issue>-XXXXXX`),
# rendered into the prompt as the LITERAL `<lanedir>/verdict.md` — no
# `${_agent_session_id}` token in the path at all. This closes a gap the
# #353/#354 literal left open: codex/opencode mint their thread/session id
# AFTER launch, so `${_agent_session_id}` can be EMPTY at prompt-RENDER time
# for those CLIs, collapsing the #353/#354 path back to the cross-project-
# collidable `/tmp/verdict-codex-<issue>-.md` shape. A `mktemp -d` suffix has
# no such dependency. See test-issue-355-lane-scratch-namespace.sh for the
# full D1/D2/D3/D4/R6 coverage this PR adds; this file keeps validating the
# original #353 race is closed under the NEW path mechanism.
#
# This test:
#   1. Source-of-truth greps: the bare `/tmp/verdict-<agent>.md` form (no issue
#      number, no session id token) is ABSENT; the lane-dir self-provisioning
#      fallback (PROJECT_ID + agent + ISSUE_NUMBER tokens, `mktemp -d`) is
#      present.
#   2. Behavioral two-writer simulation: render the prompt for two DISTINCT
#      (issue, lane-dir) pairs — mirroring how the real fan-out loop provisions
#      one lane dir per agent — write a DIFFERENT body to each path (simulating
#      two concurrent agents), then invoke the real post-verdict.sh for issue 1
#      and assert the posted body is body A verbatim — never body B.
#
# Run: bash tests/unit/test-issue-353-verdict-body-namespace.sh

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

PROMPT_FN=$(awk '/^build_review_prompt\(\) \{/,/^\}/' "$WRAPPER")

# ---------------------------------------------------------------------------
echo "=== TC-VBN-SRC: the bare global verdict-body path is gone; namespaced form present ==="
# ---------------------------------------------------------------------------

# AC1: the bare `/tmp/verdict-${_agent_name}.md` form (agent name only, no
# issue number, no session id) must be ABSENT from the prompt function.
if grep -qE '/tmp/verdict-\$\{_agent_name\}\.md' <<<"$PROMPT_FN"; then
  echo -e "  ${RED}FAIL${NC}: TC-VBN-01 bare /tmp/verdict-\${_agent_name}.md form still present"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-VBN-01 bare /tmp/verdict-\${_agent_name}.md form is absent"
  PASS=$((PASS + 1))
fi

# AC1 (#355 update): the #353/#354 session-id-namespaced literal is GONE —
# build_review_prompt no longer constructs the verdict body path itself from
# ${_agent_session_id}; it takes the caller-rendered path as an optional 4th
# arg and self-provisions a `mktemp -d` lane dir (PROJECT_ID+agent+ISSUE_NUMBER
# keyed, no session-id dependency) only when the caller omits it.
if grep -qE '_verdict_body_path=.*/tmp/verdict-.*\$\{_agent_name\}.*\$\{ISSUE_NUMBER\}.*\$\{_agent_session_id\}' <<<"$PROMPT_FN"; then
  echo -e "  ${RED}FAIL${NC}: TC-VBN-02 the #353/#354 session-id-namespaced literal is still present (should be superseded by the #355 lane-dir mechanism)"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-VBN-02 the #353/#354 session-id-namespaced literal is gone (superseded by #355's lane-dir mechanism)"
  PASS=$((PASS + 1))
fi

# AC1 (#355): the self-provisioning fallback calls the shared
# _verdict_body_lane_dir helper (lib-review-artifact.sh) keyed by PROJECT_ID +
# agent name + ISSUE_NUMBER — no session-id token required. Routed through the
# single-source-of-truth helper (not a second hand-rolled mktemp template) so
# it can never diverge from the fan-out loop's own provisioning call.
if grep -qE '_verdict_body_lane_dir "\$\{PROJECT_ID:-\}" "\$\{_agent_name\}" "\$\{ISSUE_NUMBER:-\}"' <<<"$PROMPT_FN"; then
  echo -e "  ${GREEN}PASS${NC}: TC-VBN-02b self-provisioning fallback calls _verdict_body_lane_dir keyed by project+agent+issue (no session-id dependency)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-VBN-02b no self-provisioning _verdict_body_lane_dir call found"
  FAIL=$((FAIL + 1))
fi

# The namespaced variable must actually be USED at every verdict-post site
# (not just declared and ignored) — at least 3 uses (the generic example +
# the PASS branch + the FAIL branch), consistent with post-verdict.sh being
# referenced 5x (3 concrete invocations + 2 prose mentions).
_n_body_path_uses=$(grep -coE '\$\{_verdict_body_path\}' <<<"$PROMPT_FN")
if [[ "$_n_body_path_uses" -ge 3 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-VBN-03 namespaced body path used at >=3 sites (found $_n_body_path_uses)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-VBN-03 namespaced body path used at only $_n_body_path_uses site(s), expected >=3"
  FAIL=$((FAIL + 1))
fi

# post-verdict.sh's own usage-example doc string must no longer show the bare
# `/tmp/verdict.md` global-scratch form.
if grep -qF '/tmp/verdict.md' "$HELPER_SRC"; then
  echo -e "  ${RED}FAIL${NC}: TC-VBN-04 post-verdict.sh usage example still shows the bare /tmp/verdict.md form"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-VBN-04 post-verdict.sh usage example no longer shows the bare /tmp/verdict.md form"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-VBN-BEHAVE: rendered prompt resolves to a DISTINCT path per (issue, session) ==="
# ---------------------------------------------------------------------------
_FN_SLICE=$(mktemp)
awk '/^build_review_prompt\(\) \{/,/^}$/' "$WRAPPER" > "$_FN_SLICE"
_RESOLVE_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-resolve.sh"
_ARTIFACT_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-artifact.sh"

render_for_issue() {
  local issue="$1" sid="$2" project="${3:-}"
  (
    set +e
    render_bot_review_section() { :; }
    _revalidate_ac_coverage_file() { printf ''; }
    gh() { return 0; }
    PR_NUMBER=210; ISSUE_NUMBER="$issue"; REPO="owner/repo"; REPO_OWNER="owner"
    REPO_NAME="repo"; PR_BRANCH="feat/x"; REVIEW_BOTS_VALIDATED=""; E2E_ACTIVE="false"
    # #355: PROJECT_ID feeds the self-provisioning lane-dir fallback below —
    # empty when the caller wants the "no PROJECT_ID set" degraded case.
    PROJECT_ID="$project"
    unset AGENT_REVIEW_MODEL AGENT_REVIEW_MODEL_CLAUDE AGENT_REVIEW_MODEL_CODEX
    source "$_RESOLVE_LIB"
    # #355: _verdict_body_lane_dir (the D1 lane-dir provisioner) lives in
    # lib-review-artifact.sh, sourced by the real wrapper but not by this
    # function-slice sandbox.
    source "$_ARTIFACT_LIB"
    source "$_FN_SLICE"
    build_review_prompt "codex" "$sid"
  )
}

# Two DIFFERENT issue numbers with EMPTY session ids — simulating two
# concurrent codex reviews on the host, in different projects/issues (#342's
# actual scenario), AND the #355-motivating gap where codex's session id is
# not yet minted at prompt-render time (empty 2nd arg). No 4th (caller-
# rendered) arg is passed, so build_review_prompt self-provisions its own
# mktemp -d lane dir per call.
PROMPT_ISSUE_1=$(render_for_issue 342 "" "proj-a")
PROMPT_ISSUE_2=$(render_for_issue 999 "" "proj-b")
rm -f "$_FN_SLICE"

# Extract each prompt's RESOLVED body path generically (not a hardcoded
# expected literal) — whatever /tmp/review-<project>-codex-<issue>-XXXXXX/
# verdict.md the CURRENT code actually renders. This is what makes TC-VBN-SIM
# below a genuine regression test: if the lane-dir mechanism were reverted to
# a bare agent-name-only literal, PATH_1 and PATH_2 would resolve to the
# IDENTICAL string, and the simulation's second write would clobber the first
# writer's file at that shared path — exactly the #342 race.
PATH_1=$(grep -oE '/tmp/review-[A-Za-z0-9._-]+/verdict\.md' <<<"$PROMPT_ISSUE_1" | head -1)
PATH_2=$(grep -oE '/tmp/review-[A-Za-z0-9._-]+/verdict\.md' <<<"$PROMPT_ISSUE_2" | head -1)

assert_true "TC-VBN-05 issue #342 (empty session id, codex-shaped) resolves its own lane-dir path" \
  "$([[ -n "$PATH_1" ]] && echo true || echo false)"
assert_true "TC-VBN-06 issue #999 (empty session id, codex-shaped) resolves its own lane-dir path" \
  "$([[ -n "$PATH_2" ]] && echo true || echo false)"
assert_true "TC-VBN-07 the two resolved paths are DISTINCT (no collision) even with EMPTY session ids" \
  "$([[ "$PATH_1" != "$PATH_2" ]] && echo true || echo false)"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-VBN-SIM: two-writer race simulation — post-verdict.sh for issue 1 posts body A, never body B ==="
# ---------------------------------------------------------------------------
# Reproduces the #342 race directly using the SAME resolved paths PATH_1/
# PATH_2 extracted above (not independently-constructed literals). Writer A
# (issue 342) writes FIRST to PATH_1; writer B (issue 999, sibling project)
# writes SECOND to PATH_2, simulating B's write landing after A's but before
# A's post-verdict.sh invocation reads it — the exact interleaving that
# poisoned #342. Because the fix makes PATH_1 != PATH_2 (asserted by
# TC-VBN-07), B's write cannot clobber A's file. Pre-fix (bare agent-name-only
# path), PATH_1 would equal PATH_2, B's write WOULD clobber A's file, and
# TC-VBN-09/10 below would fail — proving this is a genuine regression test,
# not a tautology. VERDICT_BODY_FILE is deliberately left UNSET for this
# simulation — this test isolates the D1 path-uniqueness mechanism; D2's
# read-side enforcement is covered separately in
# test-issue-355-lane-scratch-namespace.sh.

SIM_SB="$(mktemp -d)"
cat > "$SIM_SB/autonomous.conf" <<'CONF'
REPO="owner/repo"
REPO_OWNER="owner"
REPO_NAME="repo"
CONF
cat > "$SIM_SB/gh" <<STUB
#!/bin/bash
prev=""
for a in "\$@"; do
  if [[ "\$prev" == "--body" ]]; then printf '%s' "\$a" > "$SIM_SB/gh-body.txt"; fi
  prev="\$a"
done
echo "https://github.com/owner/repo/issues/342#issuecomment-1"
exit 0
STUB
chmod +x "$SIM_SB/gh"
cp "$HELPER_SRC" "$SIM_SB/post-verdict.sh"
chmod +x "$SIM_SB/post-verdict.sh"
[[ -f "$LIBCONFIG_SRC" ]] && cp "$LIBCONFIG_SRC" "$SIM_SB/lib-config.sh"

# writer A (issue 342) writes first...
printf 'Review findings:\n1. GENUINE finding for issue 342 (ours).' > "$PATH_1"
# ...then writer B (issue 999, sibling project) writes second — if PATH_1 and
# PATH_2 were the same file (the pre-fix bug), this OVERWRITES writer A's body.
printf 'Review findings:\n1. FOREIGN finding for issue 999 (sibling project — must NEVER appear on 342).' > "$PATH_2"

( cd "$SIM_SB" && ./post-verdict.sh 342 fail "$PATH_1" codex "174a3d5b-b345-4f91-9d46-17ab86ee6d09" sonnet >/dev/null 2>&1 )
SIM_RC=$?
POSTED_BODY=$(cat "$SIM_SB/gh-body.txt" 2>/dev/null || echo "")
rm -f "$PATH_1" "$PATH_2"
rm -rf "$SIM_SB"

assert_true "TC-VBN-08 post-verdict.sh for issue 342 exited 0" \
  "$([[ "$SIM_RC" -eq 0 ]] && echo true || echo false)"
assert_true "TC-VBN-09 posted body contains issue 342's GENUINE finding" \
  "$([[ "$POSTED_BODY" == *"GENUINE finding for issue 342"* ]] && echo true || echo false)"
assert_true "TC-VBN-10 posted body does NOT contain issue 999's FOREIGN finding" \
  "$([[ "$POSTED_BODY" != *"FOREIGN finding for issue 999"* ]] && echo true || echo false)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
