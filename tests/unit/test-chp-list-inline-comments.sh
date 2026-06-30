#!/bin/bash
# test-chp-list-inline-comments.sh — #296 second-tier (#328).
#
# Proves the NEW CHP read verb chp_list_inline_comments and the byte-identical
# migration of the single surviving raw PR inline-review-comment read at
# autonomous-dev.sh:1086 (the dev-resume prompt builder's PR_REVIEW_COMMENTS read).
#
# The proofs (ACs of #328):
#   AC1  GOLDEN-TRACE, argument-boundary-preserving — a recording `gh` stub writes
#        argv NUL-delimited (one arg per record, NOT space-joined), so a word-split
#        or re-escaped selector FAILS. Asserts argc + each exact arg incl. the
#        verbatim --jq formatter (which carries spaces, `|` pipes, `**`, `\(…)`).
#        Plus the caller's formatter produces the same `- **path:line** — body`
#        rendering through the system jq (the formatter STAYS caller-side, #281).
#   AC2  SELF-GUARDING SHIM — leaf-absent / unset-CODE_HOST → WARN + return 1 (the
#        `|| true` site degrades to empty PR_REVIEW_COMMENTS), NEVER a `set -e` abort.
#   AC3  SOURCE-SHAPE — zero raw `gh api …pulls/…/comments` at the :1086 site; the
#        new leaf+shim present; baseline shrank by exactly the one migrated sig. (The
#        DISTINCT :1093 issues/…/comments AUTO_MERGE read this issue scoped OUT was
#        migrated independently behind itp_list_comments by #334, so it too is no
#        longer a raw-gh / baselined site — AC3 asserts it ABSENT, not present.)
#   AC4  INV-91 Migration-log bullet present (also pinned in test-spec-drift.sh).
#
# Run: env -u PROJECT_DIR bash tests/unit/test-chp-list-inline-comments.sh
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
CHP_LIB="$SCRIPTS/lib-code-host.sh"
CHP_GITHUB="$SCRIPTS/providers/chp-github.sh"
DEV_SH="$SCRIPTS/autonomous-dev.sh"
INVARIANTS="$PROJECT_ROOT/docs/pipeline/invariants.md"
BASELINE="$SCRIPTS/providers/cutover-baseline.json"

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
assert_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      needle: |$needle|"; echo "      hay:    |$hay|"
    FAIL=$((FAIL + 1))
  fi
}
pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

export REPO=zxkane/autonomous-dev-team

# The verbatim --jq formatter the :1086 site passes (must survive byte-identically
# as a SINGLE argv element). Kept here as the golden expectation.
FORMATTER='[.[] | "- **\(.path):\(.line // .original_line // "N/A")** — \(.body)"] | join("\n")'

# ===========================================================================
# Recording `gh` stub — captures every `gh` invocation NUL-delimited so argument
# boundaries are preserved EXACTLY (no space-join collapse). read_call reads one
# back into the CALL_ARGV array.
# ===========================================================================
GH_STUB_BODY='
gh() {
  local n; n=$(cat "$REC_DIR/.count" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$REC_DIR/.count"
  : > "$REC_DIR/call-$n"
  printf "%s\0" "$@" >> "$REC_DIR/call-$n"
  printf "%s %s\n" "${1:-}" "${2:-}" >> "$REC_DIR/.verbs"
  # Emit a fixed inline-comment payload when this is the api comments read so the
  # caller-formatter rendering proof (AC1) can run against a known shape.
  if [[ "${1:-}" == "api" ]]; then
    cat "$REC_DIR/.payload" 2>/dev/null || printf ""
    return 0
  fi
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
  local dir="$1" v1="$2" v2="$3" n=0 line
  while IFS= read -r line; do
    n=$((n+1))
    [[ "$line" == "$v1 $v2" ]] && { echo "call-$n"; return 0; }
  done < "$dir/.verbs"
  return 1
}

# ===========================================================================
# AC1 — GOLDEN-TRACE + SEAM-REACHABILITY. Drive the REAL chp_list_inline_comments
#       (shim → leaf) with the REAL CHP seam sourced and the recording gh stub;
#       assert the OBSERVED argv is byte-identical, boundaries intact.
# ===========================================================================
echo "=== AC1: chp_list_inline_comments golden-trace (gh api repos/\$REPO/pulls/\$PR/comments <--jq>) ==="
RUNDIR=$(mktemp -d)
REC1="$RUNDIR/rec1"; mkdir -p "$REC1"
: > "$REC1/.payload"  # AC1 trace path needs no payload
env -u CODE_HOST -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
    REPO="$REPO" REC_DIR="$REC1" FORMATTER="$FORMATTER" \
  bash -c "
    set -uo pipefail
    source '$CHP_LIB' 2>/dev/null    # sources providers/chp-github.sh → live shim + leaf
    $GH_STUB_BODY
    chp_list_inline_comments 42 --jq \"\$FORMATTER\"
  " >/dev/null 2>&1

if [[ -f "$REC1/.verbs" ]] && grep -qx "api repos/zxkane/autonomous-dev-team/pulls/42/comments" "$REC1/.verbs"; then
  pass "AC1 seam-reachability: stub OBSERVED 'gh api repos/\$REPO/pulls/42/comments' through chp_list_inline_comments (exercised)"
  cn=$(call_for_verb "$REC1" api "repos/$REPO/pulls/42/comments") && read_call "$REC1" "$cn"
  # argc: api repos/$REPO/pulls/42/comments --jq <formatter> = 4 args
  assert_eq "AC1 golden-trace argc (boundaries preserved)" "4" "${#CALL_ARGV[@]}"
  assert_eq "AC1 argv[0]=api" "api" "${CALL_ARGV[0]:-}"
  assert_eq "AC1 argv[1]=repos/\$REPO/pulls/42/comments (verb supplies global REPO + positional PR)" \
    "repos/$REPO/pulls/42/comments" "${CALL_ARGV[1]:-}"
  assert_eq "AC1 argv[2]=--jq" "--jq" "${CALL_ARGV[2]:-}"
  assert_eq "AC1 argv[3]=<verbatim formatter, single element>" "$FORMATTER" "${CALL_ARGV[3]:-}"
  # Boundary proof: the captured formatter is ONE argv element carrying a space AND a pipe.
  assert_contains "AC1 captured formatter is one element containing a space" " " "${CALL_ARGV[3]:-}"
  assert_contains "AC1 captured formatter is one element containing a | pipe" "|" "${CALL_ARGV[3]:-}"
else
  fail "AC1 seam-reachability: stub did NOT observe the 'gh api …/pulls/42/comments' — chp_list_inline_comments not exercised"
fi
rm -rf "$RUNDIR"

# ===========================================================================
# AC1 (cont.) — the caller's formatter renders IDENTICALLY (jq stays caller-side).
#   Run the verbatim formatter against a sample pulls/N/comments payload through the
#   system jq; assert the `- **path:line** — body` rendering incl. the
#   `.line // .original_line // "N/A"` fallback.
# ===========================================================================
echo "=== AC1 (cont.): caller formatter renders the same '- **path:line** — body' lines ==="
if command -v jq >/dev/null 2>&1; then
  SAMPLE='[
    {"path":"src/a.ts","line":12,"original_line":10,"body":"fix this"},
    {"path":"src/b.ts","line":null,"original_line":7,"body":"and this"},
    {"path":"src/c.ts","line":null,"original_line":null,"body":"no line"}
  ]'
  rendered=$(printf '%s' "$SAMPLE" | jq -r "$FORMATTER")
  EXPECTED=$'- **src/a.ts:12** — fix this\n- **src/b.ts:7** — and this\n- **src/c.ts:N/A** — no line'
  assert_eq "AC1 formatter rendering byte-identical (.line // .original_line // N/A fallback)" "$EXPECTED" "$rendered"
else
  fail "AC1 jq not available to verify the caller-formatter rendering"
fi

# ===========================================================================
# AC2 — SELF-GUARDING SHIM. Leaf-absent and unset-CODE_HOST degrade to WARN +
#       return 1 under set -e, never an abort. (The :1086 `|| true` site then sets
#       PR_REVIEW_COMMENTS empty.)
# ===========================================================================
echo "=== AC2: self-guarding shim — leaf-absent → WARN + return 1, no set -e abort ==="
# Source the seam, then unset the github leaf so the shim's declare -F miss fires.
rc=0
out=$(env -u CODE_HOST -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
        REPO="$REPO" \
      bash -c "
        set -euo pipefail
        source '$CHP_LIB' 2>/dev/null
        unset -f chp_github_list_inline_comments 2>/dev/null || true
        result=\$(chp_list_inline_comments 5 --jq '.' 2>/tmp/clic_warn_\$\$ || true)
        echo \"RESULT=[\$result]\"
        echo \"RC_AFTER=\$?\"
        cat /tmp/clic_warn_\$\$ >&2; rm -f /tmp/clic_warn_\$\$
      " 2>"$RUNDIR.warn") || rc=$?
warnmsg=$(cat "$RUNDIR.warn" 2>/dev/null || true); rm -f "$RUNDIR.warn"
if [[ "$out" == *"RESULT=[]"* && "$rc" -eq 0 ]]; then
  pass "AC2 leaf-absent: \$(chp_list_inline_comments … || true) → empty + no abort (set -e survived)"
else
  fail "AC2 leaf-absent did NOT degrade as expected (out=[$out] rc=$rc)"
fi
assert_contains "AC2 leaf-absent emits the [INV-95] WARN to stderr" "WARN: [INV-95]" "$warnmsg"

echo "=== AC2 (cont.): direct return-1 contract on leaf-absent ==="
rc2=0
env -u CODE_HOST -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR REPO="$REPO" \
  bash -c "
    set -uo pipefail
    source '$CHP_LIB' 2>/dev/null
    unset -f chp_github_list_inline_comments 2>/dev/null || true
    chp_list_inline_comments 5 >/dev/null 2>&1
  " ; rc2=$?
assert_eq "AC2 shim returns 1 (not 0) when the leaf is absent" "1" "$rc2"

echo "=== AC2 (cont.): non-github CODE_HOST whose leaf is absent degrades (no provider file → bare-guard miss, no abort) ==="
# A genuinely non-GitHub backend selected through the PUBLIC seam: CODE_HOST=fakehost
# sources no providers/chp-fakehost.sh (guarded source in lib-code-host.sh is a no-op),
# so chp_fakehost_list_inline_comments is absent. The bare `declare -F
# chp_${CODE_HOST}_list_inline_comments` miss → WARN + return 1, NOT an
# `chp_fakehost_list_inline_comments: command not found` abort under set -e.
# (Empty CODE_HOST is NOT a valid leaf-absent probe: lib-code-host.sh defaults
# `CODE_HOST="${CODE_HOST:-github}"` at source time, so "" resolves to the github
# leaf — this case uses a real non-default backend name instead.)
rc3=0
out3=$(env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR REPO="$REPO" CODE_HOST="fakehost" \
  bash -c "
    set -euo pipefail
    source '$CHP_LIB' 2>/dev/null
    r=\$(chp_list_inline_comments 5 2>/tmp/clic_fh_\$\$ || true)
    echo \"RESULT=[\$r]\"
    cat /tmp/clic_fh_\$\$ >&2; rm -f /tmp/clic_fh_\$\$
  " 2>"$RUNDIR.fhwarn") || rc3=$?
fhwarn=$(cat "$RUNDIR.fhwarn" 2>/dev/null || true); rm -f "$RUNDIR.fhwarn"
if [[ "$out3" == *"RESULT=[]"* && "$rc3" -eq 0 ]]; then
  pass "AC2 non-github leaf-absent (CODE_HOST=fakehost): bare declare -F miss → empty + return 1, NOT a chp_fakehost_… abort"
else
  fail "AC2 non-github CODE_HOST did NOT bare-guard as expected (out=[$out3] rc=$rc3)"
fi
# The WARN names the bare-expanded provider leaf (proves the bare ${CODE_HOST} guard,
# IDENTICAL to the leaf dispatch — the #323/#324 bare-guard lesson).
assert_contains "AC2 WARN names the bare-expanded chp_fakehost_list_inline_comments leaf" \
  "chp_fakehost_list_inline_comments" "$fhwarn"

# ===========================================================================
# AC3 — SOURCE-SHAPE. Zero executable raw gh api pulls/…/comments at :1086; the
#       new verb call present. (The DISTINCT :1093 issues/…/comments AUTO_MERGE
#       read this issue scoped OUT was migrated independently behind
#       itp_list_comments by #334, so it is no longer a raw-gh site either — we
#       assert it is ABSENT as raw gh, not present.)
# ===========================================================================
echo "=== AC3: source-shape — raw gh api pulls/…/comments gone, chp_list_inline_comments present ==="
# Strip leading-whitespace #-comment lines first (same classifier as the cutover guard).
nonc() { grep -aE '(^|[^A-Za-z_-])gh ' "$1" | awk '{s=$0;sub(/^[[:space:]]+/,"",s); if(substr(s,1,1)=="#")next; print s}'; }
n_pulls=$(nonc "$DEV_SH" | grep -c 'gh api "repos/${REPO}/pulls/${PR_NUM}/comments"' || true)
assert_eq "AC3 autonomous-dev.sh has ZERO executable raw 'gh api …/pulls/\$PR_NUM/comments'" "0" "$n_pulls"
assert_eq "AC3 autonomous-dev.sh invokes chp_list_inline_comments \"\$PR_NUM\" (×1)" \
  "1" "$(grep -c 'chp_list_inline_comments "\$PR_NUM"' "$DEV_SH" || true)"
# The DISTINCT :1093 issue-level AUTO_MERGE-marker read was migrated behind
# itp_list_comments by #334 (merged onto main before this rebase) → it is no longer
# an executable raw `gh api …/issues/$PR_NUM/comments` site.
n_issues=$(nonc "$DEV_SH" | grep -c 'gh api "repos/${REPO}/issues/${PR_NUM}/comments"' || true)
assert_eq "AC3 the distinct issues/\$PR_NUM/comments AUTO_MERGE read is also gone (migrated by #334)" \
  "0" "$n_issues"
assert_eq "AC3 autonomous-dev.sh's AUTO_MERGE marker now routes through itp_list_comments \"\$PR_NUM\"" \
  "1" "$(grep -c 'AUTO_MERGE_FAILURE_MARKER=$(itp_list_comments "\$PR_NUM"' "$DEV_SH" || true)"

echo "=== AC3 (cont.): the verb is defined in the seam (shim + leaf) ==="
assert_eq "AC3 lib-code-host.sh defines the chp_list_inline_comments shim" \
  "1" "$(grep -c '^chp_list_inline_comments()' "$CHP_LIB" || true)"
assert_eq "AC3 providers/chp-github.sh defines the chp_github_list_inline_comments leaf" \
  "1" "$(grep -c '^chp_github_list_inline_comments()' "$CHP_GITHUB" || true)"

echo "=== AC3 (cont.): cutover baseline shrank by exactly the one migrated sig ==="
if command -v jq >/dev/null 2>&1; then
  has_pulls=$(jq '[.surviving_sites[] | select(.file=="autonomous-dev.sh" and (.content | test("pulls/\\$\\{PR_NUM\\}/comments")))] | length' "$BASELINE")
  has_issues=$(jq '[.surviving_sites[] | select(.file=="autonomous-dev.sh" and (.content | test("issues/\\$\\{PR_NUM\\}/comments")))] | length' "$BASELINE")
  assert_eq "AC3 baseline NO LONGER carries the pulls/\$PR_NUM/comments survivor (migrated #328)" "0" "$has_pulls"
  assert_eq "AC3 baseline NO LONGER carries the distinct issues/\$PR_NUM/comments survivor (migrated #334)" "0" "$has_issues"
else
  fail "AC3 jq not available to inspect the baseline"
fi

# ===========================================================================
# AC4 — the exact INV-91 Migration-log bullet is present (also pinned in
#       test-spec-drift.sh as TC-SPEC-GATE-328).
# ===========================================================================
echo "=== AC4: INV-91 Migration-log bullet ==="
AC4_BULLET='- #296 second-tier (#328): the dev-resume PR inline-review-comment read (`PR_REVIEW_COMMENTS`, autonomous-dev.sh) migrated from raw `gh api repos/$REPO/pulls/$PR_NUM/comments --jq` to the NEW verb `chp_list_inline_comments` — byte-identical (the `--jq` formatter stays caller-side, #281); baseline shrank by 1 sig.'
if grep -qF -- "$AC4_BULLET" "$INVARIANTS"; then
  pass "AC4 exact INV-91 Migration-log bullet present in invariants.md"
else
  fail "AC4 INV-91 Migration-log bullet missing/changed in invariants.md"
fi

# Also assert the new INV-95 heading + its heading-adjacent triage tag exist (the
# TC-SPEC-GATE-040/041 contract; locality assertion here too).
echo "=== AC4 (cont.): INV-95 heading + triage tag ==="
assert_eq "AC4 invariants.md has the INV-95 heading" \
  "1" "$(grep -cE '^## INV-95:' "$INVARIANTS" || true)"
adj95=$(awk '/^## INV-95:/{h=NR} /^_Triage \(issue #236\): \[machine-checked: tests\/unit\/test-chp-list-inline-comments\.sh\]_/{if(h && NR-h<=2) c++} END{print c+0}' "$INVARIANTS")
assert_eq "AC4 INV-95 carries a heading-adjacent machine-checked triage tag" "1" "$adj95"

# ===========================================================================
echo ""
echo "=== Summary ==="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
[ "$FAIL" -eq 0 ]
