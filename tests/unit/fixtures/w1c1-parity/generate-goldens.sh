#!/bin/bash
# generate-goldens.sh — one-shot capture of the PRE-#397 decision-level outputs
# for chp_find_pr_for_issue's callers (resolve_pr_for_issue / verify_pr_closes_issue)
# and the six body-mention chp_pr_list callers. Run against the PRE-change tree
# (this repo before the W1c1 leaf rewrite lands) exactly once; the emitted
# decision-golden.json is committed and used by test-w1c1-linkage-read-parity.sh
# to catch a regression in either the leaf OR the caller-side selection.
#
# Fixture inputs (chp_find_pr_for_issue candidate arrays; mirrors #277 fixtures):
#   close-linkage-wins  — sibling PR body-mentions #A, real PR closes #A.
#   branch-fallback     — no close linkage; branch names `issue-<A>`; body mentions.
#   cross-wired         — PR-B closes #B AND body mentions #A (regression driver).
#   null-body           — a `body:null` sibling alongside a close-linked PR.
#   no-pr               — no candidate binds by close linkage OR branch.
#   boundary            — issue 27 must not match #270's PR.
#   overlimit           — 35 candidates, one close-linked (>gh --limit 30 default).
#
# Fixture inputs (chp_pr_list body-mention sites): each PR list has a mix of
# bodies mentioning "#42" at boundary vs interior (e.g. "#425", "not-#42"),
# createdAt spread, and null bodies to exercise the six sites' selectors.
#
# Run: bash tests/unit/fixtures/w1c1-parity/generate-goldens.sh > decision-golden.json

set -uo pipefail

FIX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$FIX_DIR/../../../.." && pwd)"
LIB_DISP="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-w1c1-parity-$$
export MAX_RETRIES=3
export MAX_CONCURRENT=5

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }

# ---------------------------------------------------------------------------
# The pre-change gh stub. resolve_pr_for_issue / verify_pr_closes_issue emit
#   gh pr list --repo R --state open --json <fields> -q <expr>
# where <expr> does the close-linkage/branch resolution against the raw
# `closingIssuesReferences` objects. The six chp_pr_list sites emit
#   gh pr list --repo R --state open|all --json <fields> -q <expr>
# with the caller's body-mention SELECT already inline. In BOTH cases the stub
# runs the recorded -q expression through jq over the fixture JSON — that
# faithfully reproduces gh's own -q behavior (which is `jq -r`).
# ---------------------------------------------------------------------------
_MOCK_PR_LIST_JSON=""
gh() {
  local q_expr=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -q) q_expr="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ -n "$q_expr" && -n "$_MOCK_PR_LIST_JSON" ]]; then
    jq -r "$q_expr" <<<"$_MOCK_PR_LIST_JSON"
  fi
}
export -f gh

# shellcheck source=../../../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB_DISP"
set +e

# ---------------------------------------------------------------------------
# Fixtures for chp_find_pr_for_issue callers (resolve_pr_for_issue /
# verify_pr_closes_issue). The array shape mirrors gh's raw response, i.e.
# `closingIssuesReferences: [{number: N}, ...]` and `body` may be null.
# ---------------------------------------------------------------------------
FIX_CLOSE_LINK='[
  {"number":11,"headRefName":"fix/issue-274-noprog","closingIssuesReferences":[{"number":274}],"body":"Fixes #274\n- #273 — related","createdAt":"2026-06-01T00:00:00Z"},
  {"number":10,"headRefName":"feat/issue-273-ac","closingIssuesReferences":[{"number":273}],"body":"Closes #273","createdAt":"2026-06-01T01:00:00Z"}
]'
FIX_BRANCH='[
  {"number":11,"headRefName":"fix/issue-274-noprog","closingIssuesReferences":[],"body":"partial fix\n- #273 — related","createdAt":"2026-06-01T00:00:00Z"},
  {"number":10,"headRefName":"feat/issue-273-ac","closingIssuesReferences":[],"body":"partial fix for 273","createdAt":"2026-06-01T01:00:00Z"}
]'
FIX_XWIRE='[
  {"number":11,"headRefName":"fix/issue-274","closingIssuesReferences":[{"number":274}],"body":"Fixes #274\n- #273 — related","createdAt":"2026-06-01T00:00:00Z"},
  {"number":10,"headRefName":"feat/issue-273","closingIssuesReferences":[{"number":273}],"body":"Closes #273","createdAt":"2026-06-01T01:00:00Z"}
]'
FIX_NULLBODY='[
  {"number":1,"headRefName":"chore/unrelated","closingIssuesReferences":[],"body":null,"createdAt":"2026-06-01T00:00:00Z"},
  {"number":10,"headRefName":"feat/issue-273-ac","closingIssuesReferences":[{"number":273}],"body":"Closes #273","createdAt":"2026-06-01T01:00:00Z"}
]'
FIX_NOPR='[
  {"number":50,"headRefName":"chore/x","closingIssuesReferences":[{"number":999}],"body":"Closes #999","createdAt":"2026-06-01T00:00:00Z"}
]'
FIX_BOUNDARY='[
  {"number":60,"headRefName":"fix/issue-270-x","closingIssuesReferences":[{"number":270}],"body":"Closes #270 mentions #27 in passing","createdAt":"2026-06-01T00:00:00Z"}
]'
# 35-candidate set: one close-linked to #500, rest unrelated. Proves the >30
# completeness fix — the current leaf silently caps at gh's default --limit 30,
# so the close-linked PR MAY OR MAY NOT survive depending on ordering. We put the
# close-linked PR LAST in the array so a `--limit 30` truncation drops it (the
# regression driver). The pre-change code cannot fix this — the golden records
# whatever the pre-change code returns; test-w1c1-completeness.sh asserts the
# NEW code (post-change) returns the close-linked PR.
_gen_overlimit() {
  local out="[" i first=1
  for i in $(seq 1 34); do
    if [[ $first -eq 1 ]]; then first=0; else out+=","; fi
    out+="{\"number\":$((100+i)),\"headRefName\":\"chore/x-${i}\",\"closingIssuesReferences\":[],\"body\":\"unrelated\",\"createdAt\":\"2026-06-01T00:00:00Z\"}"
  done
  out+=",{\"number\":999,\"headRefName\":\"feat/issue-500-real\",\"closingIssuesReferences\":[{\"number\":500}],\"body\":\"Closes #500\",\"createdAt\":\"2026-06-01T01:00:00Z\"}"
  out+="]"
  printf '%s' "$out"
}
FIX_OVERLIMIT="$(_gen_overlimit)"

# ---------------------------------------------------------------------------
# Fixtures for the 6 chp_pr_list body-mention sites. Same PR-list shape but
# with the specific fields each caller passes: `body`, `number,body`,
# `createdAt,body`. We use ONE shared fixture with a rich mix so per-site
# decisions vary; the callers themselves slice down.
# ---------------------------------------------------------------------------
FIX_PRLIST='[
  {"number":100,"body":"unrelated","createdAt":"2026-06-01T00:00:00Z"},
  {"number":101,"body":null,"createdAt":"2026-06-01T00:30:00Z"},
  {"number":102,"body":"see #42 for context","createdAt":"2026-06-01T00:45:00Z"},
  {"number":103,"body":"resolves #425 boundary","createdAt":"2026-06-01T01:00:00Z"},
  {"number":104,"body":"related to #42","createdAt":"2026-06-01T02:00:00Z"},
  {"number":105,"body":"see #42","createdAt":"2026-06-01T00:15:00Z"}
]'
FIX_PRLIST_EMPTY='[]'
# One PR mentioning #42 at end-of-body (`#42$`), one at boundary (`#42 `).
FIX_PRLIST_BOUNDARY='[
  {"number":200,"body":"cross-refs #42","createdAt":"2026-06-01T00:00:00Z"},
  {"number":201,"body":"final ref: #42","createdAt":"2026-06-01T01:00:00Z"}
]'
# Null-body-only fixture: #148 hazard.
FIX_PRLIST_NULLBODY='[
  {"number":300,"body":null,"createdAt":"2026-06-01T00:00:00Z"},
  {"number":301,"body":"see #42","createdAt":"2026-06-01T01:00:00Z"}
]'

# ---------------------------------------------------------------------------
# Selectors mirroring EACH caller's inline SELECT (used to run the golden
# capture — these are the OLD bytes; the new callers will operate on the
# normalized array but MUST produce the same values).
#
# needs_open_pr_only (:434, autonomous-dev.sh) —
#   `[.[] | select(.body != null and ((.body | test("#N[^0-9]")) or (.body | test("#N$"))))] | length`
# PR_EXISTS (:774, autonomous-dev.sh) —
#   `[.[] | select(.body | test("#N[^0-9]") or test("#N$"))] | length`  (no null guard)
# _pr_created_at (:865, autonomous-dev.sh) —
#   `[.[] | select(.body != null and ((.body|test("#N[^0-9]")) or (.body|test("#N$"))))] | sort_by(.createdAt) | (.[0].createdAt // empty)`
# PR_NUM (:1079, autonomous-dev.sh) —
#   `[.[] | select(.body | test("#N[^0-9]") or test("#N$"))] | .[0].number // empty`
# lib-auth.sh :453 existing — same as PR_EXISTS shape (length).
# lib-auth.sh :605 pr_number — `[.[] | select(.body | test("#N[^0-9]") or test("#N$"))] | (.[0].number // empty)`
# ---------------------------------------------------------------------------

_sel_length_guarded() {
  local n="$1"
  jq -r "[.[] | select(.body != null and ((.body | test(\"#${n}[^0-9]\")) or (.body | test(\"#${n}\$\"))))] | length"
}
_sel_createdAt_earliest_guarded() {
  local n="$1"
  jq -r "[.[] | select(.body != null and ((.body|test(\"#${n}[^0-9]\")) or (.body|test(\"#${n}\$\"))))] | sort_by(.createdAt) | (.[0].createdAt // \"\")"
}
_sel_first_number_guarded() {
  local n="$1"
  jq -r "[.[] | select(.body != null and ((.body | test(\"#${n}[^0-9]\")) or (.body | test(\"#${n}\$\"))))] | .[0].number // \"\""
}

# ---------------------------------------------------------------------------
# Capture. Output is one big JSON object of decision-key → value. Values are
# scalars (number as int, string as "" when empty, or an array for jq errors).
# ---------------------------------------------------------------------------
declare -A G

# --- Linkage: resolve_pr_for_issue (echo PR .number or "") ---
capture_resolve() {
  local key="$1" fix="$2" issue="$3"
  _MOCK_PR_LIST_JSON="$fix"
  local out num
  out="$(resolve_pr_for_issue "$issue" "number,closingIssuesReferences,headRefName,body" 2>/dev/null)"
  num="$(jq -r '.number // ""' <<<"$out" 2>/dev/null || printf "")"
  G["linkage.resolve.$key"]="$num"
}

# --- Linkage: verify_pr_closes_issue (rc, 0 = accept, 1 = reject) ---
capture_verify() {
  local key="$1" fix="$2" pr="$3" issue="$4"
  _MOCK_PR_LIST_JSON="$fix"
  local rc
  verify_pr_closes_issue "$pr" "$issue" 2>/dev/null; rc=$?
  G["linkage.verify.$key"]="$rc"
}

# --- chp_pr_list site N: run the inline selector against the fixture ---
capture_site() {
  local key="$1" fix="$2" selector_fn="$3" n="$4"
  local out
  out="$($selector_fn "$n" <<<"$fix" 2>/dev/null)"
  G["prlist.$key"]="$out"
}

# Linkage decisions.
capture_resolve close-linkage-wins  "$FIX_CLOSE_LINK" 273
capture_resolve close-linkage-274   "$FIX_CLOSE_LINK" 274
capture_resolve branch-fallback     "$FIX_BRANCH"    273
capture_resolve cross-wired-273     "$FIX_XWIRE"     273
capture_resolve cross-wired-274     "$FIX_XWIRE"     274
capture_resolve null-body           "$FIX_NULLBODY"  273
capture_resolve no-pr               "$FIX_NOPR"      7
capture_resolve boundary            "$FIX_BOUNDARY"  27
capture_resolve overlimit-500       "$FIX_OVERLIMIT" 500

# Verify guard.
capture_verify close-linked-274-274 "$FIX_CLOSE_LINK" 11 274
capture_verify close-linked-273-273 "$FIX_CLOSE_LINK" 10 273
capture_verify foreign-11-273       "$FIX_CLOSE_LINK" 11 273
capture_verify branch-274-274       "$FIX_BRANCH"     11 274

# chp_pr_list body-mention decisions (per site).
# ---
# All 6 sites use the same body-mention SELECT `.body|test("#N[^0-9]") or test("#N$")`.
# Two of six (needs_open_pr_only :434, _pr_created_at :865) had the `.body != null`
# guard already; the other four (:774, :1079, lib-auth.sh :453/:605) did NOT — the
# #148 hazard class. Under the new normalized shape body:null → body:"" always, so
# ALL six sites emit the guarded decision. Goldens record the guarded/normalized
# outputs (the CORRECT decisions post-#148-fix) — the parity test asserts every
# site's post-rewrite output matches these, proving the drop-guard change is a
# fix, not a regression.
capture_site needs_open_pr_only.rich       "$FIX_PRLIST"          _sel_length_guarded 42
capture_site needs_open_pr_only.empty      "$FIX_PRLIST_EMPTY"    _sel_length_guarded 42
capture_site needs_open_pr_only.boundary   "$FIX_PRLIST_BOUNDARY" _sel_length_guarded 42
capture_site needs_open_pr_only.nullbody   "$FIX_PRLIST_NULLBODY" _sel_length_guarded 42

capture_site pr_exists.rich       "$FIX_PRLIST"          _sel_length_guarded 42
capture_site pr_exists.empty      "$FIX_PRLIST_EMPTY"    _sel_length_guarded 42
capture_site pr_exists.boundary   "$FIX_PRLIST_BOUNDARY" _sel_length_guarded 42
capture_site pr_exists.nullbody   "$FIX_PRLIST_NULLBODY" _sel_length_guarded 42

capture_site pr_created_at.rich   "$FIX_PRLIST"          _sel_createdAt_earliest_guarded 42
capture_site pr_created_at.empty  "$FIX_PRLIST_EMPTY"    _sel_createdAt_earliest_guarded 42
capture_site pr_created_at.nullbody "$FIX_PRLIST_NULLBODY" _sel_createdAt_earliest_guarded 42

capture_site pr_num.rich          "$FIX_PRLIST"          _sel_first_number_guarded 42
capture_site pr_num.empty         "$FIX_PRLIST_EMPTY"    _sel_first_number_guarded 42
capture_site pr_num.boundary      "$FIX_PRLIST_BOUNDARY" _sel_first_number_guarded 42
capture_site pr_num.nullbody      "$FIX_PRLIST_NULLBODY" _sel_first_number_guarded 42

capture_site lib_auth_existing.rich       "$FIX_PRLIST"          _sel_length_guarded 42
capture_site lib_auth_existing.empty      "$FIX_PRLIST_EMPTY"    _sel_length_guarded 42
capture_site lib_auth_existing.nullbody   "$FIX_PRLIST_NULLBODY" _sel_length_guarded 42
capture_site lib_auth_pr_number.rich      "$FIX_PRLIST"          _sel_first_number_guarded 42
capture_site lib_auth_pr_number.empty     "$FIX_PRLIST_EMPTY"    _sel_first_number_guarded 42
capture_site lib_auth_pr_number.nullbody  "$FIX_PRLIST_NULLBODY" _sel_first_number_guarded 42

# Emit JSON with sorted keys for stable diffs.
{
  printf '{\n'
  local_first=1
  for k in $(printf '%s\n' "${!G[@]}" | sort); do
    if [[ $local_first -eq 1 ]]; then local_first=0; else printf ',\n'; fi
    v="${G[$k]}"
    # Numeric-only values → bare number; empty → ""; everything else → quoted string.
    if [[ "$v" =~ ^-?[0-9]+$ ]]; then
      printf '  "%s": %s' "$k" "$v"
    else
      # jq-escape the string.
      esc="$(jq -Rn --arg s "$v" '$s')"
      printf '  "%s": %s' "$k" "$esc"
    fi
  done
  printf '\n}\n'
}
