#!/bin/bash
# test-w1c2-incidental-read-parity.sh — issue #398 (W1c2, #347 phase-2), R4.
#
# DECISION-level (not byte-level) behavior-parity suite for the 9 caller sites
# of the abstract chp_pr_view / chp_list_inline_comments contracts:
#
#   site1_approved_at (autonomous-dev.sh:604)
#   site2_preview_url (autonomous-review.sh:918)
#   site3_head_ref_name (autonomous-review.sh:948)
#   site4_head_ref_oid  (autonomous-review.sh:949)
#   site5_state (autonomous-review.sh:1591)
#   site6_state (autonomous-review.sh:3312)
#   site7_wait_count (autonomous-review.sh:3357)
#   site8_evidence_body (lib-review-e2e.sh:262)
#   site9_inline_comments (autonomous-dev.sh:1091 formatter)
#
# #398 converts both verbs from gh-argv passthrough to abstract contracts with
# NORMALIZED output — a DELIBERATE shape change, so verbatim gh-argv equivalence
# is impossible by construction. Instead this suite proves DECISION-level parity:
# for each site, the extracted value / rendered output equals the frozen
# tests/unit/fixtures/w1c2-parity/decision-golden.json entry captured on the
# FIRST TDD commit (before the abstract-contract rewrite landed) — see the
# `.meta` sidecar for provenance.
#
# The test drives each caller-site's projection over the NEW normalized shape:
#   pr_view sites  — the NEW leaf returns `{state, headRefName, headRefOid,
#                    comments:[{id,author,body,createdAt}], reviews:[{author,
#                    state,submittedAt}], ...}` (a subset per fields-csv). Plain
#                    jq over that object must produce the OLD extracted values.
#   inline sites   — the NEW leaf returns `[{id,path,line,author,body,createdAt}]`
#                    ascending, with `line` = leaf-side `line // original_line //
#                    null` fold. Plain `.line // "N/A"` over the normalized array
#                    must produce the same `- **path:line** — body` rendering the
#                    OLD `.line // .original_line // "N/A"` fold produced.
#
# Both proofs FIRST run against the OLD fixture shape (byte-identical passthrough
# — the PRE-change state) so the goldens capture is FAITHFUL. Later commits
# re-run the SAME assertions against the NEW normalized shape; the OLD/NEW
# formatter renderings must match on the mixed line/originalLine fixture.
#
# Run: env -u PROJECT_DIR bash tests/unit/test-w1c2-incidental-read-parity.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FIX="$SCRIPT_DIR/fixtures/w1c2-parity"
GOLDEN="$FIX/decision-golden.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

[[ -f "$GOLDEN" ]] || { echo "FATAL: golden fixture not found at $GOLDEN"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

# ---------------------------------------------------------------------------
# Assertion helpers.
# ---------------------------------------------------------------------------
assert_eq_golden() {
  local desc="$1" key="$2" actual="$3"
  local expected
  expected="$(jq -r --arg k "$key" '.[$k]' "$GOLDEN")"
  if [[ "$expected" == "$actual" ]]; then
    ok "$desc"
  else
    bad "$desc"
    echo "      expected: |$expected|"
    echo "      actual:   |$actual|"
  fi
}

# =========================================================================
# Site 1: approved-timestamp (autonomous-dev.sh:604)
#   OLD (byte-identical passthrough): chp_pr_view $PR --json reviews \
#     -q '[.reviews[]? | select(.state=="APPROVED") | .submittedAt] | sort | last // empty'
#   NEW (positional, plain jq): chp_pr_view $PR "reviews" | jq -r
#     '[.reviews[] | select(.state=="APPROVED") | .submittedAt] | sort | last // empty'
# The normalized shape mirrors the OLD `reviews` sub-object exactly, so the
# EXTRACTED string is IDENTICAL — the caller's jq changes from `-q` post-filter
# to a plain-jq pipe, that's it.
# =========================================================================
echo "=== Site 1 — approved-timestamp (autonomous-dev.sh:604) ==="
# The NEW normalized shape carries `reviews:[{author,state,submittedAt}]`
# ascending; the mixed fixture is already REST-shaped ({reviews:[…]}) so both
# OLD and NEW projections read `.reviews[]` identically.
s1_mixed=$(jq -r '[.reviews[]? | select(.state == "APPROVED") | .submittedAt] | sort | last // empty' < "$FIX/reviews-mixed.json")
assert_eq_golden "site1 approved_at (mixed reviews → latest APPROVED submittedAt)" \
  "site1_approved_at.mixed" "$s1_mixed"

s1_none=$(jq -r '[.reviews[]? | select(.state == "APPROVED") | .submittedAt] | sort | last // empty' < "$FIX/reviews-noapproval.json")
assert_eq_golden "site1 approved_at (no APPROVED review → empty)" \
  "site1_approved_at.no_approval" "$s1_none"

# =========================================================================
# Site 2: preview URL (autonomous-review.sh:918)
#   OLD: chp_pr_view $PR --json comments \
#          -q '[.comments[].body | select(contains("Preview"))] | last'
#        | grep -oP 'https://[^\s"]+' | head -1
#   NEW: chp_pr_view $PR "comments" | jq -r
#          '[.comments[].body | select(contains("Preview"))] | last'
#        | grep -oP 'https://[^\s"]+' | head -1
# The grep+head-1 pipe stays caller-side either way.
# =========================================================================
echo "=== Site 2 — preview URL (autonomous-review.sh:918) ==="
s2_preview=$(jq -r '[.comments[].body | select(contains("Preview"))] | last' < "$FIX/comments-mixed.json" \
  | grep -oP 'https://[^\s"]+' | head -1 || true)
assert_eq_golden "site2 preview_url (mixed comments → last Preview URL scraped)" \
  "site2_preview_url.mixed" "$s2_preview"

# =========================================================================
# Site 3+4: branch + SHA (autonomous-review.sh:948/:949)
#   OLD: chp_pr_view $PR --json headRefName -q '.headRefName'   (and headRefOid)
#   NEW: chp_pr_view $PR "headRefName" | jq -r '.headRefName'
# Normalized field named IDENTICALLY (headRefName / headRefOid, per W1c1 vocab).
# =========================================================================
echo "=== Site 3+4 — branch + SHA (autonomous-review.sh:948/:949) ==="
s3_branch=$(jq -r '.headRefName' < "$FIX/pr-state-headref.json")
assert_eq_golden "site3 headRefName" "site3_head_ref_name" "$s3_branch"
s4_sha=$(jq -r '.headRefOid' < "$FIX/pr-state-headref.json")
assert_eq_golden "site4 headRefOid" "site4_head_ref_oid" "$s4_sha"

# =========================================================================
# Site 5+6: state token → _pr_open_gate (autonomous-review.sh:1591/:3312)
#   OLD: chp_pr_view $PR --json state -q '.state'
#   NEW: chp_pr_view $PR "state" | jq -r '.state'
# W1c1 vocab pins state ∈ {OPEN,CLOSED,MERGED} — the same tokens gh emits, so
# `_pr_open_gate` continues to consume raw OPEN-token semantics unchanged.
# =========================================================================
echo "=== Site 5+6 — .state feeding _pr_open_gate ==="
s5_state=$(jq -r '.state' < "$FIX/pr-state-headref.json")
assert_eq_golden "site5 state (E2E-lane hoisted open-guard)" "site5_state.open" "$s5_state"
assert_eq_golden "site6 state (PASS-chain open-guard)"        "site6_state.open" "$s5_state"

# =========================================================================
# Site 7: bot-review-wait count (autonomous-review.sh:3357)
#   OLD: chp_pr_view $PR --json comments --jq
#          "[.comments[] | select(.body | contains(\"bot-review-wait sha=\\\"...\\\"\"))] | length"
#   NEW: chp_pr_view $PR "comments" | jq -r
#          '[.comments[] | select(.body | contains("bot-review-wait sha=\"...\""))] | length'
# The extraction produces the SAME integer count over the SAME comments array.
# =========================================================================
echo "=== Site 7 — bot-review-wait count (autonomous-review.sh:3357) ==="
s7_count=$(jq -r '[.comments[] | select(.body | contains("bot-review-wait sha=\"deadbee\""))] | length' \
  < "$FIX/comments-mixed.json")
assert_eq_golden "site7 wait_count (two holds on the SHA)" "site7_wait_count.two" "$s7_count"

# =========================================================================
# Site 8: SHA-evidence body (lib-review-e2e.sh:262)
#   OLD: chp_pr_view $PR --json comments --jq
#          "[.comments[] | select(.body|contains(\"e2e-evidence: complete sha=\\\"...\\\"\")) | .body] | last // empty"
#   NEW: chp_pr_view $PR "comments" | jq -r
#          '[.comments[] | select(.body|contains("e2e-evidence: complete sha=\"...\"")) | .body] | last // empty'
# Multi-line body must survive intact (the load-bearing property — head -1 was
# rejected in the original site because the evidence block is multi-line).
# =========================================================================
echo "=== Site 8 — SHA-evidence body (lib-review-e2e.sh:262) ==="
s8_body=$(jq -r '[.comments[] | select(.body | contains("e2e-evidence: complete sha=\"deadbee\"")) | .body] | last // empty' \
  < "$FIX/comments-mixed.json")
assert_eq_golden "site8 evidence_body (multi-line body preserved)" \
  "site8_evidence_body.mixed" "$s8_body"

# =========================================================================
# Site 9: inline-comment formatter (autonomous-dev.sh:1091)
#
# Two parity claims, per issue R4:
#   (a) SAME rendering on the mixed line/originalLine page-1 fixture. The OLD
#       caller runs `.line // .original_line // "N/A"` over the raw REST shape;
#       the NEW caller runs `.line // "N/A"` over the normalized shape (the
#       leaf folds `original_line` into `line` at normalization time). Both
#       renderings MUST be byte-identical on a fixture containing both
#       line-populated AND originalLine-only rows.
#   (b) COMPLETENESS — the NEW leaf page-walks so pages 1+2 both reach the
#       rendered block. The OLD leaf (single-page) would truncate.
# =========================================================================
echo "=== Site 9 — inline-comment formatter (autonomous-dev.sh:1091) ==="

# (a) OLD-shape rendering (byte-identical passthrough — page 1, REST fields):
FORMATTER_OLD='[.[] | "- **\(.path):\(.line // .original_line // "N/A")** — \(.body)"] | join("\n")'
s9_p1_old=$(jq -r "$FORMATTER_OLD" < "$FIX/inline-comments-page1.json")
assert_eq_golden "site9 OLD-shape rendering (page1, mixed line/originalLine)" \
  "site9_inline_comments.page1" "$s9_p1_old"

# (a) NEW-shape rendering: fold original_line into `line` at normalization
# time (mirror the leaf), rename user.login→author, created_at→createdAt, then
# render with `.line // "N/A"` (originalLine no longer at the seam).
NORMALIZE='[.[] | {id, path, line: (.line // .original_line), author: (.user.login // null), body: (.body // ""), createdAt: .created_at} ] | sort_by(.createdAt // "", .id // 0)'
FORMATTER_NEW='[.[] | "- **\(.path):\(.line // "N/A")** — \(.body)"] | join("\n")'
s9_p1_new=$(jq -c "$NORMALIZE" < "$FIX/inline-comments-page1.json" | jq -r "$FORMATTER_NEW")
assert_eq_golden "site9 NEW-shape rendering matches OLD-shape (line//original_line folded to line)" \
  "site9_inline_comments.page1" "$s9_p1_new"

# (b) Completeness — NEW leaf's page-walk merges the two pages into ONE array;
# the same normalize + formatter renders both pages contiguously.
COMBINED=$(jq -s 'add' "$FIX/inline-comments-page1.json" "$FIX/inline-comments-page2.json")
s9_comb=$(printf '%s' "$COMBINED" | jq -c "$NORMALIZE" | jq -r "$FORMATTER_NEW")
assert_eq_golden "site9 combined (page-walk completeness, >1-page content preserved)" \
  "site9_inline_comments.combined" "$s9_comb"

# =========================================================================
# Codex pre-review regression cases (P1-1 / P1-2 / P2-3) — proven directly
# against the real GitHub leaf. Source `chp-github.sh` so we drive the actual
# `chp_github_pr_view` / `chp_github_list_inline_comments`, then override the
# `gh` builtin in the SAME shell to model each edge case.
# =========================================================================
echo ""
echo "=== W1c2 codex-regression: leaf-level edge cases ==="

CHP_GITHUB="$SCRIPT_DIR/../../skills/autonomous-dispatcher/scripts/providers/chp-github.sh"
if [[ -f "$CHP_GITHUB" ]]; then
  # Isolate the leaf's `gh` override to a subshell so it doesn't leak into
  # earlier assertions (which run without a stubbed gh).

  # P1-2: chp_github_pr_view rc-0 empty stdout → fail-CLOSED (rc≠0, no stdout).
  # Reproduces the codex finding: gh returning rc 0 + empty stdout was
  # previously mis-read as a valid "state=UNKNOWN"-like answer by the caller,
  # letting a silent gh failure look like a real value.
  rc=0; out=""
  out=$(REPO=owner/repo bash -c '
    source "'"$CHP_GITHUB"'"
    gh() { return 0; }   # rc 0, empty stdout (silent gh failure)
    chp_github_pr_view 42 state
  ' 2>&1) || rc=$?
  if [[ "$rc" != "0" && -z "$out" ]]; then
    ok "P1-2 chp_github_pr_view: gh rc-0 empty stdout → fail-CLOSED (rc≠0, no partial stdout)"
  else
    bad "P1-2 chp_github_pr_view fail-OPEN on empty stdout (rc=$rc out=[$out])"
  fi

  # P1-2 companion: gh emits non-JSON on rc 0 → also fail-CLOSED (jq -e
  # object-shape guard).
  rc=0; out=""
  out=$(REPO=owner/repo bash -c '
    source "'"$CHP_GITHUB"'"
    gh() { echo "not valid json"; }
    chp_github_pr_view 42 state
  ' 2>&1) || rc=$?
  if [[ "$rc" != "0" ]]; then
    ok "P1-2 chp_github_pr_view: gh rc-0 non-JSON stdout → fail-CLOSED (rc≠0)"
  else
    bad "P1-2 chp_github_pr_view accepted non-JSON stdout (rc=$rc out=[$out])"
  fi

  # P1-1: closingIssueNumbers accepts the FLAT `[{number}]` shape real gh
  # emits (the pre-existing repo-wide idiom, lib-pr-linkage.sh:85 anchor).
  out=$(REPO=owner/repo bash -c '
    source "'"$CHP_GITHUB"'"
    gh() { echo "{\"closingIssuesReferences\":[{\"number\":42},{\"number\":41}]}"; }
    chp_github_pr_view 42 closingIssueNumbers
  ' 2>&1)
  if [[ "$out" == "{\"closingIssueNumbers\":[42,41]}" ]]; then
    ok "P1-1 closingIssueNumbers accepts FLAT [{number}] gh shape (real gh pr view --json output)"
  else
    bad "P1-1 closingIssueNumbers FLAT shape not accepted: got [$out]"
  fi

  # P1-1: closingIssueNumbers also accepts the {nodes:[…]} cursor shape
  # (backwards-compat with any GraphQL path that emits the cursor form).
  out=$(REPO=owner/repo bash -c '
    source "'"$CHP_GITHUB"'"
    gh() { echo "{\"closingIssuesReferences\":{\"nodes\":[{\"number\":100}]}}"; }
    chp_github_pr_view 42 closingIssueNumbers
  ' 2>&1)
  if [[ "$out" == "{\"closingIssueNumbers\":[100]}" ]]; then
    ok "P1-1 closingIssueNumbers accepts CURSOR {nodes:[…]} shape too (dual-form fold)"
  else
    bad "P1-1 closingIssueNumbers CURSOR shape not accepted: got [$out]"
  fi

  # P1-1: null/absent closingIssuesReferences → empty int array (never crash).
  for missing in '{"closingIssuesReferences":null}' '{}'; do
    out=$(REPO=owner/repo bash -c '
      source "'"$CHP_GITHUB"'"
      gh() { echo '"'$missing'"'; }
      chp_github_pr_view 42 closingIssueNumbers
    ' 2>&1)
    if [[ "$out" == "{\"closingIssueNumbers\":[]}" ]]; then
      ok "P1-1 closingIssueNumbers null/absent → [] (missing input: $missing)"
    else
      bad "P1-1 closingIssueNumbers missing-input not handled: input=$missing got=[$out]"
    fi
  done

  # P2-3: chp_github_list_inline_comments rc-0 empty stdout → fail-CLOSED.
  # A real zero-comment PR emits the literal `[]` from gh; empty stdout means
  # a silent gh failure the caller MUST distinguish (otherwise the dev-resume
  # prompt would treat a broken fetch as "no inline comments to address").
  rc=0; out=""
  out=$(REPO=owner/repo bash -c '
    source "'"$CHP_GITHUB"'"
    gh() { return 0; }
    chp_github_list_inline_comments 42
  ' 2>&1) || rc=$?
  if [[ "$rc" != "0" && -z "$out" ]]; then
    ok "P2-3 chp_github_list_inline_comments: gh rc-0 empty stdout → fail-CLOSED (rc≠0, no partial stdout)"
  else
    bad "P2-3 chp_github_list_inline_comments fail-OPEN on empty stdout (rc=$rc out=[$out])"
  fi

  # P2-3 companion: a real zero-comment PR (gh emits literal `[]`) is
  # distinguishable — rc 0 + `[]` normalized output.
  rc=0
  out=$(REPO=owner/repo bash -c '
    source "'"$CHP_GITHUB"'"
    gh() { echo "[]"; }
    chp_github_list_inline_comments 42
  ' 2>&1) || rc=$?
  if [[ "$rc" == "0" && "$out" == "[]" ]]; then
    ok "P2-3 chp_github_list_inline_comments: real zero-comment PR ([] from gh) distinguishable from empty-stdout failure"
  else
    bad "P2-3 chp_github_list_inline_comments: zero-comment case not distinguishable (rc=$rc out=[$out])"
  fi

  # =======================================================================
  # W1c2 online-review r1 (blocking): `chp_github_pr_view` MUST validate
  # FIELDS_CSV against the §3.2.1 vocabulary BEFORE building gh argv. A
  # GitHub-native field name (e.g. `closingIssuesReferences`, the internal
  # mapping target for the vocabulary's `closingIssueNumbers`) or an
  # unknown/typo name must be REJECTED LOUDLY with rc 2 — otherwise a
  # caller can silently depend on GitHub-only names a non-GitHub provider
  # cannot deliver, and the doc-honesty rule is violated (a field a
  # provider emits MUST be derivable from the data source it actually
  # reads, per §3.2.1's per-verb support matrix).
  # =======================================================================

  # TC-R1-VOCAB-1: raw gh-native name `closingIssuesReferences` → rc 2.
  # The vocabulary uses `closingIssueNumbers` (leaf maps to the raw name
  # internally); the raw name itself is NOT a vocabulary member.
  rc=0; out=""
  out=$(REPO=owner/repo bash -c '
    source "'"$CHP_GITHUB"'"
    gh() { echo "{\"closingIssuesReferences\":[{\"number\":42}]}"; }
    chp_github_pr_view 42 closingIssuesReferences
  ' 2>&1) || rc=$?
  if [[ "$rc" == "2" && "$out" == *"not in the §3.2.1 vocabulary"* ]]; then
    ok "r1-VOCAB-1 chp_github_pr_view rejects raw gh-native name 'closingIssuesReferences' → rc 2, loud stderr"
  else
    bad "r1-VOCAB-1 chp_github_pr_view accepted raw gh-native name (rc=$rc, expected rc 2 with vocabulary error; got stderr=[$out])"
  fi

  # TC-R1-VOCAB-2: unknown/typo field name → rc 2. Also proves the CSV walk
  # rejects on the FIRST unsupported field (never silently drops it).
  rc=0; out=""
  out=$(REPO=owner/repo bash -c '
    source "'"$CHP_GITHUB"'"
    gh() { echo "{}"; }
    chp_github_pr_view 42 number,bogusField
  ' 2>&1) || rc=$?
  if [[ "$rc" == "2" && "$out" == *"bogusField"* && "$out" == *"not in the §3.2.1 vocabulary"* ]]; then
    ok "r1-VOCAB-2 chp_github_pr_view rejects unknown 'bogusField' → rc 2, stderr names the field"
  else
    bad "r1-VOCAB-2 chp_github_pr_view unknown-field rejection wrong (rc=$rc stderr=[$out])"
  fi

  # TC-R1-VOCAB-3: every vocabulary field accepted (round-trip). Uses a
  # canned payload carrying every raw gh field the leaf reads, then requests
  # all 14 vocabulary members in one call and asserts rc 0.
  rc=0; out=""
  out=$(REPO=owner/repo bash -c '
    source "'"$CHP_GITHUB"'"
    gh() {
      cat <<EOF_PAYLOAD
{"state":"OPEN","body":null,"headRefName":"feat/x","headRefOid":"deadbeef","reviewDecision":"APPROVED","mergeable":"MERGEABLE","number":42,"title":"T","createdAt":"2026-06-27T09:00:00Z","updatedAt":"2026-06-28T09:00:00Z","mergedAt":null,"comments":[{"id":"c1","author":{"login":"a"},"body":"hi","createdAt":"2026-06-27T10:00:00Z"}],"reviews":[{"author":{"login":"r"},"state":"APPROVED","submittedAt":"2026-06-27T11:00:00Z"}],"closingIssuesReferences":[{"number":42}]}
EOF_PAYLOAD
    }
    chp_github_pr_view 42 "number,state,title,body,createdAt,updatedAt,mergedAt,headRefName,headRefOid,reviewDecision,mergeable,closingIssueNumbers,comments,reviews"
  ' 2>&1) || rc=$?
  if [[ "$rc" == "0" ]]; then
    # Confirm the normalization produced the expected keys (comments, reviews,
    # closingIssueNumbers all present in the output object).
    if jq -e '(keys | contains(["number","state","title","body","createdAt","updatedAt","mergedAt","headRefName","headRefOid","reviewDecision","mergeable","closingIssueNumbers","comments","reviews"]))' >/dev/null 2>&1 <<<"$out"; then
      ok "r1-VOCAB-3 chp_github_pr_view accepts every §3.2.1 vocabulary field (all 14 members round-trip)"
    else
      bad "r1-VOCAB-3 chp_github_pr_view produced wrong shape on all-fields request (out=[$out])"
    fi
  else
    bad "r1-VOCAB-3 chp_github_pr_view rejected a valid all-vocabulary request (rc=$rc stderr=[$out])"
  fi

  # TC-R1-VOCAB-4: chp_github_list_inline_comments has no FIELDS_CSV surface
  # — extra args are ignored (`local pr=$1` only). Confirm no analogous
  # vocabulary hole: an extra "gh-native" positional argument must NOT
  # affect behavior.
  rc=0; out=""
  out=$(REPO=owner/repo bash -c '
    source "'"$CHP_GITHUB"'"
    gh() { echo "[]"; }
    chp_github_list_inline_comments 42 closingIssuesReferences bogusExtra
  ' 2>&1) || rc=$?
  if [[ "$rc" == "0" && "$out" == "[]" ]]; then
    ok "r1-VOCAB-4 chp_github_list_inline_comments immune (no FIELDS_CSV surface — extra positional args ignored, no vocabulary hole)"
  else
    bad "r1-VOCAB-4 chp_github_list_inline_comments extra-arg passthrough hazard (rc=$rc out=[$out])"
  fi
else
  bad "codex-regression: chp-github.sh not found at $CHP_GITHUB"
fi

# =========================================================================
echo ""
echo "=== Summary ==="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
[ "$FAIL" -eq 0 ]
