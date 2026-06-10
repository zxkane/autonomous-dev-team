#!/bin/bash
# test-autonomous-review-verdict-via-helper.sh — issue #202 / INV-56.
#
# build_review_prompt must route EVERY verdict-post instruction through the
# deterministic helper `scripts/post-verdict.sh` and explicitly forbid a bare
# `gh issue comment` for the verdict. There are THREE spots:
#   1. Decision block — PASS branch
#   2. Decision block — FAIL branch
#   3. The codex-specific prompt block. Pre-#218 this was the INV-55 inline-diff
#      block; as of INV-62 (#218) it is the `codex review` CODEX_REVIEW_NOTE
#      block, which still carries a "post your verdict via post-verdict.sh"
#      instruction (the codex review lane self-posts, with a wrapper stdout
#      fallback).
# The instruction must apply to ALL agents (no per-CLI branch for the verdict
# post), and the first-line phrasing the poller matches (`Review PASSED` /
# `Review findings:`) must be preserved.
#
# Strategy (mirrors test-autonomous-review-prompt.sh):
#   1. Source-of-truth greps against the build_review_prompt function body.
#   2. Behavioral: render the prompt for codex and a non-codex agent in a
#      sandbox and assert the helper instruction appears identically for both.
#
# Run: bash tests/unit/test-autonomous-review-verdict-via-helper.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PROMPT_FN=$(awk '/^build_review_prompt\(\) \{/,/^\}/' "$WRAPPER")

assert_fn_grep() {
  local desc="$1" pattern="$2"
  # NOTE: feed the haystack via a here-string, NOT `printf | grep -q`. With
  # `set -o pipefail`, `grep -q` closes the pipe on its first match and the
  # upstream `printf` dies with SIGPIPE → the pipeline's status becomes 141
  # even though grep matched, so the `if` wrongly takes the FAIL branch
  # (flaky, position-dependent). A here-string has no pipe and no SIGPIPE.
  if grep -qE "$pattern" <<<"$PROMPT_FN"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep_count_ge() {
  local desc="$1" pattern="$2" min="$3"
  local n
  n=$(grep -cE "$pattern" <<<"$PROMPT_FN")
  if [[ "$n" -ge "$min" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc (found $n ≥ $min)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (found $n, need ≥ $min; pattern: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
echo "=== TC-PVP-SRC: build_review_prompt routes verdict through post-verdict.sh ==="
# ---------------------------------------------------------------------------

# TC-PVP-01/02: the Decision block (PASS + FAIL) references the helper. The
# helper string appears at least twice (once per branch).
assert_grep_count_ge "TC-PVP-01/02 post-verdict.sh referenced for both Decision branches" \
  'scripts/post-verdict\.sh' 2

# TC-PVP-04: the prompt explicitly forbids a bare `gh issue comment` for the
# verdict. Match loosely on "NOT ... bare `gh issue comment`" (tolerates the
# markdown bold `**NOT**`, an intervening "use a"/"hand-roll a", and the
# escaped backticks around `gh issue comment`).
assert_fn_grep "TC-PVP-04 forbids bare 'gh issue comment' for the verdict" \
  'NOT.*bare .{0,3}gh issue comment'

# TC-PVP-05: first-line phrasing preserved (poller match unchanged).
assert_fn_grep "TC-PVP-05a 'Review PASSED' phrasing preserved" 'Review PASSED'
assert_fn_grep "TC-PVP-05b 'Review findings:' phrasing preserved" 'Review findings:'

# The helper instruction names the pass/fail verdict argument.
assert_fn_grep "TC-PVP-SRC helper called with a pass verdict arg" \
  'post-verdict\.sh.*pass'
assert_fn_grep "TC-PVP-SRC helper called with a fail verdict arg" \
  'post-verdict\.sh.*fail'

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PVP-BEHAVE: rendered prompt routes verdict via helper for all agents ==="
# ---------------------------------------------------------------------------
_FN_SLICE=$(mktemp)
awk '/^build_review_prompt\(\) \{/,/^}$/' "$WRAPPER" > "$_FN_SLICE"
# build_review_prompt resolves the per-agent model via the real
# lib-review-resolve.sh::_resolve_review_agent_model (INV-41) — source the lib
# in the sandbox so the resolver is the production one, not a stub.
_RESOLVE_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-resolve.sh"
SANDBOX_OUT=$(
  set +e
  render_bot_review_section() { :; }
  _revalidate_ac_coverage_file() { printf ''; }
  gh() {
    if [[ "${1:-}" == "pr" && "${2:-}" == "diff" ]]; then
      printf 'diff --git a/x b/x\n@@ -1 +1 @@\n-OLD\n+NEW\n'; return 0
    fi
    return 0
  }
  PR_NUMBER=210; ISSUE_NUMBER=202; REPO="owner/repo"; REPO_OWNER="owner"
  REPO_NAME="repo"; PR_BRANCH="feat/x"; REVIEW_BOTS_VALIDATED=""; E2E_ACTIVE="false"
  # INV-60: per-agent model resolution. Set an override for kiro so the
  # per-agent-override path (TC-PVP-09) renders a distinct id; an agy override
  # with SPACES + PARENS (TC-PVP-12, the multi-word-model quoting regression);
  # leave claude/codex unset so they fall back to the shared/launch default
  # `sonnet` (TC-PVP-11).
  AGENT_REVIEW_MODEL_KIRO="claude-sonnet-4.6"
  AGENT_REVIEW_MODEL_AGY="Gemini 3.5 Flash (High)"
  unset AGENT_REVIEW_MODEL AGENT_REVIEW_MODEL_CLAUDE AGENT_REVIEW_MODEL_CODEX
  source "$_RESOLVE_LIB"
  source "$_FN_SLICE"
  echo "===CODEX==="
  build_review_prompt "codex" "sid-codex"
  echo "===CLAUDE==="
  build_review_prompt "claude" "sid-claude"
  echo "===KIRO==="
  build_review_prompt "kiro" "sid-kiro"
  echo "===AGY==="
  build_review_prompt "agy" "sid-agy"
)
rm -f "$_FN_SLICE"

codex_block=$(printf '%s' "$SANDBOX_OUT" | awk '/===CODEX===/{f=1;next}/===CLAUDE===/{f=0}f')
claude_block=$(printf '%s' "$SANDBOX_OUT" | awk '/===CLAUDE===/{f=1;next}/===KIRO===/{f=0}f')
kiro_block=$(printf '%s' "$SANDBOX_OUT" | awk '/===KIRO===/{f=1;next}/===AGY===/{f=0}f')
agy_block=$(printf '%s' "$SANDBOX_OUT" | awk '/===AGY===/{f=1;next}f')

check_block() {
  local name="$1" block="$2"
  # here-string (not `printf | grep -q`) to avoid the pipefail+SIGPIPE flake
  # described on assert_fn_grep above.
  if grep -q 'scripts/post-verdict.sh' <<<"$block"; then
    echo -e "  ${GREEN}PASS${NC}: TC-PVP-06 [$name] prompt routes the verdict via post-verdict.sh"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-PVP-06 [$name] prompt does NOT reference post-verdict.sh"
    FAIL=$((FAIL + 1))
  fi
}
check_block "codex" "$codex_block"
check_block "claude" "$claude_block"

# TC-PVP-03: the codex-specific prompt block (the INV-62 CODEX_REVIEW_NOTE)
# must defer the verdict post to the helper, not leave a loose bare-gh post.
# The codex block carries the codex-review verdict language AND the helper
# reference; assert the helper reference is present in the codex block.
if grep -qi 'post.*verdict' <<<"$codex_block" \
   && grep -q 'scripts/post-verdict.sh' <<<"$codex_block"; then
  echo -e "  ${GREEN}PASS${NC}: TC-PVP-03 codex review verdict language defers to post-verdict.sh"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-PVP-03 codex review block does not route verdict via post-verdict.sh"
  FAIL=$((FAIL + 1))
fi

# TC-PVP-06b: no bare `gh issue comment` for the verdict in either rendered block.
# (A `gh pr view`/`gh pr checks`/`gh issue view` for reading is fine — only the
# VERDICT post is forbidden via bare gh. We assert the explicit prohibition is
# present and the helper is the named mechanism.)
for nm in codex claude; do
  blk="${nm}_block"
  if grep -qiE 'NOT.*bare .{0,3}gh issue comment' <<<"${!blk}"; then
    echo -e "  ${GREEN}PASS${NC}: TC-PVP-06b [$nm] explicitly forbids bare gh issue comment for the verdict"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-PVP-06b [$nm] missing the bare-gh prohibition"
    FAIL=$((FAIL + 1))
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PVP-MODEL: INV-60 — verdict-post examples carry the per-agent model 6th arg ==="
# ---------------------------------------------------------------------------

# Each concrete `bash scripts/post-verdict.sh …` invocation passes its positional
# args as `<issue> <pass|fail> <body-file> <agent-name> <session-id> <model>`.
# Extract those invocation lines per block and assert the 6th arg is present and
# equals the agent's resolved model.
#
# The invocation lines look like:
#   bash scripts/post-verdict.sh 202 <pass|fail> /tmp/verdict-claude.md claude sid-claude sonnet
#   bash scripts/post-verdict.sh 202 pass /tmp/verdict-claude.md claude sid-claude sonnet
#   bash scripts/post-verdict.sh 202 fail /tmp/verdict-claude.md claude sid-claude sonnet
# We grep the invocation lines and check the trailing token after the session id.

# expected resolved model per rendered agent (mirrors _resolve_review_agent_model
# → :-sonnet given the sandbox env: kiro overridden, codex/claude unset):
declare -A EXPECTED_MODEL=( [codex]="sonnet" [claude]="sonnet" [kiro]="claude-sonnet-4.6" )

assert_invocations_carry_model() {
  local agent="$1" block="$2" expected="$3"
  # Pull the verdict-post invocation lines (those that name the agent + its sid).
  # The session id token for each agent is `sid-<agent>` in the sandbox. The
  # model 6th arg is rendered SINGLE-QUOTED (so a multi-word id stays one token —
  # PR review finding), so the expected trailing token is `'<model>'`.
  local sid="sid-${agent}"
  local lines n_total n_with_model
  lines=$(grep -E 'post-verdict\.sh' <<<"$block" | grep -E "[[:space:]]${agent}[[:space:]]${sid}[[:space:]]'")
  n_total=$(grep -cE "[[:space:]]${agent}[[:space:]]${sid}[[:space:]]'" <<<"$block")
  # Lines where the session id is FOLLOWED by the single-quoted expected model.
  # grep -F on the fixed `<agent> <sid> '<expected>'` string (handles the dots
  # in `claude-sonnet-4.6` and any parens without ERE escaping).
  n_with_model=$(grep -cF "${agent} ${sid} '${expected}'" <<<"$block")

  if [[ "$n_total" -ge 1 ]]; then
    echo -e "  ${GREEN}PASS${NC}: TC-PVP-07 [$agent] at least one verdict-post invocation rendered ($n_total found)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-PVP-07 [$agent] no verdict-post invocation found in block"
    FAIL=$((FAIL + 1))
  fi

  # Every invocation that names the agent+sid must carry the model 6th arg.
  if [[ "$n_total" -ge 1 && "$n_with_model" -eq "$n_total" ]]; then
    echo -e "  ${GREEN}PASS${NC}: TC-PVP-08/10 [$agent] all $n_total invocation(s) carry the model 6th arg '$expected'"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-PVP-08/10 [$agent] $n_with_model/$n_total invocation(s) carry model '$expected'"
    echo "      invocations:"
    printf '        %s\n' "$lines"
    FAIL=$((FAIL + 1))
  fi
}

# TC-PVP-08 (value equals resolved model) + TC-PVP-10 (codex AND non-codex,
# no per-CLI branch) + TC-PVP-11 (unset → launch default `sonnet`):
assert_invocations_carry_model "codex"  "$codex_block"  "${EXPECTED_MODEL[codex]}"
assert_invocations_carry_model "claude" "$claude_block" "${EXPECTED_MODEL[claude]}"

# TC-PVP-09: per-agent override (AGENT_REVIEW_MODEL_KIRO) surfaces the distinct
# id, NOT the shared/launch default.
assert_invocations_carry_model "kiro" "$kiro_block" "${EXPECTED_MODEL[kiro]}"
# Belt-and-suspenders: the kiro block must NOT show `sonnet` as kiro's 6th arg.
if grep -qF "kiro sid-kiro 'sonnet'" <<<"$kiro_block"; then
  echo -e "  ${RED}FAIL${NC}: TC-PVP-09 kiro verdict-post used the shared default 'sonnet' instead of its override"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-PVP-09 kiro verdict-post uses its per-agent override, not 'sonnet'"
  PASS=$((PASS + 1))
fi

# TC-PVP-12 (PR review finding — multi-word-model quoting regression): a model id
# with SPACES + PARENS (`Gemini 3.5 Flash (High)`, the motivating valid value)
# must be rendered as a SINGLE shell-safe token in every invocation — i.e.
# single-quoted — so an agent copying the example verbatim does not (a) split it
# into args 6/7/8 (truncating to `(model: Gemini)`) or (b) hit a bash syntax
# error on the literal `(` and post no verdict at all. Assert each invocation
# ends with `'Gemini 3.5 Flash (High)'` (the quoted whole id) after agy's sid.
# Count only the concrete INVOCATION lines (those that write a body file), not
# the INV-56 prose mention of `bash scripts/post-verdict.sh` with no positional
# args — match on the `/tmp/verdict-agy.md` body-file token that only an actual
# invocation carries.
_n_agy_inv=$(grep -E 'post-verdict\.sh' <<<"$agy_block" | grep -cF '/tmp/verdict-agy.md')
_n_agy_quoted=$(grep -cF "agy sid-agy 'Gemini 3.5 Flash (High)'" <<<"$agy_block")
if [[ "$_n_agy_inv" -ge 1 && "$_n_agy_quoted" -eq "$_n_agy_inv" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-PVP-12 all $_n_agy_inv agy invocation(s) single-quote the multi-word model as one token"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-PVP-12 $_n_agy_quoted/$_n_agy_inv agy invocation(s) quote 'Gemini 3.5 Flash (High)' as one token"
  echo "      invocations:"
  printf '        %s\n' "$(grep -E 'post-verdict\.sh' <<<"$agy_block")"
  FAIL=$((FAIL + 1))
fi
# And the rendered example must actually PARSE + reach post-verdict.sh as a
# single 6th positional arg. Extract one PASS invocation line, run it against a
# stub post-verdict.sh that echoes its $6, and assert the whole model id arrives.
_agy_pass_line=$(grep -F "agy sid-agy 'Gemini 3.5 Flash (High)'" <<<"$agy_block" | grep -E '[[:space:]]pass[[:space:]]' | head -1)
if [[ -n "$_agy_pass_line" ]]; then
  _STUBDIR=$(mktemp -d)
  # Minimal stub: echo arg6 so we can prove it parsed as ONE token.
  cat > "$_STUBDIR/post-verdict.sh" <<'STUB'
#!/bin/bash
printf 'ARG6=[%s]\n' "${6:-}"
STUB
  chmod +x "$_STUBDIR/post-verdict.sh"
  # The line begins with `bash scripts/post-verdict.sh …`; redirect `scripts/` to
  # the stub dir by running from $_STUBDIR with a `scripts` symlink to itself.
  ln -s "$_STUBDIR" "$_STUBDIR/scripts"
  _arg6=$( cd "$_STUBDIR" && eval "${_agy_pass_line}" 2>/dev/null )
  if [[ "$_arg6" == "ARG6=[Gemini 3.5 Flash (High)]" ]]; then
    echo -e "  ${GREEN}PASS${NC}: TC-PVP-12b rendered agy example parses the model as a single 6th arg"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-PVP-12b rendered agy example did NOT pass the model as one arg (got '$_arg6')"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$_STUBDIR"
else
  echo -e "  ${RED}FAIL${NC}: TC-PVP-12b could not extract an agy PASS invocation line to parse-test"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
