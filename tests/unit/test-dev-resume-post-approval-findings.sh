#!/bin/bash
# test-dev-resume-post-approval-findings.sh — regression for issue #188 (INV-57).
#
# On dev-resume, the dev agent declares "nothing outstanding" and exits when the
# linked PR is APPROVED + green CI + mergeable, even when a NEWER review-findings /
# change-request comment (with BLOCKING / [P1] items) was posted to the issue AFTER
# the approval. The standing APPROVED reviewDecision short-circuits the resume before
# the late findings are acted on.
#
# The wrapper-side fix is `emit_post_approval_findings_block <issue_num> <pr_num>`:
# it compares the newest findings comment's createdAt against the latest APPROVED
# review's submittedAt and, when findings are newer (or no approval exists), emits a
# prompt block telling the agent the APPROVED/mergeable state is STALE and it must NOT
# exit "nothing outstanding". This test extracts that helper from autonomous-dev.sh and
# drives it with a stubbed `gh`.
#
# Run: bash tests/unit/test-dev-resume-post-approval-findings.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_emitted() {
  local label="$1" out="$2"
  if [[ -n "$out" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $label (block emitted)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $label (expected a block, got EMPTY)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_emitted() {
  local label="$1" out="$2"
  if [[ -z "$out" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $label (no block, as expected)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $label (expected EMPTY, got: $(echo "$out" | head -c 120))"
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

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# Extract emit_post_approval_findings_block() from autonomous-dev.sh.
HELPER_FN=$(awk '/^emit_post_approval_findings_block\(\) \{/,/^\}/' "$WRAPPER")
if [[ -z "$HELPER_FN" ]]; then
  echo -e "${RED}FAIL${NC}: could not extract emit_post_approval_findings_block() from $WRAPPER"
  exit 1
fi

# --- Stub harness -----------------------------------------------------------
# The helper queries two host shapes (post-#296-B6):
#   chp_pr_view <pr> ... --json reviews          → approval submittedAt(s)  [gh pr view]
#   itp_list_comments <issue> | jq -r '<sel>'    → findings comment createdAt + body
#
# `chp_pr_view` still resolves to a real `gh pr view`, so we stub `gh` on PATH for
# the approval query. The findings READ migrated to `itp_list_comments` (the
# normalized [INV-90] array `[{…,body,createdAt}]`), so we define an
# `itp_list_comments` shim in run_helper that emits that array from the fixture —
# the helper pipes it into its OWN `jq -r '<selector>'` (the REAL selector baked
# into the wrapper, not a test-local re-implementation). Files come from env:
#   GH_PR_REVIEWS_JSON   → JSON object printed for the `pr view --json reviews` call
#                          BEFORE the helper's -q jq filter is applied. The stub
#                          applies the helper's -q expression itself (extracted from $@).
#   GH_ISSUE_COMMENTS_JSON → {comments:[…]} fixture the itp_list_comments shim
#                          unwraps to the normalized array `.comments`.
#   GH_FAIL              → if "1", every gh call AND itp_list_comments fails
#                          (transient outage — both reads fail-closed).
#   GH_PR_VIEW_FAIL=1    → only the approval query (`gh pr view`) fails; the
#                          findings READ (itp_list_comments) still succeeds.
#
# The stub honors the `-q <expr>` the helper passes so the test exercises the
# REAL jq expressions baked into the wrapper, not a test-local re-implementation.
STUB_DIR="$TMPROOT/bin"
mkdir -p "$STUB_DIR"

cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
# GH_FAIL=1         → ALL gh calls fail (transient outage). The itp_list_comments
#                     shim (run_helper) honors GH_FAIL too, so the findings read
#                     fails-closed in lockstep.
# GH_PR_VIEW_FAIL=1 → only `gh pr view` (the approval query) fails; the findings
#                     query (`itp_list_comments`) still succeeds. Pins the
#                     fail-closed contract: an approval-query failure must NOT be
#                     mistaken for "no approval" (issue #188 codex finding 1).
[[ "${GH_FAIL:-0}" == "1" ]] && exit 3

# Find the -q <expr> argument (the jq filter the helper supplies).
expr=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "-q" || "$prev" == "--jq" ]]; then expr="$a"; break; fi
  prev="$a"
done

src=""
case "$*" in
  *"pr view"*)    [[ "${GH_PR_VIEW_FAIL:-0}" == "1" ]] && exit 3; src="${GH_PR_REVIEWS_JSON:-}";;
  *"issue view"*) src="${GH_ISSUE_COMMENTS_JSON:-}";;
  *) echo ""; exit 0;;
esac

if [[ -z "$src" || ! -f "$src" ]]; then echo ""; exit 0; fi
if [[ -n "$expr" ]]; then
  jq -r "$expr" < "$src" 2>/dev/null
else
  cat "$src"
fi
exit 0
EOF
chmod +x "$STUB_DIR/gh"

write_reviews() {
  # $@ pairs of "<state> <submittedAt>"
  local file="$TMPROOT/reviews.json"
  local arr="[]"
  while [ "$#" -ge 2 ]; do
    arr=$(jq --arg s "$1" --arg t "$2" '. + [{state:$s, submittedAt:$t}]' <<<"$arr")
    shift 2
  done
  jq -n --argjson r "$arr" '{reviews: $r}' > "$file"
  echo "$file"
}

write_comments() {
  # $@ pairs of "<createdAt>::<body>"
  local file="$TMPROOT/comments.json"
  local arr="[]"
  for pair in "$@"; do
    local ts="${pair%%::*}" body="${pair#*::}"
    arr=$(jq --arg t "$ts" --arg b "$body" '. + [{createdAt:$t, body:$b}]' <<<"$arr")
  done
  jq -n --argjson c "$arr" '{comments: $c}' > "$file"
  echo "$file"
}

run_helper() {
  # run_helper <issue> <pr> KEY=VAL...
  local issue="$1" pr="$2"; shift 2
  env \
    PATH="$STUB_DIR:$PATH" \
    REPO="acme/widget" \
    "$@" \
    bash -c "
      set -euo pipefail
      log() { :; }
      # [INV-87] (#282) emit_post_approval_findings_block now reads the PR's
      # reviews via chp_pr_view (the general read primitive). Real leaf:
      # \`gh pr view \$pr --repo \$REPO \"\$@\"\`; define the same shim so this
      # isolation harness (PATH-stubbed gh + extracted helper) resolves the verb.
      chp_pr_view() { local _pr=\"\$1\"; shift; gh pr view \"\$_pr\" --repo \"\${REPO:-acme/widget}\" \"\$@\"; }
      # [INV-87]/[INV-90] (#296 B6) emit_post_approval_findings_block now reads the
      # issue comments via itp_list_comments (the normalized array \`[{…,body,createdAt}]\`)
      # then applies its OWN \`jq -r '<selector>'\`. Shim the verb so this isolation
      # harness emits that array from the {comments:[…]} fixture. Fail-closed on
      # GH_FAIL (a verb failure → empty + non-zero so the helper's \`if !\` returns 0);
      # GH_PR_VIEW_FAIL is NOT honored here (only the approval query fails in that case).
      itp_list_comments() {
        [[ \"\${GH_FAIL:-0}\" == \"1\" ]] && return 3
        local _src=\"\${GH_ISSUE_COMMENTS_JSON:-}\"
        [[ -n \"\$_src\" && -f \"\$_src\" ]] || { echo \"\"; return 0; }
        jq -c '.comments // []' < \"\$_src\"
      }
      $HELPER_FN
      emit_post_approval_findings_block '$issue' '$pr'
    "
}

FINDINGS_P1='Review findings:

[BLOCKING] [P1] Data race in submitFeed.

session: 11111111-1111-1111-1111-111111111111'
FINDINGS_NONPREFIX='## Codex review findings

[P1] BLOCKING: the new artifacts table has no TTL configured.'
OPERATOR_NOTE='[P1] BLOCKING: data race in submitFeed — please fix before merge'
PASSED='Review PASSED - All checklist items verified.

session: 33333333-3333-3333-3333-333333333333'

echo "=== TC-PAF-001..007: emit_post_approval_findings_block ==="

# TC-PAF-001 — APPROVED@07:00, findings@08:00 (newer) → emit
out=$(run_helper 188 50 \
  GH_PR_REVIEWS_JSON="$(write_reviews APPROVED 2026-06-08T07:00:00Z)" \
  GH_ISSUE_COMMENTS_JSON="$(write_comments "2026-06-08T08:00:00Z::$FINDINGS_P1")")
assert_emitted "TC-PAF-001 findings newer than approval → emit" "$out"

# TC-PAF-002 — APPROVED@08:00 (newest), findings@07:00 → no emit
out=$(run_helper 188 50 \
  GH_PR_REVIEWS_JSON="$(write_reviews APPROVED 2026-06-08T08:00:00Z)" \
  GH_ISSUE_COMMENTS_JSON="$(write_comments "2026-06-08T07:00:00Z::$FINDINGS_P1")")
assert_not_emitted "TC-PAF-002 approval newer than findings → no emit (genuinely done)" "$out"

# TC-PAF-003 — APPROVED, no findings at all → no emit
out=$(run_helper 188 50 \
  GH_PR_REVIEWS_JSON="$(write_reviews APPROVED 2026-06-08T07:00:00Z)" \
  GH_ISSUE_COMMENTS_JSON="$(write_comments "2026-06-08T06:00:00Z::Dispatching autonomous review...")")
assert_not_emitted "TC-PAF-003 approval + no findings → no emit" "$out"

# TC-PAF-004 — no approval, findings present → emit
out=$(run_helper 188 50 \
  GH_PR_REVIEWS_JSON="$(write_reviews)" \
  GH_ISSUE_COMMENTS_JSON="$(write_comments "2026-06-08T08:00:00Z::$FINDINGS_P1")")
assert_emitted "TC-PAF-004 findings with no approval → emit" "$out"

# TC-PAF-005 — APPROVED@07:00, non-prefix findings (## Codex review findings + [P1])@08:00 → emit
out=$(run_helper 188 50 \
  GH_PR_REVIEWS_JSON="$(write_reviews APPROVED 2026-06-08T07:00:00Z)" \
  GH_ISSUE_COMMENTS_JSON="$(write_comments "2026-06-08T08:00:00Z::$FINDINGS_NONPREFIX")")
assert_emitted "TC-PAF-005 non-prefix [P1] findings newer than approval → emit (broadened)" "$out"

# TC-PAF-006 — gh errors → fail-closed (no emit), no set -e abort
out=$(run_helper 188 50 GH_FAIL=1)
rc=$?
assert_not_emitted "TC-PAF-006 gh failure → fail-closed (no emit)" "$out"
if [ "$rc" -eq 0 ]; then
  echo -e "  ${GREEN}PASS${NC}: TC-PAF-006 helper returns 0 under gh failure (no set -e abort)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-PAF-006 helper returned $rc under gh failure (should be 0)"
  FAIL=$((FAIL + 1))
fi

# TC-PAF-007 — APPROVED@07:00, a Review PASSED comment@08:00 (newer, but a PASS) → no emit
out=$(run_helper 188 50 \
  GH_PR_REVIEWS_JSON="$(write_reviews APPROVED 2026-06-08T07:00:00Z)" \
  GH_ISSUE_COMMENTS_JSON="$(write_comments "2026-06-08T08:00:00Z::$PASSED")")
assert_not_emitted "TC-PAF-007 newer Review PASSED (not findings) → no emit" "$out"

# TC-PAF-008 — operator [P1] BLOCKING note (no prefix, no 'findings' word, but BLOCKING+P1) newer → emit
out=$(run_helper 188 50 \
  GH_PR_REVIEWS_JSON="$(write_reviews APPROVED 2026-06-08T07:00:00Z)" \
  GH_ISSUE_COMMENTS_JSON="$(write_comments "2026-06-08T08:00:00Z::$OPERATOR_NOTE")")
assert_emitted "TC-PAF-008 operator [P1] BLOCKING note newer than approval → emit" "$out"

# TC-PAF-009 — APPROVED@07:00, a NEWER "remaining items NON-BLOCKING" note (no real
# findings token) → NO emit. The consuming anchor must reject NON-BLOCKING so a
# genuinely-done agent isn't sent back into a fix loop by a reassurance note.
NON_BLOCKING_NOTE='Remaining items are NON-BLOCKING — safe to merge once CI is green.'
out=$(run_helper 188 50 \
  GH_PR_REVIEWS_JSON="$(write_reviews APPROVED 2026-06-08T07:00:00Z)" \
  GH_ISSUE_COMMENTS_JSON="$(write_comments "2026-06-08T08:00:00Z::$NON_BLOCKING_NOTE")")
assert_not_emitted "TC-PAF-009 newer 'NON-BLOCKING' note → no emit (consuming anchor rejects hyphen)" "$out"

# ── Issue #188 review round 1 (codex findings) ────────────────────────────────

# TC-PAF-010 (codex finding 1) — the approval query (`gh pr view`) FAILS but the
# findings query (`gh issue view`) succeeds with a findings comment. A query
# FAILURE must be fail-closed (no emit) — NOT mistaken for "no approval" (which
# would emit). This is the contract the INV-57 docs promise but the first cut
# violated (empty approved_at from `|| true` was indistinguishable from a real
# transient/permission error).
out=$(run_helper 188 50 \
  GH_PR_VIEW_FAIL=1 \
  GH_ISSUE_COMMENTS_JSON="$(write_comments "2026-06-08T08:00:00Z::$FINDINGS_P1")")
rc=$?
assert_not_emitted "TC-PAF-010 approval-query failure → fail-closed (NOT treated as no-approval)" "$out"
if [ "$rc" -eq 0 ]; then
  echo -e "  ${GREEN}PASS${NC}: TC-PAF-010 helper returns 0 on approval-query failure (no set -e abort)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-PAF-010 helper returned $rc on approval-query failure (should be 0)"
  FAIL=$((FAIL + 1))
fi

# TC-PAF-011 (codex finding 2a) — a newer `Review PASSED - No BLOCKING issues remain`
# verdict contains the BLOCKING token but is a PASS, not a finding → NO emit.
PASSED_WITH_TOKEN='Review PASSED - No BLOCKING issues remain. LGTM.

session: 44444444-4444-4444-4444-444444444444'
out=$(run_helper 188 50 \
  GH_PR_REVIEWS_JSON="$(write_reviews APPROVED 2026-06-08T07:00:00Z)" \
  GH_ISSUE_COMMENTS_JSON="$(write_comments "2026-06-08T08:00:00Z::$PASSED_WITH_TOKEN")")
assert_not_emitted "TC-PAF-011 'Review PASSED - No BLOCKING issues remain' → no emit (PASS, not finding)" "$out"

# TC-PAF-012 (codex finding 2b) — a dev implementation/status comment that mentions
# BLOCKING / [P1] in prose (e.g. THIS issue's own impl-complete comment) is NOT a
# review change-request → NO emit. Otherwise a status report would falsely re-open
# a genuinely-done approved PR.
IMPL_STATUS='## ✅ Implementation complete — PR #204

Fixed the dev-resume short-circuit. Addresses [P1] BLOCKING data-correctness items.

Session ID: `ed1dd96d-c0a4-4acc-bc1d-23dded2a3833`'
out=$(run_helper 188 50 \
  GH_PR_REVIEWS_JSON="$(write_reviews APPROVED 2026-06-08T07:00:00Z)" \
  GH_ISSUE_COMMENTS_JSON="$(write_comments "2026-06-08T08:00:00Z::$IMPL_STATUS")")
assert_not_emitted "TC-PAF-012 dev impl/status comment with BLOCKING/[P1] in prose → no emit" "$out"

# TC-PAF-013 (codex finding 2c) — an Agent Session Report (status) mentioning the
# tokens is likewise NOT a finding → NO emit.
SESSION_REPORT='**Agent Session Report (Dev)**

Exit code: 0. Resolved [P1] BLOCKING items per review.'
out=$(run_helper 188 50 \
  GH_PR_REVIEWS_JSON="$(write_reviews APPROVED 2026-06-08T07:00:00Z)" \
  GH_ISSUE_COMMENTS_JSON="$(write_comments "2026-06-08T08:00:00Z::$SESSION_REPORT")")
assert_not_emitted "TC-PAF-013 Agent Session Report with tokens → no emit (status, not finding)" "$out"

# TC-PAF-TIE (AC4) — :613 is ORDER-IMMUNE. Two findings with byte-identical
# whole-second createdAt, ONE older than the approval and ONE equal-to/after the
# findings projection: the explicit `| sort` on projected ISO-8601 strings picks
# the same max timestamp regardless of insertion order, so the emit decision is
# invariant. Here APPROVED@07:00 and two findings@08:00 (same second) → findings
# are newer → emit, and the chosen timestamp is 08:00 either way.
out=$(run_helper 188 50 \
  GH_PR_REVIEWS_JSON="$(write_reviews APPROVED 2026-06-08T07:00:00Z)" \
  GH_ISSUE_COMMENTS_JSON="$(write_comments \
    "2026-06-08T08:00:00Z::$FINDINGS_P1" \
    "2026-06-08T08:00:00Z::$OPERATOR_NOTE")")
assert_emitted "TC-PAF-TIE :613 order-immune — same-second findings newer than approval → emit (explicit | sort)" "$out"

echo ""
echo "=== TC-PAF-MIG: #296 B6 migration guards (false-green hazard closed) ==="

# Extract the findings selector from the migrated :613 site (the `findings_at`
# assignment now reads `itp_list_comments "$issue_num" 2>/dev/null | jq -r '<EXPR>'`).
PAF_SELECTOR=$(awk '
  /if ! findings_at=\$\(itp_list_comments/ {
    match($0, /jq -r '\''([^'\'']+)'\''/, a)
    if (a[1] != "") { print a[1]; exit }
  }' "$WRAPPER")
if [[ -n "$PAF_SELECTOR" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-PAF-MIG01 findings selector extracted (non-empty) from the migrated itp_list_comments read"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-PAF-MIG01 could not extract the migrated findings selector (itp_list_comments | jq -r) from $WRAPPER"
  FAIL=$((FAIL + 1))
fi

# Unique-live-site: the extracted selector must match the live migrated findings_at
# assignment EXACTLY ONCE (proves we exercised the real wrapper read, not a stale dup).
if [[ -n "$PAF_SELECTOR" ]]; then
  _paf_live="if ! findings_at=\$(itp_list_comments \"\$issue_num\" 2>/dev/null | jq -r '${PAF_SELECTOR}' 2>/dev/null); then"
  _paf_count=$(grep -Fc -- "$_paf_live" "$WRAPPER")
  if [[ "$_paf_count" -eq 1 ]]; then
    echo -e "  ${GREEN}PASS${NC}: TC-PAF-MIG02 extracted selector matches the live findings_at assignment exactly once"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-PAF-MIG02 extracted selector matched the live findings_at assignment $_paf_count times (expected 1)"
    FAIL=$((FAIL + 1))
  fi
fi

# Static guard: the OLD raw `gh issue view … --json comments` reads are GONE.
if grep -qE 'gh issue view "\$(ISSUE_NUMBER|issue_num)" --repo "\$REPO" --json comments' "$WRAPPER"; then
  echo -e "  ${RED}FAIL${NC}: TC-PAF-MIG03 a raw 'gh issue view … --json comments' resume read survives — not migrated"
  grep -nE 'gh issue view "\$(ISSUE_NUMBER|issue_num)" --repo "\$REPO" --json comments' "$WRAPPER" | sed 's/^/      /'
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-PAF-MIG03 no raw 'gh issue view … --json comments' resume read remains (both behind itp_list_comments)"
  PASS=$((PASS + 1))
fi

echo ""
echo "=== Source-of-truth greps (prompt wiring + INV) ==="

assert_grep "TC-PAF-W01: emit_post_approval_findings_block helper is defined" \
  '^emit_post_approval_findings_block\(\) \{' "$WRAPPER"
assert_grep "TC-PAF-W03: helper output interpolated into a prompt builder" \
  'POST_APPROVAL_FINDINGS|emit_post_approval_findings_block ' "$WRAPPER"

# TC-PAF-W02: the emitted block content. Extract the heredoc body.
PAF_BLOCK=$(awk '/cat <<POSTAPPROVAL$/{p=1;next} /^POSTAPPROVAL$/{p=0} p' "$WRAPPER")
echo "$PAF_BLOCK" > "$TMPROOT/paf-block.txt"
assert_grep "TC-PAF-W02: block names post-approval findings" \
  '[Pp]ost-approval' "$TMPROOT/paf-block.txt"
assert_grep "TC-PAF-W02: block tells agent NOT to exit nothing-outstanding" \
  '[Nn]ot.*(exit|nothing outstanding)|do NOT.*exit|MUST NOT.*nothing' "$TMPROOT/paf-block.txt"
assert_grep "TC-PAF-W02: block references the stale APPROVED/mergeable state" \
  'APPROVED|mergeable|reviewDecision' "$TMPROOT/paf-block.txt"

# TC-PAF-W04: wrapper passes bash -n
echo ""
echo "=== TC-PAF-W04: wrapper passes bash -n ==="
if bash -n "$WRAPPER" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: wrapper passes bash -n"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: wrapper has syntax errors"
  FAIL=$((FAIL + 1))
fi

# TC-PAF-D03: INV-57 exists and is referenced from dev-agent-flow.md
INV_DOC="$PROJECT_ROOT/docs/pipeline/invariants.md"
FLOW_DOC="$PROJECT_ROOT/docs/pipeline/dev-agent-flow.md"
echo ""
echo "=== Doc-contract assertions ==="
assert_grep "TC-PAF-D03: INV-57 defined in invariants.md" '^## INV-57' "$INV_DOC"
assert_grep "TC-PAF-D03: dev-agent-flow.md references INV-57" 'INV-57' "$FLOW_DOC"

AM_DOC="$PROJECT_ROOT/skills/autonomous-dev/references/autonomous-mode.md"
assert_grep "TC-PAF-D01: autonomous-mode.md documents approval-vs-findings timestamp ordering" \
  '[Tt]imestamp|newer than the.*approval|after the approval' "$AM_DOC"
assert_grep "TC-PAF-D02: autonomous-mode.md documents broadened findings recognition" \
  'BLOCKING|\[P1\]' "$AM_DOC"

echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="
[ "$FAIL" -eq 0 ]
