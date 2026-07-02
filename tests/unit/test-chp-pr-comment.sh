#!/bin/bash
# test-chp-pr-comment.sh — #329 (#296 second-tier).
#
# Mints the general CHP write primitive `chp_pr_comment PR [extra gh args…]` (the
# PR-comment sibling of the shipped read primitives `chp_pr_view`/`chp_pr_list`)
# and migrates all 7 raw `gh pr comment` write sites behind it:
#   autonomous-review.sh:3342,3538  +  lib-review-e2e.sh:344,380,387,402,580
#
# The proofs (AC1-AC5 of #329):
#   1. GOLDEN-TRACE, argument-boundary-preserving (AC1) — a recording `gh` stub
#      writes argv NUL-delimited (one arg per record), so the leaf is asserted to
#      emit `gh pr comment $PR --repo $REPO --body <body>` BYTE-IDENTICALLY and to
#      add NO redirects of its own (no stray `2>`/`>` in the captured argv).
#   2. PER-SITE FRAMING (AC2) — each of the 7 migrated sites keeps its EXACT
#      redirect/capture/gating form (3538 `2>&1 >/dev/null` capture; 380 `|| rc=$?`
#      gating; 580 `>/dev/null 2>&1` broker; the four `|| true` reports).
#   3. SELF-GUARDING SHIM (AC3) — with the enabled provider defining no
#      chp_${CODE_HOST}_pr_comment leaf the shim WARNs + `return 1` (a clean
#      non-zero the `|| true` sites degrade on), NO `set -e` abort. Mirrors the
#      chp_pr_view/chp_pr_list self-guarding shape.
#   4. SOURCE-SHAPE (AC4) — zero executable raw `gh pr comment` in the two files;
#      new leaf+shim present; chp_pr_comment invoked at all 7 sites; baseline -7.
#   5. DOCS (AC5) — provider-spec.md two→three prose + mapping row; the chp_pr_comment
#      INV heading (INV-102, renumbered from INV-95, then INV-101, on successive
#      rebases) + triage marker + Migration-log bullet.
#
# Run: bash tests/unit/test-chp-pr-comment.sh   (FULL suite under env -u PROJECT_DIR)
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
CHP_LIB="$SCRIPTS/lib-code-host.sh"
CHP_GITHUB="$SCRIPTS/providers/chp-github.sh"
REVIEW_SH="$SCRIPTS/autonomous-review.sh"
E2E_LIB="$SCRIPTS/lib-review-e2e.sh"
BASELINE="$SCRIPTS/providers/cutover-baseline.json"
CUTOVER="$SCRIPTS/check-provider-cutover.sh"
SPEC="$PROJECT_ROOT/docs/pipeline/provider-spec.md"
INVARIANTS="$PROJECT_ROOT/docs/pipeline/invariants.md"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected: |$expected|"
    echo "      actual:   |$actual|"
    FAIL=$((FAIL + 1))
  fi
}
pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

export REPO=zxkane/autonomous-dev-team

# ===========================================================================
# Recording `gh` stub — captures every `gh` invocation NUL-delimited so argument
# boundaries are preserved EXACTLY (no space-join collapse). Returns 0 (benign).
# ===========================================================================
GH_STUB_BODY='
gh() {
  local n; n=$(cat "$REC_DIR/.count" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$REC_DIR/.count"
  : > "$REC_DIR/call-$n"
  printf "%s\0" "$@" >> "$REC_DIR/call-$n"
  printf "%s %s\n" "${1:-}" "${2:-}" >> "$REC_DIR/.verbs"
  return 0
}
'

read_call() {
  local f="$1/$2"
  CALL_ARGV=()
  [[ -f "$f" ]] || return 1
  mapfile -d '' -t CALL_ARGV < "$f"
  return 0
}
call_for_verb() {
  local dir="$1" v1="$2" v2="$3" n=0
  while IFS= read -r line; do
    n=$((n+1))
    [[ "$line" == "$v1 $v2" ]] && { echo "call-$n"; return 0; }
  done < "$dir/.verbs"
  return 1
}

# ===========================================================================
# 1. GOLDEN-TRACE (AC1) — the leaf emits a byte-identical passthrough that adds
#    NO redirects of its own.
# ===========================================================================
echo "=== TC-CPC-001/002: golden-trace — leaf emits byte-identical argv, NO leaf-added redirects ==="
RUNDIR=$(mktemp -d)
REC1="$RUNDIR/rec1"; mkdir -p "$REC1"
BODY=$'## E2E Failure\n\nLine with spaces | pipe and a 2> token that must NOT fracture'
env -u CODE_HOST -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
    REPO="$REPO" REC_DIR="$REC1" \
  bash -c "
    set -uo pipefail
    source '$CHP_LIB' 2>/dev/null     # CODE_HOST defaults to github → chp_github_pr_comment live
    $GH_STUB_BODY
    chp_pr_comment 42 --body \"\$1\"
  " _ "$BODY" >/dev/null 2>&1

if [[ -f "$REC1/.verbs" ]] && grep -qx "pr comment" "$REC1/.verbs"; then
  pass "TC-CPC-001 seam-reachability: stub OBSERVED a 'gh pr comment' call THROUGH chp_pr_comment (exercised, not just reachable)"
  cn=$(call_for_verb "$REC1" pr comment) && read_call "$REC1" "$cn"
  # argc: pr comment 42 --repo $REPO --body <body> = 7 args
  assert_eq "TC-CPC-001 golden-trace argc (boundaries preserved)" "7" "${#CALL_ARGV[@]}"
  assert_eq "TC-CPC-001 argv[0]=pr" "pr" "${CALL_ARGV[0]:-}"
  assert_eq "TC-CPC-001 argv[1]=comment" "comment" "${CALL_ARGV[1]:-}"
  assert_eq "TC-CPC-001 argv[2]=42 (PR positional)" "42" "${CALL_ARGV[2]:-}"
  assert_eq "TC-CPC-001 argv[3]=--repo" "--repo" "${CALL_ARGV[3]:-}"
  assert_eq "TC-CPC-001 argv[4]=\$REPO (leaf supplies global REPO)" "$REPO" "${CALL_ARGV[4]:-}"
  assert_eq "TC-CPC-001 argv[5]=--body (caller-supplied tail)" "--body" "${CALL_ARGV[5]:-}"
  assert_eq "TC-CPC-001 argv[6]=<verbatim body, single element>" "$BODY" "${CALL_ARGV[6]:-}"

  # TC-CPC-002 — the leaf adds NO redirects: the captured argv must contain NO
  # element that is a bare redirect operator. (The body element happens to carry
  # the substring "2>" inside prose — that proves we check argv ELEMENTS for an
  # EXACT redirect token, not a substring; a real `2>`/`>`/`2>&1` redirect would
  # appear as its OWN argv element if the leaf wrongly baked one in.)
  stray=0
  for a in "${CALL_ARGV[@]}"; do
    case "$a" in '2>'|'>'|'2>&1'|'>/dev/null'|'2>/dev/null') stray=1 ;; esac
  done
  assert_eq "TC-CPC-002 leaf-added redirects: NONE (no bare redirect token in argv)" "0" "$stray"
else
  fail "TC-CPC-001 seam-reachability: stub did NOT observe a 'gh pr comment' — chp_pr_comment not exercised"
fi
rm -rf "$RUNDIR"

# ===========================================================================
# 3. SELF-GUARDING SHIM (AC3) — leaf-absent → WARN + return 1, no abort. Run
#    BEFORE the source-shape block so a degraded path is proven first.
# ===========================================================================
echo "=== TC-CPC-020/021: self-guarding shim degrades on leaf-absent, no set -e abort ==="
DEGRADED_DIR="$PROJECT_ROOT/tests/unit/fixtures/provider-degraded"
rc=0
out=$(env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
        REPO="$REPO" CODE_HOST=degraded AUTONOMOUS_PROVIDERS_DIR="$DEGRADED_DIR" \
      bash -c "
        set -euo pipefail
        source '$CHP_LIB' 2>/dev/null    # degraded provider: shim present, leaf ABSENT
        # The '|| true' caller framing must swallow the shim's clean non-zero.
        chp_pr_comment 42 --body 'x' 2>/dev/null || true
        echo POSTGUARD
        # Now prove the shim itself returns non-zero (separate, ungated probe):
        if chp_pr_comment 42 --body 'x' 2>/dev/null; then echo SHIM_RC=0; else echo SHIM_RC=nonzero; fi
      " 2>/dev/null) || rc=$?
assert_eq "TC-CPC-021 leaf-absent '|| true' site does NOT abort under set -e (reaches POSTGUARD)" \
  "yes" "$([[ "$out" == *POSTGUARD* ]] && echo yes || echo no)"
assert_eq "TC-CPC-020 self-guarding shim returns clean non-zero when leaf absent" \
  "yes" "$([[ "$out" == *"SHIM_RC=nonzero"* ]] && echo yes || echo no)"
# The shim WARNs to stderr naming the missing leaf (loud misconfiguration).
warn=$(env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
        REPO="$REPO" CODE_HOST=degraded AUTONOMOUS_PROVIDERS_DIR="$DEGRADED_DIR" \
      bash -c "source '$CHP_LIB' 2>/dev/null; chp_pr_comment 42 --body 'x' 2>&1 >/dev/null" 2>&1 || true)
assert_eq "TC-CPC-020 shim WARNs naming the missing chp_<host>_pr_comment leaf" \
  "yes" "$([[ "$warn" == *"chp_degraded_pr_comment"* && "$warn" == *WARN* ]] && echo yes || echo no)"

# ===========================================================================
# 4. SOURCE-SHAPE (AC4) — zero executable raw `gh pr comment`; leaf+shim present;
#    chp_pr_comment at all 7 sites; baseline shrank by 7; cutover guard PASS.
# ===========================================================================
echo "=== TC-CPC-030/031: zero executable raw 'gh pr comment' in the two HOT files ==="
# Classify like the cutover guard: strip leading-whitespace #-comment lines first.
count_exec_gh_pr_comment() {
  grep -aE '(^|[^A-Za-z_-])gh ' "$1" 2>/dev/null \
    | awk '{s=$0;sub(/^[[:space:]]+/,"",s); if(substr(s,1,1)=="#")next; print s}' \
    | grep -c 'gh pr comment' || true
}
assert_eq "TC-CPC-030 autonomous-review.sh has ZERO executable raw 'gh pr comment'" \
  "0" "$(count_exec_gh_pr_comment "$REVIEW_SH")"
assert_eq "TC-CPC-031 lib-review-e2e.sh has ZERO executable raw 'gh pr comment'" \
  "0" "$(count_exec_gh_pr_comment "$E2E_LIB")"

echo "=== TC-CPC-032: new leaf + shim present ==="
assert_eq "TC-CPC-032 chp_github_pr_comment leaf defined in providers/chp-github.sh" \
  "1" "$(grep -c '^chp_github_pr_comment()' "$CHP_GITHUB" || true)"
assert_eq "TC-CPC-032 chp_pr_comment shim defined in lib-code-host.sh" \
  "1" "$(grep -c '^chp_pr_comment()' "$CHP_LIB" || true)"

echo "=== TC-CPC-033: chp_pr_comment invoked at all 7 migrated sites (review ×2, e2e ×5) ==="
assert_eq "TC-CPC-033 autonomous-review.sh invokes chp_pr_comment ×2" \
  "2" "$(grep -c 'chp_pr_comment "\$PR_NUMBER"' "$REVIEW_SH" || true)"
assert_eq "TC-CPC-033 lib-review-e2e.sh invokes chp_pr_comment ×5" \
  "5" "$(grep -c 'chp_pr_comment "\$PR_NUMBER"' "$E2E_LIB" || true)"

echo "=== TC-CPC-010..016: per-site framing preserved verbatim ==="
# 3342: conflict marker post — `chp_pr_comment "$PR_NUMBER" \` continuation whose
# body tail closes with `2>/dev/null || true`. The continuation-line form is the
# ONLY `chp_pr_comment "$PR_NUMBER" \` in autonomous-review.sh (3538 is a capture,
# not a `\` continuation), so a count of exactly 1 pins it.
# 3342 is the only review line that STARTS (after indent) with the verb + `\`
# continuation; 3538's continuation is prefixed by `if ! _comment_err=$(`, so an
# anchored `^[space]*chp_pr_comment …` pins exactly the conflict-marker post.
assert_eq "TC-CPC-010 review:3342 chp_pr_comment '\\' continuation present (conflict marker post)" \
  "1" "$(grep -cE '^[[:space:]]*chp_pr_comment "\$PR_NUMBER" \\$' "$REVIEW_SH" || true)"
# The conflict-marker body tail keeps its `2>/dev/null || true` framing.
assert_eq "TC-CPC-010 review:3342 conflict body tail keeps '2>/dev/null || true'" \
  "1" "$(grep -cF 'main.$(declare -F run_footer >/dev/null 2>&1 && run_footer || true)" 2>/dev/null || true' "$REVIEW_SH" || true)"
# 3538: capture form `if ! _comment_err=$(chp_pr_comment … 2>&1 >/dev/null); then`
assert_eq "TC-CPC-011 review:3538 keeps the '2>&1 >/dev/null' capture form" \
  "1" "$(grep -cF 'if ! _comment_err=$(chp_pr_comment "$PR_NUMBER" \' "$REVIEW_SH" || true)"
# The capture-close `2>&1 >/dev/null); then` line is shared with a label-edit
# capture (3554, NOT migrated), so the file carries it twice — the migration must
# preserve BOTH (neither gains/loses the framing). Pin the count at 2.
assert_eq "TC-CPC-011 review: capture-close '2>&1 >/dev/null); then' preserved (×2: comment + label-edit)" \
  "2" "$(grep -c '2>&1 >/dev/null); then' "$REVIEW_SH" || true)"
# 380: the ONLY gating site — `--body "$evidence" 2>/dev/null || rc=$?`
assert_eq "TC-CPC-013 e2e:380 keeps the '|| rc=\$?' gating form" \
  "1" "$(grep -cF 'chp_pr_comment "$PR_NUMBER" --body "$evidence" 2>/dev/null || rc=$?' "$E2E_LIB" || true)"
# 580: INV-79 broker — `if chp_pr_comment … --body "$body" >/dev/null 2>&1; then`
assert_eq "TC-CPC-016 e2e:580 keeps the broker '>/dev/null 2>&1' form" \
  "1" "$(grep -cF 'if chp_pr_comment "$PR_NUMBER" --body "$body" >/dev/null 2>&1; then' "$E2E_LIB" || true)"
# 344/387/402: report posts each ending `2>/dev/null || true` (the multi-line
# heredoc-style bodies). There are exactly 3 such `chp_pr_comment "$PR_NUMBER" \`
# continuation-line posts in lib-review-e2e.sh.
assert_eq "TC-CPC-012/014/015 e2e:344/387/402 keep the report '\\' continuation form (×3)" \
  "3" "$(grep -cE '^[[:space:]]*chp_pr_comment "\$PR_NUMBER" \\$' "$E2E_LIB" || true)"

echo "=== TC-CPC-034: cutover-baseline.json no longer carries the 5 'gh pr comment' entries ==="
assert_eq "TC-CPC-034 baseline has ZERO 'gh pr comment' content entries" \
  "0" "$(jq '[.surviving_sites[] | select(.content | test("gh pr comment"))] | length' "$BASELINE" 2>/dev/null || echo ERR)"

echo "=== TC-CPC-035: check-provider-cutover.sh (INV-91) PASSES on the migrated tree ==="
# Run the guard against THIS worktree's scripts dir + baseline. Skip the
# monotonicity ref check (origin/main lacks this PR — default OFF gives a graceful
# skip; Check 1 + the in-repo baseline still anchor the tree).
cut_out=$(bash "$CUTOVER" --scripts-dir "$SCRIPTS" --baseline "$BASELINE" 2>&1) || true
if grep -q 'cutover-guard: PASS' <<<"$cut_out"; then
  pass "TC-CPC-035 check-provider-cutover.sh PASS (no new raw gh; baseline reconciles)"
else
  fail "TC-CPC-035 check-provider-cutover.sh did NOT pass — migrated tree drifts from baseline"
  echo "$cut_out" | grep -E '::error::|FAIL' | head -10
fi

# ===========================================================================
# 5. DOCS (AC5) — provider-spec.md prose + mapping row; the chp_pr_comment INV
#    heading (INV-102, renumbered from INV-95, then INV-101) + triage + bullet.
# ===========================================================================
echo "=== TC-CPC-040/041: provider-spec.md prose names the general primitives + mapping-appendix row ==="
# The stale "two general"/"three general" count words must be gone from the
# self-guarding prose block (the §3.2 caller-guard convention paragraph,
# ~242-258). By the time this PR rebased, main had independently landed a THIRD
# general primitive (chp_list_inline_comments, #328) ahead of chp_pr_comment, so
# the merged prose reads "four general read+write primitives" — chp_pr_view,
# chp_pr_list, chp_list_inline_comments, and chp_pr_comment. Assert on the
# COUNT WORD being consistent with chp_pr_comment being present, not a hardcoded
# ordinal — a future sibling primitive would otherwise re-break this pin the same
# way "two"->"three" did here.
spec_flat="$(sed 's/^> \?//' "$SPEC" | tr '\n' ' ' | tr -s ' ')"
assert_eq "TC-CPC-040 no stale 'two general read primitives' claim in provider-spec.md" \
  "no" "$([[ "$spec_flat" == *'two general read primitives'* ]] && echo yes || echo no)"
assert_eq "TC-CPC-040 prose names chp_pr_comment among the 'general read+write primitives'" \
  "yes" "$([[ "$spec_flat" =~ [a-z-]+\ general\ read\+write\ primitives ]] && echo yes || echo no)"
# The prose now names chp_pr_comment as a self-guarding general primitive.
assert_eq "TC-CPC-040 provider-spec.md prose names chp_pr_comment (self-guarding general primitive)" \
  "yes" "$([[ -n "$(grep -n 'chp_pr_comment' "$SPEC")" ]] && echo yes || echo no)"
# Mapping-appendix extraction row references chp_pr_comment + #329.
assert_eq "TC-CPC-041 provider-spec.md mapping appendix has a chp_pr_comment #329 row" \
  "yes" "$([[ -n "$(grep -nE 'chp_pr_comment.*#329|#329.*chp_pr_comment' "$SPEC")" ]] && echo yes || echo no)"

echo "=== TC-CPC-042: invariants.md chp_pr_comment INV heading + triage marker + Migration-log bullet ==="
# Keyed on the chp_pr_comment heading TEXT, not a fixed INV number: main independently
# claimed INV-95 (#328, chp_list_inline_comments) before this PR landed, so this PR's
# heading was renumbered on successive rebases (INV-95 -> INV-101 -> INV-102, see
# the note under the heading).
# A hardcoded number would break again on the next collision/renumber.
assert_eq "TC-CPC-042 chp_pr_comment INV heading present in invariants.md" \
  "1" "$(grep -cE '^## INV-[0-9]+: every PR-comment write in the HOT review files routes through the general `chp_pr_comment`' "$INVARIANTS" || true)"
# Triage marker is heading-adjacent (within 2 lines) — mirrors TC-SPEC-GATE-040/041.
adj=$(awk '/^## INV-[0-9]+: every PR-comment write in the HOT review files routes through the general `chp_pr_comment`/{h=NR} /^_Triage \(issue #236\):/{if(h && NR-h<=2) c++; h=0} END{print c+0}' "$INVARIANTS")
assert_eq "TC-CPC-042 chp_pr_comment INV heading carries a heading-adjacent _Triage (issue #236): marker" "1" "$adj"
# Migration-log bullet for #329 present.
assert_eq "TC-CPC-042 INV-91 Migration-log carries a #329 bullet" \
  "yes" "$([[ -n "$(grep -nE '#329.*chp_pr_comment|chp_pr_comment.*#329' "$INVARIANTS")" ]] && echo yes || echo no)"

# ===========================================================================
echo ""
echo "=== Summary ==="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
[ "$FAIL" -eq 0 ]
